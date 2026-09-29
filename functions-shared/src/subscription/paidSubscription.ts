/**
 * Whether a platform subscription counts as paid for.
 *
 * The first free month is Stripe trial time (`stripe/platformCheckoutTrial.ts`), so an
 * owner who subscribes with a card reads `trialing` for up to two months before the
 * first charge. Every entitlement treats that subscription exactly like `active`.
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

/** A Firestore document's data, or nothing. */
export type SubscriptionDocData = Record<string, unknown> | null | undefined;

function isNonEmptyString(value: unknown): boolean {
  return typeof value === 'string' && value.trim().length > 0;
}

/**
 * `active`, or `trialing` with a Stripe subscription behind it.
 *
 * [status] is an account's `subscriptionStatus` or a facility's
 * `platformSubscriptionStatus`. [stripeSubscriptionId] is the account's
 * `stripeSubscriptionId` or the facility's `stripePlatformSubscriptionId`.
 */
export function hasPaidOrCardTrialSubscription(status: unknown, stripeSubscriptionId: unknown): boolean {
  if (status === 'active') return true;
  return status === 'trialing' && isNonEmptyString(stripeSubscriptionId);
}

/** [hasPaidOrCardTrialSubscription] for a `facilityCreatorAccounts` doc. */
export function accountHasPaidOrCardTrialSubscription(account: SubscriptionDocData): boolean {
  if (!account) return false;
  return hasPaidOrCardTrialSubscription(account.subscriptionStatus, account.stripeSubscriptionId);
}

/** [hasPaidOrCardTrialSubscription] for a `facilities` doc's per-facility platform subscription. */
export function facilityHasPaidOrCardTrialSubscription(facility: SubscriptionDocData): boolean {
  if (!facility) return false;
  return hasPaidOrCardTrialSubscription(
    facility.platformSubscriptionStatus,
    facility.stripePlatformSubscriptionId,
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
): boolean {
  if (accountHasPaidOrCardTrialSubscription(account)) return true;
  return facilities.some((facility) => facilityHasPaidOrCardTrialSubscription(facility));
}

/**
 * The unpaid app trial: the account reads `trialing` and the owner has no paid or
 * card-backed subscription on the account or on any of [facilities].
 */
export function isUnpaidAppTrial(
  account: SubscriptionDocData,
  facilities: readonly SubscriptionDocData[],
): boolean {
  if (!account || account.subscriptionStatus !== 'trialing') return false;
  return !ownerHasPaidOrCardTrialSubscription(account, facilities);
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
): Promise<boolean> {
  if (!isUnpaidAppTrial(account, [facility])) return false;
  const linked = await loadLinkedFacilities();
  return isUnpaidAppTrial(account, [facility, ...linked]);
}
