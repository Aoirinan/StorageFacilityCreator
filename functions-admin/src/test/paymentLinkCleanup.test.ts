import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import {
  PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION,
  PUBLIC_PAYMENT_LINKS_COLLECTION,
} from '@sfc/functions-shared/stripe/completePublicLinkPayment';
import { STRIPE_WEBHOOK_REFUSALS_COLLECTION } from '@sfc/functions-shared/stripe/webhookRefusals';
import { FakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import { FACILITY_KEYED_COLLECTIONS } from '../facilityPurge';
import { PURGE_ROOT_COLLECTIONS } from '../superAdminPlatformPurge';

type Report = { paymentLinks: Array<Record<string, unknown>> };
type SessionsApi = {
  retrieve(id: string, params: unknown, options: { stripeAccount?: string }): Promise<unknown>;
  expire(id: string, params: unknown, options: { stripeAccount?: string }): Promise<unknown>;
  list?(params: Record<string, unknown>, options: { stripeAccount?: string }): Promise<unknown>;
};
type FakeStripeApi = {
  checkout: { sessions: SessionsApi };
  paymentIntents?: { search(params: Record<string, unknown>, options: { stripeAccount?: string }): Promise<unknown> };
};

// The ops script is plain CommonJS outside src/; load it the way `npm run security:cleanup` does.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const cleanup = require('../../scripts/security-hardening-cleanup.cjs') as {
  rotatedLinkData: (
    current: Record<string, unknown>,
    replacementToken: string,
    rotatedFrom: string,
    rotatedAt: unknown,
  ) => Record<string, unknown>;
  rotatePendingPaymentLinks: (deps: {
    db: admin.firestore.Firestore;
    stripe: FakeStripeApi | null;
    apply: boolean;
    report: Report;
    fieldValue: unknown;
    newToken?: () => string;
  }) => Promise<void>;
};

test('platform purge deletes payment links, their exception records and Stripe refusals', () => {
  const purged: readonly string[] = PURGE_ROOT_COLLECTIONS;
  assert.ok(purged.includes(PUBLIC_PAYMENT_LINKS_COLLECTION));
  // Tenant ids, amounts and connected-account ids: customer data like the links.
  assert.ok(purged.includes(PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION));
  assert.ok(purged.includes(STRIPE_WEBHOOK_REFUSALS_COLLECTION));
});

test('deleting one facility deletes its link exceptions, Stripe refusals and processed-event marks too', () => {
  const keyed: readonly string[] = FACILITY_KEYED_COLLECTIONS;
  // Each carries facilityId and tenant ids, outside the facility's subtree.
  assert.ok(keyed.includes(PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION));
  assert.ok(keyed.includes(STRIPE_WEBHOOK_REFUSALS_COLLECTION));
  assert.ok(keyed.includes('stripeWebhookEvents'));
});

test('online move-in payment records go with their facility, and with a platform purge', () => {
  // Tenant ids and amounts, and refunds or disputes the webhook recorded on
  // a move-in payment that never completed a move-in. The paid checkouts the
  // sweep has still to settle name the facility, account and amount too.
  for (const collection of ['publicMoveInPayments', 'publicMoveInPaidCheckouts']) {
    assert.ok((FACILITY_KEYED_COLLECTIONS as readonly string[]).includes(collection), collection);
    assert.ok((PURGE_ROOT_COLLECTIONS as readonly string[]).includes(collection), collection);
  }
});

test('a rotated payment link keeps the link but not the old token\'s checkout session', () => {
  const current = {
    facilityId: 'f1',
    tenantId: 't1',
    amount: 80,
    description: 'October rent',
    token: 'legacy-token',
    status: 'pending',
    expiresAt: 'later',
    checkoutSessionId: 'cs_live_old',
    checkoutSessionIds: ['cs_live_old'],
    checkoutAttempt: 2,
    checkoutExpiresAt: 'soon',
  };

  const rotated = cleanup.rotatedLinkData(current, 'a'.repeat(48), 'legacy-token', 'now');

  assert.deepEqual(rotated, {
    facilityId: 'f1',
    tenantId: 't1',
    amount: 80,
    description: 'October rent',
    token: 'a'.repeat(48),
    status: 'pending',
    expiresAt: 'later',
    rotatedFrom: 'legacy-token',
    rotatedAt: 'now',
  });
  // The source document is left as it was (it is revoked separately).
  assert.equal(current.checkoutSessionId, 'cs_live_old');
});

