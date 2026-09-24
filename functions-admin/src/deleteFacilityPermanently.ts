import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { hasAutopaySubscription, tenantDisplayName } from '@sfc/functions-shared';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared/auth/appCheck';
import { summarizeCancelOutcomes } from '@sfc/functions-shared/stripe/subscriptionCleanup';
import { findOwnerAccountDoc } from '@sfc/functions-shared/platform/ownerAccount';
import {
  FacilityBillingNotStoppedError,
  FacilityPurgeDeps,
  purgeFacility,
  stripeFacilityPurgeDeps,
} from './facilityPurge';
import { DELETE_FACILITY_OTP_PURPOSE, consumeRecentTwoFactor } from './recentTwoFactor';
import { STRIPE_SECRETS } from './secrets';

/**
 * The owner's Delete facility (Facility management > Delete, behind the
 * typed confirmation and the email code). The app used to delete the
 * subcollections itself and skip any it couldn't, then delete the facility
 * doc: with tenant deletes now super-admin only in the rules, that left
 * every tenant doc behind. The rules now keep facility docs from being
 * deleted directly too, so this is the only way an owner can.
 */

export type DeleteFacilityDeps = {
  db: admin.firestore.Firestore;
  purge: FacilityPurgeDeps;
  nowMs: () => number;
};

export const FACILITY_BILLING_NOT_STOPPED_MESSAGE =
  "Nothing was deleted: we couldn't stop this facility's subscription billing. " +
  'Try again, and contact support if it keeps happening.';

export const FACILITY_DELETE_FAILED_MESSAGE =
  "The facility couldn't be fully deleted. Refresh the list to see what changed, then try again.";

/** The refusal while tenants are active; the app's pre-check words it the same way. */
export function facilityHasActiveTenantsMessage(count: number): string {
  const tenants = count === 1 ? '1 active tenant' : `${count} active tenants`;
  return (
    `Nothing was deleted: this facility still has ${tenants}. ` +
    'Move them out or archive them first, then delete the facility.'
  );
}

/** The refusal while tenants still have autopay set up, naming a few of them. */
export function facilityHasAutopayTenantsMessage(names: string[]): string {
  const shown = names.slice(0, 5);
  const more = names.length - shown.length;
  const who = more > 0 ? `${shown.join(', ')} and ${more} more` : shown.join(', ');
  const tenants = names.length === 1 ? '1 tenant' : `${names.length} tenants`;
  return (
    `Nothing was deleted: autopay is still set up for ${tenants} (${who}), ` +
    "and deleting the facility wouldn't stop it. Open each tenant and press " +
    'Disable autopay, then delete the facility.'
  );
}

/** Tenant collections a facility may have; oldTenants is the legacy one. */
const TENANT_COLLECTIONS = ['tenants', 'oldTenants'] as const;

/** billing/default docs read per getAll. */
const BILLING_READ_BATCH = 300;

/**
 * Names of the facility's tenants, active or not, whose autopay is still
 * set up: a Stripe subscription id or autopayEnabled on billing/default.
 * The purge cancels the facility's own subscriptions only, so a tenant's
 * (an archived tenant's, say) went on charging them after the facility and
 * every record of it were gone.
 */
export async function tenantsWithAutopay(
  db: admin.firestore.Firestore,
  facilityRef: admin.firestore.DocumentReference,
): Promise<string[]> {
  const names: string[] = [];
  for (const collection of TENANT_COLLECTIONS) {
    const tenants = (await facilityRef.collection(collection).select('name').get()).docs;
    for (let i = 0; i < tenants.length; i += BILLING_READ_BATCH) {
      const batch = tenants.slice(i, i + BILLING_READ_BATCH);
      const billing = await db.getAll(...batch.map((t) => t.ref.collection('billing').doc('default')));
      billing.forEach((snap, j) => {
        if (snap.exists && hasAutopaySubscription(snap.data())) {
          names.push(tenantDisplayName(batch[j].data(), batch[j].id));
        }
      });
    }
  }
  return names;
}

export function parseDeleteFacilityRequest(data: unknown): { facilityId: string } {
  const input = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>;
  const facilityId = typeof input.facilityId === 'string' ? input.facilityId.trim() : '';
  if (facilityId.length === 0 || facilityId.includes('/')) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }
  return { facilityId };
}

