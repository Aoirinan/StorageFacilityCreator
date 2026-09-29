import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  getStripeClient,
  platformOfferMarkerUpdates,
  platformOfferUsageFromSubscription,
} from '@sfc/functions-shared';

// Stripe v20 types: Subscription/Invoice may have stricter Expandable types; these fields exist at runtime
type SubscriptionWithPeriod = Stripe.Subscription & { current_period_end?: number; current_period_start?: number };

function mapSubscriptionStatus(status: Stripe.Subscription.Status): string {
  switch (status) {
    case 'active':
      return 'active';
    case 'past_due':
      return 'pastDue';
    case 'canceled':
      return 'cancelled';
    case 'trialing':
      return 'trialing';
    case 'incomplete':
      return 'incomplete';
    case 'incomplete_expired':
      return 'incompleteExpired';
    case 'unpaid':
      return 'unpaid';
    default:
      return status;
  }
}

export function subPeriodEnd(sub: Stripe.Subscription): number | undefined {
  return (sub as SubscriptionWithPeriod).current_period_end;
}

function subPeriodStart(sub: Stripe.Subscription): number | undefined {
  return (sub as SubscriptionWithPeriod).current_period_start;
}

export function invoiceSubscriptionId(inv: Stripe.Invoice): string | null {
  const sub = (inv as Stripe.Invoice & { subscription?: string | Stripe.Subscription | null }).subscription;
  return typeof sub === 'string' ? sub : (sub as Stripe.Subscription)?.id ?? null;
}

/**
 * Updates [ref] only if it still exists; false when it doesn't. A facility
 * or account delete cancels its subscriptions and then deletes the docs, so
 * their Stripe events can arrive after the docs are gone. A plain update
 * failed with NOT_FOUND and Stripe retried the event for days.
 */
export async function updateIfExists(
  ref: admin.firestore.DocumentReference,
  fields: admin.firestore.UpdateData<admin.firestore.DocumentData>,
): Promise<boolean> {
  return ref.firestore.runTransaction(async (transaction) => {
    if (!(await transaction.get(ref)).exists) return false;
    transaction.update(ref, fields);
    return true;
  });
}

export function isWebsiteAddonSubscription(subscription: Stripe.Subscription): boolean {
  return subscription.metadata?.subscriptionType === 'website_addon';
}

export function hasActiveWebsiteAdminTrial(
  data: Record<string, unknown>,
  nowMs = Date.now(),
): boolean {
  const value = data.websiteAdminTrialEndsAt;
  return value instanceof admin.firestore.Timestamp && value.toMillis() > nowMs;
}