// --- rotating links against Stripe ------------------------------------------

const ACCOUNT = 'acct_facility1';
const NEW_TOKEN = 'b'.repeat(48);

type FakeSession = { status: string; payment_status: string };

/**
 * Sessions on the facility's account ([account], ACCOUNT by default); a
 * lookup on any other account misses. [lookupError] makes every lookup fail
 * that way instead.
 */
function fakeStripe(
  sessions: Record<string, FakeSession>,
  failExpire = false,
  { account = ACCOUNT, lookupError }: { account?: string; lookupError?: Error } = {},
) {
  const calls: Array<[string, string, string | undefined]> = [];
  const api: SessionsApi = {
    async retrieve(id, _params, options) {
      calls.push(['retrieve', id, options.stripeAccount]);
      if (lookupError) throw lookupError;
      const found = options.stripeAccount === account ? sessions[id] : undefined;
      if (!found) throw Object.assign(new Error(`No such checkout.session: '${id}'`), { code: 'resource_missing', statusCode: 404 });
      return { id, ...found };
    },
    async expire(id, _params, options) {
      calls.push(['expire', id, options.stripeAccount]);
      if (failExpire) throw new Error('Only Checkout Sessions with a status of open can be expired.');
      sessions[id] = { status: 'expired', payment_status: 'unpaid' };
      return { id, status: 'expired' };
    },
  };
  return { stripe: { checkout: { sessions: api } }, calls };
}

function setupLinks(link: Record<string, unknown>) {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1', { stripeConnectAccountId: ACCOUNT });
  fake.seed('publicPaymentLinks/legacy-token', {
    facilityId: 'f1',
    tenantId: 't1',
    amount: 80,
    status: 'pending',
    token: 'legacy-token',
    ...link,
  });
  return fake;
}

async function rotate(fake: FakeFirestore, stripe: FakeStripeApi | null, apply: boolean) {
  const report: Report = { paymentLinks: [] };
  await cleanup.rotatePendingPaymentLinks({
    db: fake.firestore(),
    stripe,
    apply,
    report,
    fieldValue: admin.firestore.FieldValue,
    newToken: () => NEW_TOKEN,
  });
  return report.paymentLinks;
}

test('a link whose old session was paid but not yet marked paid is not rotated', async () => {
  const fake = setupLinks({ checkoutSessionId: 'cs_2', checkoutSessionIds: ['cs_1', 'cs_2'] });
  const { stripe, calls } = fakeStripe({
    cs_1: { status: 'expired', payment_status: 'unpaid' },
    cs_2: { status: 'complete', payment_status: 'paid' },
  });

  const links = await rotate(fake, stripe, true);

  // Before: rotated anyway, and the new link offered a second Pay Now.
  assert.equal(links[0].action, 'skipped');
  assert.equal(links[0].reason, 'session_completed');
  assert.equal(links[0].sessionId, 'cs_2');
  assert.deepEqual(fake.writes, []);
  assert.equal(calls.some(([op]) => op === 'expire'), false);
  assert.equal(fake.read('publicPaymentLinks/legacy-token')!.status, 'pending');
});

test('an open old session is expired on the facility\'s account before the link is rotated', async () => {
  const fake = setupLinks({ checkoutSessionId: 'cs_2', checkoutSessionIds: ['cs_1', 'cs_2'] });
  const { stripe, calls } = fakeStripe({
    cs_1: { status: 'expired', payment_status: 'unpaid' },
    cs_2: { status: 'open', payment_status: 'unpaid' },
  });

  const links = await rotate(fake, stripe, true);

  assert.equal(links[0].action, 'rotated');
  assert.deepEqual(links[0].expiredSessionIds, ['cs_2']);
  assert.deepEqual(calls, [
    ['retrieve', 'cs_1', ACCOUNT],
    ['retrieve', 'cs_2', ACCOUNT],
    ['expire', 'cs_2', ACCOUNT],
  ]);
  assert.equal(fake.read('publicPaymentLinks/legacy-token')!.status, 'revoked');
  const rotated = fake.read(`publicPaymentLinks/${NEW_TOKEN}`)!;
  assert.equal(rotated.status, 'pending');
  assert.equal(rotated.checkoutSessionId, undefined);
});

