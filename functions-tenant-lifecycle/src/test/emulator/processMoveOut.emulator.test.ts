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
const contract = async (id: string) => (await fac().collection('contracts').doc(id).get()).data()!;

/** The tenant's posted ledger rows, oldest amount first, as the app reads them. */
async function ledger(): Promise<Array<Record<string, unknown>>> {
  const snap = await fac().collection('ledgers').where('tenantId', '==', 't1').where('status', '==', 'posted').get();
  return snap.docs.map((d) => d.data()).sort((a, b) => Number(a.amount) - Number(b.amount));
}

/** What LedgerService.getLedgerBalance shows: the plain sum of posted amounts. */
async function balance(): Promise<number> {
  return (await ledger()).reduce((sum, row) => sum + Number(row.amount), 0);
}

/** A tenant paid up and then some: a $50 payment with nothing to apply it to. */
async function seedCredit(amount = 50): Promise<void> {
  await fac().collection('ledgers').doc('pay1').set({
    tenantId: 't1',
    facilityId: FACILITY,
    type: 'payment',
    amount: -amount,
    description: 'Payment',
    status: 'posted',
  });
}

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

// Refunds. The screen sends moveOutRefund (the credit it worked out) whether
// or not Process Refund is ticked, and processRefund says whether it was.
// The ledger balance is the plain sum of posted amounts, so a refund of a
// credit must be posted positive to bring it back to 0.

test('a credit balance with Process Refund on: one positive refund row, the balance ends at 0', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await seedCredit(50);
  assert.equal(await balance(), -50);

  const result = await moveOut('u101', 'c101', {
    moveOutCharges: 0,
    moveOutRefund: 50,
    processRefund: true,
    refundMethod: 'check',
  });
  assert.equal(result.success, true);
  assert.equal(result.refundPosted, true);

  const rows = await ledger();
  assert.equal(rows.length, 2, 'the payment and one refund row');
  const refund = rows[1];
  assert.equal(refund.type, 'refund');
  assert.equal(refund.amount, 50, 'positive: the credit is gone once the money is handed back');
  assert.equal(refund.description, 'Move-out refund');
  assert.equal(refund.referenceId, 'c101');
  assert.equal(refund.createdBy, OWNER);
  assert.deepEqual(refund.metadata, {
    moveOutDate: '2026-09-23T12:00:00.000Z',
    moveOutRefund: true,
    refundMethod: 'check',
  });
  assert.equal(await balance(), 0);
  assert.equal((await contract('c101')).moveOutRefund, 50);
});

test('Process Refund off: no refund row, the credit stays on the ledger', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await seedCredit(50);

  // The screen sends the refund it worked out either way; only the flag
  // says whether the owner is giving it. The amount alone used to post it.
  const result = await moveOut('u101', 'c101', { moveOutCharges: 0, moveOutRefund: 50, processRefund: false });
  assert.equal(result.success, true);
  assert.equal(result.refundPosted, false);

  const rows = await ledger();
  assert.equal(rows.length, 1, 'only the payment');
  assert.equal(rows[0].type, 'payment');
  assert.equal(await balance(), -50);
  // The contract records what was refunded, which is nothing.
  assert.equal((await contract('c101')).moveOutRefund, 0);
  assert.equal((await unit('u101')).status, 'available', 'the move-out itself went through');
});

test('a refund is not posted when the flag is missing or not exactly true', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await seedCredit(50);
  await moveOut('u101', 'c101', { moveOutRefund: 50 });
  assert.equal((await ledger()).length, 1);
  await moveOut('u102', 'c102', { moveOutRefund: 50, processRefund: 'true' });
  assert.equal((await ledger()).length, 1);
  assert.equal(await balance(), -50);
});

