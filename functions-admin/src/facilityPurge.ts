import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared/stripe/client';
import { getOrCreateAddOnPriceId, getOrCreateBasePriceId } from '@sfc/functions-shared/stripe/subscriptionPricing';
import {
  CancelOutcome,
  CancellableSubscription,
  anyCancelFailed,
  cancelSubscriptions,
  collectSubscriptionsToCancel,
} from '@sfc/functions-shared/stripe/subscriptionCleanup';

/**
 * Permanently removing one facility: shared by superAdminDeleteFacility and
 * the owner's deleteFacilityPermanently, so both leave nothing behind.
 *
 * The owner's delete used to run in the browser, subcollection by
 * subcollection, carrying on past any it could not delete and then deleting
 * the facility doc anyway. Tenant docs (names, ID numbers, portal codes)
 * were left with no facility to reach them through. Here the whole subtree
 * goes in one admin recursiveDelete, after the billing has been stopped.
 */

/** What the purge does outside Firestore; injected so tests need neither Stripe nor Storage. */
export interface FacilityPurgeDeps {
  /** Cancels these subscriptions, carrying on past individual failures. */
  cancelSubscriptions(subscriptions: CancellableSubscription[]): Promise<CancelOutcome[]>;
  /** Sets the legacy account subscription's quantities for [facilityCount] facilities. */
  alignAccountSubscription(subscriptionId: string, facilityCount: number): Promise<void>;
  /** Removes Storage objects under [prefix]. Best effort: never throws. */
  deleteStoragePrefix(prefix: string): Promise<void>;
}

/** A facility subscription could not be cancelled, so nothing was deleted. */
export class FacilityBillingNotStoppedError extends Error {
  constructor(readonly outcomes: CancelOutcome[]) {
    super('Could not cancel the facility subscriptions');
    this.name = 'FacilityBillingNotStoppedError';
  }
}

/**
 * Stops the facility's billing, then deletes its public map entry (when it
 * points here), takes it off its creator account (and realigns that
 * account's legacy subscription), removes its Storage files best effort,
 * and finally its whole Firestore subtree. [accountId] is the creator
 * account to take it off, or null.
 */
export async function purgeFacility(
  db: admin.firestore.Firestore,
  facilityRef: admin.firestore.DocumentReference,
  facilityData: Record<string, unknown>,
  deps: FacilityPurgeDeps,
  accountId: string | null,
): Promise<{ subscriptionOutcomes: CancelOutcome[] }> {
  const facilityId = facilityRef.id;

  // Stop the billing before removing the thing being billed for. Done first
  // on purpose: if the delete succeeded and this failed, the customer would
  // keep paying for a facility that no longer exists, and nothing would be
  // left to point at the charge.
  const subscriptionOutcomes = await deps.cancelSubscriptions(
    collectSubscriptionsToCancel(facilityData, null),
  );
  if (anyCancelFailed(subscriptionOutcomes)) {
    throw new FacilityBillingNotStoppedError(subscriptionOutcomes);
  }

  const metaSnap = await facilityRef.collection('mapEngine').doc('meta').get();
  const publicSlug = metaSnap.exists
    ? String(metaSnap.get('publicSlug') || '').trim().toLowerCase()
    : '';
  if (publicSlug) {
    const pubRef = db.collection('publicFacilityMaps').doc(publicSlug);
    const pubSnap = await pubRef.get();
    if (pubSnap.exists && String(pubSnap.get('facilityId') || '') === facilityId) {
      await db.recursiveDelete(pubRef);
    }
  }

  if (accountId) {
    const accRef = db.collection('facilityCreatorAccounts').doc(accountId);
    const accSnap = await accRef.get();
    if (accSnap.exists) {
      const accountData = accSnap.data() as Record<string, unknown>;
      const oldIds = (accountData.facilityIds as string[]) || [];
      const newIds = oldIds.filter((id) => id !== facilityId);

      const accUpdates: Record<string, unknown> = {
        facilityIds: admin.firestore.FieldValue.arrayRemove(facilityId),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      if (accountData.referralRewardPreferredFacilityId === facilityId) {
        accUpdates.referralRewardPreferredFacilityId = admin.firestore.FieldValue.delete();
      }
      await accRef.update(accUpdates);

      const subscriptionId = (accountData.stripeSubscriptionId as string | undefined)?.trim();
      if (subscriptionId) {
        await deps.alignAccountSubscription(subscriptionId, newIds.length);
      }
    }
  }

  await deps.deleteStoragePrefix(`facilities/${facilityId}/`);
  await db.recursiveDelete(facilityRef);
  return { subscriptionOutcomes };
}

/**
 * The legacy account plan: one base item plus one add-on per facility after
 * the first. Unchanged from superAdminDeleteFacility, where it lived inline.
 */
export async function alignAccountSubscriptionQuantity(
  stripe: Stripe,
  subscriptionId: string,
  facilityCount: number,
): Promise<void> {
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const basePriceId = process.env.STRIPE_BASE_PRICE_ID || (await getOrCreateBasePriceId(stripe));
  const addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || (await getOrCreateAddOnPriceId(stripe));
  const additionalFacilityCount = Math.max(0, facilityCount - 1);
  const baseItem = subscription.items.data.find((item: Stripe.SubscriptionItem) => item.price.id === basePriceId);
  const addOnItem = subscription.items.data.find((item: Stripe.SubscriptionItem) => item.price.id === addOnPriceId);
  const currentAddOnQty = addOnItem ? addOnItem.quantity : 0;
  if (baseItem?.quantity === 1 && currentAddOnQty === additionalFacilityCount) return;

  const updatesStripe: Stripe.SubscriptionUpdateParams = {
    items: [],
    proration_behavior: 'create_prorations',
  };
  if (baseItem) {
    updatesStripe.items!.push({ id: baseItem.id, quantity: 1 });
  } else {
    updatesStripe.items!.push({ price: basePriceId, quantity: 1 });
  }
  if (additionalFacilityCount > 0) {
    if (addOnItem) {
      updatesStripe.items!.push({ id: addOnItem.id, quantity: additionalFacilityCount });
    } else {
      updatesStripe.items!.push({ price: addOnPriceId, quantity: additionalFacilityCount });
    }
  } else if (addOnItem) {
    updatesStripe.items!.push({ id: addOnItem.id, deleted: true });
  }
  await stripe.subscriptions.update(subscriptionId, updatesStripe);
}

/**
 * Remove all Firebase Storage objects under [prefix] (contracts, documents,
 * branding, etc.). Best-effort: logs and does not throw so Firestore cleanup
 * can still proceed if Storage is unavailable.
 */
export async function deleteStoragePrefixBestEffort(prefix: string): Promise<void> {
  try {
    const bucket = admin.storage().bucket();
    await bucket.deleteFiles({ prefix, force: true });
    functions.logger.info('deleteFacilityStoragePrefix: removed objects', { prefix });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    functions.logger.warn('deleteFacilityStoragePrefix: failed (Firestore delete will still run)', {
      prefix,
      error: msg,
    });
  }
}

/** The production purge: live Stripe and the default Storage bucket. */
export function stripeFacilityPurgeDeps(): FacilityPurgeDeps {
  return {
    cancelSubscriptions: (subscriptions) =>
      subscriptions.length === 0
        ? Promise.resolve([])
        : cancelSubscriptions(getStripeClient(), subscriptions),
    alignAccountSubscription: (subscriptionId, facilityCount) =>
      alignAccountSubscriptionQuantity(getStripeClient(), subscriptionId, facilityCount),
    deleteStoragePrefix: deleteStoragePrefixBestEffort,
  };
}
