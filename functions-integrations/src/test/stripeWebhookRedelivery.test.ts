/**
 * Stripe resends events (a failed delivery, a manual resend from the
 * Dashboard) and the app writes some of the same rows the webhook does.
 * These check that a second write never undoes what staff or the first
 * writer recorded, and that a refund the webhook fails to record is retried.
 *
 * Runs the deployed webhook dispatch and processRefund callable against an
 * in-memory Firestore.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { processRefund, refundIdempotencyKey, refundRequestId } from '../stripeFacilityProcessRefund';
import { ACCOUNT, event, LEDGERS, linkPaymentIntent, setup } from './support/webhookFakes';

const OWNER = 'owner_uid';

function refundedCharge(refundId = 're_1'): Stripe.Charge {
  return {
    id: 'ch_1',
    object: 'charge',
    amount: 4200,
    amount_refunded: 4200,
    payment_intent: 'pi_1',
    refunds: { data: [{ id: refundId, amount: 4200, status: 'succeeded' }] },
  } as unknown as Stripe.Charge;
}

/** Facility f1 owned by OWNER, with a $42 card payment pi_1 on its account. */
function paidByCard() {
  const ctx = setup();
  ctx.fake.seed('facilities/f1', { ...ctx.fake.read('facilities/f1')!, ownerUid: OWNER });
  ctx.stripe.put(ACCOUNT, 'pi_1', {
    id: 'pi_1',
    object: 'payment_intent',
    amount: 4200,
    status: 'succeeded',
    latest_charge: 'ch_1',
    metadata: { facilityId: 'f1', tenantId: 't1' },
  });
  return ctx;
}

const refund = (processRefund as unknown as {
  run: (data: unknown, context: unknown) => Promise<Record<string, unknown>>;
}).run;
const staff = { auth: { uid: OWNER }, app: { appId: 'test' } };

test('a resent payment_intent.succeeded does not bring back a payment row staff voided', async () => {
  const { fake } = setup();
  const pi = linkPaymentIntent('pi_1');
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', pi, ACCOUNT, 'evt_a'));
  const path = `${LEDGERS}/payment_pi_1`;
  fake.seed(path, { ...fake.read(path)!, status: 'voided', voidedBy: 'staff' });

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', pi, ACCOUNT, 'evt_a'));

  // Before: set() without merge rewrote it 'posted', crediting the tenant again.
  assert.equal(fake.read(path)!.status, 'voided');
  assert.equal(fake.read(path)!.voidedBy, 'staff');
});

test('an autopay row keeps its own fields when the webhook for the same charge arrives', async () => {
  const { fake } = setup();
  // What autopayScheduled.ts writes before Stripe's event arrives.
  fake.seed(`${LEDGERS}/payment_pi_auto`, {
    tenantId: 't1',
    facilityId: 'f1',
    type: 'payment',
    amount: -42,
    description: 'Autopay Payment - pi_auto',
    referenceId: 'pi_auto',
    status: 'posted',
    createdBy: 'system',
    metadata: { paymentMethod: 'stripe', autopay: true, paymentIntentId: 'pi_auto' },
  });
  const pi = {
    ...linkPaymentIntent('pi_auto'),
    metadata: { facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm1', autopay: 'true' },
  } as Stripe.PaymentIntent;

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', pi, ACCOUNT));

  assert.deepEqual(fake.list(LEDGERS), ['payment_pi_auto']);
  const row = fake.read(`${LEDGERS}/payment_pi_auto`)!;
  assert.equal(row.amount, -42);
  assert.equal(row.status, 'posted');
  assert.equal(row.createdBy, 'system');
  // Linked to the payment record the webhook keeps, as before.
  assert.equal(row.referenceId, 'stripe_pi_auto');
  assert.deepEqual(row.metadata, { paymentMethod: 'stripe', autopay: true, paymentIntentId: 'pi_auto' });
});

test('a Firestore failure recording a refund fails the webhook so Stripe retries', async () => {
  const { fake } = paidByCard();
  const f = fake as unknown as { applyAll: (writes: Array<{ path: string }>) => void };
  const original = f.applyAll.bind(fake);
  let failures = 1;
  f.applyAll = (writes) => {
    if (failures > 0 && writes.some((w) => w.path.includes('/ledgers/refund_'))) {
      failures--;
      throw new Error('UNAVAILABLE: try again');
    }
    original(writes);
  };

  // Before: logged and swallowed, the event marked processed, and the refund
  // never reached the ledger: the tenant kept a credit for money returned.
  await assert.rejects(dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT)), /UNAVAILABLE/);
  assert.equal(fake.read(`${LEDGERS}/refund_re_1`), undefined);

  // Stripe's retry records it once.
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));
  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.amount, 42);
  assert.equal(fake.writesTo(`${LEDGERS}/refund_re_1`).filter((w) => w.op === 'create').length, 1);
});

