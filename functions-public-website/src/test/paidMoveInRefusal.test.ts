/**
 * A renter who has paid is moved in or refunded, never just turned away.
 *
 * completePublicMoveIn checked the reservation, the unit and the Do Not Rent
 * list after Checkout had taken the payment, and threw when any of them had
 * changed: the renter was left paid with no tenancy and no refund, and the
 * owner was told nothing. The unit was also written without being read in
 * the transaction, so a unit rented to someone else in the meantime was
 * taken from them.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'fs';
import * as path from 'path';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-paid';
const UNIT = 'unit-paid';
const RESERVATION = 'res-paid';
const TOKEN = 'paid-move-in-token-0123456789';
const ACCOUNT = 'acct_paid';
const PI = 'pi_paid';
const EMAIL = 'renter@example.com';
const UNIT_PATH = `facilities/${FACILITY}/units/${UNIT}`;
const RESERVATION_PATH = `publicReservations/${RESERVATION}`;
const HOLD_PATH = `facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`;
const USE_PATH = `publicMoveInPayments/${PI}`;
const REFUND_ALERT_PATH = `facilities/${FACILITY}/Notifications/move-in-refund-${PI}`;
const ALREADY_USED = 'This payment has already been used to complete a move-in. Contact the facility.';

const FACILITY_DATA = {
  name: 'Paid Storage',
  stripeConnectAccountId: ACCOUNT,
  stripeConnectOnboardingComplete: true,
};

/** How checkout tags the PaymentIntent it creates. */
const TAGGED = { type: 'public_move_in', reservationId: RESERVATION };

type StripeStub = {
  /** Paid in full by default. */
  amountReceived?: number;
  metadata?: Record<string, string>;
  /** The Checkout Sessions Stripe lists for the payment, or the error it gives. */
  sessions?: Array<{ metadata: Record<string, string> }> | Error;
  /** refunds.create fails with this while it is set. */
  refundError?: { code?: string; message: string } | null;
  /** Runs when completion asks Stripe for the payment: after its first read of the unit, before its transaction. */
  onRetrieve?: () => void;
};

type StripeCalls = {
  refunds: Array<{ params: Record<string, any>; options: Record<string, any> }>;
  sessionLookups: number;
};

/** A facility taking card payments online, with [UNIT] held for [RESERVATION] and checkout started. */
function seedPaidRental(inMemory: InMemoryFirestore, reservationFields: Record<string, unknown> = {}): number {
  inMemory.seed(`facilities/${FACILITY}`, FACILITY_DATA);
  inMemory.seed(UNIT_PATH, { status: 'available', unitNumber: 'P1', unitType: 'standard', monthlyRate: 100 });
  const reservation = {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'P1',
    status: 'pending',
    moveInToken: TOKEN,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    expiresAt: Timestamp.fromDate(new Date(Date.now() + 10 * 60 * 1000)),
    email: EMAIL,
    name: 'Rita Renter',
    metadata: {},
  };
  const quote = computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(UNIT_PATH) as Record<string, any>,
    facilityData: FACILITY_DATA,
    publicSettings: {},
    moveInDate: reservation.moveInDate.toDate(),
  });
  assert.ok(quote.totalCents > 0);
  // As createPublicMoveInCheckout leaves it.
  inMemory.seed(RESERVATION_PATH, {
    ...reservation,
    expectedCheckoutAmountCents: quote.totalCents,
    checkoutUpdatedAt: Timestamp.now(),
    ...reservationFields,
  });
  inMemory.seed(HOLD_PATH, { facilityId: FACILITY, unitId: UNIT, reservationId: RESERVATION, status: 'pending' });
  return quote.totalCents;
}

