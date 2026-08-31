import test from 'node:test';
import assert from 'node:assert/strict';
import {
  calculateNextAutopayRun,
  isAutopayDue,
  isFacilityChargeReady,
  resolveChargeAmount,
  roundMoney,
  shouldAttemptCharge,
  sumLedgerBalance,
} from '../autopayScheduledHelpers';

// --- charge readiness -------------------------------------------------------
// Guards the bug where the cron charged via the platform Stripe client while the
// customer/payment method lived on the facility's connected account.

test('isFacilityChargeReady requires both a connected account and charges enabled', () => {
  assert.equal(
    isFacilityChargeReady({
      stripeConnectAccountId: 'acct_1',
      stripeStatus: { chargesEnabled: true },
    }),
    true,
  );

  assert.equal(
    isFacilityChargeReady({ stripeConnectAccountId: 'acct_1' }),
    false,
    'an account that cannot accept charges must not be charged',
  );

  assert.equal(
    isFacilityChargeReady({ stripeStatus: { chargesEnabled: true } }),
    false,
    'chargesEnabled without an account id is meaningless',
  );

  assert.equal(isFacilityChargeReady({}), false);
  assert.equal(isFacilityChargeReady(undefined), false);
});

// --- due check --------------------------------------------------------------

test('isAutopayDue treats a missing next-run as not due', () => {
  const now = new Date('2026-03-10T00:00:00Z');
  assert.equal(isAutopayDue(null, now), false);
  assert.equal(isAutopayDue(undefined, now), false);
});

test('isAutopayDue is true only once the next-run has arrived', () => {
  const now = new Date('2026-03-10T00:00:00Z');
  assert.equal(isAutopayDue(new Date('2026-03-11T00:00:00Z'), now), false);
  assert.equal(isAutopayDue(new Date('2026-03-10T00:00:00Z'), now), true);
  assert.equal(isAutopayDue(new Date('2026-03-09T00:00:00Z'), now), true);
});

// --- ledger balance ---------------------------------------------------------

test('sumLedgerBalance nets charges against payments', () => {
  assert.equal(sumLedgerBalance([{ amount: 120 }, { amount: -50 }]), 70);
});

test('sumLedgerBalance ignores missing and non-numeric amounts', () => {
  assert.equal(
    sumLedgerBalance([{ amount: 100 }, {}, { amount: 'oops' }, { amount: NaN }]),
    100,
    'a malformed ledger row must not turn the total into NaN and charge garbage',
  );
  assert.equal(sumLedgerBalance([]), 0);
});

// --- amount resolution ------------------------------------------------------

test('resolveChargeAmount uses the ledger balance when no fixed amount is set', () => {
  assert.equal(resolveChargeAmount(85, {}, {}), 85);
});

test('resolveChargeAmount lets a positive fixed amount override the balance', () => {
  assert.equal(resolveChargeAmount(85, { amount: 120 }, {}), 120);
});

test('resolveChargeAmount ignores a zero or negative fixed amount', () => {
  assert.equal(resolveChargeAmount(85, { amount: 0 }, {}), 85);
  assert.equal(resolveChargeAmount(85, { amount: -10 }, {}), 85);
});

test('resolveChargeAmount adds insurance only when opted in and configured', () => {
  const facility = { billingSettings: { defaultInsuranceAmount: 15 } };

  assert.equal(resolveChargeAmount(100, { includeInsurance: true }, facility), 115);
  assert.equal(resolveChargeAmount(100, { includeInsurance: false }, facility), 100);
  assert.equal(
    resolveChargeAmount(100, { includeInsurance: true }, { billingSettings: {} }),
    100,
    'opting in without a configured amount must not change the charge',
  );
  assert.equal(
    resolveChargeAmount(
      100,
      { includeInsurance: true },
      { billingSettings: { defaultInsuranceAmount: 'free' } },
    ),
    100,
    'a non-numeric insurance setting must not corrupt the amount',
  );
});

// --- charge attempt guard ---------------------------------------------------