test('the refund webhook keeps the staff member processRefund recorded', async () => {
  const { fake } = paidByCard();
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.refunds.create = async () => ({ id: 're_1', amount: 4200, status: 'succeeded' });

  await refund({ facilityId: 'f1', tenantId: 't1', amount: 42, refundMethod: 'creditCard', referenceId: 'pi_1' }, staff);
  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.createdBy, OWNER);
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));

  const row = fake.read(`${LEDGERS}/refund_re_1`)!;
  // Before: merged over, createdBy became system@stripe-webhook.
  assert.equal(row.createdBy, OWNER);
  assert.equal(row.amount, 42);
  assert.equal(row.status, 'posted');
  const metadata = row.metadata as Record<string, unknown>;
  assert.equal(metadata.stripeRefundId, 're_1');
  // What the webhook adds is still filled in.
  assert.equal(metadata.connectedAccountId, ACCOUNT);
  assert.equal(metadata.paymentIntentId, 'pi_1');
});

test('processRefund landing after the webhook keeps the webhook\'s account and takes over the attribution', async () => {
  const { fake } = paidByCard();
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.refunds.create = async () => ({ id: 're_1', amount: 4200, status: 'succeeded' });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));
  await refund({ facilityId: 'f1', tenantId: 't1', amount: 42, refundMethod: 'creditCard', referenceId: 'pi_1' }, staff);

  const row = fake.read(`${LEDGERS}/refund_re_1`)!;
  assert.equal(row.createdBy, OWNER);
  assert.equal((row.metadata as Record<string, unknown>).connectedAccountId, ACCOUNT);
});

test('a refund voided by staff stays voided when the refund event is resent', async () => {
  const { fake } = paidByCard();
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));
  fake.seed(`${LEDGERS}/refund_re_1`, { ...fake.read(`${LEDGERS}/refund_re_1`)!, status: 'voided' });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));

  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.status, 'voided');
});

test('two deliberate refunds of the same amount on one charge are two refunds; a double-click is one', async () => {
  paidByCard();
  const keys: string[] = [];
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.refunds.create = async (_params: unknown, options: Stripe.RequestOptions) => {
    keys.push(String(options.idempotencyKey));
    return { id: `re_${keys.length}`, amount: 1000, status: 'succeeded' };
  };
  const call = (requestId?: string) =>
    refund({ facilityId: 'f1', tenantId: 't1', amount: 10, refundMethod: 'creditCard', referenceId: 'pi_1', requestId }, staff);

  await call('refund-click-0001');
  await call('refund-click-0001'); // double-click or retry: same key, Stripe returns the first
  await call('refund-click-0002'); // a second refund staff meant

  assert.equal(keys[0], keys[1]);
  assert.notEqual(keys[1], keys[2]);
  assert.equal(keys[0], 'refund_ch_1_1000_refund-click-0001');
  // A caller that sends no id keeps the old key.
  assert.equal(refundIdempotencyKey('ch_1', 1000, refundRequestId(undefined)), 'refund_ch_1_1000');
  assert.equal(refundRequestId('../bad key'), null);
});
