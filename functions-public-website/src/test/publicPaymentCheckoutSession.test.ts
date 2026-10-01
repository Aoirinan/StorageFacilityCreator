import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import { completePublicLinkPayment } from '@sfc/functions-shared';
import { FakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import {
  CHECKOUT_SESSION_TTL_SECONDS,
  confirmPublicLinkCheckout,
  getOrCreatePublicLinkCheckout,
  PublicLinkCheckoutResult,
} from '../publicPaymentCheckoutSession';
import { FakeCheckoutSessions } from './support/fakeCheckoutSessions';

const TOKEN = 'c'.repeat(48);
const ACCOUNT = 'acct_facility1';
const LINK_PATH = `publicPaymentLinks/${TOKEN}`;
const APP_URL = 'https://app.example.test';

function setup(link: Record<string, unknown> = {}) {
  const stripe = new FakeCheckoutSessions();
  const fake = new FakeFirestore();
  fake.now = () => stripe.now;
  fake.seed('facilities/f1', {
    name: 'Test Storage',
    stripeConnectAccountId: ACCOUNT,
    stripeConnectOnboardingComplete: true,
  });
  fake.seed('facilities/f1/tenants/t1', { name: 'Pat Tenant', email: 'pat@example.test' });
  fake.seed(LINK_PATH, {
    facilityId: 'f1',
    tenantId: 't1',
    amount: 80,
    description: 'October rent',
    token: TOKEN,
    status: 'pending',
    paymentIntentId: null,
    paidAt: null,
    expiresAt: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z')),
    ...link,
  });
  const deps = { db: fake.firestore(), sessions: stripe.api(), appUrl: APP_URL, now: () => stripe.now };
  return { stripe, fake, deps };
}

function checkoutOf(result: PublicLinkCheckoutResult) {
  assert.equal(result.kind, 'checkout');
  return result as Extract<PublicLinkCheckoutResult, { kind: 'checkout' }>;
}

async function rejectsWith(promise: Promise<unknown>, code: string): Promise<void> {
  await assert.rejects(promise, (error: unknown) => {
    assert.equal((error as { code?: string }).code, code);
    return true;
  });
}

test('the session is created on the facility account with PaymentIntent metadata the payment handler reads', async () => {
  const { stripe, fake, deps } = setup();

  const result = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.equal(stripe.createCalls.length, 1);
  const { params, options } = stripe.createCalls[0];
  assert.equal(options.stripeAccount, ACCOUNT);
  assert.equal(options.idempotencyKey, `link_${TOKEN}_1`);
  // Without this the payment_intent.succeeded handler finds no facilityId/tenantId
  // and the tenant's payment is never recorded.
  assert.deepEqual(params.payment_intent_data?.metadata, {
    facilityId: 'f1',
    tenantId: 't1',
    type: 'public_payment_link',
    paymentLinkToken: TOKEN,
    sfcKind: 'tenant_link',
  });
  assert.deepEqual(params.metadata, {
    facilityId: 'f1',
    tenantId: 't1',
    type: 'public_payment_link',
    paymentLinkToken: TOKEN,
  });
  assert.equal(params.expires_at, Math.floor(stripe.nowMs / 1000) + CHECKOUT_SESSION_TTL_SECONDS);
  assert.equal(params.line_items?.[0]?.price_data?.unit_amount, 8000);
  assert.equal(params.customer_email, 'pat@example.test');
  assert.equal(
    params.success_url,
    `${APP_URL}/?status=success&session_id={CHECKOUT_SESSION_ID}#/pay?token=${TOKEN}`,
  );

  const link = fake.read(LINK_PATH)!;
  assert.equal(link.checkoutSessionId, result.sessionId);
  assert.deepEqual(link.checkoutSessionIds, [result.sessionId]);
  assert.equal(link.checkoutAttempt, 1);
  assert.equal(link.status, 'pending');
});

test('clicking Pay Now again hands back the same open session', async () => {
  const { stripe, deps } = setup();

  const first = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  stripe.advance(10 * 60 * 1000);
  const second = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.equal(second.sessionId, first.sessionId);
  assert.equal(second.checkoutUrl, first.checkoutUrl);
  assert.equal(second.reused, true);
  assert.deepEqual(stripe.created(), [first.sessionId]);
});

test('simultaneous clicks (double tap, two tabs) produce one payable session', async () => {
  const { stripe, fake, deps } = setup();

  const results = (await Promise.all([
    getOrCreatePublicLinkCheckout(TOKEN, deps),
    getOrCreatePublicLinkCheckout(TOKEN, deps),
    getOrCreatePublicLinkCheckout(TOKEN, deps),
  ])).map(checkoutOf);

  const ids = new Set(results.map((r) => r.sessionId));
  assert.equal(ids.size, 1);
  assert.equal(stripe.created().length, 1);
  assert.equal(stripe.payable().length, 1);
  // Every create for the attempt used the same key, so Stripe returned the same session.
  assert.ok(stripe.createCalls.every((c) => c.options.idempotencyKey === `link_${TOKEN}_1`));
  assert.deepEqual(fake.read(LINK_PATH)!.checkoutSessionIds, [...ids]);
});

test('an expired session is replaced by a new attempt, never alongside it', async () => {
  const { stripe, fake, deps } = setup();

  const first = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  stripe.advance((CHECKOUT_SESSION_TTL_SECONDS + 60) * 1000);
  const second = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.notEqual(second.sessionId, first.sessionId);
  assert.equal(stripe.createCalls[stripe.createCalls.length - 1].options.idempotencyKey, `link_${TOKEN}_2`);
  assert.deepEqual(stripe.payable(), [second.sessionId]);
  const link = fake.read(LINK_PATH)!;
  assert.equal(link.checkoutSessionId, second.sessionId);
  assert.deepEqual(link.checkoutSessionIds, [first.sessionId, second.sessionId]);
});

test('a session about to lapse is expired before its replacement is made', async () => {
  const { stripe, deps } = setup();

  const first = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  stripe.advance((CHECKOUT_SESSION_TTL_SECONDS - 60) * 1000);
  const second = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.notEqual(second.sessionId, first.sessionId);
  assert.deepEqual(stripe.expireCalls, [first.sessionId]);
  assert.deepEqual(stripe.payable(), [second.sessionId]);
});

test('once the tenant has paid, Pay Now marks the link paid and offers no new checkout', async () => {
  const { stripe, fake, deps } = setup();

  const first = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  stripe.pay(first.sessionId, 'pi_paid');
  // The original tab's button, before any webhook has arrived.
  const again = await getOrCreatePublicLinkCheckout(TOKEN, deps);
  const afterThat = await getOrCreatePublicLinkCheckout(TOKEN, deps);

  assert.deepEqual(again, { kind: 'paid' });
  assert.deepEqual(afterThat, { kind: 'paid' });
  assert.equal(stripe.created().length, 1);
  const link = fake.read(LINK_PATH)!;
  assert.equal(link.status, 'paid');
  assert.equal(link.paymentIntentId, 'pi_paid');
  assert.equal(link.paidVia, 'checkout');
  assert.deepEqual(fake.writesTo('facilities/f1/ledgers'), []);
  assert.deepEqual(fake.writesTo('facilities/f1/payments'), []);
});

test('revoked, expired and missing links are refused', async () => {
  await rejectsWith(getOrCreatePublicLinkCheckout(TOKEN, setup({ status: 'revoked' }).deps), 'failed-precondition');
  await rejectsWith(
    getOrCreatePublicLinkCheckout(TOKEN, setup({ expiresAt: Timestamp.fromDate(new Date('2020-01-01')) }).deps),
    'failed-precondition',
  );
  await rejectsWith(getOrCreatePublicLinkCheckout('d'.repeat(48), setup().deps), 'not-found');
});

test('a failed create does not poison the attempt: the next click starts a fresh one', async () => {
  const { stripe, deps } = setup();
  stripe.failNextCreate = new Error('card_declined? no: api_connection_error');

  await assert.rejects(getOrCreatePublicLinkCheckout(TOKEN, deps), /api_connection_error/);
  const retry = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.equal(stripe.createCalls[stripe.createCalls.length - 1].options.idempotencyKey, `link_${TOKEN}_2`);
  assert.deepEqual(stripe.payable(), [retry.sessionId]);
});

test('a reservation whose session was never stored is joined with the same key and parameters', async () => {
  const { stripe, fake, deps } = setup();
  // A request reserved attempt 1 and died after Stripe created the session.
  const expiresAtSeconds = Math.floor(stripe.nowMs / 1000) + CHECKOUT_SESSION_TTL_SECONDS;
  fake.seed(LINK_PATH, {
    ...fake.read(LINK_PATH)!,
    checkoutAttempt: 1,
    checkoutExpiresAt: Timestamp.fromMillis(expiresAtSeconds * 1000),
    checkoutSessionId: null,
  });
  const orphan = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  // Simulate the crash by clearing what was stored; the joiner must land on the same session.
  fake.seed(LINK_PATH, { ...fake.read(LINK_PATH)!, checkoutSessionId: null, checkoutSessionIds: [] });

  const joined = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.equal(joined.sessionId, orphan.sessionId);
  assert.equal(stripe.created().length, 1);
  assert.equal(fake.read(LINK_PATH)!.checkoutSessionId, orphan.sessionId);
});

test('a stored session Stripe no longer has on the account is replaced, not fatal', async () => {
  const { stripe, fake, deps } = setup({ checkoutSessionId: 'cs_test_gone', checkoutSessionIds: ['cs_test_gone'], checkoutAttempt: 3 });

  const result = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.equal(stripe.createCalls[0].options.idempotencyKey, `link_${TOKEN}_4`);
  assert.deepEqual(fake.read(LINK_PATH)!.checkoutSessionIds, ['cs_test_gone', result.sessionId]);
});

test('confirm from the success page marks the link paid, and racing the webhook changes it once', async () => {
  const { stripe, fake, deps } = setup();
  const checkout = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  stripe.pay(checkout.sessionId, 'pi_race');
  const sessionForWebhook = await stripe.api().retrieve(checkout.sessionId, {}, { stripeAccount: ACCOUNT });
  const linkWritesBefore = fake.writesTo(LINK_PATH).length;

  const [confirmed, webhook] = await Promise.all([
    confirmPublicLinkCheckout(TOKEN, checkout.sessionId, deps),
    completePublicLinkPayment({ db: deps.db, session: sessionForWebhook, connectedAccountId: ACCOUNT, source: 'webhook' }),
  ]);

  assert.deepEqual(confirmed, { status: 'paid' });
  assert.ok(['marked_paid', 'already_paid'].includes(webhook.outcome));
  assert.equal(fake.writesTo(LINK_PATH).length - linkWritesBefore, 1);
  assert.equal(fake.read(LINK_PATH)!.paymentIntentId, 'pi_race');
  // Refreshing the success page is harmless.
  assert.deepEqual(await confirmPublicLinkCheckout(TOKEN, checkout.sessionId, deps), { status: 'paid' });
  assert.deepEqual(fake.list('publicPaymentLinkExceptions'), []);
});

test('confirm refuses a session that belongs to another link or another account', async () => {
  const { stripe, deps } = setup();
  stripe.inject({
    id: 'cs_test_other_link',
    account: ACCOUNT,
    status: 'complete',
    payment_status: 'paid',
    payment_intent: 'pi_other',
    amount_total: 8000,
    metadata: { type: 'public_payment_link', paymentLinkToken: 'e'.repeat(48), facilityId: 'f1', tenantId: 't1' },
  });
  stripe.inject({
    id: 'cs_test_other_account',
    account: 'acct_someone_else',
    status: 'complete',
    payment_status: 'paid',
    payment_intent: 'pi_elsewhere',
    amount_total: 8000,
    metadata: { type: 'public_payment_link', paymentLinkToken: TOKEN, facilityId: 'f1', tenantId: 't1' },
  });

  await rejectsWith(confirmPublicLinkCheckout(TOKEN, 'cs_test_other_link', deps), 'permission-denied');
  await rejectsWith(confirmPublicLinkCheckout(TOKEN, 'cs_test_other_account', deps), 'not-found');
});

test('confirm reports an unpaid session as unpaid and writes nothing', async () => {
  const { fake, deps } = setup();
  const checkout = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  const writes = fake.writes.length;

  assert.deepEqual(await confirmPublicLinkCheckout(TOKEN, checkout.sessionId, deps), { status: 'unpaid' });
  assert.equal(fake.writes.length, writes);
  assert.equal(fake.read(LINK_PATH)!.status, 'pending');
});

test('paying a session after staff revoked the link is reported as received and raised to staff', async () => {
  const { stripe, fake, deps } = setup();
  const checkout = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  fake.seed(LINK_PATH, { ...fake.read(LINK_PATH)!, status: 'revoked' });
  stripe.pay(checkout.sessionId, 'pi_after_revoke');

  assert.deepEqual(await confirmPublicLinkCheckout(TOKEN, checkout.sessionId, deps), { status: 'received' });
  assert.equal(fake.read(LINK_PATH)!.status, 'revoked');
  assert.equal(fake.read(`publicPaymentLinkExceptions/${checkout.sessionId}`)!.reason, 'paid_after_revoke');
});

test('an orphaned reservation too close to lapsing for Stripe is replaced, not joined', async () => {
  const { stripe, fake, deps } = setup();
  // A request reserved attempt 1 and died before reaching Stripe; 20 minutes on,
  // its expires_at is 25 minutes away, and Stripe refuses anything under 30.
  const expiresAtSeconds = Math.floor(stripe.nowMs / 1000) + CHECKOUT_SESSION_TTL_SECONDS;
  fake.seed(LINK_PATH, {
    ...fake.read(LINK_PATH)!,
    checkoutAttempt: 1,
    checkoutExpiresAt: Timestamp.fromMillis(expiresAtSeconds * 1000),
    checkoutSessionId: null,
  });
  stripe.advance(20 * 60 * 1000);

  const result = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.equal(stripe.createCalls.length, 1);
  assert.equal(stripe.createCalls[0].options.idempotencyKey, `link_${TOKEN}_2`);
  assert.deepEqual(stripe.payable(), [result.sessionId]);
});

test('an orphaned reservation just under the 30 minutes Stripe needs is replaced, not joined', async () => {
  const { stripe, fake, deps } = setup();
  // The edge the 31-minute join window exists for: 29.5 minutes left. A
  // window under that joined it, and Stripe refused the create outright.
  const expiresAtSeconds = Math.floor(stripe.nowMs / 1000) + CHECKOUT_SESSION_TTL_SECONDS;
  fake.seed(LINK_PATH, {
    ...fake.read(LINK_PATH)!,
    checkoutAttempt: 1,
    checkoutExpiresAt: Timestamp.fromMillis(expiresAtSeconds * 1000),
    checkoutSessionId: null,
  });
  stripe.advance(CHECKOUT_SESSION_TTL_SECONDS * 1000 - 29.5 * 60 * 1000);

  const result = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.equal(stripe.createCalls.length, 1);
  assert.equal(stripe.createCalls[0].options.idempotencyKey, `link_${TOKEN}_2`);
  assert.deepEqual(stripe.payable(), [result.sessionId]);
});

test('a revoke landing while the session is being created leaves nothing payable', async () => {
  const { stripe, fake, deps } = setup();
  stripe.duringNextCreate = () => {
    fake.seed(LINK_PATH, { ...fake.read(LINK_PATH)!, status: 'revoked' });
  };

  await rejectsWith(getOrCreatePublicLinkCheckout(TOKEN, deps), 'failed-precondition');

  assert.equal(stripe.created().length, 1);
  assert.deepEqual(stripe.expireCalls, stripe.created());
  assert.deepEqual(stripe.payable(), []);
  assert.equal(fake.read(LINK_PATH)!.status, 'revoked');
});

test('a newer attempt landing while the session is being created wins; the older session is closed', async () => {
  const { stripe, fake, deps } = setup();
  stripe.duringNextCreate = () => {
    // Another tab reserved attempt 2 after this request reserved attempt 1.
    const latest = fake.read(LINK_PATH)!;
    fake.seed(LINK_PATH, {
      ...latest,
      checkoutAttempt: 2,
      checkoutExpiresAt: Timestamp.fromMillis((Math.floor(stripe.nowMs / 1000) + CHECKOUT_SESSION_TTL_SECONDS) * 1000),
      checkoutSessionId: null,
    });
  };

  const result = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  const [first] = stripe.created();
  assert.notEqual(result.sessionId, first);
  assert.ok(stripe.expireCalls.includes(first));
  assert.deepEqual(stripe.payable(), [result.sessionId]);
  assert.equal(stripe.createCalls[stripe.createCalls.length - 1].options.idempotencyKey, `link_${TOKEN}_2`);
  assert.equal(fake.read(LINK_PATH)!.checkoutSessionId, result.sessionId);
});

test('a Stripe outage while confirming says try again, not "not this link\'s session"', async () => {
  const { stripe, deps } = setup();
  const checkout = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));
  stripe.pay(checkout.sessionId, 'pi_outage');
  stripe.failNextRetrieve = Object.assign(new Error('An error occurred with our connection to Stripe.'), {
    type: 'StripeConnectionError',
  });

  await rejectsWith(confirmPublicLinkCheckout(TOKEN, checkout.sessionId, deps), 'unavailable');
  // Once Stripe answers again the same call confirms it.
  assert.deepEqual(await confirmPublicLinkCheckout(TOKEN, checkout.sessionId, deps), { status: 'paid' });
});