function loadPublicMoveIn(inMemory: InMemoryFirestore, paidCents: number, stub: StripeStub = {}) {
  installInMemoryFirestore(inMemory);
  const calls: StripeCalls = { refunds: [], sessionLookups: 0 };
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        paymentIntents: {
          retrieve: async (id: string, options: { stripeAccount?: string }) => {
            assert.equal(options?.stripeAccount, ACCOUNT);
            stub.onRetrieve?.();
            return {
              id,
              amount_received: stub.amountReceived ?? paidCents,
              status: 'succeeded',
              metadata: stub.metadata ?? TAGGED,
            };
          },
        },
        checkout: {
          sessions: {
            list: async (params: { payment_intent?: string }, options: { stripeAccount?: string }) => {
              calls.sessionLookups += 1;
              assert.equal(params.payment_intent, PI);
              assert.equal(options?.stripeAccount, ACCOUNT);
              if (stub.sessions instanceof Error) throw stub.sessions;
              return { data: stub.sessions ?? [] };
            },
          },
        },
        refunds: {
          create: async (params: Record<string, any>, options: Record<string, any>) => {
            calls.refunds.push({ params, options });
            if (stub.refundError) {
              throw Object.assign(new Error(stub.refundError.message), { code: stub.refundError.code });
            }
            return { id: `re_${calls.refunds.length}` };
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const refundSweep = require('../pendingMoveInRefundSweep') as typeof import('../pendingMoveInRefundSweep');
  const request = {
    reservationId: RESERVATION,
    token: TOKEN,
    name: 'Rita Renter',
    email: EMAIL,
    phone: '5551234567',
    signaturePngBase64:
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    paymentIntentId: PI,
  };
  return {
    calls,
    complete: (overrides: Record<string, unknown> = {}) =>
      testEnv.wrap(moveIn.completePublicMoveIn)({ ...request, ...overrides }, callableContext) as Promise<{
        success?: boolean;
        tenantId?: string;
      }>,
    getByToken: () =>
      testEnv.wrap(moveIn.getPublicReservationByToken)({ token: TOKEN }, callableContext) as Promise<{
        found?: boolean;
      }>,
    /** One run of the scheduled sweep of stalled refunds, as deployed. */
    sweep: () => testEnv.wrap(refundSweep.resumeStalledMoveInRefunds)({}),
    sweepFunction: refundSweep.resumeStalledMoveInRefunds,
  };
}

/** The renter was refused with [pattern], and told their payment was refunded (or will be). */
function refundedWith(pattern: RegExp, refunded = true) {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string; details?: Record<string, unknown> };
    assert.equal(e.code, 'failed-precondition');
    assert.match(String(e.message), pattern);
    assert.match(
      String(e.message),
      refunded ? /has been refunded to your card/ : /The facility has been told and will refund/,
    );
    assert.deepEqual(e.details, { refunded, paymentIntentId: PI });
    return true;
  };
}

function refusedWith(code: string, message: string) {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string };
    assert.equal(e.code, code);
    assert.equal(e.message, message);
    return true;
  };
}

function tenants(inMemory: InMemoryFirestore): string[] {
  return inMemory.listCollection(`facilities/${FACILITY}/tenants`);
}

function alerts(inMemory: InMemoryFirestore): string[] {
  return inMemory.listCollection(`facilities/${FACILITY}/Notifications`);
}

/** One full refund of [PI] on the facility's account, keyed so Stripe makes it once. */
function assertRefundedOnce(calls: StripeCalls) {
  assert.equal(calls.refunds.length, 1);
  assertRefundCall(calls.refunds[0]);
}

function assertRefundCall(call: StripeCalls['refunds'][number]) {
  assert.equal(call.params.payment_intent, PI);
  assert.equal(call.params.amount, undefined);
  assert.equal(call.options.stripeAccount, ACCOUNT);
  assert.equal(call.options.idempotencyKey, `public_move_in_refund_${PI}`);
}

/** The owner's alert of the refund, and the payment's record, say how it went. */
function assertRefundRecorded(
  inMemory: InMemoryFirestore,
  refusal: string,
  status: 'refunded' | 'failed',
  paidCents: number,
) {
  const use = inMemory.read(USE_PATH) as Record<string, any>;
  assert.equal(use.reservationId, RESERVATION);
  assert.equal(use.tenantId, null);
  assert.equal(use.amountReceivedCents, paidCents);
  assert.equal(use.refund.refusal, refusal);
  assert.equal(use.refund.status, status);

  assert.deepEqual(alerts(inMemory), [REFUND_ALERT_PATH]);
  const alert = inMemory.read(REFUND_ALERT_PATH) as Record<string, any>;
  // The type the app's alert banner shows.
  assert.equal(alert.type, 'ONLINE_MOVE_IN_REVIEW');
  assert.equal(alert.readAt, null);
  assert.equal(alert.tenantName, 'Rita Renter');
  assert.match(String(alert.message), /Rita Renter paid \$\d+\.\d\d online for unit P1, but was not moved in/);
  assert.equal(alert.metadata.reason, refusal);
  assert.equal(alert.metadata.paymentIntentId, PI);
  assert.equal(alert.metadata.reservationId, RESERVATION);
  assert.equal(alert.metadata.refundStatus, status);
  if (status === 'refunded') {
    assert.match(String(alert.message), /refunded to them automatically/);
    // The owner is not left to find out from their Stripe balance.
    assert.match(String(alert.message), /Stripe does not return its processing fee on a refund\./);
  } else {
    assert.match(String(alert.message), new RegExp(`Refund payment ${PI} in your Stripe dashboard`));
  }
}

