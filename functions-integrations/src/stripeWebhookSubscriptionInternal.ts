import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';

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

export async function updateFacilityFromPlatformSubscription(facilityId: string, subscriptionId: string) {
  try {
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    // Deleted: nothing to update, so no Stripe read and no NOT_FOUND error.
    if (!(await facilityRef.get()).exists) {
      functions.logger.info(`Platform subscription ${subscriptionId} event for deleted facility ${facilityId}; nothing to update`);
      return;
    }
    const stripe = getStripeClient();
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
      platformSubscriptionTrialEnd: subscription.trial_end
        ? admin.firestore.Timestamp.fromMillis(subscription.trial_end * 1000)
        : null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(
      updated
        ? `Facility ${facilityId} updated from platform subscription ${subscriptionId}`
        : `Facility ${facilityId} deleted while platform subscription ${subscriptionId} was read; nothing updated`,
    );
  } catch (error: any) {
    functions.logger.error(`Error updating facility from subscription: ${error.message}`, error);
  }
}

export async function updateAccountFromSubscription(accountId: string, subscriptionId: string) {
  try {
    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);
    const status = mapSubscriptionStatus(subscription.status);

    await admin
      .firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .update({
        subscriptionStatus: status,
        stripeSubscriptionId: subscriptionId,
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
        subscriptionTrialEnd: subscription.trial_end
          ? admin.firestore.Timestamp.fromMillis(subscription.trial_end * 1000)
          : null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Account ${accountId} updated from subscription ${subscriptionId}`);
  } catch (error: any) {
    functions.logger.error(`Error updating account from subscription: ${error.message}`, error);
  }
}
