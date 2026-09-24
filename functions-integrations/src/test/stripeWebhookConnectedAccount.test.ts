import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { ACCOUNT, event, LEDGERS, linkPaymentIntent, PAYMENTS, setup } from './support/webhookFakes';

// A Standard account's owner can create a PaymentIntent with any metadata,
// including another facility's id. Only events from the facility's own
// connected account may write to that facility.

function portalPaymentIntent(id: string): Stripe.PaymentIntent {
  return {
    ...linkPaymentIntent(id),
    metadata: { facilityId: 'f1', tenantId: 't1', type: 'tenant_portal_payment' },
  } as Stripe.PaymentIntent;
}

function refundedCharge(id: string, paymentIntent: string): Stripe.Charge {
  return {
    id,
    object: 'charge',
    amount: 4200,
    amount_refunded: 4200,
    payment_intent: paymentIntent,
    refunds: { data: [{ id: `re_${id}`, amount: 4200, status: 'succeeded' }] },
  } as unknown as Stripe.Charge;
}

test('a payment made on another account naming this facility credits nothing', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_forged'), 'acct_other'));
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_forged2'), 'acct_other'));

  assert.equal(fake.writes.length, 0);
  assert.deepEqual(fake.list(LEDGERS), []);
  assert.deepEqual(fake.list(PAYMENTS), []);
});

test('a connected-account payment for a facility with no connected account is refused', async () => {
  const { fake } = setup();
  fake.seed('facilities/f1', { name: 'Test Storage', stripeConnectAccountId: null });

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_1'), ACCOUNT));

  assert.equal(fake.writes.length, 0);
});

test('payments on the facility\'s own account, and platform payments, are still credited', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_own'), ACCOUNT));
  // No event.account: the platform's own PaymentIntent, which only this server creates.
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_platform')));

  assert.deepEqual(fake.list(LEDGERS), ['payment_pi_own', 'payment_pi_platform']);
  assert.equal(fake.read(`${LEDGERS}/payment_pi_own`)!.amount, -42);
});

test('a refund made on another account naming this facility charges the tenant nothing', async () => {
  const { fake, stripe } = setup();
  stripe.put('acct_other', 'pi_forged', portalPaymentIntent('pi_forged'));

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('ch_forged', 'pi_forged'), 'acct_other'));

  assert.equal(fake.writes.length, 0);
});

test('a refund on the facility\'s own account is posted', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'pi_1', portalPaymentIntent('pi_1'));

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('ch_1', 'pi_1'), ACCOUNT));

  assert.deepEqual(fake.list(LEDGERS), ['refund_re_ch_1']);
  assert.equal(fake.read(`${LEDGERS}/refund_re_ch_1`)!.amount, 42);
});
