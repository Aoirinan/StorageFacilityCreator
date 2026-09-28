/**
 * A unit a tenant already has is not rented online.
 *
 * The public map shows a unit as rented when it is linked to a tenant, or
 * when an active tenant claims it: by their unitId, or with none by their
 * unitNumber (trimmed and lower-cased) in their unitArea, or in any area
 * without one. An owner can add a tenant with a unit number and never link
 * the unit. The
 * holds, checkout and completion looked only at the unit, so such a unit
 * could be held, paid for and moved into, from a stale map or by a direct
 * call with the unit id the map publishes: two active tenants on one unit.
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

const FACILITY = 'fac-claimed';
const UNIT = 'unit-claimed';
const ACCOUNT = 'acct_claimed';
const UNIT_PATH = `facilities/${FACILITY}/units/${UNIT}`;
const HOLD_PATH = `facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`;
const TENANTS = `facilities/${FACILITY}/tenants`;
const NOT_AVAILABLE = 'Unit is not currently available';
const NO_LONGER_AVAILABLE = 'Unit is no longer available';

/** Takes card payments online through Stripe Connect. */
const FACILITY_DATA = {
  name: 'Claimed Storage',
  stripeConnectAccountId: ACCOUNT,
  stripeConnectOnboardingComplete: true,
};

const SIGNATURE =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

type Renter = { reservationId: string; token: string; paymentIntentId: string; name: string; email: string };

const RITA: Renter = {
  reservationId: 'res-rita',
  token: 'rita-move-in-token-0123456789',
  paymentIntentId: 'pi_rita',
  name: 'Rita Renter',
  email: 'rita@example.com',
};
const SAM: Renter = {
  reservationId: 'res-sam',
  token: 'sam-move-in-token-0123456789',
  paymentIntentId: 'pi_sam',
  name: 'Sam Second',
  email: 'sam@example.com',
};
const RENTERS = [RITA, SAM];

const minutesFromNow = (minutes: number) => Timestamp.fromDate(new Date(Date.now() + minutes * 60 * 1000));

type Harness = {
  refunds: Array<{ params: Record<string, any>; options: Record<string, any> }>;
  checkoutSessions: number;
  hold: (data: Record<string, unknown>) => Promise<{ success?: boolean; reservationId?: string }>;
  checkout: (data: Record<string, unknown>) => Promise<{ checkoutUrl?: string }>;
  complete: (renter: Renter, overrides?: Record<string, unknown>) => Promise<{ success?: boolean; tenantId?: string }>;
};

/**
 * Loads publicMoveIn against [inMemory]. Stripe reports each renter's
 * PaymentIntent paid in full ([paidCents]) and tagged for their reservation,
 * and runs [onRetrieve] when completion asks for it: after completion's first
 * read of the unit, before its transaction.
 */