/** Nothing of the move-in was written. */
function assertNotMovedIn(inMemory: InMemoryFirestore) {
  assert.deepEqual(tenants(inMemory), []);
  assert.deepEqual(inMemory.listCollection(`facilities/${FACILITY}/contracts`), []);
  assert.deepEqual(inMemory.listCollection(`facilities/${FACILITY}/ledgers`), []);
}

test('a renter who has paid for a unit rented while their payment was checked is refunded, and the other tenant keeps it', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents, {
    // The owner rents the unit to someone else after completion first read it.
    onRetrieve: () =>
      inMemory.seed(UNIT_PATH, {
        status: 'occupied',
        unitNumber: 'P1',
        unitType: 'standard',
        monthlyRate: 100,
        tenantId: 'tenant-other',
        tenantName: 'Otto Other',
      }),
  });

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service while you were paying/));

  // Before: the unit was written without being read again, so it went to
  // the new renter over the tenant who had it.
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, 'tenant-other');
  assert.equal(inMemory.read(UNIT_PATH)?.tenantName, 'Otto Other');
  assertNotMovedIn(inMemory);
  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'unit-taken', 'refunded', paidCents);
  // The reservation is over, and its hold released.
  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, any>;
  assert.equal(reservation.status, 'cancelled');
  assert.equal(reservation.cancelReason, 'paid-move-in-refused:unit-taken');
  assert.equal(reservation.refundedPaymentIntentId, PI);
  assert.equal(inMemory.read(HOLD_PATH), undefined);
});

for (const [why, unitFields] of [
  ['rented since the hold', { status: 'occupied' }],
  ['taken out of service since the hold', { status: 'maintenance' }],
  ['linked to a tenant since the hold', { tenantId: 'tenant-other' }],
] as Array<[string, Record<string, unknown>]>) {
  test(`a renter who has paid for a unit ${why} is refunded, not turned away with their money kept`, async () => {
    const inMemory = new InMemoryFirestore();
    const paidCents = seedPaidRental(inMemory);
    inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), ...unitFields });
    const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

    // Before: 'Unit is no longer available', and the payment kept.
    await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));

    assertNotMovedIn(inMemory);
    assertRefundedOnce(calls);
    assertRefundRecorded(inMemory, 'unit-taken', 'refunded', paidCents);
  });
}

test('a renter who has paid for a unit deleted since the hold is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.getStore().delete(UNIT_PATH);
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  // Before: 'Reserved unit not found', and the payment kept.
  await assert.rejects(() => complete(), refundedWith(/This unit was removed while you were paying/));

  assertNotMovedIn(inMemory);
  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'unit-missing', 'refunded', paidCents);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'cancelled');
});

test('a renter who has paid for a unit deleted while their payment was checked is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents, {
    onRetrieve: () => inMemory.getStore().delete(UNIT_PATH),
  });

  // Before: the transaction's update of the missing unit failed as an
  // internal error, and the payment was kept.
  await assert.rejects(() => complete(), refundedWith(/This unit was removed while you were paying/));

  assertNotMovedIn(inMemory);
  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'unit-missing', 'refunded', paidCents);
});

test('a renter who has paid and was added to the Do Not Rent list since checkout is refunded, not moved in', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(`facilities/${FACILITY}/dnr/entry-1`, { active: true, emailLower: EMAIL, nameLower: 'someone' });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  // The screening's own words: the renter is not told they are on a list.
  // Before: this, with the payment kept.
  await assert.rejects(
    () => complete(),
    refundedWith(/^Online move-in is not available\. Please contact the facility directly\./),
  );

  assertNotMovedIn(inMemory);
  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'do-not-rent', 'refunded', paidCents);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'available');
});

