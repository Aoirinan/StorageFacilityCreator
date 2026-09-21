import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveLateFee } from '../delinquencyAutomation';

const legacy = {
  gracePeriodDays: 3,
  baseLateFee: 25,
  dailyLateFee: 5,
  lateFeeType: null,
  lateFeeAmount: null,
  maxLateFee: null,
};

test('a configured flat fee is used instead of the hardcoded default', () => {
  // The settings screen has always written lateFeeType/lateFeeAmount and
  // nothing read them, so every facility got $25 + $5/day whatever they set.
  const fee = resolveLateFee({
    rules: { ...legacy, lateFeeType: 'flat', lateFeeAmount: 15 },
    daysLate: 40,
    balance: 150,
  });
  assert.equal(fee, 15);
});

test('a configured percentage fee is taken from the balance', () => {
  const fee = resolveLateFee({
    rules: { ...legacy, lateFeeType: 'percentage', lateFeeAmount: 10 },
    daysLate: 10,
    balance: 150,
  });
  assert.equal(fee, 15);
});

test('the legacy accrual still applies when nothing is configured', () => {
  // 25 + (10 - 3) * 5 = 60, under the balance so uncapped.
  const fee = resolveLateFee({ rules: legacy, daysLate: 10, balance: 150 });
  assert.equal(fee, 60);
});

test('the legacy accrual can no longer exceed the debt', () => {
  // Sixty days overdue used to produce $310 on a $150 unit.
  const fee = resolveLateFee({ rules: legacy, daysLate: 60, balance: 150 });
  assert.equal(fee, 150);
  assert.ok(fee <= 150, 'a late fee must not exceed the balance it is charged on');
});

test('an explicit maxLateFee wins over the balance', () => {
  const fee = resolveLateFee({
    rules: { ...legacy, maxLateFee: 20 },
    daysLate: 60,
    balance: 150,
  });
  assert.equal(fee, 20);
});

test('a percentage fee is capped too', () => {
  const fee = resolveLateFee({
    rules: { ...legacy, lateFeeType: 'percentage', lateFeeAmount: 200, maxLateFee: 50 },
    daysLate: 5,
    balance: 150,
  });
  assert.equal(fee, 50);
});

test('fees are rounded to cents and never negative', () => {
  const fee = resolveLateFee({
    rules: { ...legacy, lateFeeType: 'percentage', lateFeeAmount: 3.333 },
    daysLate: 5,
    balance: 100,
  });
  assert.equal(fee, 3.33);

  const floored = resolveLateFee({
    rules: { ...legacy, baseLateFee: -10, dailyLateFee: 0 },
    daysLate: 4,
    balance: 100,
  });
  assert.equal(floored, 0);
});
