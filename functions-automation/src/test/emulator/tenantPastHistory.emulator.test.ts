import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

import { recordTenantPastHistory, undoTenantPastHistory } from '../../tenantPastHistoryCallable';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * The deployed callables against real Firestore (the emulator): the wrapper
 * (sign-in, App Check, who may call, error mapping), the transaction that
 * reads the tenant's ledger and writes the lot, and undo. The unit tests
 * (tenantPastHistory.test.ts) cover the same rules through the plan alone.
 * All names are made up.
 */

const FACILITY = 'fac-1';
const OWNER = 'owner-1';
const TENANT = 't1';

type Callable = {
  run: (data: unknown, context: functions.https.CallableContext) => Promise<Record<string, any>>;
};
const record = recordTenantPastHistory as unknown as Callable;
const undo = undoTenantPastHistory as unknown as Callable;

function context(uid: string | null, opts: { appCheck?: boolean } = {}) {
  return {
    ...(uid ? { auth: { uid, token: { email: `${uid}@example.com` } } } : {}),
    ...(opts.appCheck === false ? {} : { app: { appId: 'test-app', token: {} } }),
    rawRequest: {},
  } as unknown as functions.https.CallableContext;
}

const fac = () => emulatorDb().collection('facilities').doc(FACILITY);

async function seed(): Promise<void> {
  await fac().set({ name: 'Demo Storage', ownerUid: OWNER, roles: { [OWNER]: 'owner', 'emp-1': 'employee' } });
  await fac().collection('tenants').doc(TENANT).set({ name: 'Pat Example', unitNumber: 'A1', monthlyRate: 80, isActive: true });
}

function example(requestId = 'req-emulator-1') {
  const charges = [];
  for (let month = 2; month <= 9; month += 1) {
    charges.push({ year: 2026, month, day: month === 2 ? 10 : 1, amount: 80 });
  }
  const venmo = (date: string, amount: number) => ({ date, amount, method: 'venmo' });
  return {
    facilityId: FACILITY,
    tenantId: TENANT,
    requestId,
    charges,
    payments: [
      venmo('2026-02-10', 80),
      venmo('2026-03-20', 80),
      venmo('2026-04-19', 80),
      venmo('2026-05-31', 80),
      venmo('2026-06-01', 160),
    ],
  };
}

async function ledger() {
  const snap = await fac().collection('ledgers').where('tenantId', '==', TENANT).get();
  return snap.docs.map((d) => d.data());
}

async function balance() {
  const rows = await ledger();
  return Math.round(rows.filter((r) => r.status === 'posted').reduce((s, r) => s + r.amount, 0) * 100) / 100;
}

async function rejectsWith(promise: Promise<unknown>, code: string, message?: RegExp) {
  await assert.rejects(promise, (err: unknown) => {
    const e = err as functions.https.HttpsError;
    assert.equal(e.code, code, `${e.code}: ${e.message}`);
    if (message) assert.match(e.message, message);
    return true;
  });
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test('wrapper: signed out, no App Check, employee, bad input', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await rejectsWith(record.run(example(), context(null)), 'unauthenticated');
  await rejectsWith(record.run(example(), context(OWNER, { appCheck: false })), 'failed-precondition', /App Check/);
  await rejectsWith(record.run(example(), context('emp-1')), 'permission-denied');
  await rejectsWith(record.run({ ...example(), payments: [{ date: '2030-01-01', amount: 5, method: 'venmo' }] }, context(OWNER)), 'invalid-argument', /future/);
  assert.deepEqual(await ledger(), []);
});

test('the owner example, a double press, and undo', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const result = await record.run(example(), context(OWNER));
  assert.equal(result.balance, 160);
  assert.equal(result.paidThrough, '2026-07-31');
  assert.equal(await balance(), 160);
  const tenant = (await fac().collection('tenants').doc(TENANT).get()).data()!;
  assert.equal((tenant.paidThrough as admin.firestore.Timestamp).toDate().toISOString(), '2026-07-31T12:00:00.000Z');
  const payments = await fac().collection('payments').get();
  assert.equal(payments.size, 5);

  const again = await record.run(example(), context(OWNER));
  assert.equal(again.alreadyApplied, true);
  assert.equal((await ledger()).length, 13);

  // A rent charge now exists for every month, so a fresh entry is refused.
  await rejectsWith(record.run(example('req-emulator-2'), context(OWNER)), 'already-exists', /February 2026/);

  const undone = await undo.run({ facilityId: FACILITY, tenantId: TENANT, requestId: 'req-emulator-1' }, context(OWNER));
  assert.equal(undone.entriesVoided, 13);
  assert.equal(undone.paidThroughRestored, true);
  assert.equal(await balance(), 0);
  const after = (await fac().collection('tenants').doc(TENANT).get()).data()!;
  assert.equal(after.paidThrough, null);
  const voided = await fac().collection('payments').where('status', '==', 'voided').get();
  assert.equal(voided.size, 5);

  // Undone months are free again.
  const redo = await record.run(example('req-emulator-3'), context(OWNER));
  assert.equal(redo.balance, 160);
});

