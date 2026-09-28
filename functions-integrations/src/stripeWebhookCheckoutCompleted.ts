import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  FIRST_MONTH_FREE_COUPON_ID,
  FIRST_MONTH_FREE_METADATA_KEY,
  getStripeClient,
} from '@sfc/functions-shared';
import {
  recordPlatformOfferUsage,
  updateAccountFromSubscription,
  updateFacilityFromPlatformSubscription,
  updateFacilityFromWebsiteSubscription,
} from './stripeWebhookSubscriptionInternal';
import { reconcileAccountSubscription } from './accountSubscriptionReconcile';

/**
 * Did this completed platform checkout carry the first-month-free coupon? Read from the
 * session's discounts (coupon id or expanded coupon) or the metadata flag checkout sets.
 * The trial marker comes from the subscription itself (see updateAccountFromSubscription).
 */
export function platformOfferUsageFromCheckoutSession(session: Stripe.Checkout.Session): {
  trialUsed: boolean;
  firstMonthFreeUsed: boolean;
} {
  const discountHasCoupon = (session.discounts ?? []).some((d) => {
    const coupon = d?.coupon;
    const id = typeof coupon === 'string' ? coupon : coupon?.id;
    return id === FIRST_MONTH_FREE_COUPON_ID;
  });
  return {
    trialUsed: false,
    firstMonthFreeUsed: discountHasCoupon || session.metadata?.[FIRST_MONTH_FREE_METADATA_KEY] === 'true',
  };
}

export async function handleCheckoutCompleted(session: Stripe.Checkout.Session) {
  const accountId = session.metadata?.accountId;
  const facilityId = session.metadata?.facilityId;
  if (!accountId) {
    functions.logger.error('No accountId in checkout session metadata');
    return;
  }

  const subscriptionId = session.subscription as string;
  if (!subscriptionId) {
    functions.logger.error('No subscription ID in checkout session');
    return;
  }

  if (facilityId && session.metadata?.subscriptionType === 'website_addon') {
    const subscription = await getStripeClient().subscriptions.retrieve(subscriptionId);
    await updateFacilityFromWebsiteSubscription(facilityId, subscription);
    return;
  }

  // A completed platform checkout that carried the coupon has used the owner's one free month.
  // The subscription events record the same thing from the subscription's metadata, so
  // a failure here is logged rather than failing (and replaying) the whole event.
  try {
    await recordPlatformOfferUsage(admin.firestore(), accountId, platformOfferUsageFromCheckoutSession(session));
  } catch (err: unknown) {
    functions.logger.error('Could not record first-month-free usage from checkout', { accountId, err });
  }

  if (facilityId) {
    await updateFacilityFromPlatformSubscription(facilityId, subscriptionId);
    const accountDoc = await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).get();
    if (accountDoc.exists) {
      const facilityIds = (accountDoc.data()?.facilityIds as string[]) || [];
      if (!facilityIds.includes(facilityId)) {
        await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
          facilityIds: admin.firestore.FieldValue.arrayUnion(facilityId),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }
    // Roll the new facility subscription up to the account, which this branch
    // previously skipped entirely.
    await reconcileAccountSubscription(accountId);
    return;
  }

  await updateAccountFromSubscription(accountId, subscriptionId);
}
