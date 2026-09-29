/**
 * What a platform subscription Checkout Session offers: how long the Stripe trial runs,
 * and whether it carries the owner's one free month.
 *
 * The offer is "30-day trial + first month free", once per owner, ever: one trial and
 * one free month, however many times they cancel and resubscribe. Two months free in
 * total, never three.
 *
 * The free month is delivered as TRIAL TIME, not a coupon. Stripe docs
 * (https://docs.stripe.com/billing/subscriptions/coupons.md, "Coupon duration"): a
 * `once` coupon "applies only to the first invoice", and a subscription with a trial
 * finalizes a $0 first invoice when it is created. The old `sfc_first_month_free`
 * coupon was spent on that $0 trial invoice, so the first paid month was charged in
 * full. Instead, checkout pushes Stripe's `trial_end` 30 days past the end of the
 * owner's trial, and the first invoice after that is the normal price.
 *
 * Trials start in two places. Most owners get an app trial that lives only in Firestore
 * (`startTrial`, or admin approval): `subscriptionStatus: 'trialing'` plus
 * `subscriptionTrialEnd`, with no Stripe subscription behind it. Card-at-signup owners
 * have no trial record at all and get their 30 days at checkout.
 *
 * Permanent markers on `facilityCreatorAccounts` record the offer being used. They are
 * set once and never cleared, and owners cannot write them (see firestore rules):
 *   - `platformTrialUsedAt`: an app trial started, or a platform subscription with a
 *     trial was seen;
 *   - `platformFirstMonthFreeUsedAt`: a platform subscription carrying the free month
 *     (subscription metadata `firstMonthFree: 'true'`) was created.
 * Accounts from before the markers existed are judged by the conservative history rules
 * in `assessPlatformOfferHistory`.
 *
 * Pure: no Firestore, no Stripe calls, so every branch is unit tested.
 */

/** Trial length for owners with no trial record at all (card at signup). */
export const DEFAULT_PLATFORM_TRIAL_DAYS = 30;

/** Length of the free month, added to the end of the owner's trial. */
export const FIRST_MONTH_FREE_DAYS = 30;

const DAY_MS = 24 * 60 * 60 * 1000;

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
  /**
   * Every facility linked to the account, including the one being subscribed, plus any
   * other facility the same owner owns.
   */
  facilities: Doc[];
  /**
   * The owner's other `facilityCreatorAccounts` documents (same `ownerUid`, not
   * [account]). The offer is once per owner, so a duplicate or recreated account does
   * not start over.
   */
  otherAccounts?: Doc[];
};