test('a failed Do Not Rent lookup after payment moves the renter in: they were screened before paying', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.queryErrors.set('**/dnr', Object.assign(new Error('unavailable'), { code: 14 }));
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  const result = await complete();

  // Before: the read error failed the move-in, and the payment was kept.
  assert.equal(result.success, true);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
  assert.deepEqual(calls.refunds, []);
});

test('with nothing paid, a Do Not Rent match and a rented unit are refused as before, and nothing is refunded', async () => {
  for (const setUp of [
    (inMemory: InMemoryFirestore) =>
      inMemory.seed(`facilities/${FACILITY}/dnr/entry-1`, { active: true, emailLower: EMAIL }),
    (inMemory: InMemoryFirestore) => inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' }),
  ]) {
    const inMemory = new InMemoryFirestore();
    seedPaidRental(inMemory);
    // No Stripe: this facility takes nothing online, so nothing was paid.
    inMemory.seed(`facilities/${FACILITY}`, { name: 'Paid Storage' });
    setUp(inMemory);
    const { complete, calls } = loadPublicMoveIn(inMemory, 0);

    await assert.rejects(() => complete({ paymentIntentId: undefined, skipPayment: true }), (err: unknown) => {
      const e = err as { code?: string; message?: string };
      assert.equal(e.code, 'failed-precondition');
      assert.doesNotMatch(String(e.message), /refund/);
      return true;
    });

    assertNotMovedIn(inMemory);
    assert.deepEqual(calls.refunds, []);
    assert.deepEqual(alerts(inMemory), []);
    assert.equal(inMemory.read(USE_PATH), undefined);
    assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'pending');
  }
});

test('a paid completion retried after its refund refunds nothing more and adds no alert', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));
  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));

  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'unit-taken', 'refunded', paidCents);
});

test('a failed automatic refund tells the owner to refund by hand, and a retry refunds it once', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
  const stub: StripeStub = { refundError: { message: 'Stripe is down' } };
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents, stub);

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/, false));

  assertRefundRecorded(inMemory, 'unit-taken', 'failed', paidCents);
  assert.match(String(inMemory.read(REFUND_ALERT_PATH)?.message), /automatic refund failed \(Stripe is down\)/);

  // The owner read the alert; then the renter tried again, with Stripe back.
  inMemory.seed(REFUND_ALERT_PATH, { ...inMemory.read(REFUND_ALERT_PATH), readAt: Timestamp.now() });
  stub.refundError = null;
  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));

  assert.equal(calls.refunds.length, 2);
  calls.refunds.forEach(assertRefundCall);
  assertRefundRecorded(inMemory, 'unit-taken', 'refunded', paidCents);
  // Merged into the alert, not in place of what it said.
  assert.equal((inMemory.read(REFUND_ALERT_PATH) as Record<string, any>).metadata.reason, 'unit-taken');
});

test('a refund Stripe has already made is recorded as refunded, not failed', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents, {
    refundError: { code: 'charge_already_refunded', message: 'Charge has already been refunded.' },
  });

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));

  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'unit-taken', 'refunded', paidCents);
});

test('a renter whose charges changed while they paid is refunded, and the reservation stays open to pay again', async () => {
  const inMemory = new InMemoryFirestore();
  const quotedCents = seedPaidRental(inMemory);
  // Checkout charged an older, lower quote; the owner has raised the rate since.
  const paidCents = quotedCents - 500;
  inMemory.seed(RESERVATION_PATH, { ...inMemory.read(RESERVATION_PATH), expectedCheckoutAmountCents: paidCents });
  const { complete, calls } = loadPublicMoveIn(inMemory, quotedCents, { amountReceived: paidCents });

  // Before: 'Move-in charges changed since checkout started. Refresh and
  // try again.', with the first payment kept, so paying again paid twice.
  await assert.rejects(() => complete(), refundedWith(/The move-in charges changed while you were paying/));

  assertNotMovedIn(inMemory);
  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'charges-changed', 'refunded', paidCents);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'pending');
  assert.ok(inMemory.read(HOLD_PATH));
});

