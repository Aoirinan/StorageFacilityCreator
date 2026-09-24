import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared/auth/appCheck';
import { summarizeCancelOutcomes } from '@sfc/functions-shared/stripe/subscriptionCleanup';
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
  const owned = await db.collection('facilityCreatorAccounts').where('ownerUid', '==', ownerUid).limit(1).get();
  return owned.empty ? null : owned.docs[0].id;
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
  // can't be deleted at all. Active tenants are moved out or archived first.
  // Checked before the email code is spent. Active is exactly true, as in
  // TenantModel and the server jobs.
  if (!superAdmin) {
    const active = await facilityRef.collection('tenants').where('isActive', '==', true).count().get();
    const count = active.data().count;
    if (count > 0) {
      throw new functions.https.HttpsError('failed-precondition', facilityHasActiveTenantsMessage(count), {
        reason: 'active-tenants',
        activeTenants: count,
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
