import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import type { CancelOutcome, CancellableSubscription } from '@sfc/functions-shared/stripe/subscriptionCleanup';

import {
  FACILITY_BILLING_NOT_STOPPED_MESSAGE,
  FACILITY_DELETE_FAILED_MESSAGE,
  deleteFacilityPermanently,
  deleteFacilityPermanentlyHandler,
} from '../../deleteFacilityPermanently';
import { FacilityPurgeDeps } from '../../facilityPurge';
import { TWO_FACTOR_REQUIRED_MESSAGE } from '../../recentTwoFactor';
import { clearEmulator, emulatorDb, skipWithoutEmulator } from './firestoreEmulator';

/**
 * The owner's Delete facility against real Firestore (the emulator): who may
 * call it, the email-code check, and that the whole facility goes, tenants
 * included. The app used to delete it subcollection by subcollection and
 * skip any it couldn't, so the facility doc went and tenant docs stayed.
 */

const OWNER = 'owner-1';
const FACILITY = 'fac-1';
const NOW = Date.parse('2026-09-23T12:00:00Z');

type Calls = {
  cancelled: CancellableSubscription[];
  aligned: Array<[string, number]>;
  storage: string[];
};

function fakePurge(calls: Calls, overrides: Partial<FacilityPurgeDeps> = {}): FacilityPurgeDeps {
  return {
    cancelSubscriptions: async (subs) => {
      calls.cancelled.push(...subs);
      return subs.map((s): CancelOutcome => ({ id: s.id, label: s.label, status: 'canceled' }));
    },
    alignAccountSubscription: async (id, count) => {
      calls.aligned.push([id, count]);
    },
    deleteStoragePrefix: async (prefix) => {
      calls.storage.push(prefix);
    },
    ...overrides,
  };
}

function newCalls(): Calls {
  return { cancelled: [], aligned: [], storage: [] };
}

function context(uid: string | null, opts: { appCheck?: boolean; superadmin?: boolean } = {}) {
  return {
    ...(uid ? { auth: { uid, token: { superadmin: opts.superadmin === true } } } : {}),
    ...(opts.appCheck === false ? {} : { app: { appId: 'test-app', token: {} } }),
    rawRequest: {},
  } as unknown as functions.https.CallableContext;
}

async function run(
  uid: string | null,
  purge: FacilityPurgeDeps,
  opts: { appCheck?: boolean; superadmin?: boolean; facilityId?: string } = {},
) {
  return deleteFacilityPermanentlyHandler({ facilityId: opts.facilityId ?? FACILITY }, context(uid, opts), {
    db: emulatorDb(),
    purge,
    nowMs: () => NOW,
  });
}

async function seedFacility(): Promise<void> {
  const db = emulatorDb();
  const fac = db.collection('facilities').doc(FACILITY);
  await fac.set({
    name: 'Acme Storage',
    ownerUid: OWNER,
    managers: { 'manager-1': true },
    facilityCreatorAccountId: 'acct-1',
    stripePlatformSubscriptionId: 'sub_platform',
    stripeWebsiteSubscriptionId: 'sub_website',
  });
  await fac.collection('tenants').doc('t1').set({ name: 'Ada Park', governmentIdNumber: 'D123', portalAccessCode: '4242' });
  await fac.collection('tenants').doc('t1').collection('billing').doc('default').set({ autopayEnabled: false });
  await fac.collection('tenants').doc('t1').collection('paymentMethods').doc('pm1').set({ isActive: true });
  await fac.collection('units').doc('u1').set({ unitNumber: '101', tenantId: 't1', status: 'occupied' });
  await fac.collection('ledgers').doc('l1').set({ tenantId: 't1', amount: 100 });
  // No rule matches oldTenants: the app's delete failed here and carried on.
  await fac.collection('oldTenants').doc('o1').set({ name: 'Old' });
  await fac.collection('mapEngine').doc('meta').set({ publicSlug: 'Acme' });
  await db.collection('publicFacilityMaps').doc('acme').set({ facilityId: FACILITY });
  await db.collection('facilityCreatorAccounts').doc('acct-1').set({
    ownerUid: OWNER,
    facilityIds: [FACILITY, 'fac-2'],
    referralRewardPreferredFacilityId: FACILITY,
    stripeSubscriptionId: 'sub_account',
  });
}

