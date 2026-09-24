import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';

import { deleteTenantsPermanently } from '../../deleteTenantsPermanentlyCallable';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * The deployed callable against real Firestore (the emulator): its wrapper
 * (sign-in, App Check, a missing facility, who may call, error mapping) and
 * the real transaction adapter, firestoreTenantDeleteTransaction, whose
 * queries run inside the transaction that deletes. The unit tests fake both.
 */

const FACILITY = 'fac-1';
const OWNER = 'owner-1';

type Callable = {
  run: (data: unknown, context: functions.https.CallableContext) => Promise<Record<string, unknown>>;
};
const callable = deleteTenantsPermanently as unknown as Callable;

function context(uid: string | null, opts: { appCheck?: boolean; superadmin?: boolean } = {}) {
  return {
    ...(uid
      ? { auth: { uid, token: { email: `${uid}@example.com`, superadmin: opts.superadmin === true } } }
      : {}),
    ...(opts.appCheck === false ? {} : { app: { appId: 'test-app', token: {} } }),
    rawRequest: {},
  } as unknown as functions.https.CallableContext;
}

function call(tenantIds: string[], uid: string | null = OWNER, opts: { appCheck?: boolean; superadmin?: boolean; facilityId?: string } = {}) {
  return callable.run({ facilityId: opts.facilityId ?? FACILITY, tenantIds }, context(uid, opts));
}

const fac = () => emulatorDb().collection('facilities').doc(FACILITY);

async function seed(): Promise<void> {
  await fac().set({
    name: 'Acme Storage',
    ownerUid: OWNER,
    roles: { [OWNER]: 'owner', 'emp-1': 'employee' },
    platformSubscriptionStatus: 'active',
  });
  const tenants = fac().collection('tenants');
  await tenants.doc('clean').set({ name: 'Clean Entry', phone: '555' });
  await tenants.doc('occupant').set({ name: 'Ada Park' });
  await tenants.doc('history').set({ name: 'Bo Diaz' });
  await tenants.doc('autopay').set({ name: 'Cy Lee' });
  await tenants.doc('autopay').collection('paymentMethods').doc('pm1').set({ isActive: false, autopayEnabled: true });
  await fac().collection('ledgers').doc('l1').set({ tenantId: 'history', status: 'posted', amount: 100 });
  // Clean Entry: a stale link on an available unit, and a gate code.
  await fac().collection('units').doc('u9').set({ unitNumber: '9', status: 'available', tenantId: 'clean' });
  await fac().collection('gateAccess').doc('g1').set({ tenantId: 'clean', isActive: true, accessCode: '1234' });
  // Ada Park: no history, still in a locked-out unit.
  await fac()
    .collection('units')
    .doc('u102')
    .set({ unitNumber: '102', status: 'lockout', tenantId: 'occupant', tenantName: 'Ada Park' });
}

async function exists(path: string): Promise<boolean> {
  return (await emulatorDb().doc(path).get()).exists;
}

async function auditRows(): Promise<Array<Record<string, unknown>>> {
  const snap = await fac().collection('auditLogs').get();
  return snap.docs.map((d) => d.data());
}

async function rejectsWith(promise: Promise<unknown>, code: string, message?: string | RegExp) {
  await assert.rejects(promise, (err: unknown) => {
    const e = err as functions.https.HttpsError;
    assert.equal(e.code, code, `${e.code}: ${e.message}`);
    if (typeof message === 'string') assert.equal(e.message, message);
    if (message instanceof RegExp) assert.match(e.message, message);
    return true;
  });
}

test.beforeEach(async () => {
  if (!skipWithoutEmulator) await clearEmulator();
});

test('wrapper: signed out, no App Check token, bad request, missing facility', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await rejectsWith(call(['clean'], null), 'unauthenticated');
  await rejectsWith(call(['clean'], OWNER, { appCheck: false }), 'failed-precondition', /App Check/);
  await rejectsWith(call([]), 'invalid-argument');
  await rejectsWith(call(['clean'], OWNER, { facilityId: 'nope' }), 'not-found', 'Facility not found');
  assert.equal(await exists(`facilities/${FACILITY}/tenants/clean`), true);
});

test('wrapper: an employee is refused; an unpaid facility is refused with the app wording', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await rejectsWith(call(['clean'], 'emp-1'), 'permission-denied');
  await fac().update({ platformSubscriptionStatus: 'past_due' });
  await rejectsWith(call(['clean']), 'failed-precondition', /active paid subscription or an active trial/);
  assert.equal(await exists(`facilities/${FACILITY}/tenants/clean`), true);
});

test('history anywhere in the selection refuses it all, and nothing is written', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const result = await call(['clean', 'history', 'occupant', 'autopay']);
  assert.equal(result.status, 'refused');
  assert.deepEqual(
    (result.blocked as Array<{ tenantId: string; reasons: string[] }>).map((b) => [b.tenantId, b.reasons]),
    [
      ['history', ['charges or payments on the ledger']],
      // Autopay armed on a card, read through the real adapter.
      ['autopay', ['an autopay subscription']],
    ],
  );
  for (const t of ['clean', 'history', 'occupant', 'autopay']) {
    assert.equal(await exists(`facilities/${FACILITY}/tenants/${t}`), true, t);
  }
  assert.equal((await fac().collection('units').doc('u102').get()).get('tenantId'), 'occupant');
  assert.deepEqual(await auditRows(), []);
});

