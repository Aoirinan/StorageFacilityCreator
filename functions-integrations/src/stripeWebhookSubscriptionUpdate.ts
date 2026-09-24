import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  isWebsiteAddonSubscription,
  subPeriodEnd,
  updateAccountFromSubscription,
  updateFacilityFromPlatformSubscription,
  updateFacilityFromWebsiteSubscription,
} from './stripeWebhookSubscriptionInternal';
import { reconcileAccountSubscription } from './accountSubscriptionReconcile';

export async function handleSubscriptionUpdate(subscription: Stripe.Subscription) {
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;

  if (facilityId && isWebsiteAddonSubscription(subscription)) {
    await updateFacilityFromWebsiteSubscription(facilityId, subscription);
    return;
  }

  if (facilityId && !tenantId) {
    await updateFacilityFromPlatformSubscription(facilityId, subscription.id);
    // The facility is now current; roll that up so the account stops reporting
    // whatever it last said before per-facility billing took over.
    await reconcileAccountSubscription(accountId ?? '');
    return;
  }

  if (accountId && !facilityId) {
    await updateAccountFromSubscription(accountId, subscription.id);
    return;
  }

  if (facilityId && tenantId) {
    const tenantRef = admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId);
    // A merge write under a deleted tenant (or facility) recreated a billing
    // doc that nothing in the app could reach.
    if (!(await tenantRef.get()).exists) {
      functions.logger.info('Autopay subscription event for a deleted tenant; nothing to update', {
        facilityId,
        tenantId,
        subscriptionId: subscription.id,
      });
      return;
    }
    const billingRef = tenantRef.collection('billing').doc('default');
    const periodEnd = subPeriodEnd(subscription);
    const nextDue = periodEnd ? admin.firestore.Timestamp.fromDate(new Date(periodEnd * 1000)) : null;
    await billingRef.set(
      {
        stripeSubscriptionId: subscription.id,
        autopayEnabled: subscription.status === 'active' || subscription.status === 'trialing',
        nextDueAt: nextDue,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  }
}
