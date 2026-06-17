import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  enforceAppCheckOrThrow,
  getOrCreateAddOnPriceId,
  getOrCreateBasePriceId,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

export function facilityIdsInSync(current: string[], actual: string[]): boolean {
  const currentSet = new Set(current);
  const actualSet = new Set(actual);
  return currentSet.size === actualSet.size && actual.every((id) => currentSet.has(id));
}

export function additionalFacilityAddonQuantity(facilityCount: number): number {
  return Math.max(0, facilityCount - 1);
}

/**
 * Reconcile account.facilityIds with facilities linked to this account (server-side).
 * Uses facilityCreatorAccountId so intentionally-removed facilities stay removed.
 */
export const reconcileAccountFacilityIds = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (_data: unknown, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);
  const uid = context.auth.uid;
  const db = admin.firestore();

  const accountSnap = await db.collection('facilityCreatorAccounts').where('ownerUid', '==', uid).limit(1).get();
  if (accountSnap.empty) {
    throw new functions.https.HttpsError('not-found', 'No account found for user');
  }
  const accountDoc = accountSnap.docs[0];
  const accountId = accountDoc.id;
  const accountData = accountDoc.data();

  const facilitiesSnap = await db
    .collection('facilities')
    .where('facilityCreatorAccountId', '==', accountId)
    .where('active', '==', true)
    .get();
  const actualIds = facilitiesSnap.docs.map((d) => d.id);

  const current = (accountData.facilityIds as string[]) || [];
  if (facilityIdsInSync(current, actualIds)) {
    functions.logger.info(`reconcileAccountFacilityIds: already in sync, facilityCount=${actualIds.length}`);
    return { success: true, facilityCount: actualIds.length, updated: false };
  }

  await db.collection('facilityCreatorAccounts').doc(accountId).update({
    facilityIds: actualIds,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  functions.logger.info(`reconcileAccountFacilityIds: ${current.length} -> ${actualIds.length} for account ${accountId}`);

  const subscriptionId = accountData.stripeSubscriptionId as string | undefined;
  if (subscriptionId) {
    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);
    const basePriceId = process.env.STRIPE_BASE_PRICE_ID || (await getOrCreateBasePriceId(stripe));
    const addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || (await getOrCreateAddOnPriceId(stripe));
    const facilityCount = actualIds.length;
    const additionalFacilityCount = additionalFacilityAddonQuantity(facilityCount);
    const baseItem = subscription.items.data.find((item) => item.price.id === basePriceId);
    const addOnItem = subscription.items.data.find((item) => item.price.id === addOnPriceId);
    const currentAddOnQty = addOnItem ? addOnItem.quantity : 0;
    if (baseItem?.quantity === 1 && currentAddOnQty === additionalFacilityCount) {
      functions.logger.info(`reconcileAccountFacilityIds: Stripe already in sync for account ${accountId}`);
    } else {
      const updates: { items: Record<string, unknown>[]; proration_behavior: string } = {
        items: [],
        proration_behavior: 'create_prorations',
      };
      if (baseItem) {
        updates.items.push({ id: baseItem.id, quantity: 1 });
      } else {
        updates.items.push({ price: basePriceId, quantity: 1 });
      }
      if (additionalFacilityCount > 0) {
        if (addOnItem) {
          updates.items.push({ id: addOnItem.id, quantity: additionalFacilityCount });
        } else {
          updates.items.push({ price: addOnPriceId, quantity: additionalFacilityCount });
        }
      } else if (addOnItem) {
        updates.items.push({ id: addOnItem.id, deleted: true });
      }
      await stripe.subscriptions.update(subscriptionId, updates as any);
      functions.logger.info(`reconcileAccountFacilityIds: Stripe updated for account ${accountId}, facilityCount=${facilityCount}`);
    }
  }

  return { success: true, facilityCount: actualIds.length, updated: true };
});
