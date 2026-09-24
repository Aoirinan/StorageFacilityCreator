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
    stripe: { checkout: { sessions: SessionsApi } } | null;
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

test('deleting one facility deletes its link exceptions and Stripe refusals too', () => {
  const keyed: readonly string[] = FACILITY_KEYED_COLLECTIONS;
  // Both carry facilityId, tenant ids and amounts, outside the facility's subtree.
  assert.ok(keyed.includes(PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION));
  assert.ok(keyed.includes(STRIPE_WEBHOOK_REFUSALS_COLLECTION));
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

/** Sessions on the facility's account; a lookup on any other account misses. */
function fakeStripe(sessions: Record<string, { status: string; payment_status: string }>, failExpire = false) {
  const calls: Array<[string, string, string | undefined]> = [];
  const api: SessionsApi = {
    async retrieve(id, _params, options) {
      calls.push(['retrieve', id, options.stripeAccount]);
      const found = options.stripeAccount === ACCOUNT ? sessions[id] : undefined;
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

async function rotate(fake: FakeFirestore, stripe: { checkout: { sessions: SessionsApi } } | null, apply: boolean) {
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

test('a link that never started a checkout is rotated, with or without Stripe', async () => {
  const fake = setupLinks({});

  const links = await rotate(fake, null, true);

  assert.equal(links[0].action, 'rotated');
  assert.equal(fake.read('publicPaymentLinks/legacy-token')!.status, 'revoked');
  assert.equal(fake.read(`publicPaymentLinks/${NEW_TOKEN}`)!.rotatedFrom, 'legacy-token');
});

test('a current 48-character token is never rotated', async () => {
  const fake = new FakeFirestore();
  fake.seed(`publicPaymentLinks/${'c'.repeat(48)}`, { facilityId: 'f1', status: 'pending' });

  assert.deepEqual(await rotate(fake, null, true), []);
  assert.deepEqual(fake.writes, []);
});
