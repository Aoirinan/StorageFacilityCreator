import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

import { generateMonthlyRentCharges } from '../../monthlyRentCharges';
import { generateFacilityRentCharges } from '../../rentChargeJob';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * The monthly rent job and the generateMonthlyRentCharges callable against
 * real Firestore (the emulator): the ledger query, the units and contracts
 * read for a tenant whose move-in rent covers the month, and what is posted.
 * The unit tests (rentChargeHelpers.test.ts) cover the same rules through
 * the helpers alone. All names are made up.
 */

const FACILITY = 'fac-1';
const OWNER = 'owner-1';

const fac = () => emulatorDb().collection('facilities').doc(FACILITY);
const at = (iso: string) => admin.firestore.Timestamp.fromDate(new Date(iso));

type Row = Record<string, unknown>;

async function tenant(id: string, monthlyRate: number, unitNumber: string, units: Array<[string, number]>) {
  await fac().collection('tenants').doc(id).set({ name: `Tenant ${id}`, unitNumber, monthlyRate, isActive: true });
  for (const [unitId, rate] of units) {
    await fac().collection('units').doc(unitId).set({ unitNumber: unitId, monthlyRate: rate, tenantId: id, status: 'occupied' });
  }
}

async function row(tenantId: string, data: Row) {
  await fac().collection('ledgers').add({ tenantId, facilityId: FACILITY, status: 'posted', ...data });
}

/** The online move-in's rent rows. */
const onlineRent = (type: 'proratedRent' | 'rent', iso: string, amount: number, contractId: string): Row => ({
  type,
  amount,
  description: type === 'rent' ? 'Next Month Rent' : 'Prorated Rent',
  referenceId: contractId,
  entryDate: at(iso),
  createdBy: 'publicMoveIn',
  metadata: { lineItemId: null, isProrated: type === 'proratedRent' },
});

/** The app wizard's rent rows. */
const appRent = (lineItemType: 'proratedRent' | 'rent', moveInDate: string, entryIso: string, amount: number, contractId: string): Row => ({
  type: 'rentCharge',
  amount,
  description: lineItemType === 'rent' ? 'Monthly Rent' : 'Prorated Rent',
  referenceId: contractId,
  entryDate: at(entryIso),
  metadata: { lineItemType, isProrated: lineItemType === 'proratedRent', moveInDate: `${moveInDate}T00:00:00.000` },
});

/**
 * - pinewood: $1, moved in online in September dated 1 Oct, October charged at move-in.
 * - nextMonth: online move-in on 20 Sep with "Next Month Rent" for October.
 * - midSep: app move-in on 15 Sep, prorated: October is owed.
 * - twoUnits: unit A at $50 held since August, unit B at $100 moved in dated 1 Oct.
 * - leftB: moved into B dated 1 Oct and moved out of it before; rate is A's $50.
 * - short: two units at a $100 rate, B's $100 October charged at move-in.
 * - charged: October already posted by an earlier run.
 */
async function seed() {
  await fac().set({ name: 'Demo Storage', ownerUid: OWNER, active: true, roles: { [OWNER]: 'owner' } });

  await tenant('pinewood', 1, 'TEST-1', [['TEST-1', 1]]);
  await row('pinewood', onlineRent('proratedRent', '2026-10-01T00:00:00Z', 1, 'c-pinewood'));
  await row('pinewood', { type: 'payment', amount: -1, referenceId: 'pi_1', entryDate: at('2026-09-23T18:12:00Z') });

  await tenant('nextMonth', 120, 'N1', [['N1', 120]]);
  await row('nextMonth', onlineRent('proratedRent', '2026-09-20T00:00:00Z', 44, 'c-next'));
  await row('nextMonth', onlineRent('rent', '2026-09-20T00:00:00Z', 120, 'c-next'));

  await tenant('midSep', 120, 'M1', [['M1', 120]]);
  await row('midSep', appRent('proratedRent', '2026-09-15', '2026-09-15T14:30:00Z', 64, 'c-mid'));

  await tenant('twoUnits', 150, 'A1', [['A1', 50], ['B1', 100]]);
  await row('twoUnits', appRent('proratedRent', '2026-08-10', '2026-08-10T15:00:00Z', 35.48, 'c-a1'));
  await row('twoUnits', appRent('rent', '2026-10-01', '2026-10-01T05:00:00Z', 100, 'c-b1'));
  await fac().collection('contracts').doc('c-b1').set({ tenantId: 'twoUnits', isActive: true });

  await tenant('leftB', 50, 'A2', [['A2', 50]]);
  await row('leftB', appRent('rent', '2026-10-01', '2026-10-01T05:00:00Z', 100, 'c-b2'));
  await fac().collection('contracts').doc('c-b2').set({ tenantId: 'leftB', isActive: false, moveOutStatus: 'completed' });

  await tenant('short', 100, 'A3', [['A3', 50], ['B3', 100]]);
  await row('short', appRent('rent', '2026-10-01', '2026-10-01T05:00:00Z', 100, 'c-b3'));

  await tenant('charged', 80, 'C1', [['C1', 80]]);
  await row('charged', {
    type: 'rentCharge',
    amount: 80,
    description: 'Monthly Rent - October 2026',
    entryDate: at('2026-10-01T12:00:00Z'),
    metadata: { recurringCharge: true, chargeType: 'monthlyRent', month: 10, year: 2026 },
  });
}

/** October's monthly charges, by tenant. */
async function octoberCharges(): Promise<Record<string, Row[]>> {
  const snap = await fac().collection('ledgers').where('metadata.chargeType', '==', 'monthlyRent').get();
  const byTenant: Record<string, Row[]> = {};
  for (const doc of snap.docs) {
    const data = doc.data();
    if (data.metadata?.month !== 10 || data.metadata?.year !== 2026) continue;
    (byTenant[data.tenantId] ??= []).push(data);
  }
  return byTenant;
}