test('a renter who paid again for a reservation already completed is refunded the second payment', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory, { status: 'completed', paymentIntentId: 'pi_first' });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  // Before: 'Reservation is not active', and the second payment kept.
  await assert.rejects(() => complete(), refundedWith(/already completed or cancelled/));

  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'reservation-closed', 'refunded', paidCents);
  // Left as it was: this payment did not close it.
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'completed');
});

test('a renter who has paid for a reservation cancelled while they paid is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory, { status: 'cancelled' });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  await assert.rejects(() => complete(), refundedWith(/already completed or cancelled/));

  assertNotMovedIn(inMemory);
  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'reservation-closed', 'refunded', paidCents);
});

test('the payment that completed a reservation, offered to it again, is refused as used and never refunded', async () => {
  const inMemory = new InMemoryFirestore();
  // Completed with this payment, with neither a use record nor a ledger
  // entry to show it.
  const paidCents = seedPaidRental(inMemory, { status: 'completed', paymentIntentId: PI });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  // A refund here would hand the renter back the rent for a unit they keep.
  await assert.rejects(() => complete(), refusedWith('failed-precondition', ALREADY_USED));

  assert.deepEqual(calls.refunds, []);
  assert.deepEqual(alerts(inMemory), []);
  assert.equal(inMemory.read(USE_PATH), undefined);
});

test('a payment that completed a move-in is refused as used when offered again, and never refunded', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  assert.equal((await complete()).success, true);
  await assert.rejects(() => complete(), refusedWith('failed-precondition', ALREADY_USED));

  assert.deepEqual(calls.refunds, []);
  assert.equal(tenants(inMemory).length, 1);
});

test('while earlier move-ins cannot be checked, a payment is not refunded, and trying again refunds it', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory, { status: 'completed' });
  const ledgerError = Object.assign(new Error('unavailable'), { code: 14 });
  inMemory.queryErrors.set(`facilities/${FACILITY}/ledgers`, ledgerError);
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  // The reservation was completed before payments had use records: this
  // payment may be the one that completed it.
  await assert.rejects(
    () => complete(),
    refusedWith('unavailable', 'Your payment could not be checked just now. Please try again in a moment.'),
  );
  assert.deepEqual(calls.refunds, []);
  assert.equal(inMemory.read(USE_PATH), undefined);
  assert.deepEqual(alerts(inMemory), []);

  // No ledger entry of it, once the lookup works: a second payment.
  inMemory.queryErrors.delete(`facilities/${FACILITY}/ledgers`);
  await assert.rejects(() => complete(), refundedWith(/already completed or cancelled/));
  assertRefundedOnce(calls);
});

test('an untagged payment is refunded once Stripe shows its Checkout Session was for this reservation', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
  // Paid through a session created before checkout tagged its payments.
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents, {
    metadata: {},
    sessions: [{ metadata: { type: 'public_move_in', reservationId: RESERVATION, facilityId: FACILITY } }],
  });

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));

  assert.equal(calls.sessionLookups, 1);
  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'unit-taken', 'refunded', paidCents);
});

for (const [why, sessions] of [
  ['another kind of Checkout Session', [{ metadata: { type: 'public_payment_link', reservationId: RESERVATION } }]],
  ['another reservation\'s Checkout Session', [{ metadata: { type: 'public_move_in', reservationId: 'res-other' } }]],
  ['no Checkout Session', []],
] as Array<[string, Array<{ metadata: Record<string, string> }>]>) {
  test(`an untagged payment from ${why} is not refunded: the renter is refused as unpaid`, async () => {
    const inMemory = new InMemoryFirestore();
    const paidCents = seedPaidRental(inMemory);
    inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
    const { complete, calls } = loadPublicMoveIn(inMemory, paidCents, { metadata: {}, sessions });

    // Refunding a payment made for something else would take the owner's money.
    await assert.rejects(() => complete(), refusedWith('failed-precondition', 'Unit is no longer available'));

    assert.deepEqual(calls.refunds, []);
    assert.deepEqual(alerts(inMemory), []);
    assert.equal(inMemory.read(USE_PATH), undefined);
    assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'pending');
  });
}

