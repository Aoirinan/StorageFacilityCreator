/**
 * Refunds and card disputes on online move-in payments.
 *
 * A move-in's PaymentIntent carries no tenantId (the renter is not a tenant
 * yet when they pay), so its refund and dispute rows were written with
 * `tenantId: null`: on nobody's ledger, while the tenant it moved in kept
 * the credit for money handed back. The tenant is now found through the
 * move-in's own records; with none (refunded or disputed before the move-in
 * completed) nothing goes on a ledger, and the move-in payment record and
 * the owner are told.
 *
 * Runs the deployed webhook dispatch against an in-memory Firestore.
 * Made-up ids only: this repo is public.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { ACCOUNT, event, LEDGERS, setup } from './support/webhookFakes';

const PI = 'pi_movein';
const MOVE_IN_PAYMENT = `publicMoveInPayments/${PI}`;
const NOTIFICATIONS = 'facilities/f1/Notifications';

function moveInSetup() {
  const ctx = setup();
  ctx.stripe.put(ACCOUNT, PI, {
    id: PI,
    object: 'payment_intent',
    amount: 12500,
    status: 'succeeded',
    metadata: { type: 'public_move_in', reservationId: 'res_1', facilityId: 'f1' },
  });
  ctx.fake.seed('publicReservations/res_1', { facilityId: 'f1', status: 'pending' });
  return ctx;
}

/** What completePublicMoveIn writes, in one transaction, when the move-in completes. */
function completeMoveIn(fake: ReturnType<typeof setup>['fake'], tenantId = 't_new') {
  fake.seed(MOVE_IN_PAYMENT, { paymentIntentId: PI, facilityId: 'f1', reservationId: 'res_1', tenantId, contractId: 'c1' });
  fake.seed('publicReservations/res_1', { facilityId: 'f1', status: 'completed', tenantId, paymentIntentId: PI });
}

function refundedCharge(refundId = 're_1', amount = 12500): Stripe.Charge {
  return {
    id: 'ch_movein',
    object: 'charge',
    amount: 12500,
    amount_refunded: amount,
    payment_intent: PI,
    refunds: { data: [{ id: refundId, amount, status: 'succeeded' }] },
  } as unknown as Stripe.Charge;
}

function dispute(overrides: Record<string, unknown> = {}): Stripe.Dispute {
  return {
    id: 'du_movein',
    object: 'dispute',
    amount: 12500,
    charge: 'ch_movein',
    payment_intent: PI,
    reason: 'product_not_received',
    status: 'needs_response',
    balance_transactions: [{ amount: -12500 }],
    ...overrides,
  } as unknown as Stripe.Dispute;
}

const ledgerRows = (fake: ReturnType<typeof setup>['fake']) =>
  fake.list(LEDGERS).map((id) => ({ id, ...fake.read(`${LEDGERS}/${id}`)! }));

test('refunding a completed online move-in posts the refund to the tenant it moved in', async () => {
  const { fake } = moveInSetup();
  completeMoveIn(fake);

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 5000), ACCOUNT));

  const row = fake.read(`${LEDGERS}/refund_re_1`)!;
  // Before: tenantId null, on nobody's ledger.
  assert.equal(row.tenantId, 't_new');
  assert.equal(row.amount, 50);
  assert.deepEqual(fake.list(NOTIFICATIONS), []);
});

test('a move-in completed before the move-in payment record existed is found through its reservation', async () => {
  const { fake } = moveInSetup();
  fake.seed('publicReservations/res_1', { facilityId: 'f1', status: 'completed', tenantId: 't_old', paymentIntentId: PI });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));

  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.tenantId, 't_old');
  // A reservation that names another payment is not this payment's tenant.
  const other = moveInSetup();
  other.fake.seed('publicReservations/res_1', { facilityId: 'f1', tenantId: 't_old', paymentIntentId: 'pi_other' });
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));
  assert.equal(other.fake.read(`${LEDGERS}/refund_re_1`), undefined);
});