function load(inMemory: InMemoryFirestore, paidCents = 0, onRetrieve?: () => void): Harness {
  installInMemoryFirestore(inMemory);
  const harness = { refunds: [], checkoutSessions: 0 } as unknown as Harness;
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
            const renter = RENTERS.find((r) => r.paymentIntentId === id);
            assert.ok(renter, `unexpected PaymentIntent ${id}`);
            onRetrieve?.();
            return {
              id,
              amount_received: paidCents,
              status: 'succeeded',
              metadata: { type: 'public_move_in', reservationId: renter.reservationId },
            };
          },
        },
        checkout: {
          sessions: {
            create: async () => {
              harness.checkoutSessions += 1;
              return { id: 'cs_claimed', url: 'https://checkout.example/cs_claimed' };
            },
          },
        },
        refunds: {
          create: async (params: Record<string, any>, options: Record<string, any>) => {
            harness.refunds.push({ params, options });
            return { id: `re_${harness.refunds.length}` };
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  harness.hold = (data) =>
    testEnv.wrap(moveIn.createPublicReservationHold)(data, callableContext) as ReturnType<Harness['hold']>;
  harness.checkout = (data) =>
    testEnv.wrap(moveIn.createPublicMoveInCheckout)(data, callableContext) as ReturnType<Harness['checkout']>;
  harness.complete = (renter, overrides = {}) =>
    testEnv.wrap(moveIn.completePublicMoveIn)(
      {
        reservationId: renter.reservationId,
        token: renter.token,
        name: renter.name,
        email: renter.email,
        phone: '5551234567',
        signaturePngBase64: SIGNATURE,
        paymentIntentId: renter.paymentIntentId,
        ...overrides,
      },
      callableContext,
    ) as ReturnType<Harness['complete']>;
  return harness;
}

/** A facility with online rentals on, and [UNIT] (number U7) at it. */
function seedFacilityAndUnit(
  inMemory: InMemoryFirestore,
  facilityData: Record<string, unknown> = FACILITY_DATA,
  unitFields: Record<string, unknown> = {},
) {
  inMemory.seed(`facilities/${FACILITY}`, facilityData);
  inMemory.seed(`facilities/${FACILITY}/settings/public`, { publicRentalsEnabled: true });
  inMemory.seed(UNIT_PATH, {
    status: 'available',
    unitNumber: 'U7',
    unitType: 'standard',
    monthlyRate: 100,
    ...unitFields,
  });
}

function seedTenant(inMemory: InMemoryFirestore, id: string, fields: Record<string, unknown>) {
  inMemory.seed(`${TENANTS}/${id}`, { name: `Tenant ${id}`, ...fields });
}

/**
 * [renter]'s reservation of [UNIT] as checkout leaves it, holding the unit
 * until [holdMinutes] from now (negative: the hold has run out). Returns the
 * amount checkout quoted, in cents.
 */
function seedReservation(inMemory: InMemoryFirestore, renter: Renter, holdMinutes = 10): number {
  const reservation = {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'U7',
    status: 'pending',
    moveInToken: renter.token,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    expiresAt: minutesFromNow(holdMinutes),
    email: renter.email,
    name: renter.name,
    metadata: {},
  };
  const quote = computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(UNIT_PATH) as Record<string, any>,
    facilityData: inMemory.read(`facilities/${FACILITY}`) as Record<string, any>,
    publicSettings: {},
    moveInDate: reservation.moveInDate.toDate(),
  });
  inMemory.seed(`publicReservations/${renter.reservationId}`, {
    ...reservation,
    expectedCheckoutAmountCents: quote.totalCents,
    checkoutUpdatedAt: Timestamp.now(),
  });
  return quote.totalCents;
}

function seedHold(inMemory: InMemoryFirestore, renter: Renter, holdMinutes: number) {
  inMemory.seed(HOLD_PATH, {
    facilityId: FACILITY,
    unitId: UNIT,
    reservationId: renter.reservationId,
    status: 'pending',
    expiresAt: minutesFromNow(holdMinutes),
  });
}

/** The request the rental page sends for a hold on [unitId]. */
function holdRequest(unitId = UNIT) {
  return { facilityId: FACILITY, unitId, email: 'renter@example.com', name: 'Rita Renter' };
}

/** Checkout for [renter], for the amount the server quotes, so only the unit check can stop it. */
function checkoutRequest(inMemory: InMemoryFirestore, renter: Renter) {
  const reservation = inMemory.read(`publicReservations/${renter.reservationId}`) as Record<string, unknown>;
  const quote = computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(UNIT_PATH),
    facilityData: FACILITY_DATA,
    moveInDate: (reservation.moveInDate as Timestamp).toDate(),
  });
  assert.ok(quote.totalCents >= 50);
  return { reservationId: renter.reservationId, token: renter.token, amount: quote.totalAmount };
}

function refusedWith(message: string) {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string };
    assert.equal(e.code, 'failed-precondition');
    assert.equal(e.message, message);
    return true;
  };
}

/** Why a renter who has paid was refunded, as the renter is told it. */
const REFUSAL_TEXT = {
  'unit-taken': /rented or taken out of service while you were paying/,
  'unit-held': /Your hold on this unit ran out, and another renter is now paying for it/,
};
type UnitRefusal = keyof typeof REFUSAL_TEXT;

