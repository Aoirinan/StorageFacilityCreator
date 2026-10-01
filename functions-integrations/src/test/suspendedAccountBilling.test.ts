import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';

import {
  SUSPENDED_ACCOUNT_BILLING_MESSAGE,
  SUSPENDED_ACCOUNT_REASON,
  refuseBillingForSuspendedAccount,
} from '../stripePlatformSuspendedAccount';

test('a suspended account is refused, with a reason the app shows as written', () => {
  assert.throws(
    () => refuseBillingForSuspendedAccount({ suspended: true, subscriptionStatus: 'cancelled' }),
    (error: unknown) => {
      assert.ok(error instanceof functions.https.HttpsError);
      assert.equal(error.code, 'failed-precondition');
      assert.equal(error.message, SUSPENDED_ACCOUNT_BILLING_MESSAGE);
      assert.deepEqual(error.details, { reason: SUSPENDED_ACCOUNT_REASON });
      return true;
    },
  );
  // The app matches on this value (ErrorMessageHelper).
  assert.equal(SUSPENDED_ACCOUNT_REASON, 'account_suspended');
});

test('any other account goes on to checkout', () => {
  // Suspended means the literal true only, as the app and every other
  // server check read it: a stray truthy value refused here would lock out
  // of paying an owner the app treats as active.
  for (const account of [
    {},
    { suspended: false },
    { suspended: null },
    { suspended: 'false' },
    { suspended: 'true' },
    { suspended: 1 },
    { subscriptionStatus: 'cancelled' },
  ]) {
    assert.doesNotThrow(() => refuseBillingForSuspendedAccount(account), JSON.stringify(account));
  }
});
