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
 * Checkout's PaymentIntents carry no facilityId either, only `type` and
 * `reservationId` (functions-public-website publicMoveIn.ts), so the
 * PaymentIntents here have that shape. The facility is found through the
 * same records, and the event must still come from its account.
 *
 * Runs the deployed webhook dispatch against an in-memory Firestore.
 * Made-up ids only: this repo is public.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { processRefund } from '../stripeFacilityProcessRefund';
import { ACCOUNT, event, LEDGERS, setup } from './support/webhookFakes';

const PI = 'pi_movein';
const MOVE_IN_PAYMENT = `publicMoveInPayments/${PI}`;
const NOTIFICATIONS = 'facilities/f1/Notifications';

/** What checkout puts on a move-in's PaymentIntent: no facilityId, no tenantId. */
const CHECKOUT_METADATA = { type: 'public_move_in', reservationId: 'res_1' };

function moveInPaymentIntent(metadata: Record<string, string> = CHECKOUT_METADATA) {
  return { id: PI, object: 'payment_intent', amount: 12500, status: 'succeeded', metadata };
}

function moveInSetup(metadata: Record<string, string> = CHECKOUT_METADATA, options: { reservation?: boolean } = {}) {
  const ctx = setup();
  ctx.stripe.put(ACCOUNT, PI, moveInPaymentIntent(metadata));
  if (options.reservation !== false) ctx.fake.seed('publicReservations/res_1', { facilityId: 'f1', status: 'pending' });
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

// The facility, when the PaymentIntent does not name one.

test('the facility of a move-in PaymentIntent that names none is found through its reservation', async () => {
  const { fake } = moveInSetup();
  assert.equal(moveInPaymentIntent().metadata.facilityId, undefined);

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));

  // Before: "missing facilityId metadata", and nothing recorded anywhere, so
  // the renter could still complete the move-in with money handed back.
  const record = fake.read(MOVE_IN_PAYMENT)!;
  assert.equal(record.facilityId, 'f1');
  assert.ok((record.untenantedRefunds as Record<string, unknown>).re_1);
  assert.deepEqual(fake.list(NOTIFICATIONS), ['moveInPaymentRefund_re_1']);
});

test('the facility is found through the move-in payment record when the reservation is gone', async () => {
  const { fake } = moveInSetup(CHECKOUT_METADATA, { reservation: false });
  fake.seed(MOVE_IN_PAYMENT, { paymentIntentId: PI, facilityId: 'f1', reservationId: 'res_1', tenantId: 't_new' });

  await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute(), ACCOUNT));

  assert.equal(fake.read(`${LEDGERS}/dispute_du_movein`)!.tenantId, 't_new');
});

test('an older move-in PaymentIntent that names its facility is handled as before', async () => {
  const { fake } = moveInSetup({ ...CHECKOUT_METADATA, facilityId: 'f1' });
  completeMoveIn(fake);

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 5000), ACCOUNT));

  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.tenantId, 't_new');
});

test('a move-in PaymentIntent no record names a facility for writes nothing', async () => {
  const { fake } = moveInSetup(CHECKOUT_METADATA, { reservation: false });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));

  assert.deepEqual(fake.writes.filter((w) => !w.path.startsWith('stripeWebhookEvents/')), []);
});

test('another account\'s PaymentIntent naming this facility\'s reservation is refused, not recorded', async () => {
  const { fake, stripe } = moveInSetup();
  completeMoveIn(fake);
  stripe.put('acct_other', PI, moveInPaymentIntent());

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge(), 'acct_other'));
  await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute(), 'acct_other'));

  assert.deepEqual(ledgerRows(fake), []);
  assert.equal(fake.read(MOVE_IN_PAYMENT)!.untenantedRefunds, undefined);
  assert.deepEqual(fake.list(NOTIFICATIONS), []);
  const refusals = fake.list('stripeWebhookRefusals');
  assert.equal(refusals.length, 2);
  for (const id of refusals) assert.equal(fake.read(`stripeWebhookRefusals/${id}`)!.facilityId, 'f1');
});

// The app's own card refund (processRefund: the move-out screen's, among
// others) on a move-in whose records name no tenant: completed before
// reservations recorded their PaymentIntent (about 2026-09-24).

const OWNER = 'owner_uid';
const staff = { auth: { uid: OWNER }, app: { appId: 'test' } };
const runProcessRefund = (processRefund as unknown as {
  run: (data: unknown, context: unknown) => Promise<Record<string, unknown>>;
}).run;