/** The renter was turned away because the unit is taken ([refusal]), and told their payment was refunded. */
function refundedAsTaken(renter: Renter, refusal: UnitRefusal = 'unit-taken') {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string; details?: Record<string, unknown> };
    assert.equal(e.code, 'failed-precondition');
    assert.match(String(e.message), REFUSAL_TEXT[refusal]);
    assert.match(String(e.message), /has been refunded to your card/);
    assert.deepEqual(e.details, { refunded: true, paymentIntentId: renter.paymentIntentId });
    return true;
  };
}

/** One full refund of [renter]'s payment, and the owner told why, as for any unit taken while a renter paid. */
function assertRefundedAsTaken(
  inMemory: InMemoryFirestore,
  harness: Harness,
  renter: Renter,
  refusal: UnitRefusal = 'unit-taken',
) {
  assert.equal(harness.refunds.length, 1);
  assert.equal(harness.refunds[0].params.payment_intent, renter.paymentIntentId);
  assert.equal(harness.refunds[0].options.idempotencyKey, `public_move_in_refund_${renter.paymentIntentId}`);
  const use = inMemory.read(`publicMoveInPayments/${renter.paymentIntentId}`) as Record<string, any>;
  assert.equal(use.tenantId, null);
  assert.equal(use.refund.refusal, refusal);
  assert.equal(use.refund.status, 'refunded');
  const alert = inMemory.read(
    `facilities/${FACILITY}/Notifications/move-in-refund-${renter.paymentIntentId}`,
  ) as Record<string, any>;
  assert.equal(alert.type, 'ONLINE_MOVE_IN_REVIEW');
  assert.equal(alert.metadata.reason, refusal);
  assert.equal(alert.metadata.refundStatus, 'refunded');
  assert.match(String(alert.message), new RegExp(`${renter.name} paid .* online for unit U7, but was not moved in`));
  assert.equal(inMemory.read(`publicReservations/${renter.reservationId}`)?.status, 'cancelled');
}

/** The ids of the facility's active tenants whose unit number is U7, as the public map reads it. */
function activeTenantsInU7(inMemory: InMemoryFirestore): string[] {
  return inMemory
    .listCollection(TENANTS)
    .filter((key) => !key.slice(TENANTS.length + 1).includes('/'))
    .filter((key) => {
      const t = inMemory.read(key) as Record<string, unknown>;
      return t.isActive === true && String(t.unitNumber || '').trim().toLowerCase() === 'u7';
    })
    .map((key) => key.split('/').pop() as string)
    .sort();
}

/** The unit number spellings an owner might type for U7. */
const U7_SPELLINGS = ['U7', 'u7', '  u7 ', '\tU7'];

// ---------------------------------------------------------------------------
// The hold
// ---------------------------------------------------------------------------

type FixtureDoc = { id: string; data: Record<string, unknown> };
type PublicMapCase = {
  name: string;
  units: FixtureDoc[];
  tenants: FixtureDoc[];
  publicSettings?: Record<string, unknown>;
  expected: Record<string, Record<string, unknown>>;
};

/** The cases the app's publish and the inventory sync both run (test/fixtures/public_map_units.json). */
function publicMapCases(): PublicMapCase[] {
  const file = path.join(__dirname, '..', '..', '..', 'test', 'fixtures', 'public_map_units.json');
  return (JSON.parse(fs.readFileSync(file, 'utf8')) as { cases: PublicMapCase[] }).cases;
}

test('every shared public map case: the hold is taken for exactly the units the map offers', async () => {
  const cases = publicMapCases();
  assert.ok(cases.length >= 10, 'the shared fixture was not read');
  for (const c of cases) {
    for (const unit of c.units) {
      // A fresh facility per unit, so one unit's hold and the per-caller rate
      // limit do not decide another's.
      const inMemory = new InMemoryFirestore();
      inMemory.seed(`facilities/${FACILITY}`, { name: 'Claimed Storage' });
      inMemory.seed(`facilities/${FACILITY}/settings/public`, { ...c.publicSettings, publicRentalsEnabled: true });
      for (const u of c.units) inMemory.seed(`facilities/${FACILITY}/units/${u.id}`, u.data);
      for (const t of c.tenants) inMemory.seed(`${TENANTS}/${t.id}`, t.data);
      const { hold } = load(inMemory);

      // A unit the map leaves off (archived) is not offered either.
      const offered = c.expected[unit.id]?.isRentable === true;
      const why = `${c.name}: ${unit.id}`;
      if (offered) {
        assert.equal((await hold(holdRequest(unit.id))).success, true, why);
      } else {
        await assert.rejects(() => hold(holdRequest(unit.id)), refusedWith(NOT_AVAILABLE), why);
        assert.deepEqual(inMemory.listCollection('publicReservations'), [], why);
      }
    }
  }
});