export async function updateFacilityFromWebsiteSubscription(
  facilityId: string,
  subscription: Stripe.Subscription,
): Promise<void> {
  const status = mapSubscriptionStatus(subscription.status);
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  const stripeEntitled = status === 'active' || status === 'trialing';
  const settingsRef = facilityRef.collection('settings').doc('public');
  let isEntitled = stripeEntitled;
  const found = await db.runTransaction(async (transaction) => {
    const facilitySnap = await transaction.get(facilityRef);
    // Deleted (its subscriptions are cancelled first): throwing made Stripe
    // retry the event for days, and there is nothing left to update.
    if (!facilitySnap.exists) return false;
    isEntitled = stripeEntitled ||
      hasActiveWebsiteAdminTrial(
        (facilitySnap.data() || {}) as Record<string, unknown>,
      );
    transaction.update(facilityRef, {
      stripeWebsiteSubscriptionId: subscription.id,
      websiteSubscriptionStatus: status,
      websiteSubscriptionCurrentPeriodEnd: subPeriodEnd(subscription)
        ? admin.firestore.Timestamp.fromMillis(subPeriodEnd(subscription)! * 1000)
        : null,
      websiteSubscriptionCancelAtPeriodEnd: subscription.cancel_at_period_end,
      websiteCheckoutSessionId: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (!isEntitled) {
      transaction.set(
        settingsRef,
        {
          enabled: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedBy: 'stripeWebhook',
        },
        { merge: true },
      );
    }
    return true;
  });
  if (!found) {
    functions.logger.info('Website subscription event for a deleted facility; nothing to update', {
      facilityId,
      subscriptionId: subscription.id,
    });
    return;
  }
  functions.logger.info('Facility website subscription updated', {
    facilityId,
    subscriptionId: subscription.id,
    status,
    isEntitled,
  });
}

/** Tests pass a fake Firestore and Stripe client; webhooks pass nothing. */
export type PlatformSubscriptionWebhookDeps = {
  db?: FirebaseFirestore.Firestore;
  stripe?: Stripe;
};

/**
 * Records, once and for good, that this owner used the trial and/or the first free
 * month. Markers already set are left alone, and nothing here ever clears one.
 */
export async function recordPlatformOfferUsage(
  db: FirebaseFirestore.Firestore,
  accountId: string,
  usage: { trialUsed: boolean; firstMonthFreeUsed: boolean },
): Promise<void> {
  if (!accountId || (!usage.trialUsed && !usage.firstMonthFreeUsed)) return;
  const accountRef = db.collection('facilityCreatorAccounts').doc(accountId);
  const written = await db.runTransaction(async (transaction) => {
    const snap = await transaction.get(accountRef);
    if (!snap.exists) return null;
    const markers = platformOfferMarkerUpdates(
      (snap.data() ?? {}) as Record<string, unknown>,
      usage,
      admin.firestore.FieldValue.serverTimestamp(),
    );
    if (Object.keys(markers).length === 0) return {};
    transaction.update(accountRef, markers);
    return markers;
  });
  if (written && Object.keys(written).length > 0) {
    functions.logger.info('Recorded platform offer usage', { accountId, markers: Object.keys(written) });
  }
}

export async function updateFacilityFromPlatformSubscription(
  facilityId: string,
  subscriptionId: string,
  deps: PlatformSubscriptionWebhookDeps = {},
) {
  try {
    const db = deps.db ?? admin.firestore();
    const facilityRef = db.collection('facilities').doc(facilityId);
    // Deleted: nothing to update, so no Stripe read and no NOT_FOUND error.
    const facilitySnap = await facilityRef.get();
    if (!facilitySnap.exists) {
      functions.logger.info(`Platform subscription ${subscriptionId} event for deleted facility ${facilityId}; nothing to update`);
      return;
    }
    const stripe = deps.stripe ?? getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);
    const status = mapSubscriptionStatus(subscription.status);

    const updated = await updateIfExists(facilityRef, {
      stripePlatformSubscriptionId: subscriptionId,
      platformSubscriptionStatus: status,
      platformSubscriptionCurrentPeriodStart: subPeriodStart(subscription)
        ? admin.firestore.Timestamp.fromMillis(subPeriodStart(subscription)! * 1000)
        : null,
      platformSubscriptionCurrentPeriodEnd: subPeriodEnd(subscription)
        ? admin.firestore.Timestamp.fromMillis(subPeriodEnd(subscription)! * 1000)
        : null,
      platformSubscriptionCancelAtPeriodEnd: subscription.cancel_at_period_end,
      // Never null an existing trial end: it is this facility's record that its trial happened.
      ...(subscription.trial_end
        ? { platformSubscriptionTrialEnd: admin.firestore.Timestamp.fromMillis(subscription.trial_end * 1000) }
        : {}),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(
      updated
        ? `Facility ${facilityId} updated from platform subscription ${subscriptionId}`
        : `Facility ${facilityId} deleted while platform subscription ${subscriptionId} was read; nothing updated`,
    );
    const accountId =
      (subscription.metadata?.accountId as string | undefined) ||
      (facilitySnap.get('facilityCreatorAccountId') as string | undefined) ||
      '';
    if (!accountId) {
      functions.logger.warn('Platform subscription has no account to record offer usage on', { facilityId, subscriptionId });
    }
    await recordPlatformOfferUsage(db, accountId, platformOfferUsageFromSubscription(subscription));
  } catch (error: any) {
    functions.logger.error(`Error updating facility from subscription: ${error.message}`, error);
  }
}

/**
 * Account fields mirrored from an account-level platform subscription, plus the offer
 * markers. A subscription without a trial never nulls an existing
 * `subscriptionTrialEnd`: that date is the record that the owner's one trial happened.
 * A subscription carrying the free month moves `subscriptionTrialEnd` to the end of the
 * free month (its Stripe `trial_end`). The app reads a `trialing` account whose trial end
 * has passed as expired, so leaving the app trial's end there would lock the owner out
 * for the free month.
 */
export function accountUpdateFromPlatformSubscription(
  subscription: Stripe.Subscription,
  existingAccount: Record<string, unknown>,
): Record<string, unknown> {
  const update: Record<string, unknown> = {
    subscriptionStatus: mapSubscriptionStatus(subscription.status),
    stripeSubscriptionId: subscription.id,
    subscriptionCurrentPeriodStart: subPeriodStart(subscription)
      ? admin.firestore.Timestamp.fromMillis(subPeriodStart(subscription)! * 1000)
      : null,
    subscriptionCurrentPeriodEnd: subPeriodEnd(subscription)
      ? admin.firestore.Timestamp.fromMillis(subPeriodEnd(subscription)! * 1000)
      : null,
    subscriptionCancelAtPeriodEnd: subscription.cancel_at_period_end,
    subscriptionCanceledAt: subscription.canceled_at
      ? admin.firestore.Timestamp.fromMillis(subscription.canceled_at * 1000)
      : null,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    ...platformOfferMarkerUpdates(
      existingAccount,
      platformOfferUsageFromSubscription(subscription),
      admin.firestore.FieldValue.serverTimestamp(),
    ),
  };
  if (subscription.trial_end) {
    update.subscriptionTrialEnd = admin.firestore.Timestamp.fromMillis(subscription.trial_end * 1000);
  }
  return update;
}

export async function updateAccountFromSubscription(
  accountId: string,
  subscriptionId: string,
  deps: PlatformSubscriptionWebhookDeps = {},
) {
  try {
    const db = deps.db ?? admin.firestore();
    const stripe = deps.stripe ?? getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);
    const accountRef = db.collection('facilityCreatorAccounts').doc(accountId);

    const updated = await db.runTransaction(async (transaction) => {
      const snap = await transaction.get(accountRef);
      if (!snap.exists) return false;
      transaction.update(
        accountRef,
        accountUpdateFromPlatformSubscription(subscription, (snap.data() ?? {}) as Record<string, unknown>),
      );
      return true;
    });

    functions.logger.info(
      updated
        ? `Account ${accountId} updated from subscription ${subscriptionId}`
        : `Account ${accountId} not found for subscription ${subscriptionId}; nothing updated`,
    );
  } catch (error: any) {
    functions.logger.error(`Error updating account from subscription: ${error.message}`, error);
  }
}
