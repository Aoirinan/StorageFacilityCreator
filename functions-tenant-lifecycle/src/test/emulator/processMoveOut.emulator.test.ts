import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';

import { processMoveOut } from '../../moveOutPortalHold';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * The deployed processMoveOut (the move-out screen's default path) against
 * real Firestore. A tenant's monthlyRate is the sum of the rates of the
 * units they hold; moving out of one of two units used to leave it alone,
 * so they kept being billed for the unit they gave up.
 */

const FACILITY = 'fac-1';
const OWNER = 'owner-1';

type Callable = {
  run: (data: unknown, context: functions.https.CallableContext) => Promise<Record<string, unknown>>;
};
const callable = processMoveOut as unknown as Callable;

const context = {
  auth: { uid: OWNER, token: {} },
  app: { appId: 'test-app', token: {} },
  rawRequest: {},
} as unknown as functions.https.CallableContext;

const fac = () => emulatorDb().collection('facilities').doc(FACILITY);
const tenant = async () => (await fac().collection('tenants').doc('t1').get()).data()!;

function moveOut(unitId: string, contractId: string) {
  return callable.run(
    { facilityId: FACILITY, tenantId: 't1', unitId, contractId, moveOutDate: '2026-09-23T12:00:00Z' },
    context,
  );
}

async function seed(): Promise<void> {
  await fac().set({ name: 'Acme Storage', ownerUid: OWNER });
  // No email: the confirmation email step is skipped.
  await fac().collection('tenants').doc('t1').set({ name: 'Ada Park', isActive: true, unitNumber: '101', monthlyRate: 250 });
  const units = fac().collection('units');
  await units.doc('u101').set({ unitNumber: '101', status: 'occupied', tenantId: 't1', monthlyRate: 100 });
  await units.doc('u102').set({ unitNumber: '102', status: 'lockout', tenantId: 't1', monthlyRate: 150 });
  const contracts = fac().collection('contracts');
  await contracts.doc('c101').set({ tenantId: 't1', unitId: 'u101', isActive: true, status: 'active' });
  await contracts.doc('c102').set({ tenantId: 't1', unitId: 'u102', isActive: true, status: 'active' });
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test("one of two units: that unit's rent comes off, the unit number moves, still active", { skip: skipWithoutEmulator }, async () => {
  await seed();
  assert.equal((await moveOut('u101', 'c101')).success, true);

  const t = await tenant();
  assert.equal(t.monthlyRate, 150);
  assert.equal(t.unitNumber, '102');
  assert.equal(t.isActive, true);
  const u101 = (await fac().collection('units').doc('u101').get()).data()!;
  assert.equal(u101.status, 'available');
  assert.equal(u101.tenantId, null);

  // Their last unit: the tenancy ends and the rate is kept as history.
  assert.equal((await moveOut('u102', 'c102')).success, true);
  const after = await tenant();
  assert.equal(after.isActive, false);
  assert.equal(after.unitNumber, '');
  assert.equal(after.monthlyRate, 150);
});

test('a unit number naming a unit still held stays; the rate never goes below 0', { skip: skipWithoutEmulator }, async () => {
  await seed();
  // A prorated first month left the rate below the unit's full rate.
  await fac().collection('tenants').doc('t1').update({ unitNumber: '102', monthlyRate: 60 });
  await moveOut('u101', 'c101');
  const t = await tenant();
  assert.equal(t.monthlyRate, 0);
  assert.equal(t.unitNumber, '102');
  assert.equal(t.isActive, true);
});