test('a unit linked to a tenant is not held, though its status says available', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory, { name: 'Claimed Storage' }, { tenantId: 'tenant-other' });
  const { hold } = load(inMemory);

  // Before: only the status was read, so the unit was held and rented over its tenant.
  await assert.rejects(() => hold(holdRequest()), refusedWith(NOT_AVAILABLE));

  assert.deepEqual(inMemory.listCollection('publicReservations'), []);
  assert.equal(inMemory.read(HOLD_PATH), undefined);
});

for (const spelling of U7_SPELLINGS) {
  test(`a unit an active tenant has by unit number (${JSON.stringify(spelling)}) is not held`, async () => {
    const inMemory = new InMemoryFirestore();
    seedFacilityAndUnit(inMemory, { name: 'Claimed Storage' });
    seedTenant(inMemory, 'tenant-typed-in', { isActive: true, unitNumber: spelling });
    const { hold } = load(inMemory);

    // Before: held, though the public map shows the unit rented.
    await assert.rejects(() => hold(holdRequest()), refusedWith(NOT_AVAILABLE));

    assert.deepEqual(inMemory.listCollection('publicReservations'), []);
    assert.equal(inMemory.read(HOLD_PATH), undefined);
  });
}

test('a tenant who is not active does not keep their old unit from being held', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory, { name: 'Claimed Storage' });
  seedTenant(inMemory, 'moved-out', { isActive: false, unitNumber: 'U7' });
  seedTenant(inMemory, 'no-flag', { unitNumber: 'U7' });
  seedTenant(inMemory, 'text-flag', { isActive: 'true', unitNumber: 'U7' });
  const { hold } = load(inMemory);

  assert.equal((await hold(holdRequest())).success, true);
  assert.ok(inMemory.read(HOLD_PATH));
});

// ---------------------------------------------------------------------------
// Checkout
// ---------------------------------------------------------------------------

test('checkout is refused for a unit an active tenant has by unit number, before Stripe is called', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  seedReservation(inMemory, RITA);
  seedTenant(inMemory, 'tenant-typed-in', { isActive: true, unitNumber: ' u7' });
  const harness = load(inMemory);

  await assert.rejects(() => harness.checkout(checkoutRequest(inMemory, RITA)), refusedWith(NOT_AVAILABLE));

  assert.equal(harness.checkoutSessions, 0);
});

test('checkout reaches Stripe when only a tenant who is not active had the unit', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  seedReservation(inMemory, RITA);
  seedTenant(inMemory, 'moved-out', { isActive: false, unitNumber: 'U7' });
  const harness = load(inMemory);

  const result = await harness.checkout(checkoutRequest(inMemory, RITA));

  assert.equal(harness.checkoutSessions, 1);
  assert.equal(result.checkoutUrl, 'https://checkout.example/cs_claimed');
});

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

test('a move-in with nothing to pay is refused for a unit an active tenant has by unit number, and nothing is written', async () => {
  const inMemory = new InMemoryFirestore();
  // No Stripe: nothing is paid online here.
  seedFacilityAndUnit(inMemory, { name: 'Claimed Storage' });
  seedReservation(inMemory, RITA);
  seedTenant(inMemory, 'tenant-typed-in', { isActive: true, unitNumber: 'u7 ' });
  const harness = load(inMemory);

  await assert.rejects(
    () => harness.complete(RITA, { paymentIntentId: undefined, skipPayment: true }),
    refusedWith(NO_LONGER_AVAILABLE),
  );

  assert.deepEqual(activeTenantsInU7(inMemory), ['tenant-typed-in']);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, undefined);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'available');
  assert.deepEqual(inMemory.listCollection(`facilities/${FACILITY}/contracts`), []);
  assert.equal(inMemory.read(`publicReservations/${RITA.reservationId}`)?.status, 'pending');
  assert.deepEqual(harness.refunds, []);
});