test('hand-entered entries voided in the same save, move-in saved, and both put back by undo', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const ledgers = fac().collection('ledgers');
  const typedToday = admin.firestore.Timestamp.fromDate(new Date('2026-09-28T02:00:00Z'));
  const handIds: string[] = [];
  for (let i = 0; i < 8; i += 1) {
    await ledgers.doc(`hand-c${i}`).set({ tenantId: TENANT, type: 'rentCharge', status: 'posted', amount: 80, entryDate: typedToday, metadata: { invoiceId: 'inv-1' } });
    handIds.push(`hand-c${i}`);
  }
  for (const [i, amount] of [-160, -80, -80, -80].entries()) {
    await ledgers.doc(`hand-p${i}`).set({ tenantId: TENANT, type: 'payment', status: 'posted', amount, entryDate: typedToday });
    handIds.push(`hand-p${i}`);
  }
  assert.equal(await balance(), 240);

  const result = await record.run(
    { ...example('req-emulator-4'), voidLedgerEntryIds: handIds, moveInDate: '2026-02-10' },
    context(OWNER),
  );
  assert.equal(result.existingVoided, 12);
  assert.equal(result.moveInDateSaved, true);
  assert.equal(await balance(), 160);
  const tenant = (await fac().collection('tenants').doc(TENANT).get()).data()!;
  assert.equal((tenant.moveInDate as admin.firestore.Timestamp).toDate().toISOString(), '2026-02-10T12:00:00.000Z');

  const undone = await undo.run({ facilityId: FACILITY, tenantId: TENANT, requestId: 'req-emulator-4' }, context(OWNER));
  assert.equal(undone.entriesRestored, 12);
  assert.equal(await balance(), 240);
  const after = (await fac().collection('tenants').doc(TENANT).get()).data()!;
  assert.equal(after.moveInDate, null);
});

test('voiding Record-payment payments brings paidThrough back, voids the tenant rows, and undo restores both', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const ts = (iso: string) => admin.firestore.Timestamp.fromDate(new Date(iso));
  await fac().collection('tenants').doc(TENANT).update({ paidThrough: ts('2027-01-31T06:00:00Z') });
  const handIds: string[] = [];
  for (const [i, amount] of [160, 80, 80, 80].entries()) {
    await fac().collection('payments').doc(`pay-${i}`).set({ tenantId: TENANT, amount, status: 'completed', isActive: true, method: 'venmo', createdAt: ts('2026-09-28T02:00:00Z') });
    await fac().collection('tenants').doc(TENANT).collection('payments').doc(`row-${i}`).set({
      type: 'manual',
      status: 'succeeded',
      amountCents: amount * 100,
      facilityPaymentId: `pay-${i}`,
      createdAt: ts('2026-09-28T02:00:01Z'),
    });
    await fac().collection('ledgers').doc(`led-${i}`).set({
      tenantId: TENANT,
      type: 'payment',
      status: 'posted',
      amount: -amount,
      entryDate: ts('2026-09-28T02:00:00Z'),
      metadata: { paymentId: `pay-${i}`, invoiceId: 'inv-9' },
    });
    handIds.push(`led-${i}`);
  }
  await fac().collection('invoices').doc('inv-9').set({ invoiceNumber: 'INV-0009' });

  const result = await record.run({ ...example('req-emulator-5'), voidLedgerEntryIds: handIds }, context(OWNER));
  assert.equal(result.paidThroughBefore, '2027-01-31');
  assert.equal(result.paidThrough, '2026-07-31');
  assert.deepEqual(result.invoicesToReview, [{ id: 'inv-9', number: 'INV-0009' }]);
  const rows = await fac().collection('tenants').doc(TENANT).collection('payments').get();
  assert.ok(rows.docs.every((d) => d.get('status') === 'voided'));

  // A different request under the same id is refused.
  await rejectsWith(record.run({ ...example('req-emulator-5'), payments: [] }, context(OWNER)), 'already-exists', /different details/);

  await undo.run({ facilityId: FACILITY, tenantId: TENANT, requestId: 'req-emulator-5' }, context(OWNER));
  const tenant = (await fac().collection('tenants').doc(TENANT).get()).data()!;
  assert.equal((tenant.paidThrough as admin.firestore.Timestamp).toDate().toISOString(), '2027-01-31T06:00:00.000Z');
  const restored = await fac().collection('tenants').doc(TENANT).collection('payments').get();
  assert.ok(restored.docs.every((d) => d.get('status') === 'succeeded'));
});

test('undo: an employee is refused', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await record.run(example(), context(OWNER));
  await rejectsWith(
    undo.run({ facilityId: FACILITY, tenantId: TENANT, requestId: 'req-emulator-1' }, context('emp-1')),
    'permission-denied',
  );
  assert.equal(await balance(), 160);
});
