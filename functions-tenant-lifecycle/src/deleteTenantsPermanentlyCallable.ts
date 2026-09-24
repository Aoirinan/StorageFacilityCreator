import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { TenantDeleteDocData as DocData, enforceAppCheckOrThrow } from '@sfc/functions-shared';
import {
  DeleteTenantsResult,
  actorRoleOf,
  authorizePermanentTenantDelete,
  deleteTenantsInTransaction,
  firestoreTenantDeleteTransaction,
  parseDeleteTenantsRequest,
} from './tenantPermanentDelete';

/**
 * Permanently delete tenants entered by mistake, all or none. The only way
 * an owner or manager can delete a tenant doc: the rules allow it to super
 * admins alone. Refusals come back as { status: 'refused', blocked } for the
 * app to explain; see tenantPermanentDelete.ts.
 */
export const deleteTenantsPermanently = functions
  .runWith({ timeoutSeconds: 120 })
  .https.onCall(async (data: unknown, context): Promise<DeleteTenantsResult> => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);
    const { facilityId, tenantIds } = parseDeleteTenantsRequest(data);

    const uid = context.auth.uid;
    // The claim, as in the rules: an allowlisted email alone can be an
    // unverified password account.
    const superAdmin = context.auth.token?.superadmin === true;
    const db = admin.firestore();
    const facilitySnap = await db.collection('facilities').doc(facilityId).get();
    if (!facilitySnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }
    const facility = (facilitySnap.data() || {}) as DocData;
    const nowMs = Date.now();
    await authorizePermanentTenantDelete({
      uid,
      superAdmin,
      facility,
      nowMs,
      loadAccount: async (accountId) => {
        const snap = await db.collection('facilityCreatorAccounts').doc(accountId).get();
        return snap.exists ? ((snap.data() || {}) as DocData) : null;
      },
    });

    const actor = {
      uid,
      email: typeof context.auth.token?.email === 'string' ? context.auth.token.email : null,
      role: actorRoleOf(facility, uid, superAdmin),
    };
    try {
      const result = await db.runTransaction((tx) =>
        deleteTenantsInTransaction(firestoreTenantDeleteTransaction(db, tx, facilityId), {
          facilityId,
          tenantIds,
          actor,
          nowMs,
        }),
      );
      functions.logger.info('deleteTenantsPermanently', {
        facilityId,
        uid,
        requested: tenantIds.length,
        status: result.status,
        ...(result.status === 'deleted'
          ? { unitsUnlinked: result.unitsUnlinked, gateAccessDeactivated: result.gateAccessDeactivated }
          : { blocked: result.blocked.map((b) => b.tenantId) }),
      });
      return result;
    } catch (error: unknown) {
      if (error instanceof functions.https.HttpsError) throw error;
      functions.logger.error('deleteTenantsPermanently failed', { facilityId, uid, error });
      throw new functions.https.HttpsError(
        'internal',
        "Couldn't delete. Refresh the tenant list to see what changed, then try again.",
      );
    }
  });
