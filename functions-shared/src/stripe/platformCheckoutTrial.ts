/**
 * What a platform subscription Checkout Session offers: which trial, and whether the
 * first-month-free coupon is attached.
 *
 * The offer is "30-day trial, then first month free", and it is once per owner, ever:
 * one trial and one free month, however many times they cancel and resubscribe.
 *
 * Trials start in two places. Most owners get an app trial that lives only in Firestore
 * (`startTrial`, or admin approval): `subscriptionStatus: 'trialing'` plus
 * `subscriptionTrialEnd`, with no Stripe subscription behind it. Card-at-signup owners
 * get a Stripe trial at checkout instead. Checkout used to hand every owner a fresh
 * 30-day Stripe trial plus the coupon, on top of any app trial, and again on every
 * resubscribe.
 *
 * Permanent markers on `facilityCreatorAccounts` record the offer being used. They are
 * set once and never cleared, and owners cannot write them (see firestore rules):
 *   - `platformTrialUsedAt`: an app trial started, or a platform subscription with a
 *     trial was seen;
 *   - `platformFirstMonthFreeUsedAt`: a platform subscription carrying the coupon was
 *     created.
 * Accounts from before the markers existed are judged by the conservative history rules
 * in `assessPlatformOfferHistory`.
 *
 * Pure: no Firestore, no Stripe calls, so every branch is unit tested.
 */

/** Trial length for owners with no trial record at all (card at signup). */
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

/** Account statuses that mean "never subscribed": the account was just created. */
const FRESH_ACCOUNT_STATUSES = new Set(['', 'pendingApproval']);

/** Account statuses only a Stripe subscription (or an admin standing in for one) produces. */
const SUBSCRIBED_ACCOUNT_STATUSES = new Set(['active', 'pastDue', 'unpaid', 'incomplete', 'incompleteExpired']);

type Doc = Record<string, unknown>;

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

/** A marker or timestamp counts when it holds anything at all. */
function isSet(value: unknown): boolean {
  if (value === null || value === undefined || value === false) return false;
  if (typeof value === 'string') return value.trim().length > 0;
  return true;
}