test('net charges below zero (unused prorated rent) are posted as a credit, so refunding it ends at 0', { skip: skipWithoutEmulator }, async () => {
  // The month was billed in advance and the tenant leaves early: the screen's
  // lines net to a credit for the unused days, and it counts that credit in
  // the refund. Dropping the credit while posting the refund left the tenant
  // owing the very amount they were handed back.
  await seed();
  const result = await moveOut('u101', 'c101', {
    moveOutCharges: -100,
    moveOutRefund: 100,
    processRefund: true,
    refundMethod: 'cash',
  });
  assert.equal(result.success, true);

  const rows = await ledger();
  assert.equal(rows.length, 2);
  assert.equal(rows[0].type, 'credit');
  assert.equal(rows[0].amount, -100);
  assert.match(String(rows[0].description), /^Move-out credit/);
  assert.equal(rows[0].referenceId, 'c101');
  assert.equal(rows[1].type, 'refund');
  assert.equal(rows[1].amount, 100);
  assert.equal(await balance(), 0);
  assert.equal((await contract('c101')).moveOutCharges, -100);
});

test('a net credit with Process Refund off stays as the credit', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await moveOut('u101', 'c101', { moveOutCharges: -100, moveOutRefund: 100, processRefund: false });
  const rows = await ledger();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].type, 'credit');
  assert.equal(rows[0].amount, -100);
  assert.equal(await balance(), -100);
});

test('positive charges post a move-out fee, as before; zero posts nothing', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await moveOut('u101', 'c101', { moveOutCharges: 40.004 });
  let rows = await ledger();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].type, 'moveOutFee');
  assert.equal(rows[0].amount, 40, 'whole cents');
  assert.equal(rows[0].description, 'Move-out charges');
  assert.equal(await balance(), 40);

  await moveOut('u102', 'c102', { moveOutCharges: 0 });
  rows = await ledger();
  assert.equal(rows.length, 1);
});

// The move-out date. The screen sends the day the owner picked as a calendar
// day; the client deployed before this sent local midnight with no offset,
// which Node read as UTC, so it showed as the evening before in US zones.

test('the move-out date is the day the owner picked, at noon UTC, in either form', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await moveOut('u101', 'c101', { moveOutDate: '2026-09-23', moveOutCharges: 10 });
  const at = (doc: Record<string, unknown>) =>
    (doc.moveOutDate as { toDate: () => Date }).toDate().toISOString();
  assert.equal(at(await contract('c101')), '2026-09-23T12:00:00.000Z');
  assert.equal(at(await unit('u101')), '2026-09-23T12:00:00.000Z');
  const fee = (await ledger())[0];
  assert.equal((fee.entryDate as { toDate: () => Date }).toDate().toISOString(), '2026-09-23T12:00:00.000Z');
  assert.equal((fee.metadata as Record<string, unknown>).moveOutDate, '2026-09-23T12:00:00.000Z');

  // The deployed client's form: toIso8601String() of a local DateTime.
  await moveOut('u102', 'c102', { moveOutDate: '2026-09-23T00:00:00.000' });
  assert.equal(at(await contract('c102')), '2026-09-23T12:00:00.000Z');
  assert.equal(at(await unit('u102')), '2026-09-23T12:00:00.000Z');
});

test('a move-out date that is not a date is refused before anything is written', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await rejectsWith(moveOut('u101', 'c101', { moveOutDate: '2026-02-30' }), 'invalid-argument', /moveOutDate/);
  await rejectsWith(moveOut('u101', 'c101', { moveOutDate: 'soon' }), 'invalid-argument', /moveOutDate/);
  assert.equal((await unit('u101')).status, 'occupied');
  assert.equal((await contract('c101')).isActive, true);
  assert.equal((await ledger()).length, 0);
});

test('a move-out dated after today (UTC) is refused before anything is written', { skip: skipWithoutEmulator }, async () => {
  // The screen offers no later day; a direct call or an old page could.
  await seed();
  const tomorrow = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  await rejectsWith(
    moveOut('u101', 'c101', { moveOutDate: tomorrow, moveOutCharges: 10 }),
    'invalid-argument',
    /^The move-out date is after today, so nothing was moved out\./,
  );
  assert.equal((await unit('u101')).status, 'occupied');
  assert.equal((await contract('c101')).isActive, true);
  assert.equal((await ledger()).length, 0);
  // Today (UTC) is allowed.
  const today = new Date().toISOString().slice(0, 10);
  assert.equal((await moveOut('u101', 'c101', { moveOutDate: today })).success, true);
});

