/**
 * What to do when an autopay charge is declined.
 *
 * Previously a failure recorded `autopayLastResult: 'failed'` and nothing else:
 * nobody was notified, and `autopayNextRun` was left in the past, so the same
 * card was retried every night indefinitely. A card that has been reissued
 * (the common case — the tenant's bank sends a new number) can never succeed,
 * so that is roughly thirty declines a month per tenant, forever.
 *
 * That matters beyond noise. Card networks and Stripe both track decline rates,
 * and a platform generating avoidable declines across many facilities risks its
 * own account standing. Retrying a permanently dead card is not persistence, it
 * is self-harm.
 */

/**
 * Decline codes that cannot succeed on a later attempt, because the stored card
 * details are wrong or the card is gone. Retrying these achieves nothing.
 */
const PERMANENT_DECLINE_CODES = new Set([
  'incorrect_number',
  'invalid_number',
  'expired_card',
  'invalid_expiry_month',
  'invalid_expiry_year',
  'incorrect_cvc',
  'invalid_cvc',
  'lost_card',
  'stolen_card',
  'pickup_card',
  'revocation_of_authorization',
  'revocation_of_all_authorizations',
  'no_such_card',
  'account_closed',
  'invalid_account',
]);

/** Failures tolerated before autopay is switched off and the tenant asked to act. */
export const MAX_CONSECUTIVE_AUTOPAY_FAILURES = 3;

/** Days to wait after a retryable failure, so a soft decline is not hammered nightly. */
export const AUTOPAY_RETRY_BACKOFF_DAYS = 3;

export interface AutopayFailureOutcome {
  /** Consecutive failure count after this attempt. */
  failures: number;
  /** Whether autopay should be switched off and the tenant asked to fix it. */
  disarm: boolean;
  /** When to try again; null when disarmed. */
  nextRun: Date | null;
  /** Short reason suitable for showing an operator or tenant. */
  reason: string;
  /** True when the card itself is the problem and a new one is required. */
  needsNewCard: boolean;
}

export function isPermanentDecline(code: unknown): boolean {
  return PERMANENT_DECLINE_CODES.has(String(code || '').trim().toLowerCase());
}

/**
 * Decide the outcome of a declined autopay charge.
 *
 * `previousFailures` is the count before this attempt, so the first failure
 * arrives as 0.
 */
export function resolveAutopayFailureOutcome(params: {
  previousFailures?: unknown;
  declineCode?: unknown;
  message?: unknown;
  now: Date;
}): AutopayFailureOutcome {
  const prior =
    typeof params.previousFailures === 'number' && Number.isFinite(params.previousFailures)
      ? Math.max(0, Math.floor(params.previousFailures))
      : 0;
  const failures = prior + 1;
  const message = String(params.message || '').trim();

  // A card that is wrong or gone will not become right by waiting. Stop
  // immediately rather than spending the tolerance on attempts that cannot work.
  if (isPermanentDecline(params.declineCode)) {
    return {
      failures,
      disarm: true,
      nextRun: null,
      needsNewCard: true,
      reason: message || 'The saved card was declined and needs to be replaced.',
    };
  }

  if (failures >= MAX_CONSECUTIVE_AUTOPAY_FAILURES) {
    return {
      failures,
      disarm: true,
      nextRun: null,
      needsNewCard: true,
      reason:
        message ||
        `Autopay was turned off after ${failures} failed attempts. Please update the card on file.`,
    };
  }

  const nextRun = new Date(params.now.getTime());
  nextRun.setUTCDate(nextRun.getUTCDate() + AUTOPAY_RETRY_BACKOFF_DAYS);
  return {
    failures,
    disarm: false,
    nextRun,
    needsNewCard: false,
    reason: message || 'The card was declined. We will try again in a few days.',
  };
}