test('a dry run looks the sessions up but changes nothing on Stripe or in Firestore', async () => {
  const fake = setupLinks({ checkoutSessionId: 'cs_1', checkoutSessionIds: ['cs_1'] });
  const { stripe, calls } = fakeStripe({ cs_1: { status: 'open', payment_status: 'unpaid' } });

  const links = await rotate(fake, stripe, false);

  assert.equal(links[0].action, 'would_rotate');
  assert.deepEqual(links[0].expiredSessionIds, ['cs_1']);
  assert.deepEqual(calls, [['retrieve', 'cs_1', ACCOUNT]]);
  assert.deepEqual(fake.writes, []);
});

test('a link is left alone when its sessions cannot be checked or expired', async () => {
  // No Stripe key given to the script.
  let fake = setupLinks({ checkoutSessionIds: ['cs_1'] });
  let links = await rotate(fake, null, true);
  assert.equal(links[0].reason, 'stripe_not_checked');
  assert.deepEqual(fake.writes, []);

  // The session was paid between the lookup and the expire.
  fake = setupLinks({ checkoutSessionIds: ['cs_1'] });
  const failing = fakeStripe({ cs_1: { status: 'open', payment_status: 'unpaid' } }, true);
  links = await rotate(fake, failing.stripe, true);
  assert.equal(links[0].reason, 'session_expire_failed');
  assert.deepEqual(fake.writes, []);

  // The facility has no connected account to look the session up on.
  fake = setupLinks({ checkoutSessionIds: ['cs_1'] });
  fake.seed('facilities/f1', { stripeConnectAccountId: null });
  links = await rotate(fake, fakeStripe({}).stripe, true);
  assert.equal(links[0].reason, 'facility_has_no_stripe_account');
  assert.deepEqual(fake.writes, []);
});

// --- legacy links with no recorded session ----------------------------------

type ListedSession = {
  id: string;
  status: string;
  payment_status: string;
  metadata?: Record<string, string>;
  payment_intent?: string | null;
  amount_total?: number;
  currency?: string;
};
type SearchablePaymentIntent = { id: string; status: string; amount: number; currency: string; metadata: Record<string, string> };

/**
 * Stripe for a link that recorded no session: [listed] sessions and
 * [searchable] PaymentIntents per account, found only by listing and by
 * metadata search, as the real API allows. [failSearch] makes the search fail.
 */
function tokenSearchStripe(
  listed: Record<string, ListedSession[]>,
  searchable: Record<string, SearchablePaymentIntent[]> = {},
  { failSearch, pageSize = 100 }: { failSearch?: Error; pageSize?: number } = {},
) {
  const calls: Array<[string, string | undefined, Record<string, unknown>?]> = [];
  const byId = new Map<string, ListedSession & { account: string }>();
  for (const [account, sessions] of Object.entries(listed)) for (const s of sessions) byId.set(s.id, { ...s, account });
  const stripe: FakeStripeApi = {
    checkout: {
      sessions: {
        async retrieve(id, _params, options) {
          calls.push(['retrieve', options.stripeAccount]);
          const found = byId.get(id);
          if (!found || found.account !== options.stripeAccount) {
            throw Object.assign(new Error(`No such checkout.session: '${id}'`), { code: 'resource_missing', statusCode: 404 });
          }
          return found;
        },
        async expire(id, _params, options) {
          calls.push(['expire', options.stripeAccount, { id }]);
          const found = byId.get(id);
          if (found) found.status = 'expired';
          return { id, status: 'expired' };
        },
        async list(params, options) {
          calls.push(['list', options.stripeAccount, params]);
          if (failSearch) throw failSearch;
          const all = listed[options.stripeAccount ?? ''] ?? [];
          const after = params.starting_after ? all.findIndex((s) => s.id === params.starting_after) + 1 : 0;
          const data = all.slice(after, after + pageSize);
          return { data, has_more: after + pageSize < all.length };
        },
      },
    },
    paymentIntents: {
      async search(params, options) {
        calls.push(['search', options.stripeAccount, params]);
        if (failSearch) throw failSearch;
        const token = /paymentLinkToken'\]:'(.*)'$/.exec(String(params.query))?.[1];
        return { data: (searchable[options.stripeAccount ?? ''] ?? []).filter((pi) => pi.metadata.paymentLinkToken === token) };
      },
    },
  };
  return { stripe, calls };
}

