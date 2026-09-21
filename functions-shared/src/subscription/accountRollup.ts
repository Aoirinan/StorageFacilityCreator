/**
 * Account-level subscription rollup.
 *
 * An operator's billing state lives in two places: the account document
 * (`facilityCreatorAccounts`) and each facility document (`facilities`). The
 * webhook handlers route by metadata and return early, so a subscription that
 * carries a `facilityId` only ever updated the facility, leaving the account
 * document frozen at whatever it last said. Real accounts therefore ended up
 * claiming `trialing` while pointing at a subscription Stripe had cancelled
 * months earlier, and locally granted trials never expired at all because no
 * Stripe object existed to fire a webhook.
 *
 * This module is the single place that decides what an account's status should
 * be, given everything known about it. It is pure so both the webhook path and
 * the nightly sweep can share it and be tested without Firestore or Stripe.
 */

/** Status vocabulary shared with the Flutter `SubscriptionStatus` enum. */
export type AccountSubscriptionStatus =
  | 'active'
  | 'pastDue'
  | 'cancelled'
  | 'trialing'
  | 'incomplete'
  | 'incompleteExpired'
  | 'unpaid'
  | 'pendingApproval';

/** The part of a facility document this decision depends on. */
export type FacilitySubscriptionSnapshot = {
  facilityId: string;
  /** `platformSubscriptionStatus`, already mapped to the shared vocabulary. */
  platformSubscriptionStatus: string | null | undefined;
};

export type AccountRollupInput = {
  /** The account's current `subscriptionStatus`. */
  currentStatus: string | null | undefined;
  /** `subscriptionTrialEnd` in epoch ms, for a locally granted trial. */
  localTrialEndMs: number | null | undefined;
  /** Every facility linked to this account. */
  facilities: FacilitySubscriptionSnapshot[];
  nowMs: number;
};

export type AccountRollupResult = {
  status: AccountSubscriptionStatus;
  /** Why this status was chosen, for logs and audit rows. */
  reason: string;
  /** True when `status` differs from `currentStatus`. */
  changed: boolean;
};

/** Facility states that mean "this site is paying, or is inside a paid-for window". */
const FACILITY_ENTITLED = new Set(['active', 'trialing']);

function hasFacilityStatus(facilities: FacilitySubscriptionSnapshot[], status: string): boolean {
  return facilities.some((f) => (f.platformSubscriptionStatus ?? '') === status);
}

/**
 * Decide an account's subscription status from its facilities and its own trial.
 *
 * Facility state wins over account state: once an operator moves to per-facility
 * billing, the facilities are the truth and the account is a rollup of them.
 * A locally granted trial only matters when no facility says otherwise.
 */
export function computeAccountRollup(input: AccountRollupInput): AccountRollupResult {
  const current = (input.currentStatus ?? '') as string;
  const facilities = input.facilities ?? [];

  const decide = (status: AccountSubscriptionStatus, reason: string): AccountRollupResult => ({
    status,
    reason,
    changed: status !== current,
  });

  // Never move an account out of admin approval automatically: the trial clock
  // has not started and only an admin decides when it does.
  if (current === 'pendingApproval') {
    return decide('pendingApproval', 'account is awaiting admin approval');
  }

  // A paying site outranks everything else.
  if (hasFacilityStatus(facilities, 'active')) {
    return decide('active', 'at least one facility subscription is active');
  }
  if (hasFacilityStatus(facilities, 'trialing')) {
    return decide('trialing', 'at least one facility subscription is trialing');
  }
  if (hasFacilityStatus(facilities, 'pastDue')) {
    return decide('pastDue', 'a facility subscription is past due');
  }
  if (hasFacilityStatus(facilities, 'unpaid')) {
    return decide('unpaid', 'a facility subscription is unpaid');
  }

  // No facility is entitled. Fall back to a locally granted trial, which exists
  // only in Firestore and so has to be expired by us rather than by Stripe.
  const trialEnd = input.localTrialEndMs;
  if (typeof trialEnd === 'number' && Number.isFinite(trialEnd)) {
    if (input.nowMs < trialEnd) {
      return decide('trialing', 'local trial has not ended yet');
    }
    // The bug this module exists to fix: the status used to stay `trialing`
    // forever, so the account looked live long after access had been cut off.
    return decide('cancelled', 'local trial ended and no facility subscription replaced it');
  }

  // Facilities exist but none is entitled, and there is no trial to fall back on.
  if (facilities.length > 0 && facilities.every((f) => !FACILITY_ENTITLED.has(f.platformSubscriptionStatus ?? ''))) {
    return decide('cancelled', 'no facility subscription is active and no trial is running');
  }

  // Nothing known: leave the account exactly as it is rather than guessing.
  const unchanged = (current || 'cancelled') as AccountSubscriptionStatus;
  return { status: unchanged, reason: 'no signal to change the status', changed: false };
}

/**
 * True when the account holds a locally granted trial that has already ended.
 * Used by the nightly sweep to find accounts to reconcile.
 */
export function isLocalTrialExpired(localTrialEndMs: number | null | undefined, nowMs: number): boolean {
  if (typeof localTrialEndMs !== 'number' || !Number.isFinite(localTrialEndMs)) return false;
  return nowMs >= localTrialEndMs;
}