function str(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

export type PlatformOfferHistoryInput = {
  /** The `facilityCreatorAccounts` document. */
  account: Doc;
  /** Every facility linked to the account, including the one being subscribed. */
  facilities: Doc[];
};

export type PlatformOfferHistory = {
  /** The owner's one trial has started (it may still be running). */
  trialUsed: boolean;
  /** A platform subscription has existed for this owner before. */
  hadPlatformSubscription: boolean;
  /** The first-month-free coupon has been used. */
  firstMonthFreeUsed: boolean;
  /** Which rules fired, for logs. */
  reasons: string[];
};

/**
 * What this owner has already used. Conservative: when in doubt, it counts as used.
 *
 * Earlier platform subscription, if ANY of:
 *   S1 account `stripeSubscriptionId` or `stripeSubscriptionIdClearedFrom` is set;
 *   S2 account `subscriptionCanceledAt` is set, or `subscriptionCancelAtPeriodEnd` is true
 *      (only written for a Stripe subscription);
 *   S3 account `subscriptionStatus` is active, pastDue, unpaid, incomplete or
 *      incompleteExpired;
 *   S4 any facility has `stripePlatformSubscriptionId`, `platformSubscriptionStatus`,
 *      `platformSubscriptionTrialEnd` or `platformSubscriptionCancelledAt`.
 *
 * Trial used, if ANY of:
 *   T1 account `platformTrialUsedAt` is set;
 *   T2 account `subscriptionTrialEnd` is set, whoever wrote it (app trial, admin, Stripe);
 *   T3 any facility has `platformSubscriptionTrialEnd`;
 *   T4 account has `stripeCustomerId` and a status other than '' / pendingApproval;
 *   T5 an earlier platform subscription exists (S1-S4).
 *
 * First month free used, if ANY of:
 *   F1 account `platformFirstMonthFreeUsedAt` is set;
 *   F2 an earlier platform subscription exists (S1-S4).
 * T2 and T4 alone do not use up the free month: an app-trial owner (who may have opened
 * and abandoned a checkout, leaving a customer id) still gets it.
 */
export function assessPlatformOfferHistory(input: PlatformOfferHistoryInput): PlatformOfferHistory {
  const account = input.account ?? {};
  const facilities = input.facilities ?? [];
  const status = str(account.subscriptionStatus);
  const reasons: string[] = [];

  // Earlier platform subscription.
  const s1 = isSet(str(account.stripeSubscriptionId)) || isSet(str(account.stripeSubscriptionIdClearedFrom));
  const s2 = isSet(account.subscriptionCanceledAt) || account.subscriptionCancelAtPeriodEnd === true;
  const s3 = SUBSCRIBED_ACCOUNT_STATUSES.has(status);
  const s4 = facilities.some(
    (f) =>
      isSet(str(f.stripePlatformSubscriptionId)) ||
      isSet(str(f.platformSubscriptionStatus)) ||
      isSet(f.platformSubscriptionTrialEnd) ||
      isSet(f.platformSubscriptionCancelledAt),
  );
  if (s1) reasons.push('S1 account subscription id');
  if (s2) reasons.push('S2 account cancellation fields');
  if (s3) reasons.push(`S3 account status ${status}`);
  if (s4) reasons.push('S4 facility platform subscription');
  const hadPlatformSubscription = s1 || s2 || s3 || s4;

  // Trial.
  const t1 = isSet(account.platformTrialUsedAt);
  const t2 = trialEndToMillis(account.subscriptionTrialEnd) !== null;
  const t3 = facilities.some((f) => trialEndToMillis(f.platformSubscriptionTrialEnd) !== null);
  const t4 = isSet(str(account.stripeCustomerId)) && !FRESH_ACCOUNT_STATUSES.has(status);
  if (t1) reasons.push('T1 platformTrialUsedAt');
  if (t2) reasons.push('T2 subscriptionTrialEnd');
  if (t3) reasons.push('T3 facility trial end');
  if (t4) reasons.push(`T4 customer with status ${status || '(none)'}`);
  const trialUsed = t1 || t2 || t3 || t4 || hadPlatformSubscription;

  // Free month.
  const f1 = isSet(account.platformFirstMonthFreeUsedAt);
  if (f1) reasons.push('F1 platformFirstMonthFreeUsedAt');
  const firstMonthFreeUsed = f1 || hadPlatformSubscription;

  return { trialUsed, hadPlatformSubscription, firstMonthFreeUsed, reasons };
}

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

export type PlatformCheckoutOffer = {
  trial: PlatformCheckoutTrialDecision;
  /** Attach the `sfc_first_month_free` coupon to this checkout. */
  attachFirstMonthFree: boolean;
  history: PlatformOfferHistory;
};

export type PlatformCheckoutOfferInput = PlatformOfferHistoryInput & {
  /** Trial length when the owner has no trial record at all (30, or the referral rule). */
  defaultTrialDays: number;
  nowMs: number;
};

/**
 * The only trial after the first one has started is the rest of a running app trial:
 * the Stripe trial then ends exactly when the app trial does, so no time is added.
 */
function decideTrial(input: PlatformCheckoutOfferInput, history: PlatformOfferHistory): PlatformCheckoutTrialDecision {
  if (history.hadPlatformSubscription) {
    return { kind: 'no_trial', reason: 'owner already had a platform subscription' };
  }
  if (!history.trialUsed) {
    return {
      kind: 'default_trial',
      trialPeriodDays: input.defaultTrialDays,
      reason: 'no trial record at all',
    };
  }

  const status = str(input.account.subscriptionStatus);
  const appTrialEndMs = trialEndToMillis(input.account.subscriptionTrialEnd);
  const remainingMs = appTrialEndMs === null ? -1 : appTrialEndMs - input.nowMs;
  if (status !== 'trialing' || appTrialEndMs === null || remainingMs <= 0) {
    return { kind: 'no_trial', reason: 'trial already used and ended' };
  }
  if (remainingMs < STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS + TRIAL_END_SAFETY_MARGIN_MS) {
    // Stripe cannot hold a trial this short. The owner loses under two days of trial.
    return { kind: 'no_trial', reason: 'app trial ends in under 48 hours' };
  }
  return {
    kind: 'align_to_app_trial',
    trialEndSeconds: Math.floor(appTrialEndMs / 1000),
    reason: 'app trial still running; Stripe trial ends when it does',
  };
}

export function decidePlatformCheckoutOffer(input: PlatformCheckoutOfferInput): PlatformCheckoutOffer {
  const history = assessPlatformOfferHistory(input);
  return {
    trial: decideTrial(input, history),
    attachFirstMonthFree: !history.firstMonthFreeUsed,
    history,
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

/** Subscription metadata key recording that checkout attached the first-month-free coupon. */
export const FIRST_MONTH_FREE_METADATA_KEY = 'firstMonthFreeCoupon';

/**
 * Which markers a platform subscription seen by a webhook uses up. A subscription with
 * any trial used the trial; one carrying our metadata flag, or any discount at all
 * (conservative: discounts are unexpanded ids on webhook payloads), used the free month.
 */
export function platformOfferUsageFromSubscription(subscription: {
  trial_end?: number | null;
  trial_start?: number | null;
  metadata?: Record<string, string> | null;
  discounts?: unknown[] | null;
}): { trialUsed: boolean; firstMonthFreeUsed: boolean } {
  const trialUsed = isSet(subscription.trial_end) || isSet(subscription.trial_start);
  const firstMonthFreeUsed =
    subscription.metadata?.[FIRST_MONTH_FREE_METADATA_KEY] === 'true' ||
    (Array.isArray(subscription.discounts) && subscription.discounts.length > 0);
  return { trialUsed, firstMonthFreeUsed };
}

/**
 * The marker fields to write on the account: only those not already set, so the first
 * time is kept and nothing is ever cleared. `stamp` is the value to write (a server
 * timestamp in production).
 */
export function platformOfferMarkerUpdates<T>(
  account: Doc,
  usage: { trialUsed: boolean; firstMonthFreeUsed: boolean },
  stamp: T,
): { platformTrialUsedAt?: T; platformFirstMonthFreeUsedAt?: T } {
  const out: { platformTrialUsedAt?: T; platformFirstMonthFreeUsedAt?: T } = {};
  if (usage.trialUsed && !isSet(account.platformTrialUsedAt)) out.platformTrialUsedAt = stamp;
  if (usage.firstMonthFreeUsed && !isSet(account.platformFirstMonthFreeUsedAt)) {
    out.platformFirstMonthFreeUsedAt = stamp;
  }
  return out;
}