const legacySession = (id: string, overrides: Partial<ListedSession> = {}): ListedSession => ({
  id,
  status: 'complete',
  payment_status: 'paid',
  metadata: { type: 'public_payment_link', paymentLinkToken: 'legacy-token', facilityId: 'f1', tenantId: 't1' },
  payment_intent: `pi_for_${id}`,
  amount_total: 8000,
  currency: 'usd',
  ...overrides,
});

test('a legacy link with no recorded session is not rotated without asking Stripe', async () => {
  const fake = setupLinks({});

  const links = await rotate(fake, null, true);

  // Before: rotated, so a link paid but never marked became a fresh Pay Now.
  assert.equal(links[0].action, 'skipped');
  assert.equal(links[0].reason, 'stripe_not_checked');
  assert.deepEqual(fake.writes, []);
});

test('a legacy link Stripe shows was paid is marked paid, not rotated, and staff are asked to check the ledger', async () => {
  const fake = setupLinks({});
  const { stripe } = tokenSearchStripe({
    [ACCOUNT]: [
      legacySession('cs_other', { metadata: { paymentLinkToken: 'another-token' } }),
      legacySession('cs_paid'),
    ],
  });

  const links = await rotate(fake, stripe, true);

  assert.equal(links[0].action, 'marked_paid');
  assert.equal(links[0].checkoutSessionId, 'cs_paid');
  const link = fake.read('publicPaymentLinks/legacy-token')!;
  assert.equal(link.status, 'paid');
  assert.equal(link.paymentIntentId, 'pi_for_cs_paid');
  assert.equal(link.paidVia, 'security_cleanup');
  assert.equal(link.needsLedgerCheck, true);
  assert.equal(fake.read(`publicPaymentLinks/${NEW_TOKEN}`), undefined);
  const exception = fake.read('publicPaymentLinkExceptions/cs_paid')!;
  assert.equal(exception.reason, 'untracked_session');
  assert.equal(exception.amountCents, 8000);
  const notice = fake.read('facilities/f1/Notifications/publicLinkException_cs_paid')!;
  assert.match(String(notice.message), /Check the tenant ledger shows it/);
});

test('a dry run reports a paid legacy link as would_mark_paid and writes nothing', async () => {
  const fake = setupLinks({});
  const { stripe, calls } = tokenSearchStripe({ [ACCOUNT]: [legacySession('cs_paid')] });

  const links = await rotate(fake, stripe, false);

  assert.equal(links[0].action, 'would_mark_paid');
  assert.deepEqual(fake.writes, []);
  assert.equal(calls.some(([op]) => op === 'expire'), false);
});

test('a legacy link paid through a PaymentIntent the session listing missed is marked paid', async () => {
  const fake = setupLinks({});
  const { stripe } = tokenSearchStripe(
    { [ACCOUNT]: [] },
    { [ACCOUNT]: [{ id: 'pi_found', status: 'succeeded', amount: 8000, currency: 'usd', metadata: { paymentLinkToken: 'legacy-token' } }] },
  );

  const links = await rotate(fake, stripe, true);

  assert.equal(links[0].action, 'marked_paid');
  assert.equal(fake.read('publicPaymentLinks/legacy-token')!.paymentIntentId, 'pi_found');
  assert.ok(fake.read('publicPaymentLinkExceptions/pi_found'));
});

test('a legacy link paid on the facility\'s previous account is found there', async () => {
  const fake = setupLinks({});
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_new', stripeConnectPreviousAccountId: ACCOUNT });
  const { stripe, calls } = tokenSearchStripe({ acct_new: [], [ACCOUNT]: [legacySession('cs_paid')] });

  const links = await rotate(fake, stripe, true);

  assert.equal(links[0].action, 'marked_paid');
  assert.equal(links[0].account, ACCOUNT);
  assert.deepEqual([...new Set(calls.filter(([op]) => op === 'list').map(([, account]) => account))], ['acct_new', ACCOUNT]);
});