test('a clean selection: units freed, gate code off, tenants gone, audited, in one transaction', { skip: skipWithoutEmulator }, async () => {
  await seed();
  const result = await call(['clean', 'occupant']);
  assert.equal(result.status, 'deleted');
  assert.equal(result.unitsUnlinked, 2);
  assert.equal(result.gateAccessDeactivated, 1);

  assert.equal(await exists(`facilities/${FACILITY}/tenants/clean`), false);
  assert.equal(await exists(`facilities/${FACILITY}/tenants/occupant`), false);
  // The locked-out unit Ada Park held is free again, with no tenant on it.
  const u102 = (await fac().collection('units').doc('u102').get()).data()!;
  assert.equal(u102.status, 'available');
  assert.equal(u102.tenantId, undefined);
  assert.equal(u102.tenantName, undefined);
  assert.equal(u102.updatedBy, OWNER);
  assert.equal((await fac().collection('units').doc('u9').get()).get('tenantId'), undefined);
  assert.equal((await fac().collection('gateAccess').doc('g1').get()).get('isActive'), false);

  const rows = await auditRows();
  const deleted = rows.filter((r) => r.eventType === 'tenant.deleted');
  assert.deepEqual(deleted.map((r) => r.targetId).sort(), ['clean', 'occupant']);
  assert.deepEqual(deleted.find((r) => r.targetId === 'clean')!.before, { name: 'Clean Entry', phone: '555' });
  const bulk = rows.filter((r) => r.eventType === 'tenant.bulkDeleted');
  assert.equal(bulk.length, 1);
  assert.deepEqual((bulk[0].metadata as Record<string, unknown>).tenantIds, ['clean', 'occupant']);
});

/** Every doc under [path] that exists, the doc itself included. */
async function docsUnder(path: string): Promise<string[]> {
  const out: string[] = [];
  const walk = async (doc: FirebaseFirestore.DocumentReference) => {
    if ((await doc.get()).exists) out.push(doc.path);
    for (const col of await doc.listCollections()) {
      for (const d of await col.listDocuments()) await walk(d);
    }
  };
  await walk(emulatorDb().doc(path));
  return out.sort();
}

test("a deleted tenant's own subcollections go with it; a refused one's stay", { skip: skipWithoutEmulator }, async () => {
  await seed();
  // What a tenant with no history can still have under its doc: a switched-off
  // card, billing/default, insurance, contact logs, a failed card payment.
  const clean = fac().collection('tenants').doc('clean');
  await clean.collection('paymentMethods').doc('pm1').set({ isActive: false, last4: '4242' });
  await clean.collection('billing').doc('default').set({ autopayEnabled: false, stripeCustomerId: 'cus_1' });
  await clean.collection('insurance').doc('i1').set({ provider: 'Acme' });
  await clean.collection('contactLogs').doc('c1').set({ type: 'call' });
  await clean.collection('payments').doc('p1').set({ status: 'failed' });
  await clean.collection('contactLogs').doc('c1').collection('attachments').doc('a1').set({ name: 'note' });

  assert.equal((await call(['clean'])).status, 'deleted');
  assert.deepEqual(await docsUnder(`facilities/${FACILITY}/tenants/clean`), []);
  // A refusal writes nothing, so the autopay tenant's card stays.
  assert.equal((await call(['autopay'])).status, 'refused');
  assert.deepEqual(await docsUnder(`facilities/${FACILITY}/tenants/autopay`), [
    `facilities/${FACILITY}/tenants/autopay`,
    `facilities/${FACILITY}/tenants/autopay/paymentMethods/pm1`,
  ]);
  // Deleting the same id again finds nothing to refuse and clears anything left.
  await clean.collection('insurance').doc('late').set({ provider: 'Late write' });
  assert.equal((await call(['clean'])).status, 'deleted');
  assert.deepEqual(await docsUnder(`facilities/${FACILITY}/tenants/clean`), []);
});

test('a super admin (the claim) with no role at the facility can delete', { skip: skipWithoutEmulator }, async () => {
  await seed();
  await fac().update({ platformSubscriptionStatus: 'past_due' });
  const result = await call(['clean'], 'admin-1', { superadmin: true });
  assert.equal(result.status, 'deleted');
  const audit = (await auditRows())[0];
  assert.equal(audit.actorRole, 'superadmin');
});

test('an unexpected Firestore failure is reported as internal, with words an owner can act on', { skip: skipWithoutEmulator }, async () => {
  await seed();
  // Ids of the form __x__ are reserved: Firestore rejects the read inside
  // the transaction with a plain error, not an HttpsError.
  await rejectsWith(
    call(['clean', '__reserved__']),
    'internal',
    "Couldn't delete. Refresh the tenant list to see what changed, then try again.",
  );
  assert.equal(await exists(`facilities/${FACILITY}/tenants/clean`), true);
});
