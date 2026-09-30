// node --test scripts/audit-transfer-credit-signs.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';

import { amountOf, classifyRefund, dayOf, overstatement } from './audit-transfer-credit-signs.mjs';

test('a posted positive transfer credit is the wrong sign; negative is right', () => {
  assert.equal(classifyRefund({ status: 'posted', amount: 50 }), 'wrong-sign');
  assert.equal(classifyRefund({ status: 'posted', amount: -50 }), 'ok');
  assert.equal(classifyRefund({ status: 'posted', amount: 0 }), 'zero');
});

test('voided and pending rows are not in the balance, whatever their sign', () => {
  assert.equal(classifyRefund({ status: 'voided', amount: 50 }), 'voided');
  assert.equal(classifyRefund({ status: 'pending', amount: 50 }), 'pending');
});

test('a row without a numeric amount is reported, not guessed at', () => {
  assert.equal(classifyRefund({ status: 'posted', amount: 'fifty' }), 'unreadable');
  assert.equal(classifyRefund({ status: 'posted' }), 'unreadable');
  assert.equal(classifyRefund(undefined), 'unreadable');
});

test('a wrong-sign credit overstates the balance by twice its amount', () => {
  // The balance holds +X where it should hold -X.
  assert.equal(overstatement(50), 100);
  assert.equal(overstatement(31.17), 62.34);
  assert.equal(overstatement(-50), 0);
  assert.equal(overstatement('x'), 0);
});

test('amounts and days read Firestore values defensively', () => {
  assert.equal(amountOf(12.5), 12.5);
  assert.equal(amountOf('12.5'), 12.5);
  assert.equal(amountOf(undefined), null);
  assert.equal(amountOf(Number.NaN), null);
  assert.equal(dayOf({ toDate: () => new Date('2026-09-16T15:00:00Z') }), '2026-09-16');
  assert.equal(dayOf('2026-09-16T00:00:00Z'), '2026-09-16');
  assert.equal(dayOf(null), null);
  assert.equal(dayOf('not a date'), null);
});
