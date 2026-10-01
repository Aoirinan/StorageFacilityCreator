/**
 * payment_intent.payment_failed on the Connect endpoint, in any order.
 *
 * Stripe delivers events out of order, more than once, and concurrently,
 * and a PaymentIntent can fail and then succeed on a retry. A failure that
 * landed after (or alongside) its success set the paid payment back to
 * `failed`, or added a second, random-id failed record: the portal counted
 * it as owed and offered Pay now for money already taken, and Process in the
 * app marked it paid and moved paid-through with no money.
 *
 * Runs the deployed webhook dispatch against an in-memory Firestore.
 * Made-up ids only: this repo is public.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { failureMayOverwrite } from '../stripeWebhookPaymentIntentFailed';
import { successMayOverwrite } from '../stripeWebhookPaymentIntentSucceeded';
import { ACCOUNT, event, PAYMENTS, setup } from './support/webhookFakes';

function paymentIntent(id: string, overrides: Record<string, unknown> = {}): Stripe.PaymentIntent {
  return {
    id,
    object: 'payment_intent',
    amount: 4200,
    currency: 'usd',
    status: 'succeeded',
    metadata: { facilityId: 'f1', tenantId: 't1', autopay: 'true' },
    ...overrides,
  } as unknown as Stripe.PaymentIntent;
}

function failed(id: string, overrides: Record<string, unknown> = {}): Stripe.PaymentIntent {
  return paymentIntent(id, {
    status: 'requires_payment_method',
    last_payment_error: { code: 'card_declined', message: 'Your card was declined.' },
    ...overrides,
  });
}

const succeededEvent = (id: string, evt?: string) => event('payment_intent.succeeded', paymentIntent(id), ACCOUNT, evt);
const failedEvent = (id: string, evt?: string) => event('payment_intent.payment_failed', failed(id), ACCOUNT, evt);

function payments(fake: ReturnType<typeof setup>['fake']): Array<Record<string, unknown> & { id: string }> {
  return fake.list(PAYMENTS).map((id) => ({ ...fake.read(`${PAYMENTS}/${id}`)!, id }));
}

test('a failure delivered after its success leaves the payment completed, and adds no record', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(succeededEvent('pi_1'));
  await dispatchStripeWebhookEvent(failedEvent('pi_1'));

  const rows = payments(fake);
  assert.deepEqual(rows.map((r) => r.id), ['stripe_pi_1']);
  assert.equal(rows[0].status, 'completed');
});

test('a failure and then a success on the same PaymentIntent end completed, on one record', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(failedEvent('pi_1'));
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'failed');
  await dispatchStripeWebhookEvent(succeededEvent('pi_1'));

  const rows = payments(fake);
  assert.deepEqual(rows.map((r) => r.id), ['stripe_pi_1']);
  assert.equal(rows[0].status, 'completed');
});

test('a failure racing its own success ends completed, on one record, whichever starts first', async () => {
  for (const order of ['failure-first', 'success-first'] as const) {
    for (let run = 0; run < 5; run += 1) {
      const { fake } = setup();
      const events = [failedEvent('pi_1'), succeededEvent('pi_1')];
      if (order === 'success-first') events.reverse();

      await Promise.all(events.map((e) => dispatchStripeWebhookEvent(e)));

      const rows = payments(fake);
      assert.deepEqual(rows.map((r) => r.id), ['stripe_pi_1'], `${order} #${run}`);
      assert.equal(rows[0].status, 'completed', `${order} #${run}`);
    }
  }
});

test('the same failure delivered twice at once writes one record', async () => {
  const { fake } = setup();

  await Promise.all([dispatchStripeWebhookEvent(failedEvent('pi_1', 'evt_a')), dispatchStripeWebhookEvent(failedEvent('pi_1', 'evt_a'))]);

  const rows = payments(fake);
  assert.deepEqual(rows.map((r) => r.id), ['stripe_pi_1']);
  assert.equal(rows[0].status, 'failed');
  assert.equal(rows[0].notes, 'Payment failed: Your card was declined.');
});

test('a failure never overwrites a payment that was paid, refunded or disputed', async () => {
  for (const status of ['completed', 'paid', 'succeeded', 'refunded', 'partially_refunded', 'disputed', 'cancelled']) {
    const { fake } = setup();
    fake.seed(`${PAYMENTS}/stripe_pi_1`, { tenantId: 't1', facilityId: 'f1', amount: 42, status, externalPaymentId: 'pi_1' });

    await dispatchStripeWebhookEvent(failedEvent('pi_1'));

    assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, status, status);
    assert.deepEqual(fake.list(PAYMENTS), ['stripe_pi_1'], status);
  }
});

test('a failure for a payment the app recorded under its own id leaves that record, and adds none', async () => {
  const { fake } = setup();
  // chargeTenantOffSession's facility payment: an auto id, found by externalPaymentId.
  fake.seed(`${PAYMENTS}/app_generated_1`, { tenantId: 't1', facilityId: 'f1', amount: 42, status: 'completed', externalPaymentId: 'pi_1' });

  await dispatchStripeWebhookEvent(failedEvent('pi_1'));

  assert.deepEqual(fake.list(PAYMENTS), ['app_generated_1']);
  assert.equal(fake.read(`${PAYMENTS}/app_generated_1`)!.status, 'completed');
});

test('a resent success does not set a refunded or disputed payment back to completed', async () => {
  for (const status of ['refunded', 'partially_refunded', 'disputed', 'paid']) {
    const { fake } = setup();
    fake.seed(`${PAYMENTS}/stripe_pi_1`, { tenantId: 't1', facilityId: 'f1', amount: 42, status, externalPaymentId: 'pi_1' });

    await dispatchStripeWebhookEvent(succeededEvent('pi_1'));

    assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, status, status);
  }
});

test('an embedded payment already marked succeeded is not set back to failed, nor is the billing summary', async () => {
  const { fake } = setup();
  fake.seed('facilities/f1/tenants/t1/payments/tp_1', { status: 'succeeded' });
  fake.seed('facilities/f1/tenants/t1/billing/default', { lastPaymentStatus: 'succeeded' });

  await dispatchStripeWebhookEvent(
    event('payment_intent.payment_failed', failed('pi_1', { metadata: { facilityId: 'f1', tenantId: 't1', paymentDocId: 'tp_1' } }), ACCOUNT),
  );

  assert.equal(fake.read('facilities/f1/tenants/t1/payments/tp_1')!.status, 'succeeded');
  assert.equal(fake.read('facilities/f1/tenants/t1/billing/default')!.lastPaymentStatus, 'succeeded');

  // Still processing when the failure arrives: marked failed as before.
  fake.seed('facilities/f1/tenants/t1/payments/tp_2', { status: 'processing' });
  await dispatchStripeWebhookEvent(
    event('payment_intent.payment_failed', failed('pi_2', { metadata: { facilityId: 'f1', tenantId: 't1', paymentDocId: 'tp_2' } }), ACCOUNT),
  );
  assert.equal(fake.read('facilities/f1/tenants/t1/payments/tp_2')!.status, 'failed');
  assert.equal(fake.read('facilities/f1/tenants/t1/billing/default')!.lastPaymentStatus, 'failed');
});

test('an autopay decline and a later successful retry leave one failed attempt and one completed payment', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(failedEvent('pi_declined'));
  await dispatchStripeWebhookEvent(succeededEvent('pi_retry'));

  // The failed record stays as history of the attempt. It is not owed: the
  // portal (portalPaymentIsOwed) and the app (paymentNotProcessableReason)
  // leave a failed record out, and the rent is on the ledger, now paid.
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_declined`)!.status, 'failed');
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_retry`)!.status, 'completed');
  assert.equal(fake.read('facilities/f1/ledgers/payment_pi_retry')!.amount, -42);
  assert.equal(fake.read('facilities/f1/ledgers/payment_pi_declined'), undefined);
});

test('which statuses a failure or a success may overwrite', () => {
  for (const status of [undefined, null, 'pending', 'processing', 'failed']) {
    assert.equal(failureMayOverwrite(status), true, String(status));
    assert.equal(successMayOverwrite(status), true, String(status));
  }
  for (const status of ['completed', 'paid', 'succeeded', 'refunded', 'partially_refunded', 'disputed', 'cancelled', 'something_new']) {
    assert.equal(failureMayOverwrite(status), false, status);
    assert.equal(successMayOverwrite(status), false, status);
  }
});