test('when Stripe cannot say whose an untagged payment is, the owner is told to check it and nothing is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents, {
    metadata: {},
    sessions: new Error('Stripe is down'),
  });

  // Before: 'Unit is no longer available', which the move-in page shows as
  // 'choose another unit', with nothing said about the money paid.
  await assert.rejects(() => complete(), (err: unknown) => {
    const e = err as { code?: string; message?: string; details?: Record<string, unknown> };
    assert.equal(e.code, 'failed-precondition');
    assert.match(String(e.message), /^This unit was rented or taken out of service while you were paying/);
    assert.match(
      String(e.message),
      /Your payment of \$\d+\.\d\d could not be checked automatically just now, so it has not been refunded yet\. The facility has been told and will look at your payment\.$/,
    );
    assert.doesNotMatch(String(e.message), /no longer available|not currently available/);
    assert.deepEqual(e.details, { refunded: false, paymentIntentId: PI });
    return true;
  });

  assert.deepEqual(calls.refunds, []);
  // No use record: a retry once Stripe answers can still refund it.
  assert.equal(inMemory.read(USE_PATH), undefined);
  const reviewPath = `facilities/${FACILITY}/Notifications/move-in-payment-review-${PI}`;
  assert.deepEqual(alerts(inMemory), [reviewPath]);
  const alert = inMemory.read(reviewPath) as Record<string, any>;
  assert.equal(alert.type, 'ONLINE_MOVE_IN_REVIEW');
  assert.equal(alert.readAt, null);
  assert.equal(alert.metadata.refundStatus, 'not-attempted');
  assert.match(String(alert.message), /Check it in your Stripe dashboard and refund it/);
});

test('a paid portal move-in whose portal account no longer matches is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory, {
    metadata: { source: 'tenant_portal_additional_unit', portalTenantId: 'tenant-source' },
  });
  // The source tenant's portal was turned off while they paid.
  inMemory.seed(`facilities/${FACILITY}/tenants/tenant-source`, {
    name: 'Rita Renter',
    emailLower: EMAIL,
    portalEnabled: false,
  });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  // Before: 'Portal-linked move-in validation failed', and the payment kept.
  await assert.rejects(() => complete(), refundedWith(/could not be linked to your tenant portal account/));

  // No tenant but the one they rent from already.
  assert.deepEqual(tenants(inMemory), [`facilities/${FACILITY}/tenants/tenant-source`]);
  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'portal-link', 'refunded', paidCents);
});

test('a renter who paid after their hold ran out is moved in: paying can take longer than the hold', async () => {
  for (const reservationFields of [
    { expiresAt: Timestamp.fromDate(new Date(Date.now() - 60 * 1000)) },
    // Marked expired by an earlier call that found the hold run out.
    { status: 'expired', expiresAt: Timestamp.fromDate(new Date(Date.now() - 60 * 1000)) },
  ]) {
    const inMemory = new InMemoryFirestore();
    const paidCents = seedPaidRental(inMemory, reservationFields);
    const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

    // Before: 'Reservation has expired' / 'Reservation is not active', with
    // the payment kept.
    const result = await complete();

    assert.equal(result.success, true);
    assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
    assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'completed');
    assert.deepEqual(calls.refunds, []);
  }
});

test('a move-in with nothing paid is still refused once its hold runs out', async () => {
  const inMemory = new InMemoryFirestore();
  seedPaidRental(inMemory, { expiresAt: Timestamp.fromDate(new Date(Date.now() - 60 * 1000)) });
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Paid Storage' });
  const { complete } = loadPublicMoveIn(inMemory, 0);

  await assert.rejects(
    () => complete({ paymentIntentId: undefined, skipPayment: true }),
    refusedWith('failed-precondition', 'Reservation has expired'),
  );
  // Left open: checkout started, so the renter may yet come back having paid.
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'pending');
});

test('a reservation whose hold ran out after checkout started still loads, so a renter who paid can finish', async () => {
  const inMemory = new InMemoryFirestore();
  seedPaidRental(inMemory, { expiresAt: Timestamp.fromDate(new Date(Date.now() - 60 * 1000)) });
  const { getByToken } = loadPublicMoveIn(inMemory, 0);

  // Before: marked expired and 'not found', with the renter paid.
  assert.equal((await getByToken()).found, true);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'pending');
});

