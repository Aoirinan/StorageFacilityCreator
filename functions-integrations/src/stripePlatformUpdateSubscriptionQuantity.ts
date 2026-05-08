import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
  getOrCreateBasePriceId,
  getOrCreateAddOnPriceId,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Update subscription quantity based on facility count
 */
export const updateSubscriptionQuantity = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    const accountDoc = await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const subscriptionId = accountData.stripeSubscriptionId as string | undefined;
    if (!subscriptionId) {
      return { success: true, message: 'No active subscription to update' };
    }

    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);

    const facilityIds = (accountData.facilityIds as string[]) || [];
    const facilityCount = facilityIds.length;
    const additionalFacilityCount = Math.max(0, facilityCount - 1);

    const basePriceId = process.env.STRIPE_BASE_PRICE_ID || (await getOrCreateBasePriceId(stripe));
    const addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || (await getOrCreateAddOnPriceId(stripe));

    const baseItem = subscription.items.data.find((item) => item.price.id === basePriceId);
    const addOnItem = subscription.items.data.find((item) => item.price.id === addOnPriceId);

    const currentAddOnQty = addOnItem ? addOnItem.quantity : 0;
    if (baseItem?.quantity === 1 && currentAddOnQty === additionalFacilityCount) {
      functions.logger.info(`Subscription quantity already correct for account ${accountId}: ${facilityCount} facilities`);
      return {
        success: true,
        facilityCount: facilityCount,
        baseQuantity: 1,
        addOnQuantity: additionalFacilityCount,
      };
    }

    const updates: Stripe.SubscriptionUpdateParams = {
      items: [],
      proration_behavior: 'create_prorations',
    };

    if (baseItem) {
      updates.items!.push({
        id: baseItem.id,
        quantity: 1,
      });
    } else {
      updates.items!.push({
        price: basePriceId,
        quantity: 1,
      });
    }

    if (additionalFacilityCount > 0) {
      if (addOnItem) {
        updates.items!.push({
          id: addOnItem.id,
          quantity: additionalFacilityCount,
        });
      } else {
        updates.items!.push({
          price: addOnPriceId,
          quantity: additionalFacilityCount,
        });
      }
    } else if (addOnItem) {
      updates.items!.push({
        id: addOnItem.id,
        deleted: true,
      });
    }

    await stripe.subscriptions.update(subscriptionId, updates);

    functions.logger.info(
      `Subscription quantity updated for account ${accountId}: ${facilityCount} facilities (1 base + ${additionalFacilityCount} add-on)`,
    );

    return {
      success: true,
      facilityCount: facilityCount,
      baseQuantity: 1,
      addOnQuantity: additionalFacilityCount,
    };
  } catch (error: any) {
    functions.logger.error('Error updating subscription quantity', error);
    throw new functions.https.HttpsError('internal', `Failed to update subscription: ${error.message}`);
  }
});
