import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

/**
 * `user_roles.roleType` values that may act on a facility.
 *
 * Mirrors the in-facility `roles` map check below (owner/manager/employee) and
 * the stricter send-side check in functions-outbound-email. `viewer` is
 * deliberately absent: a viewer is read-only and must not reach the callables
 * that charge cards.  `admin` is a legacy alias for manager still present in
 * older documents.
 */
const FACILITY_ACTING_ROLE_TYPES = new Set(['owner', 'manager', 'admin', 'employee', 'staff']);

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
    // The row's roleType must be checked, not merely its existence. An invited
    // `viewer` gets an active row here, and callers of this helper move real
    // money (POS and off-session charges, retail sales, connected-account
    // payments), so "has some role" is not the same as "may act".
    hasAccess = userRolesQuery.docs.some((doc) =>
      FACILITY_ACTING_ROLE_TYPES.has(String(doc.get('roleType') ?? '').toLowerCase()),
    );
  }

  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'You do not have access to this facility');
  }

  return facilityData;
}

/**
 * Firestore rules' isFacilityOwnerOrManager on a facility doc: the owner, a
 * `managers` entry of true, or a roles entry of owner, manager or admin.
 * Employees and user_roles rows do not count, unlike
 * getFacilityDataForUserOrThrow. For callables that take over a write the
 * rules used to allow only owners and managers.
 */
export function isFacilityOwnerOrManager(facilityData: Record<string, unknown>, uid: string): boolean {
  const roles = (facilityData.roles as Record<string, unknown> | undefined) || {};
  const managers = (facilityData.managers as Record<string, unknown> | undefined) || {};
  const role = roles[uid];
  return (
    facilityData.ownerUid === uid ||
    managers[uid] === true ||
    role === 'owner' ||
    role === 'manager' ||
    role === 'admin'
  );
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