test('a reservation whose hold ran out with no checkout started is expired, as before', async () => {
  for (const checkoutUpdatedAt of [undefined, Timestamp.fromDate(new Date(Date.now() - 25 * 60 * 60 * 1000))]) {
    const inMemory = new InMemoryFirestore();
    seedPaidRental(inMemory, { expiresAt: Timestamp.fromDate(new Date(Date.now() - 60 * 1000)) });
    const reservation = inMemory.read(RESERVATION_PATH) as Record<string, unknown>;
    delete reservation.checkoutUpdatedAt;
    inMemory.seed(RESERVATION_PATH, checkoutUpdatedAt ? { ...reservation, checkoutUpdatedAt } : reservation);
    const { getByToken } = loadPublicMoveIn(inMemory, 0);

    assert.equal((await getByToken()).found, false);
    assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'expired');
  }
});

/** The one-use record refusePaidMoveIn writes when it decides a refund, before Stripe is asked. */
function pendingRefundRecord(paidCents: number, decidedMinutesAgo: number): Record<string, unknown> {
  return {
    paymentIntentId: PI,
    facilityId: FACILITY,
    reservationId: RESERVATION,
    tenantId: null,
    contractId: null,
    amountReceivedCents: paidCents,
    refund: { status: 'pending', refusal: 'unit-taken', unitId: UNIT, unitNumber: 'P1', renterName: 'Rita Renter' },
    createdAt: Timestamp.fromMillis(Date.now() - decidedMinutesAgo * 60 * 1000),
    createdBy: 'publicMoveIn',
  };
}

test('a refund a racing completion decided before this one moved in is finished, and nobody is moved in', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);
  // After this completion's first look at the payment's record, as its
  // move-in transaction starts.
  inMemory.beforeTransaction = (n) => {
    if (n === 1) inMemory.seed(USE_PATH, { ...pendingRefundRecord(paidCents, 0), connectAccountId: ACCOUNT });
  };

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));

  // A move-in here would give the renter the unit and their money back.
  assertNotMovedIn(inMemory);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'available');
  assertRefundedOnce(calls);
  assert.equal((inMemory.read(USE_PATH) as Record<string, any>).refund.status, 'refunded');
});

test('a refund leaves another reservation\'s hold on the unit alone', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
  const theirs = { facilityId: FACILITY, unitId: UNIT, reservationId: 'res-someone-else', status: 'pending' };
  inMemory.seed(HOLD_PATH, theirs);
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));

  assertRefundedOnce(calls);
  assert.equal(inMemory.read(RESERVATION_PATH)?.status, 'cancelled');
  assert.deepEqual(inMemory.read(HOLD_PATH), theirs);
});

test('a reservation another completion finished while this payment was refused stays completed', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  // A second payment: the first completed the move-in while this one was checked.
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied', tenantId: 'tenant-first' });
  const { complete, calls } = loadPublicMoveIn(inMemory, paidCents);
  inMemory.beforeTransaction = (n) => {
    if (n === 1) {
      inMemory.seed(RESERVATION_PATH, {
        ...inMemory.read(RESERVATION_PATH),
        status: 'completed',
        paymentIntentId: 'pi_first',
        tenantId: 'tenant-first',
      });
    }
  };

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));

  // This payment is refunded; the tenancy the first one bought is not undone.
  assertRefundedOnce(calls);
  const reservation = inMemory.read(RESERVATION_PATH) as Record<string, any>;
  assert.equal(reservation.status, 'completed');
  assert.equal(reservation.paymentIntentId, 'pi_first');
  assert.equal(reservation.cancelReason, undefined);
});