async function docsUnder(path: string): Promise<string[]> {
  const db = emulatorDb();
  const ref = db.doc(path);
  const out: string[] = [];
  const walk = async (doc: admin.firestore.DocumentReference) => {
    for (const col of await doc.listCollections()) {
      for (const d of await col.listDocuments()) {
        if ((await d.get()).exists) out.push(d.path);
        await walk(d);
      }
    }
  };
  if ((await ref.get()).exists) out.push(ref.path);
  await walk(ref);
  return out;
}

async function assertNothingDeleted(): Promise<void> {
  const left = await docsUnder(`facilities/${FACILITY}`);
  assert.ok(left.includes(`facilities/${FACILITY}`), 'facility doc kept');
  assert.ok(left.includes(`facilities/${FACILITY}/tenants/t1`), 'tenant doc kept');
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

test('the owner deletes the whole facility: tenants, nested records and all', { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  const calls = newCalls();
  assert.deepEqual(await run(OWNER, fakePurge(calls)), { success: true });

  assert.deepEqual(await docsUnder(`facilities/${FACILITY}`), []);
  const db = emulatorDb();
  assert.equal((await db.collection('publicFacilityMaps').doc('acme').get()).exists, false);
  const account = (await db.collection('facilityCreatorAccounts').doc('acct-1').get()).data()!;
  assert.deepEqual(account.facilityIds, ['fac-2']);
  assert.equal(account.referralRewardPreferredFacilityId, undefined);

  // Billing stopped, the legacy plan realigned for the one facility left.
  assert.deepEqual(
    calls.cancelled.map((s) => s.id),
    ['sub_platform', 'sub_website'],
  );
  assert.deepEqual(calls.aligned, [['sub_account', 1]]);
  assert.deepEqual(calls.storage, [`facilities/${FACILITY}/`]);
});

test("a public map entry that now points at another facility is left alone", { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  const db = emulatorDb();
  await db.collection('publicFacilityMaps').doc('acme').set({ facilityId: 'fac-other' });
  await run(OWNER, fakePurge(newCalls()));
  assert.equal((await db.collection('publicFacilityMaps').doc('acme').get()).exists, true);
});

test("a facility not linked to an account comes off the owner's account", { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  await emulatorDb()
    .collection('facilities')
    .doc(FACILITY)
    .update({ facilityCreatorAccountId: admin.firestore.FieldValue.delete() });
  await run(OWNER, fakePurge(newCalls()));
  const account = (await emulatorDb().collection('facilityCreatorAccounts').doc('acct-1').get()).data()!;
  assert.deepEqual(account.facilityIds, ['fac-2']);
});

test('only the owner: a manager, staff or stranger is refused and nothing goes', { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  for (const uid of ['manager-1', 'stranger']) {
    const calls = newCalls();
    await rejectsWith(run(uid, fakePurge(calls)), 'permission-denied', 'Only the facility owner can delete it.');
    assert.deepEqual(calls.cancelled, []);
  }
  await assertNothingDeleted();
});

test('a super admin (the claim) can delete any facility', { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  await run('admin-1', fakePurge(newCalls()), { superadmin: true });
  assert.deepEqual(await docsUnder(`facilities/${FACILITY}`), []);
});

test('signed out, no App Check token, or no such facility: refused', { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  await rejectsWith(run(null, fakePurge(newCalls())), 'unauthenticated');
  await rejectsWith(run(OWNER, fakePurge(newCalls()), { appCheck: false }), 'failed-precondition', /App Check/);
  await rejectsWith(run(OWNER, fakePurge(newCalls()), { facilityId: 'nope' }), 'not-found');
  await rejectsWith(run(OWNER, fakePurge(newCalls()), { facilityId: '' }), 'invalid-argument');
  await assertNothingDeleted();
});

test('2FA on: refused without a verified code, even one that was sent', { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  const db = emulatorDb();
  const user = db.collection('users').doc(OWNER);
  await user.set({ twoFactorEnabled: true });
  const expires = admin.firestore.Timestamp.fromMillis(NOW + 5 * 60_000);
  // Sent but not entered, verified for something else, and verified but expired.
  await user.collection('otpCodes').doc('sent').set({ purpose: 'delete_facility', used: false, expiresAt: expires });
  await user.collection('otpCodes').doc('other').set({ purpose: 'sensitive_action', used: true, expiresAt: expires });
  await user.collection('otpCodes').doc('stale').set({
    purpose: 'delete_facility',
    used: true,
    expiresAt: admin.firestore.Timestamp.fromMillis(NOW - 1),
  });

  const calls = newCalls();
  await rejectsWith(run(OWNER, fakePurge(calls)), 'failed-precondition', TWO_FACTOR_REQUIRED_MESSAGE);
  await assert.rejects(run(OWNER, fakePurge(calls)), (e: functions.https.HttpsError) => {
    assert.deepEqual(e.details, { reason: 'two-factor-required' });
    return true;
  });
  assert.deepEqual(calls.cancelled, []);
  await assertNothingDeleted();
});

test('2FA on: a verified code allows one delete and is spent by it', { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  const db = emulatorDb();
  const user = db.collection('users').doc(OWNER);
  await user.set({ twoFactorEnabled: true });
  const code = user.collection('otpCodes').doc('ok');
  await code.set({
    purpose: 'delete_facility',
    used: true,
    expiresAt: admin.firestore.Timestamp.fromMillis(NOW + 60_000),
  });

  await run(OWNER, fakePurge(newCalls()));
  assert.deepEqual(await docsUnder(`facilities/${FACILITY}`), []);
  const spent = (await code.get()).data()!;
  assert.ok(spent.consumedAt, 'code marked consumed');
  assert.equal(spent.consumedBy, 'deleteFacilityPermanently');

  // The same code does not delete a second facility.
  await seedFacility();
  await rejectsWith(run(OWNER, fakePurge(newCalls())), 'failed-precondition', TWO_FACTOR_REQUIRED_MESSAGE);
  await assertNothingDeleted();
});

test('billing that will not stop: nothing is deleted', { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  const calls = newCalls();
  const purge = fakePurge(calls, {
    cancelSubscriptions: async (subs) =>
      subs.map((s): CancelOutcome => ({ id: s.id, label: s.label, status: 'failed', error: 'card_error' })),
  });
  await rejectsWith(run(OWNER, purge), 'failed-precondition', FACILITY_BILLING_NOT_STOPPED_MESSAGE);
  await assertNothingDeleted();
  assert.equal((await emulatorDb().collection('publicFacilityMaps').doc('acme').get()).exists, true);
});

test('an unexpected failure is reported as internal with a message an owner can act on', { skip: skipWithoutEmulator }, async () => {
  await seedFacility();
  const purge = fakePurge(newCalls(), {
    alignAccountSubscription: async () => {
      throw new Error('stripe is down');
    },
  });
  await rejectsWith(run(OWNER, purge), 'internal', FACILITY_DELETE_FAILED_MESSAGE);
});

test('the deployed callable, production deps and all, deletes an unbilled facility', { skip: skipWithoutEmulator }, async () => {
  // No subscriptions, no account plan: nothing reaches Stripe, and Storage
  // is best effort. This is the function the app calls.
  await seedFacility();
  await emulatorDb().collection('facilities').doc(FACILITY).update({
    stripePlatformSubscriptionId: admin.firestore.FieldValue.delete(),
    stripeWebsiteSubscriptionId: admin.firestore.FieldValue.delete(),
  });
  await emulatorDb()
    .collection('facilityCreatorAccounts')
    .doc('acct-1')
    .update({ stripeSubscriptionId: admin.firestore.FieldValue.delete() });

  const callable = deleteFacilityPermanently as unknown as {
    run: (data: unknown, context: functions.https.CallableContext) => Promise<unknown>;
  };
  await rejectsWith(callable.run({ facilityId: FACILITY }, context('manager-1')), 'permission-denied');
  assert.deepEqual(await callable.run({ facilityId: FACILITY }, context(OWNER)), { success: true });
  assert.deepEqual(await docsUnder(`facilities/${FACILITY}`), []);
});
