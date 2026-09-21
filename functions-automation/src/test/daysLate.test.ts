import test from 'node:test';
import assert from 'node:assert/strict';
import { calculateDaysLate } from '../delinquencyAutomation';

const DAY = 24 * 60 * 60 * 1000;
const NOW = new Date('2026-09-21T12:00:00Z');
const daysAgo = (n: number) => new Date(NOW.getTime() - n * DAY);

test('the grace period actually grants days', () => {
  // Measured from the start of the month, a tenant counted as 4 days late on
  // the 2nd with a 3-day grace, so the grace granted nothing.
  const justDue = calculateDaysLate({
    now: NOW,
    paidThrough: daysAgo(2),
    createdAt: null,
    gracePeriodDays: 3,
  });
  assert.equal(justDue, 0, 'inside the grace period nothing is owed yet');

  const dayAfterGrace = calculateDaysLate({
    now: NOW,
    paidThrough: daysAgo(4),
    createdAt: null,
    gracePeriodDays: 3,
  });
  assert.equal(dayAfterGrace, 1);
});

test('lateness accumulates across months instead of resetting', () => {
  // The old month-relative measure capped near 34, so lockoutDays of 45 could
  // never be reached and lienDays of 30 only fired late in a month.
  const threeMonths = calculateDaysLate({
    now: NOW,
    paidThrough: daysAgo(90),
    createdAt: null,
    gracePeriodDays: 3,
  });
  assert.equal(threeMonths, 87);
  assert.ok(threeMonths > 45, 'auto-lockout at 45 days must be reachable');
});

test('a tenant who has never paid gets the onboarding window first', () => {
  const brandNew = calculateDaysLate({
    now: NOW,
    paidThrough: null,
    createdAt: daysAgo(10),
    gracePeriodDays: 3,
  });
  assert.equal(brandNew, 0);

  const wellPast = calculateDaysLate({
    now: NOW,
    paidThrough: null,
    createdAt: daysAgo(50),
    gracePeriodDays: 3,
  });
  assert.equal(wellPast, 17); // 50 - 30 onboarding - 3 grace
});

test('a tenant paid into the future is not late', () => {
  const prepaid = calculateDaysLate({
    now: NOW,
    paidThrough: new Date(NOW.getTime() + 30 * DAY),
    createdAt: null,
    gracePeriodDays: 3,
  });
  assert.equal(prepaid, 0);
});

test('with nothing to anchor to, no debt is invented', () => {
  assert.equal(
    calculateDaysLate({ now: NOW, paidThrough: null, createdAt: null, gracePeriodDays: 3 }),
    0,
  );
});

test('a zero grace period starts the clock the next day', () => {
  assert.equal(
    calculateDaysLate({ now: NOW, paidThrough: daysAgo(1), createdAt: null, gracePeriodDays: 0 }),
    1,
  );
});
