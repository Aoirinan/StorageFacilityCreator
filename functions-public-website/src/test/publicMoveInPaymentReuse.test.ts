/**
 * One payment completes one online move-in.
 *
 * completePublicMoveIn checked only that the PaymentIntent had succeeded for
 * at least the amount due. confirmPublicMoveInCheckout hands its id to the
 * renter's browser, so a renter who paid for one unit could hold a second at
 * the same facility and complete it with the first payment, and the payment
 * was posted to the ledger twice.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-reuse';
const OTHER_FACILITY = 'fac-reuse-sister';
const CONNECT_ACCOUNT = 'acct_reuse';
const MOVE_IN_DATE = new Date(2026, 8, 25);
const ALREADY_USED = 'This payment has already been used to complete a move-in. Contact the facility.';
const OTHER_RESERVATION = 'This payment was made for a different reservation. Contact the facility.';

const FACILITY_DATA = {
  name: 'Reuse Storage',
  stripeConnectAccountId: CONNECT_ACCOUNT,
  stripeConnectOnboardingComplete: true,
};

type Rental = { facilityId: string; reservationId: string; unitId: string; unitNumber: string; token: string };

/** The unit the renter pays for. */
const FIRST: Rental = {
  facilityId: FACILITY,
  reservationId: 'res-reuse-1',
  unitId: 'unit-reuse-1',
  unitNumber: 'R1',
  token: 'reuse-move-in-token-first-0123456789',
};

/** A second, cheaper unit the same renter holds at the same facility. */
const SECOND: Rental = {
  facilityId: FACILITY,
  reservationId: 'res-reuse-2',
  unitId: 'unit-reuse-2',
  unitNumber: 'R2',
  token: 'reuse-move-in-token-second-0123456789',
};

/** A unit at a second facility the owner connected to the same Stripe account. */
const SISTER: Rental = {
  facilityId: OTHER_FACILITY,
  reservationId: 'res-reuse-sister',
  unitId: 'unit-reuse-sister',
  unitNumber: 'S1',
  token: 'reuse-move-in-token-sister-0123456789',
};

const UNIT_RATES: Record<string, number> = { [FIRST.unitId]: 100, [SECOND.unitId]: 80, [SISTER.unitId]: 80 };

type StubPaymentIntent = {
  amount_received: number;
  status: string;
  metadata?: Record<string, string>;
};

function seedRental(inMemory: InMemoryFirestore, rental: Rental) {
  inMemory.seed(`facilities/${rental.facilityId}/units/${rental.unitId}`, {
    status: 'reserved',
    unitNumber: rental.unitNumber,
    unitType: 'standard',
    monthlyRate: UNIT_RATES[rental.unitId],
  });
  inMemory.seed(`publicReservations/${rental.reservationId}`, {
    facilityId: rental.facilityId,
    unitId: rental.unitId,
    unitNumber: rental.unitNumber,
    status: 'pending',
    moveInToken: rental.token,
    moveInDate: Timestamp.fromDate(MOVE_IN_DATE),
    expiresAt: Timestamp.fromDate(new Date(Date.now() + 10 * 60 * 1000)),
    email: 'renter@example.com',
    name: 'Rita Renter',
    metadata: {},
  });
}

/** The amount a rental's move-in costs, as the callable computes it. */
function amountDueCents(inMemory: InMemoryFirestore, rental: Rental): number {
  return computePublicMoveInCharges({
    reservation: inMemory.read(`publicReservations/${rental.reservationId}`) as Record<string, any>,
    unitData: inMemory.read(`facilities/${rental.facilityId}/units/${rental.unitId}`) as Record<string, any>,
    facilityData: FACILITY_DATA,
    publicSettings: {},
    moveInDate: MOVE_IN_DATE,
  }).totalCents;
}

/** A facility taking card payments online, with the renter holding FIRST and SECOND. */
function seedFacility(): InMemoryFirestore {
  const inMemory = new InMemoryFirestore();
  inMemory.seed(`facilities/${FACILITY}`, FACILITY_DATA);
  seedRental(inMemory, FIRST);
  seedRental(inMemory, SECOND);
  // The attack needs a second unit that the first payment covers.
  assert.ok(amountDueCents(inMemory, SECOND) > 0);
  assert.ok(amountDueCents(inMemory, SECOND) < amountDueCents(inMemory, FIRST));
  return inMemory;
}

