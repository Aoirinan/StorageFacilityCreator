import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import { isSuperAdmin } from '@sfc/functions-shared/auth/superAdmin';
import {
  FacilityForOwnerError,
  buildFacilityForOwner,
  buildOwnerRoleRow,
} from '@sfc/functions-shared';

interface CreateFacilityForOwnerRequest {
  ownerUid?: string;
  name?: string;
  address?: string | null;
  phone?: string | null;
  email?: string | null;
  timeZone?: string | null;
  totalUnits?: number | null;
  gracePeriodDays?: number | null;
  lateFeeAmount?: number | null;
}

/**
 * Super admin only: create a facility that belongs to somebody else.
 *
 * The Firestore create rule deliberately pins a new facility's `ownerUid` to
 * whoever is creating it, so nobody can plant a facility under another
 * person's name. That rule stays exactly as it is; this runs through the
 * Admin SDK instead, where the caller is checked once, explicitly, here.
 *
 * Three writes make a facility real, and all three must name the owner: the
 * facility document, the owner's staff-role row, and the facility's place on
 * the owner's platform account. Doing only the first leaves an owner who
 * cannot see their own facility.
 */
export const superAdminCreateFacilityForOwner = functions.https.onCall(
  async (data: CreateFacilityForOwnerRequest, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only super admins can create a facility for another owner',
      );
    }

    const ownerUid = (data?.ownerUid || '').toString().trim();
    if (!ownerUid) {
      throw new functions.https.HttpsError('invalid-argument', 'ownerUid is required');
    }

    // A facility pointing at a uid that does not exist is unreachable by
    // anyone, including the person it was meant for.
    let ownerRecord: admin.auth.UserRecord;
    try {
      ownerRecord = await admin.auth().getUser(ownerUid);
    } catch {
      throw new functions.https.HttpsError('not-found', 'That owner account does not exist');
    }

    let facilityDoc;
    try {
      facilityDoc = buildFacilityForOwner(
        {
          ownerUid,
          name: (data?.name || '').toString(),
          address: data?.address ?? null,
          phone: data?.phone ?? null,
          email: data?.email ?? ownerRecord.email ?? null,
          timeZone: data?.timeZone ?? null,
          totalUnits: data?.totalUnits ?? null,
          gracePeriodDays: data?.gracePeriodDays ?? null,
          lateFeeAmount: data?.lateFeeAmount ?? null,
        },
        context.auth.uid,
      );
    } catch (error) {
      if (error instanceof FacilityForOwnerError) {
        throw new functions.https.HttpsError('invalid-argument', error.message);
      }
      throw error;
    }

    const db = admin.firestore();
    const facilityRef = db.collection('facilities').doc();
    const now = admin.firestore.FieldValue.serverTimestamp();

    await facilityRef.set({
      ...facilityDoc,
      createdAt: now,
      updatedAt: now,
    });

    await db.collection('user_roles').add({
      ...buildOwnerRoleRow(ownerUid, facilityRef.id, context.auth.uid),
      assignedAt: now,
      createdAt: now,
      updatedAt: now,
      userDisplayName: ownerRecord.displayName || ownerRecord.email || null,
      userEmail: ownerRecord.email || null,
    });

    // Without this the facility exists but does not count against, or appear
    // on, the owner's platform account.
    const accountSnap = await db
      .collection('facilityCreatorAccounts')
      .where('ownerUid', '==', ownerUid)
      .limit(1)
      .get();
    let accountId: string | null = null;
    if (!accountSnap.empty) {
      accountId = accountSnap.docs[0].id;
      await accountSnap.docs[0].ref.update({
        facilityIds: admin.firestore.FieldValue.arrayUnion(facilityRef.id),
        updatedAt: now,
      });
      await facilityRef.update({ facilityCreatorAccountId: accountId });
    } else {
      functions.logger.warn('Owner has no platform account; facility left unlinked', {
        ownerUid,
        facilityId: facilityRef.id,
      });
    }

    // Recorded in the owner's own audit log, so the facility's origin is
    // visible to them rather than only to us.
    await facilityRef.collection('auditLogs').add({
      eventType: 'facility_created_by_support',
      targetType: 'facility',
      targetId: facilityRef.id,
      userId: context.auth.uid,
      userEmail: callerEmail || '',
      actorRole: 'super_admin',
      metadata: { ownerUid, ownerEmail: ownerRecord.email || '', facilityName: facilityDoc.name },
      timestamp: now,
      createdAt: now,
    });

    functions.logger.info('superAdminCreateFacilityForOwner', {
      facilityId: facilityRef.id,
      ownerUid,
      accountId,
      createdBy: callerEmail,
    });

    return { success: true, facilityId: facilityRef.id, accountId };
  },
);
