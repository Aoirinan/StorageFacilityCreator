import test from 'node:test';
import assert from 'node:assert/strict';
import {
  autoLateFeesEnabled,
  delinquencyStatusFor,
  hasDelinquencyFlags,
  isActiveLien,
  planDelinquencyClear,
  planDelinquencyFlags,
} from '../delinquencyAutomation';

const rules = { noticeDays: 7, finalNoticeDays: 14, lienDays: 30, lockoutDays: 45 };

test('automatic late fees are off when the facility never set the switch', () => {
  // A facility with lateFeeAmount 10 and gracePeriodDays 10 and no
  // enableAutoLateFees field: the job used to read that as on.
  assert.equal(autoLateFeesEnabled({ lateFeeAmount: 10, gracePeriodDays: 10 }), false);
  assert.equal(autoLateFeesEnabled({}), false);
  assert.equal(autoLateFeesEnabled(undefined), false);
  assert.equal(autoLateFeesEnabled(null), false);
});

test('automatic late fees are on only when switched on', () => {
  assert.equal(autoLateFeesEnabled({ enableAutoLateFees: true }), true);
  assert.equal(autoLateFeesEnabled({ enableAutoLateFees: false }), false);
  // Anything that is not literally true stays off.
  assert.equal(autoLateFeesEnabled({ enableAutoLateFees: 'true' }), false);
  assert.equal(autoLateFeesEnabled({ enableAutoLateFees: 1 }), false);
});

test('status thresholds', () => {
  assert.equal(delinquencyStatusFor(3, rules), null);
  assert.equal(delinquencyStatusFor(7, rules), 'late');
  assert.equal(delinquencyStatusFor(14, rules), 'final_notice');
  assert.equal(delinquencyStatusFor(30, rules), 'lien');
  assert.equal(delinquencyStatusFor(45, rules), 'lockout');
});

test('a tenant with no paidThrough is never stamped, however long since createdAt', () => {
  // Imported from a paper ledger six weeks ago, nothing recorded as paid yet:
  // createdAt + 30 days put them past lockout. That is a guess, not lateness.
  for (const daysLate of [7, 14, 30, 45, 200]) {
    assert.deepEqual(
      planDelinquencyFlags({ hasPaidThrough: false, daysLate, rules }),
      { action: 'skipNoPaidThrough' },
      `daysLate ${daysLate}`,
    );
  }
  // Below every threshold there is nothing to skip or log.
  assert.deepEqual(planDelinquencyFlags({ hasPaidThrough: false, daysLate: 2, rules }), { action: 'none' });
});

test('a tenant with a paidThrough is still stamped as before', () => {
  assert.deepEqual(planDelinquencyFlags({ hasPaidThrough: true, daysLate: 10, rules }), {
    action: 'stamp',
    status: 'late',
    lienEligible: false,
  });
  assert.deepEqual(planDelinquencyFlags({ hasPaidThrough: true, daysLate: 31, rules }), {
    action: 'stamp',
    status: 'lien',
    lienEligible: true,
  });
  assert.deepEqual(planDelinquencyFlags({ hasPaidThrough: true, daysLate: 60, rules }), {
    action: 'stamp',
    status: 'lockout',
    lienEligible: true,
  });
  assert.deepEqual(planDelinquencyFlags({ hasPaidThrough: true, daysLate: 2, rules }), { action: 'none' });
});

test('flags are cleared once the tenant is caught up and owes nothing', () => {
  assert.deepEqual(
    planDelinquencyClear({ hasFlags: true, lateByPaidThrough: false, balance: 0, hasActiveLien: false }),
    { action: 'clear' },
  );
  assert.deepEqual(
    planDelinquencyClear({ hasFlags: true, lateByPaidThrough: false, balance: -20, hasActiveLien: false }),
    { action: 'clear' },
    'a credit balance owes nothing',
  );
});

test('flags stay while the tenant is late, owes, or has an active lien', () => {
  assert.deepEqual(
    planDelinquencyClear({ hasFlags: true, lateByPaidThrough: true, balance: 0, hasActiveLien: false }),
    { action: 'keep', reason: 'stillLate' },
  );
  assert.deepEqual(
    planDelinquencyClear({ hasFlags: true, lateByPaidThrough: false, balance: 0.01, hasActiveLien: false }),
    { action: 'keep', reason: 'owes' },
  );
  assert.deepEqual(
    planDelinquencyClear({ hasFlags: true, lateByPaidThrough: false, balance: 0, hasActiveLien: true }),
    { action: 'keep', reason: 'activeLien' },
  );
  assert.deepEqual(
    planDelinquencyClear({ hasFlags: false, lateByPaidThrough: false, balance: 0, hasActiveLien: false }),
    { action: 'keep', reason: 'noFlags' },
  );
});

test('which lien docs count as active', () => {
  assert.equal(isActiveLien({ status: 'active', isActive: true }), true);
  assert.equal(isActiveLien({ status: 'active' }), true);
  assert.equal(isActiveLien({ isActive: true }), true, 'no status: assume in force');
  assert.equal(isActiveLien({ status: 'resolved', isActive: true }), false);
  assert.equal(isActiveLien({ status: 'cancelled' }), false);
  assert.equal(isActiveLien({ status: 'active', isActive: false }), false, 'soft-deleted');
  assert.equal(isActiveLien(undefined), false);
});

test('which tenants carry a flag', () => {
  assert.equal(hasDelinquencyFlags({}), false);
  assert.equal(hasDelinquencyFlags({ delinquencyStatus: '' }), false);
  assert.equal(hasDelinquencyFlags({ delinquencyStatus: 'lockout' }), true);
  assert.equal(hasDelinquencyFlags({ lienEligibleDate: new Date('2026-09-01') }), true);
  assert.equal(hasDelinquencyFlags({ lienEligibleDate: null }), false);
});
