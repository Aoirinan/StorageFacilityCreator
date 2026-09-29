/**
 * A card dispute the tenant ends up paying twice.
 *
 * Staff can collect a dispute by hand (cash, the card on file, a payment
 * link) while it is still open. If the facility then wins it (the cardholder
 * withdraws it, or the bank rules for the facility), Stripe returns the money
 * too, and the tenant has paid the same amount twice. Before, that sat on the
 * ledger as a dispute credit: nobody was told, and autopay, the reminders and
 * the delinquency job kept charging the next month's rent in full. A dispute
 * link paid after the win was booked the same way, silently.
 *
 * Runs the deployed webhook dispatch against an in-memory Firestore.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import {
  buildPublicLinkPaymentIntentMetadata,
  disputeOverpaidNotificationId,
  splitLedgerBalance,
} from '@sfc/functions-shared';
import type { FakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { ACCOUNT, event, LEDGERS, setup, TOKEN } from './support/webhookFakes';

const OWNER = 'owner_uid';
const NOTIFICATIONS = 'facilities/f1/Notifications';
const OVERPAID = `${NOTIFICATIONS}/${disputeOverpaidNotificationId('du_1')}`;

function split(fake: FakeFirestore) {
  return splitLedgerBalance(
    fake
      .list(LEDGERS)
      .map((id) => fake.read(`${LEDGERS}/${id}`)!)
      .filter((row) => row.status === 'posted'),
  );
}

/** March paid by card and disputed, April rent due. */
function marchDisputed(reason = 'product_not_received') {
  const ctx = setup();
  const { fake, stripe } = ctx;
  fake.seed('facilities/f1', { ...fake.read('facilities/f1')!, ownerUid: OWNER });
  fake.seed('facilities/f1/tenants/t1', {
    ...fake.read('facilities/f1/tenants/t1')!,
    stripeConnectedCustomerId: 'cus_1',
  });
  const row = (id: string, data: Record<string, unknown>) =>
    fake.seed(`${LEDGERS}/${id}`, { tenantId: 't1', facilityId: 'f1', status: 'posted', ...data });
  row('march', { type: 'rentCharge', amount: 100 });
  row('payment_pi_march', { type: 'payment', amount: -100, metadata: { paymentIntentId: 'pi_march' } });
  row('april', { type: 'rentCharge', amount: 100 });
  stripe.put(ACCOUNT, 'pi_march', {
    id: 'pi_march',
    object: 'payment_intent',
    amount: 10000,
    status: 'succeeded',
    metadata: { facilityId: 'f1', tenantId: 't1' },
  });
  const dispute = (status: string, balanceTransactions: number[] = [-10000]) =>
    ({
      id: 'du_1',
      object: 'dispute',
      amount: 10000,
      charge: 'ch_march',
      payment_intent: 'pi_march',
      reason,
      status,
      balance_transactions: balanceTransactions.map((amount) => ({ amount })),
    }) as unknown as Stripe.Dispute;
  return { ...ctx, dispute };
}

function disputeLinkPayment(id: string): Stripe.PaymentIntent {
  return {
    id,
    object: 'payment_intent',
    amount: 10000,
    currency: 'usd',
    status: 'succeeded',
    metadata: buildPublicLinkPaymentIntentMetadata('f1', 't1', TOKEN, 'du_1'),
  } as unknown as Stripe.PaymentIntent;
}

