import test from 'node:test';
import assert from 'node:assert/strict';
import { calculateWebsiteAdminTrialEnd } from '../stripePlatformWebsiteSubscriptionAdmin';

const DAY_MS = 24 * 60 * 60 * 1000;

test('grant website trial starts from now', () => {
  assert.equal(
    calculateWebsiteAdminTrialEnd('grantTrial', 30, 1_000),
    1_000 + 30 * DAY_MS,
  );
});

test('extend website trial adds time to an unexpired grant', () => {
  const currentEnd = 10_000 + 14 * DAY_MS;
  assert.equal(
    calculateWebsiteAdminTrialEnd('extendTrial', 7, 10_000, currentEnd),
    currentEnd + 7 * DAY_MS,
  );
});

test('extend website trial restarts from now when the grant expired', () => {
  assert.equal(
    calculateWebsiteAdminTrialEnd('extendTrial', 14, 10_000, 9_000),
    10_000 + 14 * DAY_MS,
  );
});

test('website trial duration is bounded', () => {
  assert.throws(
    () => calculateWebsiteAdminTrialEnd('grantTrial', 0, 1_000),
    /1 to 365/,
  );
  assert.throws(
    () => calculateWebsiteAdminTrialEnd('grantTrial', 366, 1_000),
    /1 to 365/,
  );
});