test('a legacy link is left alone when the search for its token cannot be completed', async () => {
  // Stripe fails.
  let fake = setupLinks({});
  let { stripe } = tokenSearchStripe({}, {}, { failSearch: Object.assign(new Error('Stripe is down'), { statusCode: 500 }) });
  let links = await rotate(fake, stripe, true);
  assert.equal(links[0].action, 'skipped');
  assert.equal(links[0].reason, 'token_search_failed');
  assert.deepEqual(fake.writes, []);

  // More sessions than it lists.
  fake = setupLinks({});
  const many = Array.from({ length: 60 }, (_, i) => legacySession(`cs_${i}`, { metadata: { paymentLinkToken: 'x' } }));
  ({ stripe } = tokenSearchStripe({ [ACCOUNT]: many }, {}, { pageSize: 1 }));
  links = await rotate(fake, stripe, true);
  assert.equal(links[0].reason, 'too_many_sessions_to_search');
  assert.deepEqual(fake.writes, []);

  // No account to search.
  fake = setupLinks({});
  fake.seed('facilities/f1', { stripeConnectAccountId: null });
  links = await rotate(fake, tokenSearchStripe({}).stripe, true);
  assert.equal(links[0].reason, 'facility_has_no_stripe_account');
  assert.deepEqual(fake.writes, []);
});

test('a legacy link paid for a different amount, twice, or still settling is left for a person', async () => {
  const cases: Array<[string, ListedSession[]]> = [
    ['paid_amount_differs', [legacySession('cs_paid', { amount_total: 5000 })]],
    ['paid_more_than_once', [legacySession('cs_a'), legacySession('cs_b')]],
    ['session_completed', [legacySession('cs_debit', { payment_status: 'unpaid' })]],
  ];
  for (const [reason, sessions] of cases) {
    const fake = setupLinks({});
    const links = await rotate(fake, tokenSearchStripe({ [ACCOUNT]: sessions }).stripe, true);
    assert.equal(links[0].action, 'skipped', reason);
    assert.equal(links[0].reason, reason);
    assert.deepEqual(fake.writes, [], reason);
  }
});

test('a legacy link with only an unpaid open session found by its token has it expired, then is rotated', async () => {
  const fake = setupLinks({});
  const { stripe, calls } = tokenSearchStripe({
    [ACCOUNT]: [legacySession('cs_open', { status: 'open', payment_status: 'unpaid' }), legacySession('cs_gone', { status: 'expired', payment_status: 'unpaid' })],
  });

  const links = await rotate(fake, stripe, true);

  assert.equal(links[0].action, 'rotated');
  assert.equal(links[0].searchedByToken, true);
  assert.deepEqual(links[0].expiredSessionIds, ['cs_open']);
  assert.deepEqual(calls.filter(([op]) => op === 'expire'), [['expire', ACCOUNT, { id: 'cs_open' }]]);
  assert.equal(fake.read('publicPaymentLinks/legacy-token')!.status, 'revoked');
});

test('a recorded session found on none of the facility\'s accounts is not taken as "no session"', async () => {
  const fake = setupLinks({ checkoutSessionIds: ['cs_lost'] });
  const { stripe } = fakeStripe({});

  const links = await rotate(fake, stripe, true);

  // Before: missing everywhere read as nothing to pay, and the link was rotated.
  assert.equal(links[0].action, 'skipped');
  assert.equal(links[0].reason, 'session_not_found');
  assert.deepEqual(fake.writes, []);
});