test("another tenant's contract is refused before anything, and their own move-out still runs", { skip: skipWithoutEmulator }, async () => {
  // t1 sent with t2's contract c7 ended c7 and moved t1 out; t2's real
  // move-out through c7 was then answered "already completed".
  await seed();
  await fac().collection('tenants').doc('t2').set({ name: 'Bo Diaz', isActive: true, unitNumber: '7', monthlyRate: 80 });
  await fac().collection('units').doc('u7').set({ unitNumber: '7', status: 'occupied', tenantId: 't2', monthlyRate: 80 });
  await fac().collection('contracts').doc('c7').set({ tenantId: 't2', isActive: true, status: 'active' });

  await rejectsWith(moveOut('u101', 'c7'), 'failed-precondition', /belongs to another tenant, so nothing was moved out/);
  assert.equal((await fac().collection('contracts').doc('c7').get()).get('moveOutStatus'), undefined);
  assert.equal((await unit('u101')).status, 'occupied');
  assert.equal((await tenant()).monthlyRate, 250);

  // Even once c7 is completed, t1 is refused, not told "already completed".
  const own = await callable.run(
    { facilityId: FACILITY, tenantId: 't2', unitId: 'u7', contractId: 'c7', moveOutDate: '2026-09-23T12:00:00Z' },
    context,
  );
  assert.equal(own.alreadyCompleted, false);
  assert.equal((await tenant('t2')).isActive, false);
  await rejectsWith(moveOut('u101', 'c7'), 'failed-precondition', /belongs to another tenant/);
});

test('a contract for another unit they still rent is refused; one for a unit they gave up is not', { skip: skipWithoutEmulator }, async () => {
  await seed();
  // c102 was signed for unit 102, which t1 keeps: leaving 101 through it
  // would end the agreement for 102. 102 is in Complex 3, and is named so:
  // where numbers repeat across areas "unit 102" can be two units.
  await rejectsWith(
    moveOut('u101', 'c102'),
    'failed-precondition',
    /This contract is for unit 102 \(Complex 3\), which this tenant still rents.*Units > unit 101 > Unassign Tenant/,
  );
  assert.equal((await unit('u101')).status, 'occupied');
  assert.equal((await fac().collection('contracts').doc('c102').get()).get('isActive'), true);

  // Moved from 102 to 103 since signing (online move-in context): the
  // contract ends with the unit they are in.
  await fac().collection('units').doc('u102').update({ status: 'available', tenantId: null });
  await fac().collection('units').doc('u103').set({ unitNumber: '103', status: 'occupied', tenantId: 't1', monthlyRate: 150 });
  await fac()
    .collection('contracts')
    .doc('c102')
    .set({ tenantId: 't1', isActive: true, status: 'active', customFields: { onlineMoveInContext: { unitId: 'u102' } } });
  const result = await moveOut('u103', 'c102');
  assert.equal(result.success, true);
  assert.equal((await unit('u103')).status, 'available');
});

