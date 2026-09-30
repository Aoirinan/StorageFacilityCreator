import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  hasActiveWebsiteAdminTrial,
  isWebsiteAddonSubscription,
  updateIfExists,
} from './stripeWebhookSubscriptionInternal';
import { reconcileAccountSubscription } from './accountSubscriptionReconcile';

/**
 * The account fields a `customer.subscription.deleted` event for [subscriptionId] writes.
 *
 * The event itself proves the subscription is gone (a deleted subscription never comes
 * back), so when the account still points at it the pointer is cleared here too. The
 * reconcile pass after this only clears it once Stripe confirms, and leaves it on any
 * error other than "not found": cancelling in the free month then left the account
 * `trialing` (the rollup puts a cancelled account whose trial end is ahead back on its
 * trial) with a dead subscription id, which read as a paid card-backed trial. With the
 * pointer gone the account is the unpaid app trial until that trial end, then the
 * nightly sweep cancels it. A pointer to a different (newer) subscription is left alone.
 */
export function accountUpdateForDeletedSubscription<T>(
  account: Record<string, unknown>,
  subscriptionId: string,
  stamp: T,
): Record<string, unknown> {
  const update: Record<string, unknown> = {
    subscriptionStatus: 'cancelled',
    subscriptionCanceledAt: stamp,
    updatedAt: stamp,
  };
  const current = typeof account.stripeSubscriptionId === 'string' ? account.stripeSubscriptionId.trim() : '';
  if (subscriptionId && current === subscriptionId) {
    update.stripeSubscriptionId = null;
    update.stripeSubscriptionIdClearedAt = stamp;
    update.stripeSubscriptionIdClearedFrom = subscriptionId;
  }
  return update;
}

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
    const db = admin.firestore();
    const accountRef = db.collection('facilityCreatorAccounts').doc(accountId);
    const updated = await db.runTransaction(async (transaction) => {
      const snap = await transaction.get(accountRef);
      if (!snap.exists) return false;
      transaction.update(
        accountRef,
        accountUpdateForDeletedSubscription(
          (snap.data() ?? {}) as Record<string, unknown>,
          subscription.id,
          admin.firestore.FieldValue.serverTimestamp(),
        ),
      );
      return true;
    });
    if (updated) {
      functions.logger.info(`Subscription cancelled for account: ${accountId}`);
      // A cancellation is exactly when `stripeSubscriptionId` becomes a dead
      // pointer. The write above cleared it when it named this subscription;
      // any other pointer is verified with Stripe and cleared if dead.
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
