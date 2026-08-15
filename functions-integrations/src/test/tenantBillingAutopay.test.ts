import test from 'node:test';
import assert from 'node:assert/strict';
import { firstAutopayRun } from '../stripe/tenant_billing';

test('firstAutopayRun never schedules a charge in the current month', () => {
  // Switching AutoPay on must not charge the tenant tonight for a period they
  // may already have paid.
  const now = new Date(2026, 2, 20); // 20 Mar 2026
  const next = firstAutopayRun(now, 1);

  assert.ok(next.getTime() > now.getTime(), 'first run must be in the future');
  assert.equal(next.getMonth(), 3, 'should land in April');
  assert.equal(next.getDate(), 1);
});

test('firstAutopayRun honours the tenant billing day', () => {
  const next = firstAutopayRun(new Date(2026, 2, 20), 15);
  assert.equal(next.getMonth(), 3);
  assert.equal(next.getDate(), 15);
});

test('firstAutopayRun rolls December into the next year', () => {
  const next = firstAutopayRun(new Date(2026, 11, 10), 5);
  assert.equal(next.getFullYear(), 2027);
  assert.equal(next.getMonth(), 0);
  assert.equal(next.getDate(), 5);
});

test('firstAutopayRun clamps days that do not exist in every month', () => {
  // 29/30/31 would skip or shift in February, so anything past 28 falls back to
  // the 1st rather than silently moving the tenant's billing day around.
  for (const day of [29, 30, 31, 0, -3, NaN]) {
    const next = firstAutopayRun(new Date(2026, 0, 10), day as number);
    assert.equal(next.getDate(), 1, `day ${day} should fall back to the 1st`);
  }
});

test('firstAutopayRun accepts the inclusive 1-28 range', () => {
  assert.equal(firstAutopayRun(new Date(2026, 0, 10), 1).getDate(), 1);
  assert.equal(firstAutopayRun(new Date(2026, 0, 10), 28).getDate(), 28);
});