test('a refund is posted positive, only once made, and the credit it pays out is posted too', { skip: skipWithoutEmulator }, async () => {
  // Paid in full for the month, leaving early: the screen nets a $66.67
  // credit for unused days and a $30 cleaning fee to -$36.67 and refunds
  // $36.67. The credit was dropped (only a positive net was posted) and the
  // refund posted as -36.67: the tenant was left showing a $36.67 credit
  // they had already been paid.
  const balance = async () => {
    const rows = await fac().collection('ledgers').where('tenantId', '==', 't1').get();
    return Math.round(rows.docs.reduce((sum, d) => sum + (d.get('amount') as number), 0) * 100) / 100;
  };
  await seed();
  const cash = await moveOut('u101', 'c101', {
    moveOutCharges: -36.67,
    moveOutRefund: 36.67,
    processRefund: true,
    refundMethod: 'cash',
  });
  assert.equal(cash.refundRecorded, true);
  assert.equal(await balance(), 0);
  const refund = (await fac().collection('ledgers').where('type', '==', 'refund').get()).docs[0].data();
  assert.equal(refund.amount, 36.67);
  assert.equal(refund.metadata.refundMethod, 'cash');

  // Not refunded: the credit stays theirs.
  await clearEmulator();
  await seed();
  const kept = await moveOut('u101', 'c101', { moveOutCharges: -36.67, moveOutRefund: 36.67, processRefund: false });
  assert.equal(kept.refundRecorded, false);
  assert.equal(await balance(), -36.67);

  // By card: nothing here refunds the card or posts a refund. The amount
  // goes back as cardRefundDue for the screen to refund through
  // processRefund, and the contract says a card refund is pending until
  // the screen records what happened.
  await clearEmulator();
  await seed();
  const card = await moveOut('u101', 'c101', {
    moveOutCharges: -36.67,
    moveOutRefund: 36.67,
    processRefund: true,
    refundMethod: 'creditCard',
  });
  assert.equal(card.refundRecorded, false);
  assert.equal(card.refundPosted, false);
  assert.equal(card.cardRefundDue, 36.67);
  assert.equal(card.refundProcessed, false);
  assert.match(String(card.refundWarning), /card refund was not made by the move-out/);
  assert.doesNotMatch(String(card.refundWarning), /when Stripe confirms/);
  assert.equal(await balance(), -36.67);
  const signed = await contract('c101');
  assert.equal(signed.moveOutRefund, 0);
  assert.equal(signed.moveOutRefundMethod, 'creditCard');
  assert.deepEqual(signed.moveOutCardRefund, { status: 'pending', requested: 36.67, refunded: 0 });
  // A retry (a dropped connection) is never refunded again.
  const again = await moveOut('u101', 'c101', {
    moveOutCharges: -36.67,
    moveOutRefund: 36.67,
    processRefund: true,
    refundMethod: 'creditCard',
  });
  assert.equal(again.alreadyCompleted, true);
  assert.equal(again.cardRefundDue, 0);

  // Cash: no card refund, and none pending on the contract.
  await clearEmulator();
  await seed();
  const byCash = await moveOut('u101', 'c101', {
    moveOutCharges: -36.67,
    moveOutRefund: 36.67,
    processRefund: true,
    refundMethod: 'cash',
  });
  assert.equal(byCash.cardRefundDue, 0);
  assert.equal((await contract('c101')).moveOutRefundMethod, 'cash');
  assert.equal((await contract('c101')).moveOutCardRefund, undefined);
});

/**
 * The rent line, worked out here from the ledger by the screen's rule
 * (moveOutRent). A test tenant whose tenancy starts 1 Oct and who paid
 * October's $1 online at move-in was moved out on 24 Sep and charged
 * "Prorated Rent (24 days) $0.80" for days before their tenancy.
 */
async function seedFutureTenancy(): Promise<void> {
  await fac().set({ name: 'Acme Storage', ownerUid: OWNER });
  await fac().collection('tenants').doc('t1').set({ name: 'Test Tenant', isActive: true, unitNumber: 'TEST-1', monthlyRate: 1 });
  const october = new Date('2026-10-01T00:00:00Z');
  await fac().collection('units').doc('u1').set({
    unitNumber: 'TEST-1', status: 'occupied', tenantId: 't1', monthlyRate: 1, moveInDate: october,
  });
  await fac().collection('contracts').doc('c1').set({ tenantId: 't1', isActive: true, status: 'signed' });
  const ledgers = fac().collection('ledgers');
  await ledgers.doc('rent').set({
    tenantId: 't1', type: 'proratedRent', amount: 1, description: 'Prorated Rent', referenceId: 'c1',
    entryDate: october, status: 'posted', metadata: { lineItemId: null, isProrated: true },
  });
  await ledgers.doc('paid').set({
    tenantId: 't1', type: 'payment', amount: -1, description: 'Online move-in payment', referenceId: 'pi_1',
    entryDate: new Date('2026-09-23T18:12:00Z'), status: 'posted', metadata: {},
  });
}

