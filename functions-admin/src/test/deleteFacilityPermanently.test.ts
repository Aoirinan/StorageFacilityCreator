import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import { deleteFacilityPermanentlyHandler, parseDeleteFacilityRequest } from '../deleteFacilityPermanently';
import { isVerifiedUnspentCode } from '../recentTwoFactor';

/** A db that fails the test if it is touched: refusals must come before any read. */
const untouchable = new Proxy({} as admin.firestore.Firestore, {
  get() {
    throw new Error('Firestore was read before the caller was checked');
  },
});

const noPurge = {
  cancelSubscriptions: async () => assert.fail('purged'),
  alignAccountSubscription: async () => assert.fail('purged'),
  deleteStoragePrefix: async () => assert.fail('purged'),
};

function call(context: Record<string, unknown>, data: unknown = { facilityId: 'f1' }) {
  return deleteFacilityPermanentlyHandler(data, context as unknown as functions.https.CallableContext, {
    db: untouchable,
    purge: noPurge,
    nowMs: () => 0,
  });
}

test('refused before any read: signed out, no App Check token, a bad facility id', async () => {
  await assert.rejects(call({ app: { appId: 'a' } }), { code: 'unauthenticated' });
  await assert.rejects(call({ auth: { uid: 'u1', token: {} } }), {
    code: 'failed-precondition',
    message: 'App Check token required. Please update your app.',
  });
  for (const data of [{}, { facilityId: ' ' }, { facilityId: 'a/b' }, null, 'f1']) {
    await assert.rejects(call({ auth: { uid: 'u1', token: {} }, app: { appId: 'a' } }, data), {
      code: 'invalid-argument',
    });
  }
});

test('request: the facility id is trimmed', () => {
  assert.deepEqual(parseDeleteFacilityRequest({ facilityId: ' f1 ' }), { facilityId: 'f1' });
});

test('an email code authorizes a delete only once verifyOTP accepted it, within its 10 minutes, unspent', () => {
  const now = 1_000_000;
  const at = (ms: number) => admin.firestore.Timestamp.fromMillis(ms);
  assert.equal(isVerifiedUnspentCode({ used: true, expiresAt: at(now + 1) }, now), true);
  assert.equal(isVerifiedUnspentCode({ used: true, expiresAt: new Date(now + 1) }, now), true);
  // Sent but never entered.
  assert.equal(isVerifiedUnspentCode({ used: false, expiresAt: at(now + 1) }, now), false);
  // verifyOTP marks an expired code used too, but only once it has expired.
  assert.equal(isVerifiedUnspentCode({ used: true, expiresAt: at(now) }, now), false);
  assert.equal(isVerifiedUnspentCode({ used: true }, now), false);
  // Already spent on a delete.
  assert.equal(isVerifiedUnspentCode({ used: true, expiresAt: at(now + 1), consumedAt: at(now) }, now), false);
});