/** Loads publicMoveIn against [inMemory], with Stripe holding [paymentIntents]. */
function loadPublicMoveIn(inMemory: InMemoryFirestore, paymentIntents: Record<string, StubPaymentIntent>) {
  installInMemoryFirestore(inMemory);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        paymentIntents: {
          retrieve: async (id: string, options: { stripeAccount?: string }) => {
            const paymentIntent = paymentIntents[id];
            if (!paymentIntent || options?.stripeAccount !== CONNECT_ACCOUNT) {
              throw new Error(`No such payment_intent: '${id}'`);
            }
            return { id, metadata: {}, ...paymentIntent };
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  const wrapped = testEnv.wrap(moveIn.completePublicMoveIn);
  return (rental: Rental, paymentIntentId: string) =>
    wrapped(
      {
        reservationId: rental.reservationId,
        token: rental.token,
        name: 'Rita Renter',
        email: 'renter@example.com',
        phone: '5551234567',
        signaturePngBase64:
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        paymentIntentId,
      },
      callableContext,
    ) as Promise<{ success?: boolean; tenantId?: string }>;
}

/** A PaymentIntent whose metadata names [rental]'s reservation, set through the Checkout Session. */
function taggedPayment(inMemory: InMemoryFirestore, rental: Rental): StubPaymentIntent {
  return {
    amount_received: amountDueCents(inMemory, rental),
    status: 'succeeded',
    metadata: { type: 'public_move_in', reservationId: rental.reservationId, facilityId: rental.facilityId },
  };
}

/** A PaymentIntent with no metadata, as Checkout creates them today: Stripe returns `{}`. */
function untaggedPayment(inMemory: InMemoryFirestore, rental: Rental): StubPaymentIntent {
  return { amount_received: amountDueCents(inMemory, rental), status: 'succeeded', metadata: {} };
}

function refusedWith(message: string) {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string };
    assert.equal(e.code, 'failed-precondition');
    assert.equal(e.message, message);
    return true;
  };
}

function tenants(inMemory: InMemoryFirestore, facilityId = FACILITY): Array<Record<string, unknown>> {
  return inMemory
    .listCollection(`facilities/${facilityId}/tenants`)
    .map((path) => inMemory.read(path) as Record<string, unknown>);
}

/** Ledger entries posting [paymentIntentId] as a payment received. */
function paymentEntries(inMemory: InMemoryFirestore, paymentIntentId: string, facilityId = FACILITY) {
  return inMemory
    .listCollection(`facilities/${facilityId}/ledgers`)
    .map((path) => inMemory.read(path) as Record<string, unknown>)
    .filter((entry) => entry.type === 'payment' && entry.referenceId === paymentIntentId);
}

/** [rental] was not moved into: no tenant for its unit, and its hold and unit are as they were. */
function assertNotMovedIn(inMemory: InMemoryFirestore, rental: Rental) {
  assert.deepEqual(
    tenants(inMemory, rental.facilityId).filter((t) => t.unitNumber === rental.unitNumber),
    [],
    `no tenant for unit ${rental.unitNumber}`,
  );
  assert.equal(inMemory.read(`publicReservations/${rental.reservationId}`)?.status, 'pending');
  assert.equal(inMemory.read(`facilities/${rental.facilityId}/units/${rental.unitId}`)?.status, 'reserved');
}

test('a paid move-in completes, and its payment is recorded once', async () => {
  const inMemory = seedFacility();
  const complete = loadPublicMoveIn(inMemory, { pi_first: taggedPayment(inMemory, FIRST) });

  const result = await complete(FIRST, 'pi_first');

  assert.equal(result.success, true);
  assert.equal(tenants(inMemory).length, 1);
  assert.equal(inMemory.read(`facilities/${FACILITY}/units/${FIRST.unitId}`)?.status, 'occupied');
  const reservation = inMemory.read(`publicReservations/${FIRST.reservationId}`);
  assert.equal(reservation?.status, 'completed');
  assert.equal(reservation?.paymentIntentId, 'pi_first');
  const used = inMemory.read('publicMoveInPayments/pi_first');
  assert.equal(used?.reservationId, FIRST.reservationId);
  assert.equal(used?.facilityId, FACILITY);
  assert.equal(used?.tenantId, result.tenantId);
  assert.equal(paymentEntries(inMemory, 'pi_first').length, 1);
});

test('an untagged payment completes its own move-in once, and is refused for a second reservation, which gets no tenant', async () => {
  const inMemory = seedFacility();
  // Checkout's PaymentIntents carry no metadata, so this is the reuse exactly
  // as it could be done: pay for FIRST, move in, then offer the same payment
  // for the cheaper SECOND.
  const complete = loadPublicMoveIn(inMemory, { pi_first: untaggedPayment(inMemory, FIRST) });

  const first = await complete(FIRST, 'pi_first');
  assert.equal(first.success, true);

  await assert.rejects(() => complete(SECOND, 'pi_first'), refusedWith(ALREADY_USED));

  assertNotMovedIn(inMemory, SECOND);
  assert.equal(tenants(inMemory).length, 1);
  assert.equal(paymentEntries(inMemory, 'pi_first').length, 1);
  assert.equal(inMemory.read('publicMoveInPayments/pi_first')?.reservationId, FIRST.reservationId);
});

