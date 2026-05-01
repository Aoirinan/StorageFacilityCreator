import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

export async function getFacilityDataForUserOrThrow(
  uid: string,
  facilityId: string,
): Promise<Record<string, unknown>> {
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }

  const facilityData = (facilityDoc.data() || {}) as Record<string, unknown>;
  const ownerUid = facilityData.ownerUid as string | undefined;
  const roles = (facilityData.roles as Record<string, string>) || {};
  const managersMap = (facilityData.managers as Record<string, unknown>) || {};

  let hasAccess =
    ownerUid === uid ||
    roles[uid] === 'owner' ||
    roles[uid] === 'manager' ||
    roles[uid] === 'employee' ||
    managersMap[uid] === true;

  if (!hasAccess) {
    const userRolesQuery = await admin
      .firestore()
      .collection('user_roles')
      .where('userId', '==', uid)
      .where('facilityId', '==', facilityId)
      .where('isActive', '==', true)
      .limit(1)
      .get();
    hasAccess = !userRolesQuery.empty;
  }

  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'You do not have access to this facility');
  }

  return facilityData;
}

/**
 * Same access as Firestore isFacilityStaff + tenant portal occupants (for legacy checks).
 * Prefer getFacilityDataForUserOrThrow for staff-only flows.
 */
export async function canAccessFacility(uid: string, facilityId: string): Promise<boolean> {
  try {
    await getFacilityDataForUserOrThrow(uid, facilityId);
    return true;
  } catch (e: unknown) {
    const code = (e as { code?: string })?.code;
    if (code === 'permission-denied' || code === 'not-found') {
      const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
      if (!facilityDoc.exists) return false;
      const tenantsSnap = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .get();
      for (const t of tenantsSnap.docs) {
        const occupants = (t.data().occupants || []) as Array<{ userId?: string }>;
        if (occupants.some((o) => o.userId === uid)) return true;
      }
      return false;
    }
    throw e;
  }
}
