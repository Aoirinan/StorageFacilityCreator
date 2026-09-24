/**
 * Online rental is limited to units, and facilities, the owner offers online.
 *
 * The hold and the move-in checked only a unit's status, and every unit's id,
 * unlisted ones included, is in the world-readable publicFacilityMaps doc. A
 * direct call could hold, pay for and move into a unit the owner had not
 * listed, one kept as an office or residence, or one that was archived, and
 * could rent at a facility whose rental page was not live.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { computePublicMoveInCharges } from '../moveInCharges';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-listing';
const UNIT = 'unit-listing';
const RESERVATION = 'res-listing';
const TOKEN = 'listing-move-in-token-0123456789';
const UNIT_PATH = `facilities/${FACILITY}/units/${UNIT}`;
const HOLD_PATH = `facilities/${FACILITY}/mapEngine/activeHolds/items/${UNIT}`;
const NOT_AVAILABLE = 'Unit is not currently available';

/** Each way an owner keeps a unit off online rental, as the app writes it. */
const NOT_OFFERED: Array<[string, Record<string, unknown>]> = [
  ['not listed on the public website', { publicListingEnabled: false }],
  ['kept for internal use', { internalUse: true }],
  // An office whose listing switch was left on is still internal use.
  ['kept for internal use with its listing on', { internalUse: true, publicListingEnabled: true }],
  ['archived', { archived: true }],
];

/** Loads publicMoveIn against [inMemory], with Stripe reporting [amountReceived] paid. */
function loadPublicMoveIn(inMemory: InMemoryFirestore, amountReceived = 0) {
  installInMemoryFirestore(inMemory);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        paymentIntents: {
          retrieve: async (id: string) => ({ id, amount_received: amountReceived, status: 'succeeded' }),
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  return {
    onlineRentalsOffMessage: moveIn.ONLINE_RENTALS_OFF_MESSAGE,
    hold: (data: Record<string, unknown>) => testEnv.wrap(moveIn.createPublicReservationHold)(data, callableContext),
    complete: (data: Record<string, unknown>) => testEnv.wrap(moveIn.completePublicMoveIn)(data, callableContext),
  };
}

/** No Stripe Connect, so a move-in here takes no payment online. */
function seedFacility(inMemory: InMemoryFirestore, publicSettings: Record<string, unknown> | null) {
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Listing Storage' });
  if (publicSettings) {
    inMemory.seed(`facilities/${FACILITY}/settings/public`, publicSettings);
  }
}

function seedUnit(inMemory: InMemoryFirestore, fields: Record<string, unknown> = {}) {
  inMemory.seed(UNIT_PATH, {
    status: 'available',
    unitNumber: 'L1',
    unitType: 'standard',
    monthlyRate: 100,
    ...fields,
  });
}

function seedReservation(inMemory: InMemoryFirestore) {
  inMemory.seed(`publicReservations/${RESERVATION}`, {
    facilityId: FACILITY,
    unitId: UNIT,
    unitNumber: 'L1',
    status: 'pending',
    moveInToken: TOKEN,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    expiresAt: Timestamp.fromDate(new Date(Date.now() + 10 * 60 * 1000)),
    email: 'renter@example.com',
    name: 'Rita Renter',
    metadata: {},
  });
}

const holdRequest = {
  facilityId: FACILITY,
  unitId: UNIT,
  email: 'renter@example.com',
  name: 'Rita Renter',
};

const completeRequest = {
  reservationId: RESERVATION,
  token: TOKEN,
  name: 'Rita Renter',
  email: 'renter@example.com',
  phone: '5551234567',
  skipPayment: true,
  signaturePngBase64:
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
};

function refusedWith(message: string) {
  return (err: unknown): boolean => {
    const e = err as { code?: string; message?: string };
    assert.equal(e.code, 'failed-precondition');
    assert.equal(e.message, message);
    return true;
  };
}

function assertNothingHeld(inMemory: InMemoryFirestore) {
  assert.equal(inMemory.listCollection('publicReservations').length, 0);
  assert.equal(inMemory.read(HOLD_PATH), undefined);
}

test('a listed unit at a facility taking online rentals can be held', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacility(inMemory, { publicRentalsEnabled: true });
  seedUnit(inMemory, { publicListingEnabled: true, internalUse: false, archived: false });
  const { hold } = loadPublicMoveIn(inMemory);

  const result = (await hold(holdRequest)) as { success?: boolean };

  assert.equal(result.success, true);
  assert.equal(inMemory.listCollection('publicReservations').length, 1);
  assert.ok(inMemory.read(HOLD_PATH));
});

