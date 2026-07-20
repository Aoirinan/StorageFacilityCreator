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

export function isWebsiteAddonSubscription(subscription: Stripe.Subscription): boolean {
  return subscription.metadata?.subscriptionType === 'website_addon';
}

export async function updateFacilityFromWebsiteSubscription(
  facilityId: string,
  subscription: Stripe.Subscription,
): Promise<void> {
  const status = mapSubscriptionStatus(subscription.status);
  const isEntitled = status === 'active' || status === 'trialing';
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  const settingsRef = facilityRef.collection('settings').doc('public');
  const batch = db.batch();

  batch.update(facilityRef, {
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
    batch.set(
      settingsRef,
      {
        enabled: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedBy: 'stripeWebhook',
      },
      { merge: true },
    );
  }
  await batch.commit();
  functions.logger.info('Facility website subscription updated', {
    facilityId,
    subscriptionId: subscription.id,
    status,
    isEntitled,
  });
}

export async function updateFacilityFromPlatformSubscription(facilityId: string, subscriptionId: string) {
  try {
    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);
    const status = mapSubscriptionStatus(subscription.status);

    await admin.firestore().collection('facilities').doc(facilityId).update({
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
    functions.logger.info(`Facility ${facilityId} updated from platform subscription ${subscriptionId}`);
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