test('a renter who has paid for a unit an active tenant has by unit number is refunded, and the tenant keeps it', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  const paidCents = seedReservation(inMemory, RITA);
  seedTenant(inMemory, 'tenant-typed-in', { isActive: true, unitNumber: '  U7' });
  const harness = load(inMemory, paidCents);

  // Before: moved in, and the unit had two active tenants.
  await assert.rejects(() => harness.complete(RITA), refundedAsTaken(RITA));

  assert.deepEqual(activeTenantsInU7(inMemory), ['tenant-typed-in']);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, undefined);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'available');
  assertRefundedAsTaken(inMemory, harness, RITA);
});

test('a renter who has paid for a unit linked to a tenant, with status available, is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  const paidCents = seedReservation(inMemory, RITA);
  inMemory.seed(UNIT_PATH, { ...inMemory.read(UNIT_PATH), tenantId: 'tenant-other' });
  const harness = load(inMemory, paidCents);

  await assert.rejects(() => harness.complete(RITA), refundedAsTaken(RITA));

  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, 'tenant-other');
  assertRefundedAsTaken(inMemory, harness, RITA);
});

test('an active tenant added with the unit number while the payment is checked is seen by the move-in, and the renter is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  const paidCents = seedReservation(inMemory, RITA);
  // The owner adds a tenant in U7 after completion first read the unit and
  // the tenants: only the transaction's own read can see them.
  const harness = load(inMemory, paidCents, () =>
    seedTenant(inMemory, 'added-meanwhile', { isActive: true, unitNumber: 'u7' }),
  );

  await assert.rejects(() => harness.complete(RITA), refundedAsTaken(RITA));

  assert.deepEqual(activeTenantsInU7(inMemory), ['added-meanwhile']);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, undefined);
  assertRefundedAsTaken(inMemory, harness, RITA);
});

test('a renter who has paid is moved in when only a tenant who is not active had the unit number', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  const paidCents = seedReservation(inMemory, RITA);
  seedTenant(inMemory, 'moved-out', { isActive: false, unitNumber: 'U7' });
  const harness = load(inMemory, paidCents);

  const result = await harness.complete(RITA);

  assert.equal(result.success, true);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
  assert.deepEqual(activeTenantsInU7(inMemory), [result.tenantId]);
  assert.deepEqual(harness.refunds, []);
});

test('two renters whose holds ran out, both paid, completing at once: one moves in and the other is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  // Rita's hold ran out; Sam held the unit after her, and his ran out too.
  const paidCents = seedReservation(inMemory, RITA, -30);
  assert.equal(seedReservation(inMemory, SAM, -5), paidCents);
  seedHold(inMemory, SAM, -5);
  const harness = load(inMemory, paidCents);

  const results = await Promise.allSettled([harness.complete(RITA), harness.complete(SAM)]);

  const movedIn = results.filter((r) => r.status === 'fulfilled') as Array<
    PromiseFulfilledResult<{ success?: boolean; tenantId?: string }>
  >;
  assert.equal(movedIn.length, 1, 'exactly one renter moves in');
  const winner = results[0].status === 'fulfilled' ? RITA : SAM;
  const loser = winner === RITA ? SAM : RITA;
  const rejected = results[winner === RITA ? 1 : 0] as PromiseRejectedResult;
  assert.ok(refundedAsTaken(loser)(rejected.reason));

  // Before the transaction read the unit, both were moved in.
  const tenantId = movedIn[0].value.tenantId;
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, tenantId);
  assert.deepEqual(activeTenantsInU7(inMemory), [tenantId]);
  assert.equal(inMemory.read(`publicReservations/${winner.reservationId}`)?.status, 'completed');
  assertRefundedAsTaken(inMemory, harness, loser);
});