test('a link whose checkout changed after it was checked is not rotated', async () => {
  const fake = setupLinks({ checkoutSessionIds: ['cs_1'], checkoutAttempt: 1 });
  const { stripe } = fakeStripe({ cs_1: { status: 'expired', payment_status: 'unpaid' } });
  // The tenant opens the old link and starts a second checkout while the script runs.
  const retrieve = stripe.checkout.sessions.retrieve.bind(stripe.checkout.sessions);
  stripe.checkout.sessions.retrieve = async (id, params, options) => {
    const result = await retrieve(id, params, options);
    fake.seed('publicPaymentLinks/legacy-token', {
      ...fake.read('publicPaymentLinks/legacy-token')!,
      checkoutSessionId: 'cs_2',
      checkoutSessionIds: ['cs_1', 'cs_2'],
      checkoutAttempt: 2,
    });
    return result;
  };

  const links = await rotate(fake, stripe, true);

  // Before: only the status was checked again, and cs_2 was dropped unchecked.
  assert.equal(links[0].action, 'skipped');
  assert.equal(links[0].reason, 'link_checkout_changed');
  assert.equal(fake.read('publicPaymentLinks/legacy-token')!.status, 'pending');
  assert.equal(fake.read(`publicPaymentLinks/${NEW_TOKEN}`), undefined);
});

test('a current 48-character token is never rotated', async () => {
  const fake = new FakeFirestore();
  fake.seed(`publicPaymentLinks/${'c'.repeat(48)}`, { facilityId: 'f1', status: 'pending' });

  assert.deepEqual(await rotate(fake, null, true), []);
  assert.deepEqual(fake.writes, []);
});

test('a complete session is not rotated even before its payment has settled', async () => {
  // A bank debit completes the session with payment_status 'unpaid' and
  // pays later: rotating then offers the tenant a second Pay Now.
  const fake = setupLinks({ checkoutSessionIds: ['cs_1'] });
  const { stripe } = fakeStripe({ cs_1: { status: 'complete', payment_status: 'unpaid' } });

  const links = await rotate(fake, stripe, true);

  assert.equal(links[0].action, 'skipped');
  assert.equal(links[0].reason, 'session_completed');
  assert.deepEqual(fake.writes, []);
});

test('a session lookup that fails for any reason but "no such session" leaves the link alone', async () => {
  // A Stripe outage or a revoked key is not a missing session: the session
  // may well be paid.
  const fake = setupLinks({ checkoutSessionIds: ['cs_1'] });
  const outage = Object.assign(new Error('An error occurred with our connection to Stripe.'), {
    type: 'StripeConnectionError',
    statusCode: 500,
  });
  const { stripe, calls } = fakeStripe({ cs_1: { status: 'complete', payment_status: 'paid' } }, false, {
    lookupError: outage,
  });

  const links = await rotate(fake, stripe, true);

  assert.equal(links[0].action, 'skipped');
  assert.equal(links[0].reason, 'session_lookup_failed');
  assert.equal(links[0].sessionId, 'cs_1');
  assert.equal(calls.some(([op]) => op === 'expire'), false);
  assert.deepEqual(fake.writes, []);
});

test('on a reconnected facility a link paid on its previous account is not rotated', async () => {
  // Started before the owner reconnected Stripe: the session lives on the old account.
  const fake = setupLinks({ checkoutSessionIds: ['cs_1'] });
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_new', stripeConnectPreviousAccountId: ACCOUNT });
  const { stripe, calls } = fakeStripe({ cs_1: { status: 'complete', payment_status: 'paid' } });

  const links = await rotate(fake, stripe, true);

  // Before: missing on acct_new read as "no session", and the paid link was rotated.
  assert.equal(links[0].action, 'skipped');
  assert.equal(links[0].reason, 'session_completed');
  assert.equal(links[0].account, ACCOUNT);
  assert.deepEqual(calls, [
    ['retrieve', 'cs_1', 'acct_new'],
    ['retrieve', 'cs_1', ACCOUNT],
  ]);
  assert.deepEqual(fake.writes, []);
});

test('on a reconnected facility an open session on the previous account is expired there', async () => {
  const fake = setupLinks({ checkoutSessionIds: ['cs_1'] });
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_new', stripeConnectPreviousAccountId: ACCOUNT });
  const { stripe, calls } = fakeStripe({ cs_1: { status: 'open', payment_status: 'unpaid' } });

  const links = await rotate(fake, stripe, true);

  assert.equal(links[0].action, 'rotated');
  assert.deepEqual(links[0].expiredSessionIds, ['cs_1']);
  assert.deepEqual(calls.slice(-1), [['expire', 'cs_1', ACCOUNT]]);
  assert.equal(fake.read('publicPaymentLinks/legacy-token')!.status, 'revoked');
});