function olderMoveInSetup() {
  const ctx = moveInSetup();
  ctx.fake.seed('facilities/f1', { ...ctx.fake.read('facilities/f1')!, ownerUid: OWNER });
  // Completed, but the reservation never recorded the PaymentIntent.
  ctx.fake.seed('publicReservations/res_1', { facilityId: 'f1', status: 'completed', tenantId: 't_old' });
  ctx.stripe.put(ACCOUNT, PI, { ...moveInPaymentIntent(), latest_charge: 'ch_movein' });
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.refunds.create = async () => ({ id: 're_1', amount: 5000, status: 'succeeded' });
  return ctx;
}

const appRefund = () =>
  runProcessRefund(
    { facilityId: 'f1', tenantId: 't_old', amount: 50, refundMethod: 'creditCard', referenceId: PI, requestId: `mo_contractA_${PI}` },
    staff,
  );

const untenantedRefunds = (fake: ReturnType<typeof setup>['fake']) =>
  fake.read(MOVE_IN_PAYMENT)?.untenantedRefunds as Record<string, unknown> | undefined;

/** What the refund row should hold once both writers have run, in either order. */
function assertPostedToTenant(fake: ReturnType<typeof setup>['fake']) {
  const row = fake.read(`${LEDGERS}/refund_re_1`)!;
  assert.equal(row.tenantId, 't_old');
  assert.equal(row.createdBy, OWNER);
  assert.equal(row.amount, 50);
  assert.equal(row.status, 'posted');
  const metadata = row.metadata as Record<string, unknown>;
  assert.equal(metadata.stripeRefundId, 're_1');
  assert.equal(metadata.refundId, 're_1');
  assert.equal(metadata.chargeId, 'ch_movein');
  assert.equal(metadata.paymentIntentId, PI);
  assert.equal(metadata.connectedAccountId, ACCOUNT);
}

test('the app refunds an older move-in and the webhook lands second: the row\'s tenant is used, nothing recorded, no alert', async () => {
  const { fake } = olderMoveInSetup();

  await appRefund();
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 5000), ACCOUNT));

  // Before: recorded as refunded before any move-in (creating this record),
  // the owner told nothing was put on any ledger, and the row left without
  // the webhook's metadata.
  assert.equal(fake.read(MOVE_IN_PAYMENT), undefined);
  assert.deepEqual(fake.list(NOTIFICATIONS), []);
  assertPostedToTenant(fake);
});

test('the webhook lands first: what it recorded is withdrawn once the app posts the refund', async () => {
  const { fake } = olderMoveInSetup();

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 5000), ACCOUNT));
  // No row and no record name the tenant yet.
  assert.ok(untenantedRefunds(fake)?.re_1);
  assert.deepEqual(fake.list(NOTIFICATIONS), ['moveInPaymentRefund_re_1']);
  assert.equal(fake.read(`${LEDGERS}/refund_re_1`), undefined);

  await appRefund();

  assert.deepEqual(untenantedRefunds(fake), {});
  assert.deepEqual(fake.list(NOTIFICATIONS), []);
  assertPostedToTenant(fake);

  // A redelivery finds the row's tenant: nothing recorded, no alert.
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 5000), ACCOUNT));
  assert.deepEqual(untenantedRefunds(fake), {});
  assert.deepEqual(fake.list(NOTIFICATIONS), []);
  assertPostedToTenant(fake);
});

test('a refund made before the move-in stays recorded, with its alert, when the app refunds another', async () => {
  const { fake } = olderMoveInSetup();
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_dashboard', 1000), ACCOUNT));

  await appRefund();

  assert.ok(untenantedRefunds(fake)?.re_dashboard);
  assert.deepEqual(fake.list(NOTIFICATIONS), ['moveInPaymentRefund_re_dashboard']);
  assert.equal(fake.read(`${LEDGERS}/refund_re_dashboard`), undefined);
  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.tenantId, 't_old');
});

test('a refund row with no tenant is not one: the refund is still recorded on the move-in payment', async () => {
  const { fake } = olderMoveInSetup();
  fake.seed(`${LEDGERS}/refund_re_1`, { tenantId: null, facilityId: 'f1', type: 'refund', amount: 50, status: 'posted' });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 5000), ACCOUNT));

  assert.ok(untenantedRefunds(fake)?.re_1);
  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.tenantId, null);
});

test('the refund is made and posted even when withdrawing the webhook\'s record fails', async () => {
  const { fake } = olderMoveInSetup();
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 5000), ACCOUNT));
  const f = fake as unknown as { applyAll: (writes: Array<{ path: string }>) => void };
  const original = f.applyAll.bind(fake);
  f.applyAll = (writes) => {
    if (writes.some((w) => w.path === MOVE_IN_PAYMENT)) throw new Error('UNAVAILABLE: try again');
    original(writes);
  };

  // Thrown, processRefund would have said no refund was issued.
  const result = await appRefund();
  f.applyAll = original;

  assert.equal(result.success, true);
  assert.equal(result.stripeRefundId, 're_1');
  assert.equal(fake.read(`${LEDGERS}/refund_re_1`)!.tenantId, 't_old');
});

