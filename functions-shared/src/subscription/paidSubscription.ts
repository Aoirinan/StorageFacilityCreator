/**
 * Whether a platform subscription counts as paid for.
 *
 * The first free month is Stripe trial time (`stripe/platformCheckoutTrial.ts`), so an
 * owner who subscribes with a card reads `trialing` for up to two months before the
 * first charge. Every entitlement treats that subscription like `active`, but only
 * until its recorded trial end (plus CARD_TRIAL_GRACE_MS for webhook lag): at the
 * trial end Stripe charges and the webhook moves the status on (`active`, `pastDue`,
 * or cancelled). A `trialing` record with a subscription id whose trial end is long
 * past, or missing, is stale (a lost webhook, a pointer nobody cleared) and does not
 * count.
 *
 * The unpaid app trial also reads `trialing`: `startTrial` and the super-admin
 * approve/grant actions write `subscriptionStatus: 'trialing'` with no Stripe
 * subscription id. That one keeps its trial limits and still ends at
 * `subscriptionTrialEnd`.
 *
 * Same rule as `hasPaidOrCardTrialSubscription` in the Flutter app
 * (lib/models/paid_subscription.dart) and `accountPaidOrCardTrial` /
 * `facilityPaidOrCardTrial` in firestore.rules and storage.rules.
 */

import { trialEndToMillis } from '../stripe/platformCheckoutTrial';

/** A Firestore document's data, or nothing. */
export type SubscriptionDocData = Record<string, unknown> | null | undefined;

/**
 * How long past its recorded trial end a card-backed trial still counts as paid: the
 * webhook that moves it to `active` (or `pastDue`) can lag the trial end. Same value as
 * `cardTrialGrace` in the app and `duration.value(3, 'd')` in the rules.
 */
export const CARD_TRIAL_GRACE_MS = 3 * 24 * 60 * 60 * 1000;

function isNonEmptyString(value: unknown): boolean {
  return typeof value === 'string' && value.trim().length > 0;
}

/**
 * `active`; or `trialing` with a Stripe subscription behind it whose trial end, plus
 * CARD_TRIAL_GRACE_MS, is still ahead of [nowMs]. A missing trial end does not count.
 *
 * [status] is an account's `subscriptionStatus` or a facility's
 * `platformSubscriptionStatus`. [stripeSubscriptionId] is the account's
 * `stripeSubscriptionId` or the facility's `stripePlatformSubscriptionId`. [trialEnd] is
 * the account's `subscriptionTrialEnd` or the facility's `platformSubscriptionTrialEnd`
 * (a Firestore Timestamp, Date or epoch ms).
 */
export function hasPaidOrCardTrialSubscription(
  status: unknown,
  stripeSubscriptionId: unknown,
  trialEnd: unknown,
  nowMs: number = Date.now(),
): boolean {
  if (status === 'active') return true;
  if (status !== 'trialing' || !isNonEmptyString(stripeSubscriptionId)) return false;
  const trialEndMs = trialEndToMillis(trialEnd);
  return trialEndMs !== null && nowMs < trialEndMs + CARD_TRIAL_GRACE_MS;
}

/** [hasPaidOrCardTrialSubscription] for a `facilityCreatorAccounts` doc. */
export function accountHasPaidOrCardTrialSubscription(
  account: SubscriptionDocData,
  nowMs: number = Date.now(),
): boolean {
  if (!account) return false;
  return hasPaidOrCardTrialSubscription(
    account.subscriptionStatus,
    account.stripeSubscriptionId,
    account.subscriptionTrialEnd,
    nowMs,
  );
}

/** [hasPaidOrCardTrialSubscription] for a `facilities` doc's per-facility platform subscription. */
export function facilityHasPaidOrCardTrialSubscription(
  facility: SubscriptionDocData,
  nowMs: number = Date.now(),
): boolean {
  if (!facility) return false;
  return hasPaidOrCardTrialSubscription(
    facility.platformSubscriptionStatus,
    facility.stripePlatformSubscriptionId,
    facility.platformSubscriptionTrialEnd,
    nowMs,
  );
}

/**
 * Whether the owner is subscribed: through the account's own subscription, or through a
 * per-facility subscription on any of [facilities] (the caller picks them, normally the
 * facilities linked to the account).
 *
 * Under per-facility billing the account's status is a rollup of its facilities
 * (`subscription/accountRollup.ts`) and the account has no Stripe subscription id. During
 * a facility's free month the account therefore reads `trialing`, with the app trial's
 * end date, and only the facility shows that there is a card.
 */
export function ownerHasPaidOrCardTrialSubscription(
  account: SubscriptionDocData,
  facilities: readonly SubscriptionDocData[],
  nowMs: number = Date.now(),
): boolean {
  if (accountHasPaidOrCardTrialSubscription(account, nowMs)) return true;
  return facilities.some((facility) => facilityHasPaidOrCardTrialSubscription(facility, nowMs));
}

/**
 * The unpaid app trial: the account reads `trialing` and the owner has no paid or
 * card-backed subscription on the account or on any of [facilities].
 */
export function isUnpaidAppTrial(
  account: SubscriptionDocData,
  facilities: readonly SubscriptionDocData[],
  nowMs: number = Date.now(),
): boolean {
  if (!account || account.subscriptionStatus !== 'trialing') return false;
  return !ownerHasPaidOrCardTrialSubscription(account, facilities, nowMs);
}

/**
 * [isUnpaidAppTrial] for the owner of [facility], reading the account's other facilities
 * only when the account and [facility] do not already decide it (most sends are from
 * paying owners, whose account alone answers).
 * [loadLinkedFacilities] returns the facilities whose `facilityCreatorAccountId` is the
 * account's id. It is not called for an account that is not trialing.
 */
export async function ownerOnUnpaidAppTrial(
  account: SubscriptionDocData,
  facility: SubscriptionDocData,
  loadLinkedFacilities: () => Promise<SubscriptionDocData[]>,
  nowMs: number = Date.now(),
): Promise<boolean> {
  if (!isUnpaidAppTrial(account, [facility], nowMs)) return false;
  const linked = await loadLinkedFacilities();
  return isUnpaidAppTrial(account, [facility, ...linked], nowMs);
}
