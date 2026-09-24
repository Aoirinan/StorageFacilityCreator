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
  ['archived', { archived: true }],
];

function loadPublicMoveIn(inMemory: InMemoryFirestore) {
  installInMemoryFirestore(inMemory);
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
  });
}

test.after(() => {
  testEnv.cleanup();
});
