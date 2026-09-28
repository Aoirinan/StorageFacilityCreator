/**
 * Which trial a platform subscription Checkout Session should carry.
 *
 * The public offer is "30-day trial, then first month free": two months free in
 * total. Some owners start that trial in the app (`startTrial`), which lives only
 * in Firestore: `subscriptionStatus: 'trialing'` and `subscriptionTrialEnd` 30 days
 * out, with no Stripe subscription behind it. When those owners later subscribe,
 * Checkout used to start a second, fresh 30-day Stripe trial on top of the first
 * and still attach the first-month-free coupon: about three months free.
 *
 * This module decides the trial once, for both checkout paths:
 *   - app trial still running  -> Stripe trial ends exactly when the app trial does;
 *   - app trial over, or under Stripe's 48-hour minimum -> no Stripe trial at all;
 *   - no app trial ever (card-at-signup) -> the usual trial length (referral rule kept).
 * The first-month-free coupon is attached in every case by the caller.
 *
 * Pure: no Firestore, no Stripe calls, so every branch is unit tested.
 */

/** Trial length for owners who never had an app trial (card at signup). */
export const DEFAULT_PLATFORM_TRIAL_DAYS = 30;

/**
 * Stripe Checkout rejects `subscription_data.trial_end` unless it is at least 48 hours
 * in the future (stripe-node `Checkout.SessionCreateParams.SubscriptionData.trial_end`:
 * "Has to be at least 48 hours in the future.").
 */
export const STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS = 48 * 60 * 60 * 1000;

/**
 * Extra headroom on top of Stripe's 48 hours, so clock skew between us and Stripe and
 * request latency cannot turn a borderline trial into a rejected Checkout Session.
 */
export const TRIAL_END_SAFETY_MARGIN_MS = 10 * 60 * 1000;

export type PlatformCheckoutTrialInput = {
  /** The account's `subscriptionStatus`. */
  accountSubscriptionStatus: string | null | undefined;
  /** The account's `subscriptionTrialEnd`: a Firestore Timestamp, Date, epoch ms, or null. */
  accountTrialEnd: unknown;
  /**
   * True when the account already points at a Stripe subscription (`stripeSubscriptionId`).
   * Then `subscriptionTrialEnd` was written by the Stripe webhook, not by the app trial,
   * so it says nothing about a Firestore-only trial and the default rule applies.
   */
  accountHasStripeSubscription: boolean;
  /** Trial length when there was never an app trial (30, or the referral rule). */
  defaultTrialDays: number;
  nowMs: number;
};

export type PlatformCheckoutTrialDecision =
  | {
      kind: 'default_trial';
      trialPeriodDays: number;
      reason: string;
    }
  | {
      kind: 'align_to_app_trial';
      /** Epoch seconds, as Stripe expects for `trial_end`. */
      trialEndSeconds: number;
      reason: string;
    }
  | {
      kind: 'no_trial';
      reason: string;
    };

/** Reads a Firestore Timestamp (anything with `toMillis`), Date, or epoch ms. */
export function trialEndToMillis(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (value instanceof Date) {
    const ms = value.getTime();
    return Number.isFinite(ms) ? ms : null;
  }
  const withToMillis = value as { toMillis?: () => number };
  if (typeof withToMillis.toMillis === 'function') {
    const ms = withToMillis.toMillis();
    return typeof ms === 'number' && Number.isFinite(ms) ? ms : null;
  }
  return null;
}

export function decidePlatformCheckoutTrial(input: PlatformCheckoutTrialInput): PlatformCheckoutTrialDecision {
  const defaultTrial = (reason: string): PlatformCheckoutTrialDecision => ({
    kind: 'default_trial',
    trialPeriodDays: input.defaultTrialDays,
    reason,
  });

  if (input.accountHasStripeSubscription) {
    return defaultTrial('account already has a Stripe subscription; its trial end is not an app trial');
  }

  const appTrialEndMs = trialEndToMillis(input.accountTrialEnd);
  if (appTrialEndMs === null) {
    return defaultTrial('no app trial was ever started');
  }

  const status = (input.accountSubscriptionStatus ?? '').trim();
  const remainingMs = appTrialEndMs - input.nowMs;

  // The app trial counts as running only while the account still says `trialing`
  // and the date has not passed. Anything else (swept to `cancelled`, or the date
  // gone) means the trial month is already used up.
  if (status !== 'trialing' || remainingMs <= 0) {
    return { kind: 'no_trial', reason: 'app trial already ended' };
  }

  if (remainingMs < STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS + TRIAL_END_SAFETY_MARGIN_MS) {
    // Stripe cannot hold a trial this short. The coupon makes the first invoice $0
    // instead, so the owner still gets their free month; they lose under two days.
    return { kind: 'no_trial', reason: 'app trial ends in under 48 hours' };
  }

  return {
    kind: 'align_to_app_trial',
    trialEndSeconds: Math.floor(appTrialEndMs / 1000),
    reason: 'app trial still running; Stripe trial ends when it does',
  };
}

/**
 * The trial fields to spread into `subscription_data`. Exactly one of `trial_end` /
 * `trial_period_days` is set, or neither.
 */
export function platformCheckoutTrialSubscriptionData(
  decision: PlatformCheckoutTrialDecision,
): { trial_end?: number; trial_period_days?: number } {
  switch (decision.kind) {
    case 'default_trial':
      return { trial_period_days: decision.trialPeriodDays };
    case 'align_to_app_trial':
      return { trial_end: decision.trialEndSeconds };
    case 'no_trial':
      return {};
  }
}