// A payment returned before the move-in: the reservation it paid for, and its
// hold on the unit. Checkout records the payment on the reservation
// (checkoutPaidPaymentIntentId) and holds the unit until a day after it.

const HOLD = 'facilities/f1/mapEngine/activeHolds/items/u1';
const HELD_UNTIL = new Date(Date.now() + 20 * 60 * 60 * 1000);

/** Paid at checkout, not yet moved in: the reservation names the payment and holds unit u1. */
function paidNotMovedIn(reservation: Record<string, unknown> = {}, hold: Record<string, unknown> = {}) {
  const ctx = moveInSetup();
  ctx.fake.seed('publicReservations/res_1', {
    facilityId: 'f1',
    unitId: 'u1',
    status: 'pending',
    checkoutPaidPaymentIntentId: PI,
    ...reservation,
  });
  ctx.fake.seed(HOLD, { facilityId: 'f1', unitId: 'u1', reservationId: 'res_1', status: 'active', expiresAt: HELD_UNTIL, ...hold });
  return ctx;
}

const RETURNED: Array<[string, () => Stripe.Event, string, string]> = [
  ['refunded in Stripe', () => event('charge.refunded', refundedCharge('re_1', 1000), ACCOUNT), 'refund', 'moveInPaymentRefund_re_1'],
  ['disputed', () => event('charge.dispute.created', dispute(), ACCOUNT), 'dispute', 'moveInPaymentDispute_du_movein'],
];

for (const [label, returned, kind, alert] of RETURNED) {
  test(`a payment ${label} before the move-in cancels the reservation it paid for and frees the unit`, async () => {
    const { fake } = paidNotMovedIn();

    await dispatchStripeWebhookEvent(returned());

    // Before: the reservation kept the payment and the unit stayed held for a
    // day after it ("Unit is currently in checkout" for anyone), while the
    // renter could neither finish nor pay again.
    const reservation = fake.read('publicReservations/res_1')!;
    assert.equal(reservation.status, 'cancelled');
    assert.equal(reservation.cancelledBy, 'system@stripe-webhook');
    assert.equal(reservation.cancelReason, `paid-move-in-returned:${kind}`);
    assert.equal(reservation.returnedPaymentIntentId, PI);
    assert.equal(fake.read(HOLD), undefined);
    assert.deepEqual(fake.list(NOTIFICATIONS), [alert]);
    assert.match(String(fake.read(`${NOTIFICATIONS}/${alert}`)!.message), /the reservation was cancelled and the unit is free to rent again/);

    // Redelivered: nothing more.
    const writes = fake.writes.length;
    await dispatchStripeWebhookEvent(returned());
    assert.deepEqual(
      fake.writes.slice(writes).filter((w) => w.path.startsWith('publicReservations/') || w.path === HOLD),
      [],
    );
  });
}

test('a reservation that records another payment keeps its hold when this one is returned', async () => {
  // A second payment for the same reservation: the hold is that payment's.
  const { fake } = paidNotMovedIn({ checkoutPaidPaymentIntentId: 'pi_other' });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 1000), ACCOUNT));

  assert.equal(fake.read('publicReservations/res_1')!.status, 'pending');
  assert.ok(fake.read(HOLD));
  assert.ok(untenantedRefunds(fake)?.re_1);
  assert.doesNotMatch(String(fake.read(`${NOTIFICATIONS}/moveInPaymentRefund_re_1`)!.message), /cancelled/);
});

test('a refund the move-in itself made leaves the reservation and the hold to that path', async () => {
  const { fake } = paidNotMovedIn();
  fake.seed(MOVE_IN_PAYMENT, { paymentIntentId: PI, facilityId: 'f1', reservationId: 'res_1', refund: { status: 'pending' } });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 1000), ACCOUNT));

  assert.equal(fake.read('publicReservations/res_1')!.status, 'pending');
  assert.ok(fake.read(HOLD));
});

test('a hold that has passed to another reservation is not released', async () => {
  const { fake } = paidNotMovedIn({}, { reservationId: 'res_other' });

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('re_1', 1000), ACCOUNT));

  assert.equal(fake.read('publicReservations/res_1')!.status, 'cancelled');
  assert.equal(fake.read(HOLD)!.reservationId, 'res_other');
});

test('a reservation already closed is left as it is', async () => {
  const { fake } = paidNotMovedIn({ status: 'cancelled', cancelReason: 'renter' });

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));

  assert.equal(fake.read('publicReservations/res_1')!.cancelReason, 'renter');
  assert.ok(fake.read(HOLD));
});