function assertOctober(charges: Record<string, Row[]>) {
  assert.deepEqual(
    Object.fromEntries(Object.entries(charges).map(([id, rows]) => [id, rows.map((r) => r.amount)])),
    { midSep: [120], twoUnits: [50], leftB: [50], charged: [80] },
  );
  assert.equal(charges.twoUnits[0].description, 'Monthly Rent - October 2026 (less $100.00 charged at move-in)');
  const meta = charges.twoUnits[0].metadata as Record<string, any>;
  assert.equal(meta.monthlyRate, 150);
  assert.equal(meta.lessCoveredAtMoveIn, 100);
  assert.deepEqual(meta.coveredAtMoveIn.map((c: Row) => c.contractId), ['c-b1']);
  assert.equal(charges.midSep[0].description, 'Monthly Rent - October 2026');
}

/**
 * Rent-generation audit rows, queried the way the Generation History panel
 * queries them (lib/services/rent_generation_history.dart).
 */
async function auditRows(eventType: string): Promise<Array<Record<string, any>>> {
  const snap = await fac().collection('auditLogs').where('eventType', '==', eventType).orderBy('timestamp', 'desc').get();
  return snap.docs.map((d) => d.data());
}

/** The writeAuditLog shape, not the job's old action/at/details. */
function assertAuditShape(r: Record<string, any>) {
  assert.ok(r.timestamp instanceof admin.firestore.Timestamp, 'timestamp');
  assert.equal(r.facilityId, FACILITY);
  assert.equal(r.targetType, 'ledgerEntry');
  assert.equal(r.after.chargeType, 'monthlyRent');
  assert.equal(r.action, undefined);
  assert.equal(r.at, undefined);
  assert.equal(r.details, undefined);
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test('the job on 1 Oct skips rent charged at move-in, and a rerun posts nothing', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const result = await generateFacilityRentCharges(FACILITY, '2026-10-01');
  assert.deepEqual(result, {
    successCount: 3,
    skippedCount: 4,
    errorCount: 0,
    coveredAtMoveInCount: 2,
    reducedCount: 1,
    flaggedCount: 1,
  });
  assertOctober(await octoberCharges());

  const flagged = await auditRows('recurringCharge.needsReview');
  assert.deepEqual(flagged.map((r) => r.tenantId), ['short']);
  assert.equal(flagged[0].targetType, 'tenant');
  assert.equal(flagged[0].metadata.runId, 'scheduled_2026_10');

  const generated = await auditRows('recurringCharge.generated');
  assert.deepEqual(generated.map((r) => [r.tenantId, r.after.amount]).sort(), [['leftB', 50], ['midSep', 120], ['twoUnits', 50]]);
  for (const r of generated) {
    assertAuditShape(r);
    assert.equal(r.actorUid, 'system');
    assert.equal(r.actorEmail, 'system@scheduled-job');
    assert.deepEqual(r.metadata, { runId: 'scheduled_2026_10', source: 'scheduled' });
    assert.equal(r.after.month, 10);
    assert.equal(r.after.year, 2026);
  }
  assert.equal(generated.find((r) => r.tenantId === 'twoUnits')!.after.lessCoveredAtMoveIn, 100);

  const again = await generateFacilityRentCharges(FACILITY, '2026-10-01');
  assert.equal(again.successCount, 0);
  assert.equal(again.errorCount, 0);
  assertOctober(await octoberCharges());
});

test('November is charged in full to every tenant', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const result = await generateFacilityRentCharges(FACILITY, '2026-11-01');
  assert.equal(result.successCount, 7);
  assert.equal(result.coveredAtMoveInCount, 0);
  const snap = await fac().collection('ledgers').where('metadata.month', '==', 11).get();
  assert.equal(snap.size, 7);
});

type Callable = {
  run: (data: unknown, context: functions.https.CallableContext) => Promise<Record<string, any>>;
};

test('the callable for October makes the same decisions', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const callable = generateMonthlyRentCharges as unknown as Callable;
  const context = { auth: { uid: OWNER, token: {} }, rawRequest: {} } as unknown as functions.https.CallableContext;

  const preview = await callable.run({ facilityId: FACILITY, forDate: '2026-10-01', dryRun: true }, context);
  assert.equal(preview.successCount, 3);

  const result = await callable.run({ facilityId: FACILITY, forDate: '2026-10-01T00:00:00.000' }, context);
  assert.equal(result.successCount, 3);
  assert.equal(result.skippedCount, 4);
  assert.equal(result.errorCount, 0);
  assert.equal(result.errors.length, 1);
  assert.match(result.errors[0], /Tenant short: not charged, check by hand/);
  assertOctober(await octoberCharges());

  // The preview wrote nothing; the run wrote one row per tenant, in the
  // job's shape, all under one run id.
  const generated = await auditRows('recurringCharge.generated');
  assert.deepEqual(generated.map((r) => [r.tenantId, r.after.amount]).sort(), [['leftB', 50], ['midSep', 120], ['twoUnits', 50]]);
  const runIds = new Set(generated.map((r) => r.metadata.runId));
  assert.equal(runIds.size, 1);
  assert.match([...runIds][0], /^manual_/);
  for (const r of generated) {
    assertAuditShape(r);
    assert.equal(r.actorUid, OWNER);
    assert.equal(r.metadata.source, 'manual');
  }
  const flagged = await auditRows('recurringCharge.needsReview');
  assert.deepEqual(flagged.map((r) => [r.tenantId, r.metadata.runId]), [['short', [...runIds][0]]]);
});