export type PlatformOfferHistory = {
  /** The owner's one trial has started (it may still be running). */
  trialUsed: boolean;
  /** A platform subscription has existed for this owner before. */
  hadPlatformSubscription: boolean;
  /** The owner's one free month has been used. */
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
 * First month free used, if ANY of:
 *   F1 account `platformFirstMonthFreeUsedAt` is set;
 *   F2 an earlier platform subscription exists (S1-S4).
 *
 * Trial used, if ANY of:
 *   T1 account `platformTrialUsedAt` is set;
 *   T2 account `subscriptionTrialEnd` is set, whoever wrote it (app trial, admin, Stripe);
 *   T3 any facility has `platformSubscriptionTrialEnd`;
 *   T4 account has `stripeCustomerId` and a status other than '' / pendingApproval;
 *   T5 an earlier platform subscription exists (S1-S4);
 *   T6 the free month was used (F1): the free month comes after the trial.
 *
 * T2 and T4 alone do not use up the free month: an app-trial owner (who may have opened
 * and abandoned a checkout, leaving a customer id) still gets it.
 *
 * Other accounts of the same owner (O1-O3): each is judged by the account rules above
 * (S1-S3, F1, T1, T2, T4); whatever it used, this owner used.
 */
export function assessPlatformOfferHistory(input: PlatformOfferHistoryInput): PlatformOfferHistory {
  const own = assessOneAccount(input.account ?? {}, input.facilities ?? []);
  const reasons = [...own.reasons];
  let { trialUsed, hadPlatformSubscription, firstMonthFreeUsed } = own;
  for (const other of input.otherAccounts ?? []) {
    const h = assessOneAccount(other ?? {}, []);
    if (h.hadPlatformSubscription) reasons.push('O1 another account of this owner had a platform subscription');
    else if (h.firstMonthFreeUsed) reasons.push('O2 another account of this owner used the free month');
    else if (h.trialUsed) reasons.push('O3 another account of this owner used the trial');
    hadPlatformSubscription = hadPlatformSubscription || h.hadPlatformSubscription;
    firstMonthFreeUsed = firstMonthFreeUsed || h.firstMonthFreeUsed;
    trialUsed = trialUsed || h.trialUsed;
  }
  return { trialUsed, hadPlatformSubscription, firstMonthFreeUsed, reasons };
}

function assessOneAccount(account: Doc, facilities: Doc[]): PlatformOfferHistory {
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

  // Free month.
  const f1 = isSet(account.platformFirstMonthFreeUsedAt);
  if (f1) reasons.push('F1 platformFirstMonthFreeUsedAt');
  const firstMonthFreeUsed = f1 || hadPlatformSubscription;

  // Trial.
  const t1 = isSet(account.platformTrialUsedAt);
  const t2 = trialEndToMillis(account.subscriptionTrialEnd) !== null;
  const t3 = facilities.some((f) => trialEndToMillis(f.platformSubscriptionTrialEnd) !== null);
  const t4 = isSet(str(account.stripeCustomerId)) && !FRESH_ACCOUNT_STATUSES.has(status);
  if (t1) reasons.push('T1 platformTrialUsedAt');
  if (t2) reasons.push('T2 subscriptionTrialEnd');
  if (t3) reasons.push('T3 facility trial end');
  if (t4) reasons.push(`T4 customer with status ${status || '(none)'}`);
  const trialUsed = t1 || t2 || t3 || t4 || hadPlatformSubscription || firstMonthFreeUsed;

  return { trialUsed, hadPlatformSubscription, firstMonthFreeUsed, reasons };
}

export type PlatformCheckoutTrialDecision =
  | {
      /**
       * The owner's one free month, as trial time: Stripe's trial runs to the end of the
       * owner's trial plus FIRST_MONTH_FREE_DAYS, and the first charge is the full price.
       */
      kind: 'free_month';
      /** Epoch seconds, as Stripe expects for `trial_end`. */
      trialEndSeconds: number;
      /** Epoch seconds: where the owner's trial ends and the free month starts. */
      freeMonthStartSeconds: number;
      reason: string;
    }
  | {
      /** The rest of a running app trial, no free month (it was already used). */
      kind: 'align_to_app_trial';
      /** Epoch seconds, as Stripe expects for `trial_end`. */
      trialEndSeconds: number;
      reason: string;
    }
  | {
      /**
       * The rest of the owner's running card-backed trial (their free month, on another
       * facility or on the account), no free month of its own: a facility added while
       * the free month runs is first charged when it ends, as on the account path.
       */
      kind: 'align_to_free_month';
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
  /** This checkout carries the owner's one free month (as trial time, never a coupon). */
  firstMonthFree: boolean;
  history: PlatformOfferHistory;
};

export type PlatformCheckoutOfferInput = PlatformOfferHistoryInput & {
  /** Trial length when the owner has no trial record at all (30, or the referral rule). */
  defaultTrialDays: number;
  nowMs: number;
};

/**
 * The end (epoch ms) of the owner's running card-backed trial, or null: the latest
 * `trial_end` still ahead of now among `trialing` subscriptions with a Stripe id, on the
 * account (`subscriptionTrialEnd`) or on any of [facilities]
 * (`platformSubscriptionTrialEnd`). While the owner's free month runs, that is its end;
 * no other subscription of theirs can trial longer.
 */
function runningCardTrialEndMs(input: PlatformCheckoutOfferInput): number | null {
  let latest: number | null = null;
  const consider = (status: unknown, subscriptionId: unknown, trialEnd: unknown) => {
    if (str(status) !== 'trialing' || !isSet(str(subscriptionId))) return;
    const endMs = trialEndToMillis(trialEnd);
    if (endMs === null || endMs <= input.nowMs) return;
    if (latest === null || endMs > latest) latest = endMs;
  };
  const account = input.account ?? {};
  consider(account.subscriptionStatus, account.stripeSubscriptionId, account.subscriptionTrialEnd);
  for (const f of input.facilities ?? []) {
    consider(f.platformSubscriptionStatus, f.stripePlatformSubscriptionId, f.platformSubscriptionTrialEnd);
  }
  return latest;
}

/**
 * Free month not used yet: the Stripe trial ends FIRST_MONTH_FREE_DAYS after the end of
 * the owner's trial, where the trial ends
 *   - when a running app trial ends (however little of it is left);
 *   - `defaultTrialDays` from now, for an owner with no trial record at all;
 *   - now, when the trial was used and is over.
 * That is always at least 30 days away, well past Stripe's 48-hour minimum.
 *
 * Free month used: no fresh time at all. The only trial is the rest of time the owner
 * already has, checked before any subscription history, so a second facility is not
 * charged before the owner's first charge:
 *   - while the owner's card-backed trial runs (their free month, on another facility or
 *     on the account): exactly its end, never later. The new facility's first charge is
 *     when that free month ends, as on the account path, where an added facility joins
 *     the trialing subscription;
 *   - otherwise the rest of a running app trial (the Stripe trial then ends exactly when
 *     the app trial does).
 * With under 48 hours (plus margin) left, Stripe cannot hold the trial and there is none.
 * Nothing further is used up: `firstMonthFree` stays false.
 */
function decideTrial(input: PlatformCheckoutOfferInput, history: PlatformOfferHistory): PlatformCheckoutTrialDecision {
  const status = str(input.account.subscriptionStatus);
  const appTrialEndMs = trialEndToMillis(input.account.subscriptionTrialEnd);
  const remainingMs = appTrialEndMs === null ? -1 : appTrialEndMs - input.nowMs;
  const appTrialRunning = status === 'trialing' && appTrialEndMs !== null && remainingMs > 0;

  if (!history.firstMonthFreeUsed) {
    let freeMonthStartMs: number;
    let reason: string;
    if (appTrialRunning) {
      freeMonthStartMs = appTrialEndMs!;
      reason = 'app trial running; free month follows it';
    } else if (!history.trialUsed) {
      freeMonthStartMs = input.nowMs + input.defaultTrialDays * DAY_MS;
      reason = 'no trial record; trial then free month';
    } else {
      freeMonthStartMs = input.nowMs;
      reason = 'trial used and over; free month starts now';
    }
    // Never before now, so the trial always ends at least a full free month away.
    freeMonthStartMs = Math.max(freeMonthStartMs, input.nowMs);
    return {
      kind: 'free_month',
      trialEndSeconds: Math.floor((freeMonthStartMs + FIRST_MONTH_FREE_DAYS * DAY_MS) / 1000),
      freeMonthStartSeconds: Math.floor(freeMonthStartMs / 1000),
      reason,
    };
  }

  // The owner's running free month decides when one is running (it ends after the app
  // trial it follows); otherwise the rest of a running app trial.
  const cardTrialEndMs = runningCardTrialEndMs(input);
  const alignToFreeMonth = cardTrialEndMs !== null;
  const alignEndMs = alignToFreeMonth ? cardTrialEndMs : appTrialRunning ? appTrialEndMs : null;
  if (alignEndMs !== null) {
    if (alignEndMs - input.nowMs >= STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS + TRIAL_END_SAFETY_MARGIN_MS) {
      return alignToFreeMonth
        ? {
            kind: 'align_to_free_month',
            trialEndSeconds: Math.floor(alignEndMs / 1000),
            reason: "free month used; the owner's free month is still running, Stripe trial ends when it does",
          }
        : {
            kind: 'align_to_app_trial',
            trialEndSeconds: Math.floor(alignEndMs / 1000),
            reason: 'free month used; app trial still running, Stripe trial ends when it does',
          };
    }
    // Stripe cannot hold a trial this short. The owner loses under two days of it.
    return {
      kind: 'no_trial',
      reason: alignToFreeMonth
        ? "free month used; the owner's free month ends in under 48 hours"
        : 'free month used; app trial ends in under 48 hours',
    };
  }
  if (history.hadPlatformSubscription) {
    return { kind: 'no_trial', reason: 'owner already had a platform subscription' };
  }
  return { kind: 'no_trial', reason: 'free month already used' };
}

export function decidePlatformCheckoutOffer(input: PlatformCheckoutOfferInput): PlatformCheckoutOffer {
  const history = assessPlatformOfferHistory(input);
  const trial = decideTrial(input, history);
  return { trial, firstMonthFree: trial.kind === 'free_month', history };
}

/**
 * The trial fields to spread into `subscription_data`: `trial_end` or nothing.
 * `trial_period_days` is never sent, and no `discounts` either.
 */
export function platformCheckoutTrialSubscriptionData(decision: PlatformCheckoutTrialDecision): { trial_end?: number } {
  switch (decision.kind) {
    case 'free_month':
    case 'align_to_app_trial':
    case 'align_to_free_month':
      return { trial_end: decision.trialEndSeconds };
    case 'no_trial':
      return {};
  }
}

/**
 * Subscription (and Checkout Session) metadata key: 'true' when the subscription's trial
 * includes the owner's one free month. The webhook sets `platformFirstMonthFreeUsedAt`
 * from it.
 */
export const FIRST_MONTH_FREE_METADATA_KEY = 'firstMonthFree';
/** Metadata key: ISO time the free month starts (the end of the owner's trial). */
export const FREE_MONTH_START_METADATA_KEY = 'freeMonthStart';
/** Metadata key: ISO time the free month, and so the Stripe trial, ends. */
export const FREE_MONTH_TRIAL_END_METADATA_KEY = 'freeMonthTrialEnd';

/** Offer metadata for the Checkout Session and its subscription. */
export function platformCheckoutOfferMetadata(decision: PlatformCheckoutTrialDecision): Record<string, string> {
  const metadata: Record<string, string> = {
    trialDecision: decision.kind,
    [FIRST_MONTH_FREE_METADATA_KEY]: String(decision.kind === 'free_month'),
  };
  if (decision.kind === 'free_month') {
    metadata[FREE_MONTH_START_METADATA_KEY] = new Date(decision.freeMonthStartSeconds * 1000).toISOString();
    metadata[FREE_MONTH_TRIAL_END_METADATA_KEY] = new Date(decision.trialEndSeconds * 1000).toISOString();
  }
  return metadata;
}

/**
 * Which markers a platform subscription seen by a webhook uses up. A subscription with
 * any trial used the trial. One marked `firstMonthFree: 'true'` used the free month; so
 * did one with any discount at all (conservative: subscriptions created before this
 * change carried the old first-month-free coupon, and discounts are unexpanded ids on
 * webhook payloads).
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