for (const [why, fields] of NOT_OFFERED) {
  test(`a unit ${why} cannot be held, and nothing is written`, async () => {
    const inMemory = new InMemoryFirestore();
    seedFacility(inMemory, { publicRentalsEnabled: true });
    seedUnit(inMemory, fields);
    const { hold } = loadPublicMoveIn(inMemory);

    await assert.rejects(() => hold(holdRequest), refusedWith(NOT_AVAILABLE));

    assertNothingHeld(inMemory);
  });
}

test('an unlisted unit is refused exactly as a rented one is', async () => {
  const rented = new InMemoryFirestore();
  seedFacility(rented, { publicRentalsEnabled: true });
  seedUnit(rented, { status: 'occupied' });
  const unlisted = new InMemoryFirestore();
  seedFacility(unlisted, { publicRentalsEnabled: true });
  seedUnit(unlisted, { publicListingEnabled: false });

  const refusal = async (inMemory: InMemoryFirestore) => {
    const { hold } = loadPublicMoveIn(inMemory);
    try {
      await hold(holdRequest);
    } catch (err) {
      const e = err as { code?: string; message?: string };
      return { code: e.code, message: e.message };
    }
    assert.fail('the hold was not refused');
  };

  // An anonymous caller learns nothing about why a unit is not for rent.
  assert.deepEqual(await refusal(unlisted), await refusal(rented));
});

for (const [why, publicSettings] of [
  ['online rentals are off', { publicRentalsEnabled: false }],
  ['online rentals were never set up', null],
] as Array<[string, Record<string, unknown> | null]>) {
  test(`no unit can be held when ${why}`, async () => {
    const inMemory = new InMemoryFirestore();
    seedFacility(inMemory, publicSettings);
    seedUnit(inMemory);
    const { hold, onlineRentalsOffMessage } = loadPublicMoveIn(inMemory);

    await assert.rejects(() => hold(holdRequest), refusedWith(onlineRentalsOffMessage));

    assertNothingHeld(inMemory);
  });
}

test('a move-in for a listed unit completes', async () => {
  const inMemory = new InMemoryFirestore();
  // The facility's rental switch is not re-checked at move-in: the tenant
  // portal's move-ins come through this callable too, and the portal is not
  // the public rental page. The public hold has already checked it.
  seedFacility(inMemory, null);
  seedUnit(inMemory);
  seedReservation(inMemory);
  const { complete } = loadPublicMoveIn(inMemory);

  const result = (await complete(completeRequest)) as { success?: boolean; tenantId?: string };

  assert.equal(result.success, true);
  assert.equal(inMemory.read(UNIT_PATH)?.status, 'occupied');
  assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
});

for (const [why, fields] of NOT_OFFERED) {
  test(`a move-in is refused for a unit ${why} since the hold, and nothing is written`, async () => {
    const inMemory = new InMemoryFirestore();
    seedFacility(inMemory, null);
    seedUnit(inMemory, fields);
    seedReservation(inMemory);
    const { complete } = loadPublicMoveIn(inMemory);

    await assert.rejects(() => complete(completeRequest), refusedWith(NOT_AVAILABLE));

    assert.equal(inMemory.listCollection(`facilities/${FACILITY}/tenants`).length, 0);
    assert.equal(inMemory.listCollection(`facilities/${FACILITY}/contracts`).length, 0);
    assert.equal(inMemory.listCollection(`facilities/${FACILITY}/ledgers`).length, 0);
    assert.equal(inMemory.read(UNIT_PATH)?.status, 'available');
    assert.equal(inMemory.read(UNIT_PATH)?.tenantId, undefined);
    assert.equal(inMemory.read(`publicReservations/${RESERVATION}`)?.status, 'pending');
    // Nothing was paid, so there is nothing to tell the owner.
    assert.equal(inMemory.listCollection(`facilities/${FACILITY}/Notifications`).length, 0);
  });
}

test('a unit type the owner has not opened to online rental cannot be held, and nothing is written', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacility(inMemory, { publicRentalsEnabled: true, enabledPublicUnitTypes: ['climateControlled'] });
  seedUnit(inMemory, { unitType: 'standard' });
  const { hold } = loadPublicMoveIn(inMemory);

  // Before: the public map showed it as not rentable, but a direct call
  // held it.
  await assert.rejects(() => hold(holdRequest), refusedWith(NOT_AVAILABLE));

  assertNothingHeld(inMemory);
});