test('a renter whose hold ran out is refunded while another renter holds the unit, and that hold is kept', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  const paidCents = seedReservation(inMemory, RITA, -30);
  // Sam holds the unit now, and is in checkout for it.
  seedReservation(inMemory, SAM, 10);
  seedHold(inMemory, SAM, 10);
  const harness = load(inMemory, paidCents);

  // Told that another renter is paying for it, not that it was rented.
  await assert.rejects(() => harness.complete(RITA), refundedAsTaken(RITA, 'unit-held'));

  assert.deepEqual(activeTenantsInU7(inMemory), []);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, undefined);
  assert.equal(inMemory.read(HOLD_PATH)?.reservationId, SAM.reservationId);
  assertRefundedAsTaken(inMemory, harness, RITA, 'unit-held');
});

// ---------------------------------------------------------------------------
// Reads that decide are made in the transaction
// ---------------------------------------------------------------------------

/**
 * Adds, once, an active tenant in U7 whose unit doc was never linked, just
 * before the first commit of the transaction that read [path]: the owner
 * typing a tenant in while the transaction ran. Only a transaction that read
 * the tenants through `tx.get` sees the write and runs again.
 */
function addTenantInU7WhileTransactionReads(inMemory: InMemoryFirestore, path: string) {
  let added = false;
  inMemory.beforeCommit = ({ readPaths }) => {
    if (added || !readPaths.includes(path)) return;
    added = true;
    seedTenant(inMemory, 'added-meanwhile', { isActive: true, unitNumber: 'U7' });
  };
}

test('an active tenant added in U7 while the move-in transaction runs is seen, and the renter is refunded', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory);
  const paidCents = seedReservation(inMemory, RITA);
  addTenantInU7WhileTransactionReads(inMemory, UNIT_PATH);
  const harness = load(inMemory, paidCents);

  // Read with a plain get(), the tenants were not part of the transaction:
  // it committed, and U7 had two active tenants.
  await assert.rejects(() => harness.complete(RITA), refundedAsTaken(RITA));

  assert.deepEqual(activeTenantsInU7(inMemory), ['added-meanwhile']);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, undefined);
  assert.ok(inMemory.transactionRetries >= 1);
  assertRefundedAsTaken(inMemory, harness, RITA);
});

test('an active tenant added in U7 while the hold transaction runs is seen, and nothing is held', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory, { name: 'Claimed Storage' });
  addTenantInU7WhileTransactionReads(inMemory, UNIT_PATH);
  const { hold } = load(inMemory);

  await assert.rejects(() => hold(holdRequest()), refusedWith(NOT_AVAILABLE));

  assert.deepEqual(inMemory.listCollection('publicReservations'), []);
  assert.equal(inMemory.read(HOLD_PATH), undefined);
});

test('every shared public map case: checkout reaches Stripe for exactly the units the map offers', async () => {
  const cases = publicMapCases();
  assert.ok(cases.length >= 10, 'the shared fixture was not read');
  for (const c of cases) {
    for (const unit of c.units) {
      const inMemory = new InMemoryFirestore();
      inMemory.seed(`facilities/${FACILITY}`, FACILITY_DATA);
      inMemory.seed(`facilities/${FACILITY}/settings/public`, { ...c.publicSettings, publicRentalsEnabled: true });
      // A rate on every unit, so the amount due is over the card minimum and
      // only the unit check can stop checkout. The rate is not part of any case.
      for (const u of c.units) inMemory.seed(`facilities/${FACILITY}/units/${u.id}`, { ...u.data, monthlyRate: 100 });
      for (const t of c.tenants) inMemory.seed(`${TENANTS}/${t.id}`, t.data);
      const reservation = {
        facilityId: FACILITY,
        unitId: unit.id,
        status: 'pending',
        moveInToken: RITA.token,
        moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
        expiresAt: minutesFromNow(10),
        email: RITA.email,
        name: RITA.name,
        metadata: {},
      };
      inMemory.seed(`publicReservations/${RITA.reservationId}`, reservation);
      const quote = computePublicMoveInCharges({
        reservation,
        unitData: inMemory.read(`facilities/${FACILITY}/units/${unit.id}`),
        facilityData: FACILITY_DATA,
        moveInDate: reservation.moveInDate.toDate(),
      });
      const harness = load(inMemory);
      const request = { reservationId: RITA.reservationId, token: RITA.token, amount: quote.totalAmount };

      const why = `${c.name}: ${unit.id}`;
      if (c.expected[unit.id]?.isRentable === true) {
        assert.ok((await harness.checkout(request)).checkoutUrl, why);
        assert.equal(harness.checkoutSessions, 1, why);
      } else {
        await assert.rejects(() => harness.checkout(request), refusedWith(NOT_AVAILABLE), why);
        assert.equal(harness.checkoutSessions, 0, why);
      }
    }
  }
});

