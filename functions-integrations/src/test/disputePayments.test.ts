/**
 * A card dispute collected by hand is booked as a dispute payment.
 *
 * The Ledger tells staff to collect a lost dispute by hand. Every way they
 * could (charge the card on file, send a payment link) posted an ordinary
 * payment row, which lands in `collectible` while the dispute stays in
 * `disputed`: autopay and the delinquency job then read next month's rent as
 * paid, and the Ledger kept asking for the dispute again. Now both carry the
 * dispute's id onto the PaymentIntent and the ledger row
 * (metadata.disputeId), so the payment nets against the dispute.
 *
 * Runs the deployed chargeTenantOffSession and processRefund callables and the
 * deployed webhook dispatch against an in-memory Firestore and a recording
 * Stripe client.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { buildPublicLinkPaymentIntentMetadata, getStripeClient, splitLedgerBalance } from '@sfc/functions-shared';
import type { FakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { chargeTenantOffSession } from '../stripeFacilityOffSessionCharge';
import { processRefund } from '../stripeFacilityProcessRefund';
import { ACCOUNT, event, LEDGERS, setup, TOKEN } from './support/webhookFakes';

const OWNER = 'owner_uid';

/** A tenant whose March payment was disputed and lost, with April rent due. */
function lostDispute() {
  const ctx = setup();
  const { fake } = ctx;
  fake.seed('facilities/f1', { ...fake.read('facilities/f1')!, ownerUid: OWNER });
  fake.seed('facilities/f1/tenants/t1', {
    ...fake.read('facilities/f1/tenants/t1')!,
    stripeConnectedCustomerId: 'cus_1',
  });
  const row = (id: string, data: Record<string, unknown>) =>
    fake.seed(`${LEDGERS}/${id}`, { tenantId: 't1', facilityId: 'f1', status: 'posted', ...data });
  row('march', { type: 'rentCharge', amount: 100 });
  row('payment_pi_march', { type: 'payment', amount: -100, metadata: { paymentIntentId: 'pi_march' } });
  // What stripeWebhookDisputeCreated.ts posts once the money is withdrawn.
  row('dispute_du_1', { type: 'dispute', amount: 100, metadata: { disputeId: 'du_1', paymentIntentId: 'pi_march' } });
  row('april', { type: 'rentCharge', amount: 100 });
  return ctx;
}

function split(fake: FakeFirestore) {
  return splitLedgerBalance(
    fake
      .list(LEDGERS)
      .map((id) => fake.read(`${LEDGERS}/${id}`)!)
      .filter((row) => row.status === 'posted'),
  );
}

type Created = { params: Stripe.PaymentIntentCreateParams; options: Stripe.RequestOptions };

/** Charges go through on ACCOUNT; returns what was asked of Stripe. */
function stripeCharges(): Created[] {
  const created: Created[] = [];
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.accounts.retrieve = async () => ({ id: ACCOUNT, charges_enabled: true });
  client.paymentIntents.create = async (params: Stripe.PaymentIntentCreateParams, options: Stripe.RequestOptions) => {
    created.push({ params, options });
    return { id: `pi_hand_${created.length}`, status: 'succeeded', amount: params.amount, metadata: params.metadata };
  };
  return created;
}

const charge = (chargeTenantOffSession as unknown as {
  run: (data: unknown, context: unknown) => Promise<Record<string, unknown>>;
}).run;
const refund = (processRefund as unknown as {
  run: (data: unknown, context: unknown) => Promise<Record<string, unknown>>;
}).run;
const staff = { auth: { uid: OWNER }, app: { appId: 'test' } };

test('charging the card on file for a dispute books it against the dispute, and April is still owed', async () => {
  const { fake } = lostDispute();
  const created = stripeCharges();

  const result = await charge(
    { facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 100, description: 'Card dispute', disputeId: 'du_1', tenantConsent: true },
    staff,
  );

  assert.equal(result.success, true);
  assert.equal(created.length, 1);
  assert.equal(created[0].options.stripeAccount, ACCOUNT);
  assert.equal(created[0].params.metadata?.disputeId, 'du_1');
  const handRows = fake
    .list(LEDGERS)
    .map((id) => fake.read(`${LEDGERS}/${id}`)!)
    .filter((row) => (row.metadata as Record<string, unknown> | undefined)?.paymentIntentId === 'pi_hand_1');
  assert.equal(handRows.length, 1);
  assert.equal((handRows[0].metadata as Record<string, unknown>).disputeId, 'du_1');
  // Before: collectible 0 and disputed 100, so autopay skipped April.
  assert.deepEqual(split(fake), { total: 100, disputed: 0, collectible: 100 });
});

