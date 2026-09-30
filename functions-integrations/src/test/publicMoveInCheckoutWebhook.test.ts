/**
 * The Connect webhook's checkout.session.completed for an online move-in.
 *
 * Nothing server-side reacted to a paid move-in session before: a renter who
 * paid and closed the tab kept the unit only until checkout's hold lapsed,
 * and was never moved in or refunded, with nothing said to the owner. The
 * webhook now records the payment and holds the unit for the payer
 * (functions-shared recordPaidPublicMoveInCheckout), for functions-public-website's
 * sweep to settle. Platform checkouts (subscriptions, the owner's free month)
 * are routed as before. All data is invented.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { handleCheckoutCompleted } from '../stripeWebhookCheckoutCompleted';
import { FakeFirestore } from './support/fakeFirestore';

const FACILITY = 'fac_webhook';
const UNIT = 'unit_webhook';
const RESERVATION = 'res_webhook';
const ACCOUNT = 'acct_webhook_facility';
const PI = 'pi_webhook';
const RESERVATION_PATH = `publicReservations/${RESERVATION}`;
const HOLD_PATH = `facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`;
const PAID_PATH = `publicMoveInPaidCheckouts/${PI}`;
const USE_PATH = `publicMoveInPayments/${PI}`;
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;

function useFakeFirestore(fake: FakeFirestore): void {
  if (!admin.apps.length) admin.initializeApp({ projectId: 'fake-webhook-test' });
  const statics = {
    Timestamp: admin.firestore.Timestamp,
    FieldValue: admin.firestore.FieldValue,
    FieldPath: admin.firestore.FieldPath,
  };
  Object.defineProperty(admin, 'firestore', {
    configurable: true,
    writable: true,
    value: Object.assign(() => fake.asFirestore(), statics),
  });
}

function ts(ms: number): admin.firestore.Timestamp {
  return admin.firestore.Timestamp.fromMillis(ms);
}

function millis(value: unknown): number {
  return (value as admin.firestore.Timestamp).toMillis();
}

/** A reservation whose checkout started [startedMinutesAgo], holding its unit until the Checkout page's hold ends. */
function seed(startedMinutesAgo = 34, reservation: Record<string, unknown> = {}): FakeFirestore {
  const now = Date.now();
  const holdUntil = ts(now - startedMinutesAgo * MINUTE + 45 * MINUTE);
  return new FakeFirestore({
    [`facilities/${FACILITY}`]: { name: 'Webhook Storage', stripeConnectAccountId: ACCOUNT },
    [`facilities/${FACILITY}/units/${UNIT}`]: { status: 'available', unitNumber: 'W1' },
    [RESERVATION_PATH]: {
      facilityId: FACILITY,
      unitId: UNIT,
      status: 'pending',
      name: 'Rita Renter',
      checkoutUpdatedAt: ts(now - startedMinutesAgo * MINUTE),
      checkoutSessionId: 'cs_webhook',
      checkoutSessionAccountId: ACCOUNT,
      expiresAt: holdUntil,
      ...reservation,
    },
    [HOLD_PATH]: { facilityId: FACILITY, unitId: UNIT, reservationId: RESERVATION, status: 'pending', expiresAt: holdUntil },
  });
}

/** A paid online move-in session, as checkout creates it on the facility's account. */
function paidSession(overrides: Partial<Stripe.Checkout.Session> = {}): Stripe.Checkout.Session {
  return {
    id: 'cs_webhook',
    object: 'checkout.session',
    payment_status: 'paid',
    status: 'complete',
    payment_intent: PI,
    amount_total: 4200,
    metadata: { type: 'public_move_in', reservationId: RESERVATION, moveInToken: 'secret-token', facilityId: FACILITY },
    ...overrides,
  } as unknown as Stripe.Checkout.Session;
}

test('a paid move-in session from the facility\'s account holds the unit for the payer for a day after payment', async () => {
  const fake = seed();
  useFakeFirestore(fake);
  const paidAt = Math.floor(Date.now() / 1000) - 60;

  await handleCheckoutCompleted(paidSession(), ACCOUNT, paidAt);

  // Before: 'No accountId in checkout session metadata', and nothing held the
  // unit once checkout's hold lapsed 10 minutes after the page closed.
  const reservation = fake.read(RESERVATION_PATH)!;
  assert.equal(reservation.checkoutPaidPaymentIntentId, PI);
  assert.equal(millis(reservation.checkoutPaidAt), paidAt * 1000);
  assert.equal(millis(reservation.expiresAt), paidAt * 1000 + 24 * HOUR);
  const hold = fake.read(HOLD_PATH)!;
  assert.equal(hold.reservationId, RESERVATION);
  assert.equal(millis(hold.expiresAt), paidAt * 1000 + 24 * HOUR);
  // Recorded for the sweep, with the account that took the payment.
  const paid = fake.read(PAID_PATH)!;
  assert.equal(paid.reservationId, RESERVATION);
  assert.equal(paid.facilityId, FACILITY);
  assert.equal(paid.connectAccountId, ACCOUNT);
  assert.equal(paid.checkoutSessionId, 'cs_webhook');
  assert.equal(paid.amountCents, 4200);
  assert.equal(paid.recordedBy, 'stripeWebhook');
  assert.equal(millis(paid.paidAt), paidAt * 1000);
  // Nothing moved in, refunded or used.
  assert.equal(fake.read(USE_PATH), undefined);
  assert.equal(fake.read(`facilities/${FACILITY}/units/${UNIT}`)?.status, 'available');
});