test('the tenant pays the dispute link, then withdraws the dispute: staff are told to refund, and April is covered', async () => {
  const { fake, dispute } = marchDisputed();
  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute('needs_response'), ACCOUNT));
  assert.ok(fake.read(`${LEDGERS}/dispute_du_1`));
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', disputeLinkPayment('pi_link'), ACCOUNT));
  assert.deepEqual(fake.list(NOTIFICATIONS), []);

  // Withdrawn by the cardholder: Stripe closes it as won and returns the money.
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute('won', [-10000, 10000]), ACCOUNT));

  // March paid twice (the card, reinstated, and the link), April owed once.
  // Before: {total 0, disputed -100, collectible 100}, and autopay charged April.
  assert.deepEqual(split(fake), { total: 0, disputed: 0, collectible: 0 });
  const notice = fake.read(OVERPAID)!;
  assert.equal(notice.type, 'STRIPE_ACTION_REQUIRED');
  assert.equal(notice.tenantId, 't1');
  assert.equal(notice.tenantName, 'Pat Tenant');
  assert.match(String(notice.message), /Refund \$100\.00/);
  assert.equal((notice.metadata as Record<string, unknown>).creditCents, 10000);

  // Stripe's other events for the same win tell staff nothing new.
  const writes = fake.writesTo(OVERPAID).length;
  await dispatchStripeWebhookEvent(event('charge.dispute.funds_reinstated', dispute('won', [-10000, 10000]), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute('won', [-10000, 10000]), ACCOUNT));
  assert.equal(fake.writesTo(OVERPAID).length, writes);
});

test('a dispute link paid after the dispute was won is booked, and staff are told to refund it', async () => {
  const { fake, dispute } = marchDisputed();
  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute('needs_response'), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute('won', [-10000, 10000]), ACCOUNT));
  assert.deepEqual(fake.list(NOTIFICATIONS), []);

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', disputeLinkPayment('pi_late'), ACCOUNT));

  // The card was charged, so it is on the ledger, against the dispute.
  const row = fake.read(`${LEDGERS}/payment_pi_late`)!;
  assert.equal(row.amount, -100);
  assert.equal((row.metadata as Record<string, unknown>).disputeId, 'du_1');
  // Before: booked silently, with no notification and April still charged.
  assert.deepEqual(fake.list(NOTIFICATIONS), [disputeOverpaidNotificationId('du_1')]);
  assert.deepEqual(split(fake), { total: 0, disputed: 0, collectible: 0 });
});

test('a dispute collected in cash and then won tells staff to refund it', async () => {
  const { fake, dispute } = marchDisputed();
  await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute('under_review'), ACCOUNT));
  fake.seed(`${LEDGERS}/hand_1`, {
    tenantId: 't1',
    facilityId: 'f1',
    status: 'posted',
    type: 'payment',
    amount: -100,
    metadata: { paymentMethod: 'cash', paymentId: 'p_hand', disputeId: 'du_1' },
  });

  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute('won', [-10000, 10000]), ACCOUNT));

  assert.equal((fake.read(OVERPAID)!.metadata as Record<string, unknown>).creditCents, 10000);
});

test('a dispute won with nothing collected by hand says nothing', async () => {
  const { fake, dispute } = marchDisputed();
  await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute('under_review'), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute('won', [-10000, 10000]), ACCOUNT));

  assert.deepEqual(fake.list(NOTIFICATIONS), []);
  assert.deepEqual(split(fake), { total: 100, disputed: 0, collectible: 100 });
});

test('a dispute staff voided and the facility then won gets its reversal voided too, not a credit', async () => {
  const { fake, dispute } = marchDisputed();
  await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute('under_review'), ACCOUNT));
  fake.seed(`${LEDGERS}/dispute_du_1`, { ...fake.read(`${LEDGERS}/dispute_du_1`)!, status: 'voided' });

  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute('won', [-10000, 10000]), ACCOUNT));

  const reversal = fake.read(`${LEDGERS}/dispute_du_1_reinstated`)!;
  // Before: posted at -100, a credit for money the tenant never paid.
  assert.equal(reversal.status, 'voided');
  assert.equal(reversal.amount, -100);
  assert.match(String((reversal.metadata as Record<string, unknown>).voidReason), /voided/);
  assert.deepEqual(split(fake), { total: 100, disputed: 0, collectible: 100 });
  assert.deepEqual(fake.list(NOTIFICATIONS), []);
});
