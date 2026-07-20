import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  isWebsiteAddonSubscription,
  subPeriodEnd,
  updateAccountFromSubscription,
  updateFacilityFromPlatformSubscription,
  updateFacilityFromWebsiteSubscription,
} from './stripeWebhookSubscriptionInternal';

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
    return;
  }

  if (accountId && !facilityId) {
    await updateAccountFromSubscription(accountId, subscription.id);
    return;
  }

  if (facilityId && tenantId) {
    const billingRef = admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('billing')
      .doc('default');
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
