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
import { PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION } from '@sfc/functions-shared/stripe/completePublicLinkPayment';
import { STRIPE_WEBHOOK_REFUSALS_COLLECTION } from '@sfc/functions-shared/stripe/webhookRefusals';
import {
  LegacyCancelOutcome,
  LegacySubscriptionStripe,
  cancelLegacyAutopaySubscription,
  legacySubscriptionId,
} from '@sfc/functions-shared/stripe/legacyTenantAutopay';

/** Tenant collections a facility may have; oldTenants is the legacy one. */
export const TENANT_COLLECTIONS = ['tenants', 'oldTenants'] as const;
export type TenantCollection = (typeof TENANT_COLLECTIONS)[number];

/** billing/default docs read per getAll. */
const BILLING_READ_BATCH = 300;

/** One tenant's billing/default doc, as [tenantBillingDocs] reads it. */
export type TenantBilling = {
  collection: TenantCollection;
  tenantId: string;
  tenant: Record<string, unknown>;
  billing: Record<string, unknown>;
};

/**
 * Every tenant's billing/default doc that exists, in both tenant
 * collections, active or not. Tenant docs are read with their name only.
 */
export async function tenantBillingDocs(
  db: admin.firestore.Firestore,
  facilityRef: admin.firestore.DocumentReference,
): Promise<TenantBilling[]> {
  const out: TenantBilling[] = [];
  for (const collection of TENANT_COLLECTIONS) {
    const tenants = (await facilityRef.collection(collection).select('name').get()).docs;
    for (let i = 0; i < tenants.length; i += BILLING_READ_BATCH) {
      const batch = tenants.slice(i, i + BILLING_READ_BATCH);
      const billing = await db.getAll(...batch.map((t) => t.ref.collection('billing').doc('default')));
      billing.forEach((snap, j) => {
        if (!snap.exists) return;
        out.push({ collection, tenantId: batch[j].id, tenant: batch[j].data(), billing: snap.data() || {} });
      });
    }
  }
  return out;
}

/**
 * Cancels the tenants' legacy AutoPay subscriptions in [docs], once each
 * ([seen] carries the ids already handled across facilities, for an account
 * delete). They are on the platform Stripe account, so deleting the
 * facility doesn't stop them: a super admin's delete (which skips the
 * owner's autopay refusal) left them charging tenants with no record
 * anywhere.
 *
 * Through cancelLegacyAutopaySubscription, as every other place that
 * switches this AutoPay off: one Stripe says is gone, or looks up as
 * canceled or incomplete_expired, counts as cancelled. The generic
 * cancelSubscriptions knows an ended subscription only by its error's code
 * or wording, so a subscription ended long ago whose cancel error was
 * worded otherwise read as 'failed' on every try, and the purge refused
 * (FacilityBillingNotStoppedError) for good.
 */
export async function cancelTenantLegacySubscriptions(
  stripe: () => LegacySubscriptionStripe,
  facilityId: string,
  docs: TenantBilling[],
  seen: Set<string> = new Set(),
): Promise<CancelOutcome[]> {
  const outcomes: CancelOutcome[] = [];
  for (const doc of docs) {
    const id = legacySubscriptionId(doc.billing);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    let outcome: LegacyCancelOutcome;
    let error = 'not cancelled; it may still be billing';
    try {
      outcome = await cancelLegacyAutopaySubscription(stripe, { facilityId, tenantId: doc.tenantId }, doc.billing);
    } catch (e: unknown) {
      // No Stripe client (a missing key): nothing was cancelled.
      outcome = 'failed';
      error = e instanceof Error ? e.message : String(e);
    }
    outcomes.push(
      outcome === 'failed'
        ? { id, label: 'tenant-autopay', status: 'failed', error }
        : { id, label: 'tenant-autopay', status: 'canceled' },
    );
  }
  return outcomes;
}

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
  /**
   * The platform Stripe client the tenants' legacy AutoPay subscriptions
   * are cancelled with (cancelTenantLegacySubscriptions). Only called when
   * a tenant has one.
   */
  legacyAutopayStripe(): LegacySubscriptionStripe;
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
 * Stops the facility's billing, then takes it off its creator account (and
 * realigns that account's legacy subscription), deletes the top-level rows
 * keyed by it (roles, public reservations and payment links, domain claims,
 * public map docs), removes its Storage files and exports best effort, and
 * finally its whole Firestore subtree. [accountId] is the creator account to take it off, or
 * null.
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
  // left to point at the charge. Its tenants' legacy AutoPay subscriptions
  // too (cancelTenantLegacySubscriptions), for the same reason.
  const subscriptionOutcomes = [
    ...(await deps.cancelSubscriptions(collectSubscriptionsToCancel(facilityData, null))),
    ...(await cancelTenantLegacySubscriptions(
      () => deps.legacyAutopayStripe(),
      facilityId,
      await tenantBillingDocs(db, facilityRef),
    )),
  ];
  if (anyCancelFailed(subscriptionOutcomes)) {
    throw new FacilityBillingNotStoppedError(subscriptionOutcomes);
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

  // Before the subtree, so a failure here leaves the facility doc for a
  // retry to find.
  await deleteFacilityKeyedRecords(db, facilityId);

  await deps.deleteStoragePrefix(`facilities/${facilityId}/`);
  // Tenant, payment and audit-log CSV exports. The daily cleanup finds them
  // through facilities/{id}/exportJobs, which the recursiveDelete below
  // removes, so anything left here would stay in the bucket for good.
  await deps.deleteStoragePrefix(`exports/${facilityId}/`);
  await db.recursiveDelete(facilityRef);
  return { subscriptionOutcomes };
}