// --- A facility that reconnected a different Stripe account ------------------

const OLD_ACCOUNT = 'acct_old';

/** The link's session cs_old lives on the account the facility used before reconnecting. */
function reconnected(session: { status: 'open' | 'complete' | 'expired'; paid?: boolean }) {
  const ctx = setup({ checkoutSessionId: 'cs_old', checkoutSessionIds: ['cs_old'], checkoutAttempt: 1 });
  ctx.fake.seed('facilities/f1', {
    ...ctx.fake.read('facilities/f1')!,
    stripeConnectPreviousAccountId: OLD_ACCOUNT,
  });
  ctx.stripe.inject({
    id: 'cs_old',
    account: OLD_ACCOUNT,
    status: session.status,
    payment_status: session.paid ? 'paid' : 'unpaid',
    payment_intent: session.paid ? 'pi_old' : null,
    amount_total: 8000,
    metadata: { facilityId: 'f1', tenantId: 't1', type: 'public_payment_link', paymentLinkToken: TOKEN },
  });
  return ctx;
}

test('a session still open on the old account is closed before a new one opens on the new account', async () => {
  const { stripe, deps } = reconnected({ status: 'open' });

  const result = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  // Before: cs_old read as missing on the new account and stayed payable
  // alongside the new session.
  assert.deepEqual(stripe.expireCalls, ['cs_old']);
  assert.deepEqual(stripe.payable(), [result.sessionId]);
  assert.equal(stripe.createCalls[0].options.stripeAccount, ACCOUNT);
});

test('a session already paid on the old account stops a second payment', async () => {
  const { stripe, fake, deps } = reconnected({ status: 'complete', paid: true });

  await rejectsWith(getOrCreatePublicLinkCheckout(TOKEN, deps), 'failed-precondition');

  // Before: a fresh checkout, and the tenant paid the link twice.
  assert.equal(stripe.createCalls.length, 0);
  // Not marked paid from here: that account is not the facility's now, and
  // the webhook's refusal record is where a super admin settles it.
  assert.equal(fake.read(LINK_PATH)!.status, 'pending');
});

test('an expired session on the old account is simply replaced', async () => {
  const { stripe, deps } = reconnected({ status: 'expired' });

  const result = checkoutOf(await getOrCreatePublicLinkCheckout(TOKEN, deps));

  assert.deepEqual(stripe.expireCalls, []);
  assert.deepEqual(stripe.payable(), [result.sessionId]);
});
