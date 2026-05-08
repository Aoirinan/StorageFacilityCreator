import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { writeAuditLog } from '@sfc/functions-shared';

export type SubscriptionUpdatedInsteadOfCheckout = {
  subscriptionUpdated: true;
  checkoutUrl: null;
  message: string;
};

/**
 * If the account already has an active/trialing subscription, update Stripe item quantities
 * instead of creating a new Checkout session. Returns null to fall through to new checkout.
 */
export async function tryUpdateExistingSubscriptionInsteadOfCheckout(options: {
  stripe: Stripe;
  accountId: string;
  subscriptionId: string | undefined;
  subscriptionStatus: string;
  facilityCount: number;
  basePriceId: string;
  addOnPriceId: string;
  uid: string;
}): Promise<SubscriptionUpdatedInsteadOfCheckout | null> {
  const {
    stripe,
    accountId,
    subscriptionId,
    subscriptionStatus,
    facilityCount,
    basePriceId,
    addOnPriceId,
    uid,
  } = options;

  const additionalFacilityCount = Math.max(0, facilityCount - 1);
  const hasExistingSubscription =
    subscriptionId && (subscriptionStatus === 'trialing' || subscriptionStatus === 'active');

  if (!hasExistingSubscription || facilityCount <= 0 || !subscriptionId) {
    return null;
  }

  try {
    const subscription = await stripe.subscriptions.retrieve(subscriptionId, { expand: ['items.data.price'] });
    const getPriceId = (item: Stripe.SubscriptionItem): string =>
      typeof item.price === 'string' ? item.price : (item.price as Stripe.Price).id;
    const baseItem =
      subscription.items.data.find((item) => getPriceId(item) === basePriceId) ?? subscription.items.data[0];
    const addOnItem = subscription.items.data.find((item) => getPriceId(item) === addOnPriceId);
    const updates: Stripe.SubscriptionUpdateParams = {
      items: [],
      proration_behavior: 'create_prorations',
      cancel_at_period_end: false,
    };
    if (baseItem) {
      updates.items!.push({ id: baseItem.id, quantity: 1 });
    }
    if (additionalFacilityCount > 0) {
      if (addOnItem) {
        updates.items!.push({ id: addOnItem.id, quantity: additionalFacilityCount });
      } else {
        updates.items!.push({ price: addOnPriceId, quantity: additionalFacilityCount });
      }
    } else if (addOnItem) {
      updates.items!.push({ id: addOnItem.id, deleted: true });
    }
    await stripe.subscriptions.update(subscriptionId, updates);
    await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
      subscriptionCancelAtPeriodEnd: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info('Subscription updated for existing account instead of new checkout', {
      accountId,
      facilityCount,
      additionalFacilityCount,
    });
    await writeAuditLog(accountId, {
      action: 'subscription_updated_instead_of_checkout',
      userId: uid,
      facilityCount,
    });
    return {
      subscriptionUpdated: true,
      checkoutUrl: null,
      message:
        'Your subscription has been updated to include your new facility. You will see a prorated charge at your next billing date.',
    };
  } catch (updateError: any) {
    functions.logger.error('Error updating existing subscription, falling back to checkout', {
      error: updateError.message,
      accountId,
      subscriptionId,
    });
    return null;
  }
}