const screen = (extra: Record<string, unknown> = {}) => ({
  moveOutDate: '2026-09-24T00:00:00.000',
  prorateRent: true,
  moveOutFees: 0,
  moveOutCharges: -1,
  moveOutRefund: 1,
  processRefund: false,
  ...extra,
});

async function moveOutLedger() {
  const rows = await fac().collection('ledgers').where('tenantId', '==', 't1').get();
  return rows.docs.filter((d) => !['rent', 'paid'].includes(d.id)).map((d) => d.data());
}

test('out before a future move-in date: nothing charged, the prepaid month credited', { skip: skipWithoutEmulator }, async () => {
  await seedFutureTenancy();
  const result = await moveOut('u1', 'c1', screen());
  assert.equal(result.success, true);
  assert.equal(result.charges, -1);

  const posted = await moveOutLedger();
  assert.deepEqual(
    posted.map((r) => [r.type, r.amount, r.description, r.referenceId, r.metadata.moveOutLine]),
    [['credit', -1, 'Prorated rent credit (31 unused days)', 'c1', 'proratedRentCredit']],
  );
  // Not refunded: the dollar stays theirs, as a credit on the ledger.
  const all = await fac().collection('ledgers').where('tenantId', '==', 't1').get();
  assert.equal(all.docs.reduce((sum, d) => sum + (d.get('amount') as number), 0), -1);
  assert.equal((await fac().collection('contracts').doc('c1').get()).get('moveOutCharges'), -1);
});

test('the credit refunded in cash leaves them owing nothing', { skip: skipWithoutEmulator }, async () => {
  await seedFutureTenancy();
  await moveOut('u1', 'c1', screen({ processRefund: true, refundMethod: 'cash' }));
  const posted = await moveOutLedger();
  assert.deepEqual(
    posted.map((r) => [r.type, r.amount]).sort(),
    [['credit', -1], ['refund', 1]],
  );
});

test('charges the owner was not shown are refused and nothing is written', { skip: skipWithoutEmulator }, async () => {
  await seedFutureTenancy();
  // The old screen's figure: $0.80 for 24 September days.
  await rejectsWith(
    moveOut('u1', 'c1', screen({ moveOutCharges: 0.8, moveOutRefund: 0 })),
    'failed-precondition',
    /now come to a \$1\.00 credit, not \$0\.80\. Nothing was moved out/,
  );
  assert.deepEqual(await moveOutLedger(), []);
  const contract = (await fac().collection('contracts').doc('c1').get()).data()!;
  assert.equal(contract.isActive, true);
  assert.equal(contract.moveOutStatus, undefined);
  assert.equal((await unit('u1')).status, 'occupied');
});

test('a page from before the rent line still posts its net as one line', { skip: skipWithoutEmulator }, async () => {
  await seedFutureTenancy();
  await moveOut('u1', 'c1', { moveOutDate: '2026-09-24T00:00:00.000', moveOutCharges: 25 });
  assert.deepEqual(
    (await moveOutLedger()).map((r) => [r.type, r.amount, r.description]),
    [['moveOutFee', 25, 'Move-out charges']],
  );
});

