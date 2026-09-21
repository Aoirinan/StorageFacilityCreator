import test from 'node:test';
import assert from 'node:assert/strict';
import {
  computeAccountRollup,
  isLocalTrialExpired,
  type FacilitySubscriptionSnapshot,
} from '../subscription/accountRollup';

const NOW = Date.UTC(2026, 8, 21); // 2026-09-21
const DAY = 24 * 60 * 60 * 1000;

function fac(status: string | null, id = 'f1'): FacilitySubscriptionSnapshot {
  return { facilityId: id, platformSubscriptionStatus: status };
}

// --- facility state wins -----------------------------------------------------

test('an active facility makes the account active', () => {
  const r = computeAccountRollup({
    currentStatus: 'trialing',
    localTrialEndMs: null,
    facilities: [fac('cancelled', 'a'), fac('active', 'b')],
    nowMs: NOW,
  });
  assert.equal(r.status, 'active');
  assert.equal(r.changed, true);
});

test('a past-due facility surfaces on the account instead of a stale trialing', () => {
  // This is the exact drift found in production: the account said `trialing`
  // while its only facility had been past due for days.
  const r = computeAccountRollup({
    currentStatus: 'trialing',
    localTrialEndMs: NOW - 30 * DAY,
    facilities: [fac('pastDue')],
    nowMs: NOW,
  });
  assert.equal(r.status, 'pastDue');
  assert.equal(r.changed, true);
});

test('active outranks past due across facilities', () => {
  const r = computeAccountRollup({
    currentStatus: 'pastDue',
    localTrialEndMs: null,
    facilities: [fac('pastDue', 'a'), fac('active', 'b')],
    nowMs: NOW,
  });
  assert.equal(r.status, 'active');
});

// --- local trials ------------------------------------------------------------

test('a running local trial keeps the account trialing', () => {
  const r = computeAccountRollup({
    currentStatus: 'trialing',
    localTrialEndMs: NOW + 5 * DAY,
    facilities: [],
    nowMs: NOW,
  });
  assert.equal(r.status, 'trialing');
  assert.equal(r.changed, false);
});

test('an ended local trial stops claiming trialing', () => {
  // Without this, an account whose trial ended months ago still reports as a
  // live trial, which is what hid the lockout from the operator and from us.
  const r = computeAccountRollup({
    currentStatus: 'trialing',
    localTrialEndMs: NOW - DAY,
    facilities: [],
    nowMs: NOW,
  });
  assert.equal(r.status, 'cancelled');
  assert.equal(r.changed, true);
});

test('a trial that ends exactly now counts as ended', () => {
  const r = computeAccountRollup({
    currentStatus: 'trialing',
    localTrialEndMs: NOW,
    facilities: [],
    nowMs: NOW,
  });
  assert.equal(r.status, 'cancelled');
});

test('an entitled facility overrides an expired local trial', () => {
  const r = computeAccountRollup({
    currentStatus: 'trialing',
    localTrialEndMs: NOW - 90 * DAY,
    facilities: [fac('active')],
    nowMs: NOW,
  });
  assert.equal(r.status, 'active');
});

// --- guards ------------------------------------------------------------------

test('pendingApproval is never changed automatically', () => {
  const r = computeAccountRollup({
    currentStatus: 'pendingApproval',
    localTrialEndMs: NOW - 10 * DAY,
    facilities: [fac('active')],
    nowMs: NOW,
  });
  assert.equal(r.status, 'pendingApproval');
  assert.equal(r.changed, false);
});

test('an account with no facilities and no trial is left alone', () => {
  const r = computeAccountRollup({
    currentStatus: 'active',
    localTrialEndMs: null,
    facilities: [],
    nowMs: NOW,
  });
  assert.equal(r.changed, false);
  assert.equal(r.status, 'active');
});

test('facilities that are all cancelled cancel the account', () => {
  const r = computeAccountRollup({
    currentStatus: 'active',
    localTrialEndMs: null,
    facilities: [fac('cancelled', 'a'), fac('cancelled', 'b')],
    nowMs: NOW,
  });
  assert.equal(r.status, 'cancelled');
  assert.equal(r.changed, true);
});

// --- helper ------------------------------------------------------------------

test('isLocalTrialExpired only fires on a real past timestamp', () => {
  assert.equal(isLocalTrialExpired(NOW - 1, NOW), true);
  assert.equal(isLocalTrialExpired(NOW + 1, NOW), false);
  assert.equal(isLocalTrialExpired(null, NOW), false);
  assert.equal(isLocalTrialExpired(undefined, NOW), false);
  assert.equal(isLocalTrialExpired(Number.NaN, NOW), false);
});