test('a refund Stripe made but nobody recorded is finished by the sweep, with the same key, once it has stalled', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
  // The instance fails after Stripe refunds, before the outcome is written.
  inMemory.writeErrorsOutsideTransactions.set('publicMoveInPayments', new Error('deadline exceeded'));
  const { complete, calls, sweep } = loadPublicMoveIn(inMemory, paidCents);

  await assert.rejects(() => complete(), refundedWith(/rented or taken out of service/));
  inMemory.writeErrorsOutsideTransactions.delete('publicMoveInPayments');

  assert.equal((inMemory.read(USE_PATH) as Record<string, any>).refund.status, 'pending');
  // Before: 'The payment is being refunded to them automatically', for good.
  const pending = String(inMemory.read(REFUND_ALERT_PATH)?.message);
  assert.match(pending, /An automatic refund has been started, and this alert will say when Stripe has made it\./);
  assert.match(pending, new RegExp(`If it still says this in an hour, check payment ${PI} in your Stripe dashboard\\.`));
  assert.match(pending, /Stripe does not return its processing fee on a refund\./);

  // Decided five minutes ago: a completion may still be finishing it.
  inMemory.seed(USE_PATH, { ...inMemory.read(USE_PATH), createdAt: Timestamp.fromMillis(Date.now() - 5 * 60 * 1000) });
  await sweep();
  assert.equal(calls.refunds.length, 1);

  inMemory.seed(USE_PATH, { ...inMemory.read(USE_PATH), createdAt: Timestamp.fromMillis(Date.now() - 20 * 60 * 1000) });
  // The facility has moved to another Stripe account since: the refund is
  // made on the account that holds the payment (assertRefundCall: ACCOUNT).
  inMemory.seed(`facilities/${FACILITY}`, { ...FACILITY_DATA, stripeConnectAccountId: 'acct_moved_since' });
  await sweep();

  // Asked again with the first attempt's key, so Stripe does not refund twice.
  assert.equal(calls.refunds.length, 2);
  calls.refunds.forEach(assertRefundCall);
  assertRefundRecorded(inMemory, 'unit-taken', 'refunded', paidCents);
});

test('the sweep is deployed every 15 minutes, with the Stripe key it refunds with', () => {
  const inMemory = new InMemoryFirestore();
  const { sweepFunction } = loadPublicMoveIn(inMemory, 0);
  const endpoint = (sweepFunction as unknown as { __endpoint: Record<string, any> }).__endpoint;

  assert.equal(endpoint.scheduleTrigger?.schedule, 'every 15 minutes');
  // Without it, getStripeClient has no key and every refund it retries fails.
  assert.ok(
    (endpoint.secretEnvironmentVariables as Array<{ key: string }>).some((s) => s.key === 'STRIPE_SECRET_KEY'),
  );
  // Exported from the codebase's entry point, which is what firebase deploys.
  const entry = fs.readFileSync(path.join(__dirname, '..', 'index.js'), 'utf8');
  assert.match(entry, /exports, "resumeStalledMoveInRefunds"/);
});

test('the sweep refunds a stalled refund nobody retried, and leaves the rest alone', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidRental(inMemory);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), status: 'occupied' });
  // Decided 20 minutes ago by a completion that died before Stripe was asked,
  // and written before records kept the Stripe account: the facility's is used.
  inMemory.seed(USE_PATH, pendingRefundRecord(paidCents, 20));
  inMemory.seed(REFUND_ALERT_PATH, {
    type: 'ONLINE_MOVE_IN_REVIEW',
    facilityId: FACILITY,
    tenantId: null,
    tenantName: 'Rita Renter',
    readAt: null,
    message: 'pending',
    metadata: { reason: 'unit-taken', paymentIntentId: PI, reservationId: RESERVATION, refundStatus: 'pending' },
  });
  const others: Record<string, Record<string, unknown>> = {
    // Too recent to be stalled.
    'publicMoveInPayments/pi_young': { ...pendingRefundRecord(paidCents, 5), paymentIntentId: 'pi_young' },
    // Failed: the owner was told to refund it by hand.
    'publicMoveInPayments/pi_failed': {
      ...pendingRefundRecord(paidCents, 60),
      paymentIntentId: 'pi_failed',
      refund: { status: 'failed', refusal: 'unit-taken', unitId: UNIT, unitNumber: 'P1', renterName: 'Rita Renter' },
    },
    // Completed a move-in: never refunded.
    'publicMoveInPayments/pi_used': { paymentIntentId: 'pi_used', tenantId: 'tenant-1', createdAt: Timestamp.fromMillis(0) },
  };
  for (const [path, data] of Object.entries(others)) inMemory.seed(path, data);
  const { calls, sweep } = loadPublicMoveIn(inMemory, paidCents);

  await sweep();

  assertRefundedOnce(calls);
  assertRefundRecorded(inMemory, 'unit-taken', 'refunded', paidCents);
  for (const [path, data] of Object.entries(others)) assert.deepEqual(inMemory.read(path), data);
});

test.after(() => {
  testEnv.cleanup();
});
