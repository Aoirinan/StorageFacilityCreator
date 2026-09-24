import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  hasActiveWebsiteAdminTrial,
  isWebsiteAddonSubscription,
  updateIfExists,
} from './stripeWebhookSubscriptionInternal';
import { reconcileAccountSubscription } from './accountSubscriptionReconcile';

export async function handleSubscriptionDeleted(subscription: Stripe.Subscription) {
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;

  if (facilityId && isWebsiteAddonSubscription(subscription)) {
    const db = admin.firestore();
    const facilityRef = db.collection('facilities').doc(facilityId);
    const updated = await db.runTransaction(async (transaction) => {
      const facilitySnap = await transaction.get(facilityRef);
      // A facility delete cancels its subscriptions first, then removes the
      // facility, so this event can arrive after it is gone. Throwing here
      // made Stripe retry it for days; writing would recreate part of it.
      if (!facilitySnap.exists) return false;
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
      return true;
    });
    functions.logger.info(
      updated
        ? `Facility ${facilityId} website subscription cancelled`
        : `Website subscription ${subscription.id} cancelled for deleted facility ${facilityId}; nothing to update`,
    );
    return;
  }

  if (facilityId && !tenantId) {
    const updated = await updateIfExists(admin.firestore().collection('facilities').doc(facilityId), {
      platformSubscriptionStatus: 'cancelled',
      // Starts the offboarding grace period (see processFacilityOffboarding).
      platformSubscriptionCancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      stripePlatformSubscriptionId: admin.firestore.FieldValue.delete(),
      platformSubscriptionCurrentPeriodEnd: admin.firestore.FieldValue.delete(),
      platformSubscriptionCancelAtPeriodEnd: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(
      updated
        ? `Facility ${facilityId} platform subscription cancelled`
        : `Platform subscription ${subscription.id} cancelled for deleted facility ${facilityId}; nothing to update`,
    );
    // A cancelled site must not leave the account still claiming a live plan.
    // Still run for a deleted facility: the account rolls up from the
    // facilities it has left, and the delete itself does not do this.
    await reconcileAccountSubscription(accountId ?? '');
    return;
  }

  if (accountId) {
    // The super-admin account delete also cancels before it deletes.
    const updated = await updateIfExists(admin.firestore().collection('facilityCreatorAccounts').doc(accountId), {
      subscriptionStatus: 'cancelled',
      subscriptionCanceledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (updated) {
      functions.logger.info(`Subscription cancelled for account: ${accountId}`);
      // A cancellation is exactly when `stripeSubscriptionId` becomes a dead
      // pointer, so verify and clear it here rather than leaving the account
      // advertising a subscription that no longer exists.
      await reconcileAccountSubscription(accountId, { verifyStripeSubscription: true });
    } else {
      functions.logger.info(`Subscription ${subscription.id} cancelled for deleted account ${accountId}; nothing to update`);
    }
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
    // Gone with its tenant or facility: nothing left to switch off.
    const updated = await updateIfExists(billingRef, {
      autopayEnabled: false,
      stripeSubscriptionId: null,
      nextDueAt: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(
      updated
        ? `Tenant autopay subscription cancelled: ${subscription.id} for tenant ${tenantId}`
        : `Tenant autopay subscription ${subscription.id} cancelled; tenant ${tenantId} billing no longer exists`,
    );
  }
}
