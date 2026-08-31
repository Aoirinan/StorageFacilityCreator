import test from 'node:test';
import assert from 'node:assert/strict';
import {
  AUTOPAY_RETRY_BACKOFF_DAYS,
  MAX_CONSECUTIVE_AUTOPAY_FAILURES,
  isPermanentDecline,
  resolveAutopayFailureOutcome,
} from '../autopayFailureHelpers';

const NOW = new Date('2026-08-30T02:00:00.000Z');

// --- permanent vs retryable -------------------------------------------------

test('isPermanentDecline recognises cards that cannot succeed later', () => {
  // A reissued card produces incorrect_number and will never work again.
  assert.equal(isPermanentDecline('incorrect_number'), true);
  assert.equal(isPermanentDecline('expired_card'), true);
  assert.equal(isPermanentDecline('lost_card'), true);
  assert.equal(isPermanentDecline('INCORRECT_NUMBER'), true);
});

test('isPermanentDecline treats temporary problems as retryable', () => {
  assert.equal(isPermanentDecline('insufficient_funds'), false);
  assert.equal(isPermanentDecline('processing_error'), false);
  assert.equal(isPermanentDecline('card_declined'), false);
  assert.equal(isPermanentDecline(undefined), false);
});

// --- permanent declines stop immediately ------------------------------------

test('a permanent decline disarms on the first failure', () => {
  // Retrying a dead card nightly generates declines that harm account standing
  // and can never succeed.
  const out = resolveAutopayFailureOutcome({
    previousFailures: 0,
    declineCode: 'incorrect_number',
    now: NOW,
  });
  assert.equal(out.disarm, true);
  assert.equal(out.nextRun, null);
  assert.equal(out.needsNewCard, true);
  assert.equal(out.failures, 1);
});

// --- retryable declines back off then give up -------------------------------

test('a retryable decline backs off instead of retrying nightly', () => {
  const out = resolveAutopayFailureOutcome({
    previousFailures: 0,
    declineCode: 'insufficient_funds',
    now: NOW,
  });
  assert.equal(out.disarm, false);
  assert.equal(out.needsNewCard, false);
  assert.ok(out.nextRun, 'should schedule a retry');
  const days = Math.round((out.nextRun!.getTime() - NOW.getTime()) / 86400000);
  assert.equal(days, AUTOPAY_RETRY_BACKOFF_DAYS);
});

test('retryable declines give up after the tolerance is spent', () => {
  const out = resolveAutopayFailureOutcome({
    previousFailures: MAX_CONSECUTIVE_AUTOPAY_FAILURES - 1,
    declineCode: 'insufficient_funds',
    now: NOW,
  });
  assert.equal(out.failures, MAX_CONSECUTIVE_AUTOPAY_FAILURES);
  assert.equal(out.disarm, true);
  assert.equal(out.nextRun, null);
  assert.equal(out.needsNewCard, true);
});

test('the failure count is never allowed to go backwards or go NaN', () => {
  // Missing or malformed stored counts must not reset the tolerance forever.
  for (const prev of [undefined, null, -5, 'two', NaN]) {
    const out = resolveAutopayFailureOutcome({
      previousFailures: prev as unknown,
      declineCode: 'insufficient_funds',
      now: NOW,
    });
    assert.equal(out.failures, 1, JSON.stringify(prev));
  }
});

// --- messaging --------------------------------------------------------------

test('the Stripe message is passed through when there is one', () => {
  const out = resolveAutopayFailureOutcome({
    previousFailures: 0,
    declineCode: 'incorrect_number',
    message: 'Your card number is incorrect.',
    now: NOW,
  });
  assert.equal(out.reason, 'Your card number is incorrect.');
});

test('there is always a usable reason even with no message', () => {
  const out = resolveAutopayFailureOutcome({ previousFailures: 0, now: NOW });
  assert.ok(out.reason.length > 0);
});