test('shouldAttemptCharge requires a positive amount and a stored payment method', () => {
  assert.equal(shouldAttemptCharge(50, 'pm_1'), true);
  assert.equal(shouldAttemptCharge(0, 'pm_1'), false);
  assert.equal(shouldAttemptCharge(-5, 'pm_1'), false);
  assert.equal(shouldAttemptCharge(50, undefined), false);
  assert.equal(shouldAttemptCharge(50, ''), false);
});

// --- next run scheduling ----------------------------------------------------

test('calculateNextAutopayRun rolls monthly schedules to the next month', () => {
  const next = calculateNextAutopayRun(
    { frequency: 'monthly', dayOfMonth: 5 },
    new Date(2026, 2, 20), // 20 Mar 2026
  );
  assert.equal(next.getFullYear(), 2026);
  assert.equal(next.getMonth(), 3); // April
  assert.equal(next.getDate(), 5);
});

test('calculateNextAutopayRun rolls a December monthly schedule into the new year', () => {
  const next = calculateNextAutopayRun(
    { frequency: 'monthly', dayOfMonth: 1 },
    new Date(2026, 11, 15), // 15 Dec 2026
  );
  assert.equal(next.getFullYear(), 2027);
  assert.equal(next.getMonth(), 0); // January
});

test('calculateNextAutopayRun defaults to monthly on day 1', () => {
  const next = calculateNextAutopayRun(undefined, new Date(2026, 2, 20));
  assert.equal(next.getMonth(), 3);
  assert.equal(next.getDate(), 1);
});

test('calculateNextAutopayRun always schedules weekly runs in the future', () => {
  // Regression: the original used (dayOfWeek - now.getDay()) % 7, which is
  // NEGATIVE in JS whenever the target weekday is earlier in the week than
  // today. That produced a next-run in the PAST, so the following night's cron
  // saw it as due and charged the tenant again.
  const friday = new Date(2026, 2, 20); // 20 Mar 2026 is a Friday (getDay() === 5)
  assert.equal(friday.getDay(), 5);

  const next = calculateNextAutopayRun({ frequency: 'weekly', dayOfWeek: 1 }, friday);

  assert.ok(
    next.getTime() > friday.getTime(),
    `weekly next-run must be in the future, got ${next.toISOString()}`,
  );
  assert.equal(next.getDay(), 1, 'should land on the requested weekday (Monday)');
});

test('calculateNextAutopayRun pushes a same-weekday weekly run a full week out', () => {
  const friday = new Date(2026, 2, 20);
  const next = calculateNextAutopayRun({ frequency: 'weekly', dayOfWeek: 5 }, friday);

  assert.equal(next.getDate(), 27, 'same weekday means next week, not today');
  assert.equal(next.getDay(), 5);
});

// --- money precision --------------------------------------------------------

test('roundMoney turns float residue into a real money value', () => {
  assert.equal(roundMoney(0.1 + 0.2), 0.3);
  assert.equal(roundMoney(14.677419354838708), 14.68);
  assert.equal(roundMoney(5.551115123125783e-17), 0);
  assert.equal(roundMoney(Number.NaN), 0);
});

test('a settled balance with float residue is not charged', () => {
  // The live facility already holds ledger amounts with sub-cent precision, so
  // summing a paid-off account can leave 1e-15 behind. That used to pass
  // `amount > 0`, reach Stripe as a zero-cent charge, and fail every night —
  // eventually disarming autopay for someone who owed nothing.
  const residue = 0.1 + 0.2 - 0.3;
  assert.ok(residue > 0, 'precondition: residue really is greater than zero');
  assert.equal(shouldAttemptCharge(residue, 'pm_123'), false);
});

test('a balance below the Stripe minimum is left to accumulate', () => {
  // Stripe rejects anything under 50 cents, so attempting it is a guaranteed
  // failure. Better to carry it forward than to fail nightly.
  assert.equal(shouldAttemptCharge(0.25, 'pm_123'), false);
  assert.equal(shouldAttemptCharge(0.5, 'pm_123'), true);
});

test('normal balances still charge', () => {
  assert.equal(shouldAttemptCharge(65, 'pm_123'), true);
  assert.equal(shouldAttemptCharge(14.68, 'pm_123'), true);
});

test('a missing payment method still blocks the charge', () => {
  assert.equal(shouldAttemptCharge(65, ''), false);
  assert.equal(shouldAttemptCharge(65, undefined), false);
});
