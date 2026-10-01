import test from 'node:test';
import assert from 'node:assert/strict';
import type * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import { getStripeClient, registerStripeKeysProvider } from '@sfc/functions-shared';

import { processRefund } from '../../stripeFacilityProcessRefund';
import { handleChargeRefunded } from '../../stripeWebhookChargeRefunded';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * The move-out screen's card refund, end to end on the server: processRefund
 * makes the refund and writes `refund_<id>`, and Stripe's charge.refunded
 * webhook converges on the same row. Runs the deployed callable and webhook
 * handler against the Firestore emulator with a fake Stripe that keeps
 * idempotency keys the way Stripe does.
 *
 * Invented ids throughout: this repository is public.
 */

const FACILITY = 'fac-1';
const OWNER = 'owner-1';
const ACCOUNT = 'acct_test_facility1';
const PI = 'pi_test_movein_payment';
const CHARGE = 'ch_test_movein_payment';

registerStripeKeysProvider({
  getSecretKey: () => 'sk_test_fake_for_emulator_tests',
  getPublishableKey: () => 'pk_test_fake_for_emulator_tests',
});

type Refund = { id: string; amount: number; status: string };

/**
 * Stripe, faked: one succeeded card payment on the facility's account, and
 * refunds keyed as Stripe keys them: a key seen before hands back the refund
 * it made, whatever was asked this time.
 */
function fakeStripe(paymentIntentMetadata: Record<string, string>) {
  const byKey = new Map<string, Refund>();
  const keys: string[] = [];
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.paymentIntents.retrieve = async () => ({
    id: PI,
    object: 'payment_intent',
    status: 'succeeded',
    amount: 10000,
    latest_charge: CHARGE,
    metadata: paymentIntentMetadata,
  });
  client.refunds.create = async (params: { amount: number }, options: Stripe.RequestOptions) => {
    const key = String(options.idempotencyKey);
    keys.push(key);
    const seen = byKey.get(key);
    if (seen) return seen;
    const refund = { id: `re_test_${byKey.size + 1}`, amount: params.amount, status: 'succeeded' };
    byKey.set(key, refund);
    return refund;
  };
  return { keys, refunds: () => [...byKey.values()] };
}

type Callable = {
  run: (data: unknown, context: functions.https.CallableContext) => Promise<Record<string, unknown>>;
};
const callable = processRefund as unknown as Callable;
const staff = {
  auth: { uid: OWNER, token: {} },
  app: { appId: 'test-app', token: {} },
  rawRequest: {},
} as unknown as functions.https.CallableContext;

const refundCall = (amount: number, requestId?: string) =>
  callable.run(
    { facilityId: FACILITY, tenantId: 't1', amount, refundMethod: 'creditCard', referenceId: PI, requestId },
    staff,
  );

const ledgers = () => emulatorDb().collection('facilities').doc(FACILITY).collection('ledgers');
const row = async (id: string) => (await ledgers().doc(id).get()).data();

/** charge.refunded for CHARGE, listing [refunds]. */
function refundedCharge(refunds: Refund[]): Stripe.Charge {
  const total = refunds.reduce((sum, r) => sum + r.amount, 0);
  return {
    id: CHARGE,
    object: 'charge',
    amount: 10000,
    amount_refunded: total,
    payment_intent: PI,
    refunds: { data: refunds },
  } as unknown as Stripe.Charge;
}

async function seed(): Promise<void> {
  await emulatorDb().collection('facilities').doc(FACILITY).set({
    name: 'Test Storage',
    ownerUid: OWNER,
    stripeConnectAccountId: ACCOUNT,
  });
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test('two units at one rate moved out the same day, both refunded against one payment: two refunds', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const stripe = fakeStripe({ facilityId: FACILITY, tenantId: 't1' });
  // The move-out screen's ids for the two contracts (MoveOutCardRefund.requestId).
  const first = await refundCall(36.67, `mo_contractTestA_${PI}`);
  const second = await refundCall(36.67, `mo_contractTestB_${PI}`);

  // Keyed on charge and amount alone, the second call got the first refund
  // back: the app said it was not made, and an owner told to "only record"
  // a refund already showing in Stripe recorded one never made.
  assert.equal(first.stripeRefundId, 're_test_1');
  assert.equal(second.stripeRefundId, 're_test_2');
  assert.deepEqual(stripe.refunds().map((r) => r.amount), [3667, 3667]);
  assert.equal((await row('refund_re_test_1'))?.amount, 36.67);
  assert.equal((await row('refund_re_test_2'))?.amount, 36.67);

  // A retry of the first (a timeout, a second press) is the same refund.
  const retry = await refundCall(36.67, `mo_contractTestA_${PI}`);
  assert.equal(retry.stripeRefundId, 're_test_1');
  assert.equal(stripe.refunds().length, 2);
  assert.equal((await ledgers().where('type', '==', 'refund').get()).size, 2);
});