test('an ordinary card-on-file charge is still rent', async () => {
  const { fake } = lostDispute();
  const created = stripeCharges();

  await charge({ facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 100 }, staff);

  assert.equal('disputeId' in (created[0].params.metadata ?? {}), false);
  assert.deepEqual(split(fake), { total: 100, disputed: 100, collectible: 0 });
});

test('a card charge naming a dispute that is not this tenant\'s open one, or for more than it has out, is refused before anything is charged', async () => {
  const { fake } = lostDispute();
  fake.seed('facilities/f1/tenants/t2', { name: 'Sam Other', stripeConnectedCustomerId: 'cus_2' });
  const created = stripeCharges();

  for (const [tenantId, disputeId, amount] of [['t2', 'du_1', 100], ['t1', 'du_other', 100], ['t1', 'du_1', 150]] as const) {
    await assert.rejects(
      charge({ facilityId: 'f1', tenantId, paymentMethodId: 'pm_1', amount, disputeId, tenantConsent: true }, staff),
      (error: unknown) => (error as { code?: string }).code === 'failed-precondition',
    );
  }
  assert.deepEqual(created, []);
});

test('a payment link sent for a dispute is booked against the dispute when its payment succeeds', async () => {
  const { fake } = lostDispute();
  const pi = {
    id: 'pi_link_dispute',
    object: 'payment_intent',
    amount: 10000,
    currency: 'usd',
    status: 'succeeded',
    metadata: buildPublicLinkPaymentIntentMetadata('f1', 't1', TOKEN, 'du_1'),
  } as unknown as Stripe.PaymentIntent;

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', pi, ACCOUNT));

  const row = fake.read(`${LEDGERS}/payment_pi_link_dispute`)!;
  assert.equal(row.amount, -100);
  assert.equal((row.metadata as Record<string, unknown>).disputeId, 'du_1');
  assert.deepEqual(split(fake), { total: 100, disputed: 0, collectible: 100 });
});

test('refunding a dispute payment reopens the dispute and leaves rent alone', async () => {
  const { fake, stripe } = lostDispute();
  const created = stripeCharges();
  await charge(
    { facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 100, disputeId: 'du_1', tenantConsent: true },
    staff,
  );
  // The PaymentIntent as Stripe keeps it, dispute id and all.
  stripe.put(ACCOUNT, 'pi_hand_1', {
    id: 'pi_hand_1',
    object: 'payment_intent',
    amount: 10000,
    status: 'succeeded',
    metadata: created[0].params.metadata,
  });
  const refunded = {
    id: 'ch_hand_1',
    object: 'charge',
    amount: 10000,
    amount_refunded: 10000,
    payment_intent: 'pi_hand_1',
    refunds: { data: [{ id: 're_hand_1', amount: 10000, status: 'succeeded' }] },
  } as unknown as Stripe.Charge;

  await dispatchStripeWebhookEvent(event('charge.refunded', refunded, ACCOUNT));

  const row = fake.read(`${LEDGERS}/refund_re_hand_1`)!;
  assert.equal(row.amount, 100);
  assert.equal((row.metadata as Record<string, unknown>).disputeId, 'du_1');
  // Before: the refund's +100 was collectible, so autopay charged the
  // refunded dispute money back to the card along with April.
  assert.deepEqual(split(fake), { total: 200, disputed: 100, collectible: 100 });
});

