import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { ACCOUNT, event, LEDGERS, linkPaymentIntent, PAYMENTS, setup } from './support/webhookFakes';

function dispute(overrides: Partial<Stripe.Dispute> = {}): Stripe.Dispute {
  return {
    id: 'du_1',
    object: 'dispute',
    amount: 4200,
    charge: 'ch_1',
    payment_intent: 'pi_1',
    reason: 'fraudulent',
    status: 'needs_response',
    ...overrides,
  } as unknown as Stripe.Dispute;
}

test('a dispute on a connected-account charge is recorded once, and only when created', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'pi_1', linkPaymentIntent('pi_1'));
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_1'), ACCOUNT));

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT)); // redelivery
  await dispatchStripeWebhookEvent(event('charge.dispute.updated', dispute({ status: 'under_review' }), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.updated', dispute({ status: 'under_review' }), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute({ status: 'won' }), ACCOUNT));

  const disputeEntries = fake.list(LEDGERS).filter((id) => id.startsWith('dispute_'));
  assert.deepEqual(disputeEntries, ['dispute_du_1']);
  const entry = fake.read(`${LEDGERS}/dispute_du_1`)!;
  assert.equal(entry.amount, 42);
  assert.equal(entry.tenantId, 't1');
  assert.equal(entry.type, 'dispute');
  assert.equal((entry.metadata as Record<string, unknown>).connectedAccountId, ACCOUNT);
  assert.equal(fake.writesTo(`${LEDGERS}/dispute_du_1`).length, 1);

  const payment = fake.read(`${PAYMENTS}/stripe_pi_1`)!;
  assert.equal(payment.status, 'disputed');
  assert.equal(payment.disputeStatus, 'won');

  // Every lookup went to the facility's account, never the platform.
  assert.ok(stripe.calls.length > 0);
  assert.ok(stripe.calls.every((c) => c.stripeAccount === ACCOUNT));
});

test('concurrent deliveries of dispute.created still post one ledger entry', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'pi_1', linkPaymentIntent('pi_1'));

  await Promise.all([
    dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT, 'evt_d')),
    dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT, 'evt_d')),
  ]);

  assert.deepEqual(fake.list(LEDGERS), ['dispute_du_1']);
});

test('a dispute without payment_intent falls back to the charge, on the connected account', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'ch_1', { id: 'ch_1', payment_intent: 'pi_1' });
  stripe.put(ACCOUNT, 'pi_1', linkPaymentIntent('pi_1'));

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute({ payment_intent: null }), ACCOUNT));

  assert.deepEqual(fake.list(LEDGERS), ['dispute_du_1']);
  assert.deepEqual(stripe.calls.map((c) => [c.resource, c.stripeAccount]), [
    ['charge', ACCOUNT],
    ['payment_intent', ACCOUNT],
  ]);
});

test('a dispute whose first event is updated or closed posts nothing to the ledger', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'pi_1', linkPaymentIntent('pi_1'));

  await dispatchStripeWebhookEvent(event('charge.dispute.updated', dispute(), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute({ status: 'lost' }), ACCOUNT));

  assert.deepEqual(fake.list(LEDGERS), []);
});

test('a dispute lookup failure fails the webhook instead of being marked processed', async () => {
  setup();
  // PaymentIntent not on the account: Stripe says "No such payment_intent".
  await assert.rejects(
    dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT)),
    /No such payment_intent/,
  );
});