test('a caller that sends no request id keeps the charge-and-amount key', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const stripe = fakeStripe({ facilityId: FACILITY, tenantId: 't1' });
  await refundCall(10);
  const again = await refundCall(10);
  assert.equal(again.stripeRefundId, 're_test_1');
  assert.deepEqual(stripe.keys, [`refund_${CHARGE}_1000`, `refund_${CHARGE}_1000`]);
});

test('the webhook landing after processRefund keeps its tenant, reference and author, and adds its metadata', { skip: skipWithoutEmulator }, async () => {
  await seed();
  // An online move-in payment: its PaymentIntent names no tenant.
  const stripe = fakeStripe({ facilityId: FACILITY, reservationId: 'res-test-1' });
  await refundCall(36.67, `mo_contractTestA_${PI}`);

  await handleChargeRefunded(refundedCharge(stripe.refunds()), ACCOUNT);

  const after = (await row('refund_re_test_1'))!;
  // Before: merged tenantId null over it, and the refund left the tenant's ledger.
  assert.equal(after.tenantId, 't1');
  assert.equal(after.referenceId, PI);
  assert.equal(after.createdBy, OWNER);
  assert.equal(after.amount, 36.67);
  assert.equal(after.status, 'posted');
  assert.deepEqual(after.metadata, {
    stripeRefundId: 're_test_1',
    stripeChargeId: CHARGE,
    refundMethod: 'creditCard',
    chargeId: CHARGE,
    paymentIntentId: PI,
    refundId: 're_test_1',
    connectedAccountId: ACCOUNT,
  });

  // Redelivered: nothing changes.
  await handleChargeRefunded(refundedCharge(stripe.refunds()), ACCOUNT);
  assert.deepEqual((await row('refund_re_test_1'))!.metadata, after.metadata);
  assert.equal((await row('refund_re_test_1'))!.tenantId, 't1');
});

test('the webhook landing first: processRefund then names the tenant, and the webhook\'s metadata stays', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const stripe = fakeStripe({ facilityId: FACILITY, reservationId: 'res-test-1' });
  // Stripe's event can beat processRefund's own write.
  await handleChargeRefunded(refundedCharge([{ id: 're_test_1', amount: 3667, status: 'succeeded' }]), ACCOUNT);
  assert.equal((await row('refund_re_test_1'))!.tenantId, null);

  await refundCall(36.67, `mo_contractTestA_${PI}`);
  assert.equal(stripe.refunds()[0].id, 're_test_1');

  const after = (await row('refund_re_test_1'))!;
  assert.equal(after.tenantId, 't1');
  assert.equal(after.createdBy, OWNER);
  assert.equal(after.referenceId, PI);
  const metadata = after.metadata as Record<string, unknown>;
  assert.equal(metadata.connectedAccountId, ACCOUNT);
  assert.equal(metadata.stripeRefundId, 're_test_1');

  // And a later delivery still never nulls it.
  await handleChargeRefunded(refundedCharge(stripe.refunds()), ACCOUNT);
  assert.equal((await row('refund_re_test_1'))!.tenantId, 't1');
  assert.equal((await row('refund_re_test_1'))!.createdBy, OWNER);
});

test('a row\'s tenant, reference and author are never replaced or nulled; only missing ones are filled', { skip: skipWithoutEmulator }, async () => {
  await seed();
  fakeStripe({ facilityId: FACILITY, tenantId: 't1' });
  await ledgers().doc('refund_re_test_1').set({
    tenantId: 't1',
    facilityId: FACILITY,
    type: 'refund',
    amount: 36.67,
    description: 'Refund for charge ' + CHARGE,
    referenceId: 'staff-reference-1',
    status: 'voided',
    createdBy: 'staff-1',
    metadata: { stripeRefundId: 're_test_1' },
  });
  await ledgers().doc('refund_re_test_2').set({
    tenantId: null,
    facilityId: FACILITY,
    type: 'refund',
    amount: 5,
    status: 'posted',
    createdBy: '',
    metadata: {},
  });
  // A payments doc for the PaymentIntent, which the webhook names as the reference.
  await emulatorDb().collection('facilities').doc(FACILITY).collection('payments').doc('payment-doc-1')
    .set({ externalPaymentId: PI, amount: 100 });

  await handleChargeRefunded(
    refundedCharge([
      { id: 're_test_1', amount: 3667, status: 'succeeded' },
      { id: 're_test_2', amount: 500, status: 'succeeded' },
    ]),
    ACCOUNT,
  );

  const kept = (await row('refund_re_test_1'))!;
  assert.equal(kept.tenantId, 't1');
  assert.equal(kept.referenceId, 'staff-reference-1');
  assert.equal(kept.createdBy, 'staff-1');
  // Staff voided it; a redelivery does not post it again.
  assert.equal(kept.status, 'voided');
  assert.equal((kept.metadata as Record<string, unknown>).paymentIntentId, PI);

  const filled = (await row('refund_re_test_2'))!;
  assert.equal(filled.tenantId, 't1');
  assert.equal(filled.referenceId, 'payment-doc-1');
  assert.equal(filled.createdBy, 'system@stripe-webhook');
  assert.equal((filled.metadata as Record<string, unknown>).refundId, 're_test_2');
});