test('a card refund of a dispute payment made from the app is tagged too', async () => {
  const { fake, stripe } = lostDispute();
  const created = stripeCharges();
  await charge(
    { facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 100, disputeId: 'du_1', tenantConsent: true },
    staff,
  );
  stripe.put(ACCOUNT, 'pi_hand_1', {
    id: 'pi_hand_1',
    object: 'payment_intent',
    amount: 10000,
    status: 'succeeded',
    latest_charge: 'ch_hand_1',
    metadata: created[0].params.metadata,
  });
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.refunds.create = async () => ({ id: 're_hand_1', amount: 10000, status: 'succeeded' });

  // processRefund writes the same refund_{id} row the webhook does, without
  // merge, so whichever lands last must carry the dispute id.
  const result = await refund(
    { facilityId: 'f1', tenantId: 't1', amount: 100, refundMethod: 'creditCard', referenceId: 'pi_hand_1' },
    staff,
  );

  assert.equal(result.success, true);
  assert.equal((fake.read(`${LEDGERS}/refund_re_hand_1`)!.metadata as Record<string, unknown>).disputeId, 'du_1');
  assert.deepEqual(split(fake), { total: 200, disputed: 100, collectible: 100 });
});

test('a fraud dispute is never charged to the card on file, and nothing is charged', async () => {
  const { fake } = lostDispute();
  // What the webhook stores: Stripe's reason for the dispute.
  fake.seed(`${LEDGERS}/dispute_du_1`, {
    ...fake.read(`${LEDGERS}/dispute_du_1`)!,
    metadata: { disputeId: 'du_1', paymentIntentId: 'pi_march', reason: 'fraudulent' },
  });
  const created = stripeCharges();

  await assert.rejects(
    charge({ facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 100, disputeId: 'du_1', tenantConsent: true }, staff),
    (error: unknown) =>
      (error as { code?: string }).code === 'failed-precondition' &&
      /did not make this charge/.test(String((error as Error).message)),
  );
  // Before: charged. The cardholder had told their bank the first charge was not theirs.
  assert.deepEqual(created, []);
  assert.deepEqual(split(fake), { total: 200, disputed: 100, collectible: 100 });
});

test('a dispute charged to the card on file without the tenant\'s consent confirmed is refused before anything is charged', async () => {
  const { fake } = lostDispute();
  const created = stripeCharges();

  for (const tenantConsent of [undefined, false, 'true', 1]) {
    await assert.rejects(
      charge({ facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 100, disputeId: 'du_1', tenantConsent }, staff),
      (error: unknown) =>
        (error as { code?: string }).code === 'failed-precondition' &&
        /Confirm the tenant agreed/.test(String((error as Error).message)),
    );
  }
  // Before: only the app's checkbox stood between staff and the charge.
  assert.equal(created.length, 0);
  assert.deepEqual(split(fake), { total: 200, disputed: 100, collectible: 100 });
  // An ordinary charge is not a dispute charge and needs no confirmation.
  await charge({ facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 100 }, staff);
  assert.equal(created.length, 1);
  assert.equal('tenantConsent' in (created[0].params.metadata ?? {}), false);
});

test('the tenant\'s consent to a dispute card charge is kept on the PaymentIntent and in the audit log', async () => {
  const { fake } = lostDispute();
  const created = stripeCharges();

  await charge(
    { facilityId: 'f1', tenantId: 't1', paymentMethodId: 'pm_1', amount: 100, disputeId: 'du_1', tenantConsent: true },
    staff,
  );

  const metadata = created[0].params.metadata as Record<string, string>;
  assert.equal(metadata.tenantConsent, 'confirmed_by_staff');
  assert.equal(metadata.tenantConsentBy, OWNER);
  assert.ok(!Number.isNaN(Date.parse(metadata.tenantConsentAt)));
  const audits = fake
    .list('facilities/f1/auditLogs')
    .map((id) => fake.read(`facilities/f1/auditLogs/${id}`)!)
    .filter((row) => row.eventType === 'payment.dispute_card_charge');
  assert.equal(audits.length, 1);
  assert.equal(audits[0].actorUid, OWNER);
  assert.equal(audits[0].tenantId, 't1');
  assert.equal(audits[0].targetId, 'pi_hand_1');
  const auditMetadata = audits[0].metadata as Record<string, unknown>;
  assert.equal(auditMetadata.disputeId, 'du_1');
  assert.equal(auditMetadata.tenantConsent, 'confirmed_by_staff');
  assert.equal(auditMetadata.tenantConsentBy, OWNER);
});