test("a free month's coupon: no credit, and a cash refund for it is refused", { skip: skipWithoutEmulator }, async () => {
  // The app's move-in with a free-month coupon: +300 rent, -300 discount.
  await fac().set({ name: 'Acme Storage', ownerUid: OWNER });
  await fac().collection('tenants').doc('t1').set({ name: 'Ada Park', isActive: true, unitNumber: '7', monthlyRate: 300 });
  await fac().collection('units').doc('u7').set({ unitNumber: '7', status: 'occupied', tenantId: 't1', monthlyRate: 300 });
  await fac().collection('contracts').doc('c7').set({ tenantId: 't1', isActive: true, status: 'draft' });
  const moveIn = { moveInDate: '2026-09-01T00:00:00.000' };
  const at = new Date('2026-09-01T05:00:00Z');
  await fac().collection('ledgers').doc('rent').set({
    tenantId: 't1', type: 'rentCharge', amount: 300, referenceId: 'c7', entryDate: at, status: 'posted',
    metadata: { lineItemType: 'proratedRent', isProrated: true, ...moveIn },
  });
  await fac().collection('ledgers').doc('free').set({
    tenantId: 't1', type: 'otherCharge', amount: -300, referenceId: 'c7', entryDate: at, status: 'posted',
    metadata: { lineItemType: 'discount', ...moveIn },
  });
  const out = (extra: Record<string, unknown>) =>
    moveOut('u7', 'c7', { moveOutDate: '2026-09-10T00:00:00.000', prorateRent: true, moveOutFees: 0, ...extra });

  // What the rent-rate credit offered: $200 back, refunded in cash.
  await rejectsWith(
    out({ moveOutCharges: -200, moveOutRefund: 200, processRefund: true, refundMethod: 'cash' }),
    'failed-precondition',
    /now come to \$0\.00, not a \$200\.00 credit/,
  );
  await rejectsWith(
    out({ moveOutCharges: 0, moveOutRefund: 200, processRefund: true, refundMethod: 'cash' }),
    'failed-precondition',
    /The \$200\.00 refund is more than the \$0\.00 this tenant is owed/,
  );
  assert.equal((await fac().collection('ledgers').where('tenantId', '==', 't1').get()).size, 2, 'nothing posted');

  // What the screen now shows: nothing to charge or credit.
  const done = await out({ moveOutCharges: 0, moveOutRefund: 0 });
  assert.equal(done.success, true);
  assert.equal((await fac().collection('ledgers').where('tenantId', '==', 't1').get()).size, 2, 'no rows for a $0 move-out');
});

test('a second linked unit with no status is not one they keep, as the screen reads it: their own rate, tenancy ended', { skip: skipWithoutEmulator }, async () => {
  // The screen reads a unit with no status as available (UnitModel), so a
  // tenant whose other linked unit has none keeps no unit there, and it
  // prorates their own rate. This counted that unit as kept, prorated the
  // vacated unit's rate instead, and refused every such move-out as not
  // what the owner was shown.
  await fac().set({ name: 'Acme Storage', ownerUid: OWNER });
  await fac().collection('tenants').doc('t1').set({ name: 'Ada Park', isActive: true, unitNumber: '1', unitId: 'u1', monthlyRate: 300 });
  await fac().collection('units').doc('u1').set({ unitNumber: '1', status: 'occupied', tenantId: 't1', monthlyRate: 90 });
  await fac().collection('units').doc('u2').set({ unitNumber: '2', tenantId: 't1', monthlyRate: 210 });
  await fac().collection('contracts').doc('c1').set({ tenantId: 't1', isActive: true, status: 'active' });
  await fac().collection('gateAccess').doc('g1').set({ tenantId: 't1', accessCode: '1234', isActive: true });
  // No September rent posted: days 1 to 10 are used and charged, at $10 a
  // day on their $300 (the screen's figure), not $3 a day on the unit's $90.
  const out = (moveOutCharges: number) =>
    moveOut('u1', 'c1', {
      moveOutDate: '2026-09-10T00:00:00.000',
      prorateRent: true,
      moveOutFees: 0,
      moveOutCharges,
      moveOutRefund: 0,
    });

  await rejectsWith(out(30), 'failed-precondition', /now come to \$100\.00, not \$30\.00/);
  const done = await out(100);
  assert.equal(done.success, true);
  assert.equal(done.charges, 100);

  // Their only unit as the app reads it: the tenancy ends, gate code off,
  // as the app's own move-out and Unassign do.
  const t = await tenant();
  assert.equal(t.isActive, false);
  assert.equal(t.unitNumber, '');
  assert.equal(t.monthlyRate, 300, 'kept as history');
  assert.equal((await fac().collection('gateAccess').doc('g1').get()).get('isActive'), false);
});