test('a unit type the owner opened to online rental can be held', async () => {
  const inMemory = new InMemoryFirestore();
  seedFacility(inMemory, { publicRentalsEnabled: true, enabledPublicUnitTypes: [' standard '] });
  seedUnit(inMemory, { unitType: 'standard' });
  const { hold } = loadPublicMoveIn(inMemory);

  const result = (await hold(holdRequest)) as { success?: boolean };

  assert.equal(result.success, true);
});

/**
 * Stripe Connect is set up, so this move-in was paid through Checkout.
 * Returns what Checkout charged: the server's own quote for the unit.
 */
function seedPaidMoveIn(inMemory: InMemoryFirestore, unitFields: Record<string, unknown>): number {
  const facilityData = {
    name: 'Listing Storage',
    stripeConnectAccountId: 'acct_listing',
    stripeConnectOnboardingComplete: true,
  };
  inMemory.seed(`facilities/${FACILITY}`, facilityData);
  seedUnit(inMemory, unitFields);
  seedReservation(inMemory);
  const reservation = inMemory.read(`publicReservations/${RESERVATION}`) as Record<string, any>;
  const quote = computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(UNIT_PATH) as Record<string, any>,
    facilityData,
    publicSettings: {},
    moveInDate: (reservation.moveInDate as Timestamp).toDate(),
  });
  assert.ok(quote.totalCents > 0);
  return quote.totalCents;
}

const paidCompleteRequest = { ...completeRequest, skipPayment: false, paymentIntentId: 'pi_listing' };

for (const [why, fields, reason] of [
  ['not listed on the public website', { publicListingEnabled: false }, 'unlisted'],
  ['kept for internal use', { internalUse: true }, 'internal-use'],
  ['archived', { archived: true }, 'archived'],
] as Array<[string, Record<string, unknown>, string]>) {
  test(`a renter who has paid moves into a unit ${why} since the hold, and the owner is told`, async () => {
    const inMemory = new InMemoryFirestore();
    const paidCents = seedPaidMoveIn(inMemory, fields);
    const { complete } = loadPublicMoveIn(inMemory, paidCents);

    const result = (await complete(paidCompleteRequest)) as { success?: boolean; tenantId?: string };

    // Before: refused after Checkout had charged, with no tenancy, no
    // refund and nothing said to the owner.
    assert.equal(result.success, true);
    assert.equal(inMemory.read(UNIT_PATH)?.status, 'occupied');
    assert.equal(inMemory.read(UNIT_PATH)?.tenantId, result.tenantId);
    assert.equal(inMemory.read(`publicReservations/${RESERVATION}`)?.status, 'completed');
    // The payment is spent on this move-in, as for any other.
    assert.equal(inMemory.read('publicMoveInPayments/pi_listing')?.reservationId, RESERVATION);

    const alerts = inMemory.listCollection(`facilities/${FACILITY}/Notifications`);
    assert.equal(alerts.length, 1);
    const alert = inMemory.read(alerts[0]) as Record<string, any>;
    // The type the app's alert banner shows.
    assert.equal(alert.type, 'ONLINE_MOVE_IN_REVIEW');
    assert.equal(alert.tenantId, result.tenantId);
    assert.equal(alert.tenantName, 'Rita Renter');
    assert.equal(alert.readAt, null);
    assert.match(String(alert.message), /unit L1/);
    assert.equal(alert.metadata.reason, reason);
    assert.equal(alert.metadata.unitId, UNIT);
    assert.equal(alert.metadata.reservationId, RESERVATION);
    assert.equal(alert.metadata.paymentIntentId, 'pi_listing');
  });
}

test('a paid move-in into a unit still offered online sends the owner no alert', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidMoveIn(inMemory, {});
  const { complete } = loadPublicMoveIn(inMemory, paidCents);

  const result = (await complete(paidCompleteRequest)) as { success?: boolean };

  assert.equal(result.success, true);
  assert.equal(inMemory.listCollection(`facilities/${FACILITY}/Notifications`).length, 0);
});

test('an underpaid move-in into a unit no longer offered is still refused on the payment', async () => {
  const inMemory = new InMemoryFirestore();
  const paidCents = seedPaidMoveIn(inMemory, { internalUse: true });
  // Checkout took less than the quote: this is not a paid renter.
  const { complete } = loadPublicMoveIn(inMemory, paidCents - 1);

  await assert.rejects(() => complete(paidCompleteRequest), refusedWith('Payment not completed or amount mismatch'));

  assert.equal(inMemory.listCollection(`facilities/${FACILITY}/tenants`).length, 0);
  assert.equal(inMemory.listCollection(`facilities/${FACILITY}/Notifications`).length, 0);
});

test.after(() => {
  testEnv.cleanup();
});