test('a refund before the move-in was completed goes on no ledger; it is recorded on the move-in payment and the owner is told once', async () => {
  const { fake } = moveInSetup();

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT)); // redelivery

  assert.deepEqual(ledgerRows(fake), []);
  const record = fake.read(MOVE_IN_PAYMENT)!;
  assert.equal(record.facilityId, 'f1');
  assert.equal(record.reservationId, 'res_1');
  assert.equal(record.tenantId, undefined);
  const refund = (record.untenantedRefunds as Record<string, Record<string, unknown>>).re_1;
  assert.equal(refund.amountCents, 12500);
  assert.equal(refund.connectedAccountId, ACCOUNT);
  const notices = fake.list(NOTIFICATIONS);
  assert.deepEqual(notices, ['moveInPaymentRefund_re_1']);
  const notice = fake.read(`${NOTIFICATIONS}/${notices[0]}`)!;
  assert.equal(notice.type, 'STRIPE_ACTION_REQUIRED');
  assert.match(String(notice.message), /refund of \$125\.00 .* never completed a move-in/);
  assert.equal(fake.writesTo(`${NOTIFICATIONS}/moveInPaymentRefund_re_1`).length, 1);
});

test('two partial refunds before the move-in completed are both recorded on the move-in payment, on no ledger', async () => {
  const { fake } = moveInSetup();
  const charge = {
    ...refundedCharge(),
    amount_refunded: 7500,
    refunds: {
      data: [
        { id: 're_a', amount: 5000, status: 'succeeded' },
        { id: 're_b', amount: 2500, status: 'succeeded' },
      ],
    },
  } as unknown as Stripe.Charge;

  await dispatchStripeWebhookEvent(event('charge.refunded', charge, ACCOUNT));

  assert.deepEqual(ledgerRows(fake), []);
  const recorded = fake.read(MOVE_IN_PAYMENT)!.untenantedRefunds as Record<string, Record<string, unknown>>;
  assert.deepEqual(Object.keys(recorded).sort(), ['re_a', 're_b']);
  assert.equal(recorded.re_b.amountCents, 2500);
  assert.deepEqual(fake.list(NOTIFICATIONS), ['moveInPaymentRefund_re_a', 'moveInPaymentRefund_re_b']);
});

test('a refund the move-in itself made when it could not complete is recorded, and the owner is not told twice', async () => {
  const { fake } = moveInSetup();
  // What the move-in writes when it refuses a paid renter and refunds them.
  fake.seed(MOVE_IN_PAYMENT, { paymentIntentId: PI, facilityId: 'f1', reservationId: 'res_1', refund: { status: 'pending' } });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));

  assert.deepEqual(ledgerRows(fake), []);
  const record = fake.read(MOVE_IN_PAYMENT)!;
  assert.deepEqual(record.refund, { status: 'pending' });
  assert.ok((record.untenantedRefunds as Record<string, unknown>).re_1);
  assert.deepEqual(fake.list(NOTIFICATIONS), []);
});

test('a move-in completing while its refund is recorded: the refund lands on the tenant, never on nobody', async () => {
  const { fake } = moveInSetup();
  // The move-in's transaction commits just as the refund's is about to.
  fake.beforeCommit = (attempt) => {
    if (attempt === 1) completeMoveIn(fake);
  };

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));
  fake.beforeCommit = null;

  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.tenantId, 't_new');
  assert.equal(fake.read(MOVE_IN_PAYMENT)!.untenantedRefunds, undefined);
});

test('a dispute on a completed online move-in is posted to the tenant it moved in', async () => {
  const { fake } = moveInSetup();
  completeMoveIn(fake);

  await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute(), ACCOUNT));

  const row = fake.read(`${LEDGERS}/dispute_du_movein`)!;
  // Before: tenantId null.
  assert.equal(row.tenantId, 't_new');
  assert.equal(row.amount, 125);
});

test('a dispute on a move-in payment that never completed a move-in goes on no ledger; the owner is told', async () => {
  const { fake } = moveInSetup();

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute({ status: 'lost' }), ACCOUNT));

  assert.deepEqual(ledgerRows(fake).filter((r) => r.id.startsWith('dispute_')), []);
  const recorded = (fake.read(MOVE_IN_PAYMENT)!.untenantedDisputes as Record<string, Record<string, unknown>>).du_movein;
  assert.equal(recorded.status, 'lost');
  assert.equal(recorded.reason, 'product_not_received');
  assert.deepEqual(fake.list(NOTIFICATIONS), ['moveInPaymentDispute_du_movein']);
  assert.match(String(fake.read(`${NOTIFICATIONS}/moveInPaymentDispute_du_movein`)!.message), /card dispute of \$125\.00/);
});
