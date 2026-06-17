import test from 'node:test';
import assert from 'node:assert/strict';
import * as functions from 'firebase-functions/v1';
import {
  validateStripeKeyMode,
  rejectClientSuppliedStripeKeys,
  mapStripeErrorToUserMessage,
} from '@sfc/functions-shared';

test('validateStripeKeyMode accepts matching test and live pairs', () => {
  assert.doesNotThrow(() =>
    validateStripeKeyMode('sk_test_abc', 'pk_test_xyz'),
  );
  assert.doesNotThrow(() =>
    validateStripeKeyMode('sk_live_abc', 'pk_live_xyz'),
  );
});

test('validateStripeKeyMode rejects mixed test/live keys', () => {
  assert.throws(
    () => validateStripeKeyMode('sk_live_abc', 'pk_test_xyz'),
    /Stripe key mode mismatch/,
  );
});

test('rejectClientSuppliedStripeKeys rejects forbidden key fields', () => {
  assert.throws(
    () => rejectClientSuppliedStripeKeys({ stripeSecretKey: 'sk_test_bad' }),
    (err: unknown) =>
      err instanceof functions.https.HttpsError &&
      err.code === 'invalid-argument',
  );
  assert.throws(
    () => rejectClientSuppliedStripeKeys({ apiKey: 'secret' }),
    (err: unknown) =>
      err instanceof functions.https.HttpsError &&
      err.code === 'invalid-argument',
  );
});

test('rejectClientSuppliedStripeKeys allows empty or missing fields', () => {
  assert.doesNotThrow(() => rejectClientSuppliedStripeKeys({}));
  assert.doesNotThrow(() => rejectClientSuppliedStripeKeys({ stripeSecretKey: '' }));
  assert.doesNotThrow(() => rejectClientSuppliedStripeKeys({ facilityId: 'fac1' }));
});

test('mapStripeErrorToUserMessage maps known codes and defaults unknown', () => {
  assert.match(
    mapStripeErrorToUserMessage({ code: 'card_declined' }),
    /declined/i,
  );
  assert.match(
    mapStripeErrorToUserMessage({ code: 'insufficient_funds' }),
    /Insufficient funds/i,
  );
  assert.equal(
    mapStripeErrorToUserMessage({ code: 'unknown_code_xyz' }),
    'Failed to process payment. Please try again or contact support.',
  );
});