// ---------------------------------------------------------------------------
// Unit numbers repeated across areas
// ---------------------------------------------------------------------------

const OTHER_12 = 'unit-c3-12';
const OTHER_12_PATH = `facilities/${FACILITY}/units/${OTHER_12}`;

/** [UNIT] is 12 in Complex 2 (its area stored untidy), and [OTHER_12] is 12 in Complex 3. */
function seedTwelves(inMemory: InMemoryFirestore, other: Record<string, unknown> = {}) {
  seedFacilityAndUnit(inMemory, FACILITY_DATA, { unitNumber: '12', area: '  Complex 2 ' });
  inMemory.seed(OTHER_12_PATH, {
    status: 'available',
    unitNumber: '12',
    area: 'Complex 3',
    unitType: 'standard',
    monthlyRate: 100,
    ...other,
  });
}

test('a renter who has paid for 12 in Complex 2 is moved in while a tenant has 12 in Complex 3 by unitId', async () => {
  const inMemory = new InMemoryFirestore();
  seedTwelves(inMemory, { status: 'occupied', tenantId: 'tenant-c3' });
  seedTenant(inMemory, 'tenant-c3', { isActive: true, unitNumber: '12', unitId: OTHER_12, unitArea: 'Complex 3' });
  const paidCents = seedReservation(inMemory, RITA);
  const harness = load(inMemory, paidCents);

  // Before: claimed by number, so this unit was refused and Rita refunded.
  const result = await harness.complete(RITA);

  assert.equal(result.success, true);
  assert.deepEqual(harness.refunds, []);
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
  assert.equal(inMemory.read(OTHER_12_PATH)?.tenantId, 'tenant-c3');
});

test("an online move-in names the tenant's unit by unitId and unitArea, as the app's move-in does", async () => {
  const inMemory = new InMemoryFirestore();
  seedTwelves(inMemory);
  const paidCents = seedReservation(inMemory, RITA);
  const harness = load(inMemory, paidCents);

  const result = await harness.complete(RITA);

  // TenantService.createTenant with a picked unit (TenantModel.primaryUnitCreate):
  // the unit's number, its id, and its area trimmed.
  const tenant = inMemory.read(`${TENANTS}/${result.tenantId}`) as Record<string, unknown>;
  assert.equal(tenant.unitNumber, '12');
  assert.equal(tenant.unitId, UNIT);
  assert.equal(tenant.unitArea, 'Complex 2');
});

test('a unit with no area gives the online tenant a unitId and no unitArea', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacilityAndUnit(inMemory, FACILITY_DATA, { area: '   ' });
  const paidCents = seedReservation(inMemory, RITA);
  const harness = load(inMemory, paidCents);

  const result = await harness.complete(RITA);

  const tenant = inMemory.read(`${TENANTS}/${result.tenantId}`) as Record<string, unknown>;
  assert.equal(tenant.unitNumber, 'U7');
  assert.equal(tenant.unitId, UNIT);
  assert.equal('unitArea' in tenant, false);
});

test('the tenant an online move-in creates claims only their own 12: the 12 in the other area can still be rented', async () => {
  const inMemory = new InMemoryFirestore();
  seedTwelves(inMemory);
  const paidCents = seedReservation(inMemory, RITA);
  const harness = load(inMemory, paidCents);
  assert.equal((await harness.complete(RITA)).success, true);

  // Before: the new tenant had only the number 12, which claims every 12,
  // so the Complex 3 unit was refused though nobody has it.
  const held = await harness.hold(holdRequest(OTHER_12));

  assert.equal(held.success, true);
});

test.after(() => {
  testEnv.cleanup();
});