/**
 * Stops every subscription behind a facility creator account before it is
 * deleted (superAdminDeleteFacilityCreatorAccount): each of [facilities]'
 * own and the account's legacy plan, deduped so one shared by two
 * facilities is cancelled once, then each facility's tenants' legacy
 * AutoPay subscriptions (cancelTenantLegacySubscriptions). The caller
 * deletes nothing when any outcome failed.
 */
export async function stopAccountBilling(
  db: admin.firestore.Firestore,
  facilities: admin.firestore.QueryDocumentSnapshot[],
  accountData: Record<string, unknown>,
  deps: Pick<FacilityPurgeDeps, 'cancelSubscriptions' | 'legacyAutopayStripe'>,
): Promise<CancelOutcome[]> {
  const subscriptions = [
    ...facilities.flatMap((f) => collectSubscriptionsToCancel(f.data() as Record<string, unknown>, null)),
    ...collectSubscriptionsToCancel(null, accountData),
  ].filter((sub, i, list) => list.findIndex((other) => other.id === sub.id) === i);
  const outcomes = [...(await deps.cancelSubscriptions(subscriptions))];
  const seen = new Set(subscriptions.map((s) => s.id));
  for (const f of facilities) {
    outcomes.push(
      ...(await cancelTenantLegacySubscriptions(
        () => deps.legacyAutopayStripe(),
        f.id,
        await tenantBillingDocs(db, f.ref),
        seen,
      )),
    );
  }
  return outcomes;
}

/**
 * Top-level collections whose rows each name one facility in `facilityId`:
 * a staff role at it, a public reservation or payment link for it, a
 * custom domain it claimed, a public map doc (one per slug it has had).
 * Outside the facility's subtree, so the recursiveDelete missed them: roles
 * kept pointing former staff at a facility that no longer existed, payment
 * links kept tenants' names and amounts, and a claimed hostname could never
 * be claimed again. Public map docs went only for the current slug (from
 * mapEngine/meta), so every slug the facility had moved away from stayed
 * world readable, name, units and prices, and stayed reserved.
 */
export const FACILITY_KEYED_COLLECTIONS = [
  'publicFacilityMaps',
  'user_roles',
  'publicReservations',
  'publicPaymentLinks',
  'customDomainClaims',
  // Link payments staff must look at, and refused Stripe money events: both
  // carry the facility's tenant ids and amounts, like the links.
  PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION,
  STRIPE_WEBHOOK_REFUSALS_COLLECTION,
  // The webhook's processed-event marks name the facility and tenant too.
  // Platform purge already wipes them; a facility or account delete left them.
  'stripeWebhookEvents',
  // One per online move-in payment: the tenant it moved in and the amount,
  // and, for one refunded or disputed before the move-in completed, the
  // refund or dispute the Stripe webhook recorded there.
  'publicMoveInPayments',
] as const;

/** Deletes every row of [FACILITY_KEYED_COLLECTIONS] whose facilityId is [facilityId]. */
export async function deleteFacilityKeyedRecords(
  db: admin.firestore.Firestore,
  facilityId: string,
): Promise<Record<string, number>> {
  const deleted: Record<string, number> = {};
  for (const collection of FACILITY_KEYED_COLLECTIONS) {
    deleted[collection] = 0;
    // A page at a time: deleted rows drop out of the next query.
    for (;;) {
      const page = await db.collection(collection).where('facilityId', '==', facilityId).limit(400).get();
      if (page.empty) break;
      const batch = db.batch();
      for (const doc of page.docs) batch.delete(doc.ref);
      await batch.commit();
      deleted[collection] += page.size;
    }
  }
  return deleted;
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
    legacyAutopayStripe: () => getStripeClient(),
    alignAccountSubscription: (subscriptionId, facilityCount) =>
      alignAccountSubscriptionQuantity(getStripeClient(), subscriptionId, facilityCount),
    deleteStoragePrefix: deleteStoragePrefixBestEffort,
  };
}