/** The creator account the facility bills through, else the owner's own (as the app used). */
async function accountIdFor(
  db: admin.firestore.Firestore,
  facility: Record<string, unknown>,
): Promise<string | null> {
  const linked = typeof facility.facilityCreatorAccountId === 'string' ? facility.facilityCreatorAccountId.trim() : '';
  if (linked) return linked;
  const ownerUid = typeof facility.ownerUid === 'string' ? facility.ownerUid : '';
  if (!ownerUid) return null;
  // The same preferred account (approved/active, then oldest) the app and
  // every other codebase use: limit(1) picked an arbitrary one when an owner
  // has duplicates.
  return (await findOwnerAccountDoc(db, ownerUid))?.id ?? null;
}

export async function deleteFacilityPermanentlyHandler(
  data: unknown,
  context: functions.https.CallableContext,
  deps: DeleteFacilityDeps,
): Promise<{ success: true }> {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);
  const { facilityId } = parseDeleteFacilityRequest(data);
  const uid = context.auth.uid;
  // The claim, as in the rules: an allowlisted email alone can be an
  // unverified password account.
  const superAdmin = context.auth.token?.superadmin === true;

  const { db } = deps;
  const facilityRef = db.collection('facilities').doc(facilityId);
  const facilitySnap = await facilityRef.get();
  if (!facilitySnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facility = (facilitySnap.data() || {}) as Record<string, unknown>;
  // Owner only, as the old delete rule: managers can't delete a facility.
  if (!superAdmin && facility.ownerUid !== uid) {
    throw new functions.https.HttpsError('permission-denied', 'Only the facility owner can delete it.');
  }

  // An owner's delete took every active tenant's ledger, invoices, liens and
  // contracts with it in one click, while a single tenant with any history
  // can't be deleted at all. Active tenants are moved out or archived first,
  // and any tenant's autopay is switched off. Checked before the email code
  // is spent. Active is exactly true, as in TenantModel and the server jobs.
  if (!superAdmin) {
    const active = await facilityRef.collection('tenants').where('isActive', '==', true).count().get();
    const count = active.data().count;
    if (count > 0) {
      throw new functions.https.HttpsError('failed-precondition', facilityHasActiveTenantsMessage(count), {
        reason: 'active-tenants',
        activeTenants: count,
      });
    }
    const autopay = await tenantsWithAutopay(db, facilityRef);
    if (autopay.length > 0) {
      throw new functions.https.HttpsError('failed-precondition', facilityHasAutopayTenantsMessage(autopay), {
        reason: 'tenant-autopay',
        tenants: autopay.length,
      });
    }
  }

  await consumeRecentTwoFactor(db, uid, DELETE_FACILITY_OTP_PURPOSE, 'deleteFacilityPermanently', deps.nowMs());

  const accountId = await accountIdFor(db, facility);
  try {
    const { subscriptionOutcomes } = await purgeFacility(db, facilityRef, facility, deps.purge, accountId);
    functions.logger.info('deleteFacilityPermanently', {
      facilityId,
      uid,
      superAdmin,
      accountId,
      subscriptions: summarizeCancelOutcomes(subscriptionOutcomes),
    });
  } catch (error: unknown) {
    if (error instanceof FacilityBillingNotStoppedError) {
      functions.logger.error('deleteFacilityPermanently: billing not stopped, nothing deleted', {
        facilityId,
        uid,
        outcomes: summarizeCancelOutcomes(error.outcomes),
      });
      throw new functions.https.HttpsError('failed-precondition', FACILITY_BILLING_NOT_STOPPED_MESSAGE);
    }
    if (error instanceof functions.https.HttpsError) throw error;
    functions.logger.error('deleteFacilityPermanently failed', {
      facilityId,
      uid,
      error: error instanceof Error ? error.message : String(error),
    });
    throw new functions.https.HttpsError('internal', FACILITY_DELETE_FAILED_MESSAGE);
  }
  return { success: true };
}

/** Production deps. The legacy account quantity sync is best effort, as it was in the app. */
function productionDeps(): DeleteFacilityDeps {
  const stripe = stripeFacilityPurgeDeps();
  return {
    db: admin.firestore(),
    nowMs: () => Date.now(),
    purge: {
      ...stripe,
      alignAccountSubscription: async (subscriptionId, facilityCount) => {
        try {
          await stripe.alignAccountSubscription(subscriptionId, facilityCount);
        } catch (error: unknown) {
          functions.logger.warn('deleteFacilityPermanently: account subscription not realigned', {
            subscriptionId,
            facilityCount,
            error: error instanceof Error ? error.message : String(error),
          });
        }
      },
    },
  };
}

export const deleteFacilityPermanently = functions
  .runWith({ secrets: STRIPE_SECRETS, timeoutSeconds: 540, memory: '512MB' })
  .https.onCall((data: unknown, context) => deleteFacilityPermanentlyHandler(data, context, productionDeps()));
