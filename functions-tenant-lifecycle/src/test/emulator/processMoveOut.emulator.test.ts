import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';

import { processMoveOut } from '../../moveOutPortalHold';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * The deployed processMoveOut (the move-out screen's default path) against
 * real Firestore. A tenant's monthlyRate is the sum of the rates of the
 * units they hold; moving out of one of two units used to leave it alone,
 * so they kept being billed for the unit they gave up. Subtracting it
 * blindly then took a tenant billed one rate for two units to $0, and did
 * it again on every retry.
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
const tenant = async (id = 't1') => (await fac().collection('tenants').doc(id).get()).data()!;
const unit = async (id: string) => (await fac().collection('units').doc(id).get()).data()!;

function moveOut(unitId: string, contractId: string, extra: Record<string, unknown> = {}) {
  return callable.run(
    { facilityId: FACILITY, tenantId: 't1', unitId, contractId, moveOutDate: '2026-09-23T12:00:00Z', ...extra },
    context,
  );
}

async function seed(): Promise<void> {
  await fac().set({ name: 'Acme Storage', ownerUid: OWNER });
  // No email: the confirmation email step is skipped.
  await fac().collection('tenants').doc('t1').set({
    name: 'Ada Park',
    isActive: true,
    unitNumber: '101',
    unitId: 'u101',
    monthlyRate: 250,
  });
  const units = fac().collection('units');
  await units.doc('u101').set({ unitNumber: '101', status: 'occupied', tenantId: 't1', monthlyRate: 100 });
  await units.doc('u102').set({ unitNumber: '102', status: 'lockout', tenantId: 't1', monthlyRate: 150, area: 'Complex 3' });
  const contracts = fac().collection('contracts');
  await contracts.doc('c101').set({ tenantId: 't1', unitId: 'u101', isActive: true, status: 'active' });
  await contracts.doc('c102').set({ tenantId: 't1', unitId: 'u102', isActive: true, status: 'active' });
  await fac().collection('gateAccess').doc('g1').set({ tenantId: 't1', accessCode: '1234', isActive: true });
}

async function rejectsWith(promise: Promise<unknown>, code: string, message: RegExp) {
  await assert.rejects(promise, (err: unknown) => {
    const e = err as functions.https.HttpsError;
    assert.equal(e.code, code, `${e.code}: ${e.message}`);
    assert.match(e.message, message);
    return true;
  });
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test("one of two units: that unit's rent comes off, the unit number moves, still active", { skip: skipWithoutEmulator }, async () => {
  await seed();
  const first = await moveOut('u101', 'c101');
  assert.equal(first.success, true);
  assert.equal(first.rentNotice, 'Monthly rent is now $150.00 for unit 102.');
  assert.equal(first.rentWarning, null);

  const t = await tenant();
  assert.equal(t.monthlyRate, 150);
  assert.equal(t.unitNumber, '102');
  assert.equal(t.unitId, 'u102');
  assert.equal(t.unitArea, 'Complex 3');
  assert.equal(t.isActive, true);
  const u101 = await unit('u101');
  assert.equal(u101.status, 'available');
  assert.equal(u101.tenantId, null);
  assert.equal((await fac().collection('gateAccess').doc('g1').get()).get('isActive'), true);

  // Their last unit: the tenancy ends, the rate is kept as history, and
  // their gate code goes off with them (it stayed on).
  assert.equal((await moveOut('u102', 'c102')).success, true);
  const after = await tenant();
  assert.equal(after.isActive, false);
  assert.equal(after.unitNumber, '');
  assert.equal('unitId' in after, false);
  assert.equal('unitArea' in after, false);
  assert.equal(after.monthlyRate, 150);
  const gate = (await fac().collection('gateAccess').doc('g1').get()).data()!;
  assert.equal(gate.isActive, false);
  assert.equal(gate.updatedBy, OWNER);
});

test('a retry of a finished move-out changes nothing: the rent comes off once', { skip: skipWithoutEmulator }, async () => {
  // The screen re-enables its button on an ambiguous error (a dropped
  // connection after the commit); a second call took 250 to 150 to 50.
  await seed();
  await moveOut('u101', 'c101', { moveOutCharges: 40 });
  const again = await moveOut('u101', 'c101', { moveOutCharges: 40 });
  assert.equal(again.success, true);
  assert.equal(again.alreadyCompleted, true);
  assert.match(String(again.message), /already completed/);

  const t = await tenant();
  assert.equal(t.monthlyRate, 150);
  assert.equal(t.isActive, true);
  const charges = await fac().collection('ledgers').where('tenantId', '==', 't1').get();
  assert.equal(charges.size, 1, 'move-out charges posted once');
});

test('one rate for two units (from before the rule) is left alone and flagged, never taken to 0', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await fac().collection('tenants').doc('t1').update({ unitNumber: '102', monthlyRate: 100 });
  const result = await moveOut('u101', 'c101');
  assert.equal(result.rentWarning, "Check Ada Park's rent: they now hold unit 102; their rent is $100.00.");
  assert.equal(result.rentNotice, null);
  const t = await tenant();
  assert.equal(t.monthlyRate, 100);
  assert.equal(t.unitNumber, '102');
  assert.equal(t.isActive, true);
});

test('a second unit with no contract of its own keeps them active', { skip: skipWithoutEmulator }, async () => {
  // Unit 102 came from Edit Tenant or Units > Assign Tenant: only 101 has a
  // contract. Counting contracts switched them off while they held 102.
  await seed();
  await fac().collection('contracts').doc('c102').delete();
  await moveOut('u101', 'c101');
  const t = await tenant();
  assert.equal(t.isActive, true);
  assert.equal(t.monthlyRate, 150);
  assert.equal(t.unitNumber, '102');
});

test("another tenant's unit is refused: nothing is freed or taken off anyone", { skip: skipWithoutEmulator }, async () => {
  await seed();
  await fac().collection('units').doc('u7').set({
    unitNumber: '7',
    status: 'occupied',
    tenantId: 't2',
    tenantName: 'Bo Diaz',
    monthlyRate: 80,
  });
  await rejectsWith(moveOut('u7', 'c101'), 'failed-precondition', /Unit 7 is assigned to Bo Diaz, not this tenant/);
  assert.equal((await unit('u7')).tenantId, 't2');
  assert.equal((await tenant()).monthlyRate, 250);
  assert.equal((await fac().collection('contracts').doc('c101').get()).get('isActive'), true);
});

test('an archived contract is refused before anything is written', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await fac().collection('contracts').doc('c101').update({ isActive: false });
  await rejectsWith(moveOut('u101', 'c101'), 'failed-precondition', /archived or has already ended/);
  assert.equal((await unit('u101')).status, 'occupied');
  assert.equal((await tenant()).monthlyRate, 250);
});