test('a paid move-in session whose reservation was marked expired reopens it for the payer', async () => {
  const fake = seed(60, { status: 'expired' });
  useFakeFirestore(fake);

  await handleCheckoutCompleted(paidSession(), ACCOUNT, Math.floor(Date.now() / 1000) - 30 * 60);

  assert.equal(fake.read(RESERVATION_PATH)?.status, 'pending');
  assert.ok(millis(fake.read(HOLD_PATH)?.expiresAt) > Date.now() + 23 * HOUR);
});

test('the webhook retried after the renter moved in records nothing and holds nothing', async () => {
  const fake = seed();
  useFakeFirestore(fake);
  // Completion wrote the payment's use record, rented the unit and removed the hold.
  await fake.collection('publicMoveInPayments').doc(PI).set({ paymentIntentId: PI, tenantId: 'tenant_1' });
  await fake.collection('publicReservations').doc(RESERVATION).set({ status: 'completed' }, { merge: true });
  fake.write(HOLD_PATH, undefined as never);
  const before = fake.read(RESERVATION_PATH);

  await handleCheckoutCompleted(paidSession(), ACCOUNT, Math.floor(Date.now() / 1000));

  assert.deepEqual(fake.read(RESERVATION_PATH), before);
  assert.equal(fake.read(HOLD_PATH), undefined);
  assert.equal(fake.read(PAID_PATH), undefined);
});

test('the webhook retried after the payment was refunded does not mark the reservation paid again', async () => {
  const fake = seed();
  useFakeFirestore(fake);
  await fake.collection('publicMoveInPayments').doc(PI).set({
    paymentIntentId: PI,
    tenantId: null,
    refund: { status: 'refunded', refusal: 'charges-changed' },
  });

  await handleCheckoutCompleted(paidSession(), ACCOUNT, Math.floor(Date.now() / 1000));

  assert.equal(fake.read(RESERVATION_PATH)?.checkoutPaidPaymentIntentId, undefined);
  assert.equal(fake.read(PAID_PATH), undefined);
});

for (const [why, session, account] of [
  ['unpaid', paidSession({ payment_status: 'unpaid' }), ACCOUNT],
  ['on the platform account (no connected account on the event)', paidSession(), undefined],
  ['from another connected account', paidSession(), 'acct_someone_else'],
  ['naming another facility', paidSession({ metadata: { type: 'public_move_in', reservationId: RESERVATION, facilityId: 'fac_other' } }), ACCOUNT],
  ['with no payment', paidSession({ payment_intent: null }), ACCOUNT],
] as Array<[string, Stripe.Checkout.Session, string | undefined]>) {
  test(`a move-in session ${why} records nothing and holds nothing`, async () => {
    const fake = seed();
    useFakeFirestore(fake);
    const reservation = fake.read(RESERVATION_PATH);
    const hold = fake.read(HOLD_PATH);

    await handleCheckoutCompleted(session, account, Math.floor(Date.now() / 1000));

    assert.deepEqual(fake.read(RESERVATION_PATH), reservation);
    assert.deepEqual(fake.read(HOLD_PATH), hold);
    assert.equal(fake.read(PAID_PATH), undefined);
  });
}

test('a platform checkout still records the owner\'s free month, and never reaches the move-in code', async () => {
  const fake = new FakeFirestore({ 'facilityCreatorAccounts/acct_owner': { ownerUid: 'uid_owner' } });
  useFakeFirestore(fake);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () => ({
      subscriptions: {
        retrieve: async () => {
          throw new Error('fake stripe: subscription lookups are not part of this test');
        },
      },
    }),
  });

  await handleCheckoutCompleted(
    { id: 'cs_platform', metadata: { accountId: 'acct_owner', firstMonthFree: 'true' }, subscription: 'sub_1' } as unknown as Stripe.Checkout.Session,
  );

  assert.ok(fake.read('facilityCreatorAccounts/acct_owner')?.platformFirstMonthFreeUsedAt);
  assert.deepEqual(fake.list('publicMoveInPaidCheckouts'), []);
});