test('two completions racing on one untagged payment create one tenant', async () => {
  const inMemory = seedFacility();
  const complete = loadPublicMoveIn(inMemory, { pi_first: untaggedPayment(inMemory, FIRST) });

  // Neither has posted its payment when the other checks, so only the record
  // read and written in the tenant's transaction can stop the second.
  const outcomes = await Promise.allSettled([complete(FIRST, 'pi_first'), complete(SECOND, 'pi_first')]);

  assert.equal(outcomes.filter((o) => o.status === 'fulfilled').length, 1);
  const refusal = outcomes.find((o): o is PromiseRejectedResult => o.status === 'rejected');
  assert.ok(refusal);
  refusedWith(ALREADY_USED)(refusal.reason);
  assert.equal(tenants(inMemory).length, 1);
  assert.equal(paymentEntries(inMemory, 'pi_first').length, 1);
});

test('a payment tagged for another reservation is refused, and nothing is written', async () => {
  const inMemory = seedFacility();
  // FIRST has not been moved into, so no record of use stands in the way.
  const complete = loadPublicMoveIn(inMemory, { pi_first: taggedPayment(inMemory, FIRST) });

  await assert.rejects(() => complete(SECOND, 'pi_first'), refusedWith(OTHER_RESERVATION));

  assertNotMovedIn(inMemory, SECOND);
  assert.equal(tenants(inMemory).length, 0);
  assert.equal(inMemory.read('publicMoveInPayments/pi_first'), undefined);
  assert.equal(paymentEntries(inMemory, 'pi_first').length, 0);
});

test('a payment tagged as another kind of payment is refused, and nothing is written', async () => {
  const inMemory = seedFacility();
  // A tenant portal payment on the same connected account, big enough to cover SECOND.
  const complete = loadPublicMoveIn(inMemory, {
    pi_portal: {
      amount_received: amountDueCents(inMemory, FIRST),
      status: 'succeeded',
      metadata: { type: 'tenant_portal_payment', facilityId: FACILITY, tenantId: 'tenant-existing' },
    },
  });

  await assert.rejects(() => complete(SECOND, 'pi_portal'), refusedWith(OTHER_RESERVATION));

  assertNotMovedIn(inMemory, SECOND);
  assert.equal(tenants(inMemory).length, 0);
});

test('a payment that completed a move-in before its use was recorded is refused', async () => {
  const inMemory = seedFacility();
  // FIRST was moved into before this change: its payment was posted to the
  // ledger, but no record of use was written.
  inMemory.seed(`facilities/${FACILITY}/ledgers/earlier-payment`, {
    tenantId: 'tenant-earlier',
    facilityId: FACILITY,
    type: 'payment',
    amount: -amountDueCents(inMemory, FIRST) / 100,
    description: 'Move-in payment',
    referenceId: 'pi_first',
    status: 'posted',
    createdBy: 'publicMoveIn',
    metadata: { paymentIntentId: 'pi_first' },
  });
  const complete = loadPublicMoveIn(inMemory, { pi_first: untaggedPayment(inMemory, FIRST) });

  await assert.rejects(() => complete(SECOND, 'pi_first'), refusedWith(ALREADY_USED));

  assertNotMovedIn(inMemory, SECOND);
  assert.equal(tenants(inMemory).length, 0);
  assert.equal(paymentEntries(inMemory, 'pi_first').length, 1);
});

test('a failed lookup of earlier move-ins does not turn away a renter who has paid', async () => {
  const inMemory = seedFacility();
  inMemory.queryErrors.set(`facilities/${FACILITY}/ledgers`, Object.assign(new Error('unavailable'), { code: 14 }));
  const complete = loadPublicMoveIn(inMemory, { pi_first: untaggedPayment(inMemory, FIRST) });

  const result = await complete(FIRST, 'pi_first');

  assert.equal(result.success, true);
  assert.equal(inMemory.read('publicMoveInPayments/pi_first')?.reservationId, FIRST.reservationId);
});

test('a payment used at one facility is refused at another on the same Stripe account', async () => {
  const inMemory = seedFacility();
  inMemory.seed(`facilities/${OTHER_FACILITY}`, { ...FACILITY_DATA, name: 'Reuse Storage Two' });
  seedRental(inMemory, SISTER);
  const complete = loadPublicMoveIn(inMemory, { pi_first: untaggedPayment(inMemory, FIRST) });

  assert.equal((await complete(FIRST, 'pi_first')).success, true);

  // The sister facility's ledger has no entry for this payment, so only the
  // record of use, which is not kept per facility, can refuse it.
  await assert.rejects(() => complete(SISTER, 'pi_first'), refusedWith(ALREADY_USED));

  assertNotMovedIn(inMemory, SISTER);
  assert.equal(tenants(inMemory, OTHER_FACILITY).length, 0);
});

test.after(() => {
  testEnv.cleanup();
});
