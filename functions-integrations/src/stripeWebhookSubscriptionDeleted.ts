import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  hasActiveWebsiteAdminTrial,
  isWebsiteAddonSubscription,
} from './stripeWebhookSubscriptionInternal';

export async function handleSubscriptionDeleted(subscription: Stripe.Subscription) {
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;

  if (facilityId && isWebsiteAddonSubscription(subscription)) {
    const db = admin.firestore();
    const facilityRef = db.collection('facilities').doc(facilityId);
    await db.runTransaction(async (transaction) => {
      const facilitySnap = await transaction.get(facilityRef);
      if (!facilitySnap.exists) {
        throw new Error(`Facility ${facilityId} not found`);
      }
      const adminTrialActive = hasActiveWebsiteAdminTrial(
        (facilitySnap.data() || {}) as Record<string, unknown>,
      );
      transaction.update(facilityRef, {
        websiteSubscriptionStatus: 'cancelled',
        stripeWebsiteSubscriptionId: admin.firestore.FieldValue.delete(),
        websiteSubscriptionCurrentPeriodEnd: admin.firestore.FieldValue.delete(),
        websiteSubscriptionCancelAtPeriodEnd: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      if (!adminTrialActive) {
        transaction.set(
          facilityRef.collection('settings').doc('public'),
          {
            enabled: false,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            updatedBy: 'stripeWebhook',
          },
          { merge: true },
        );
      }
    });
    functions.logger.info(`Facility ${facilityId} website subscription cancelled`);
    return;
  }

  if (facilityId && !tenantId) {
    await admin.firestore().collection('facilities').doc(facilityId).update({
      platformSubscriptionStatus: 'cancelled',
      stripePlatformSubscriptionId: admin.firestore.FieldValue.delete(),
      platformSubscriptionCurrentPeriodEnd: admin.firestore.FieldValue.delete(),
      platformSubscriptionCancelAtPeriodEnd: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Facility ${facilityId} platform subscription cancelled`);
    return;
  }

  if (accountId) {
    await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
      subscriptionStatus: 'cancelled',
      subscriptionCanceledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Subscription cancelled for account: ${accountId}`);
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
    await billingRef.update({
      autopayEnabled: false,
      stripeSubscriptionId: null,
      nextDueAt: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Tenant autopay subscription cancelled: ${subscription.id} for tenant ${tenantId}`);
  }
}
