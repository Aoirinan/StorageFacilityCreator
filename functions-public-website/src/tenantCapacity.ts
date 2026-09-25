import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

/**
 * Most active tenants one facility may have. The same cap, counted the same
 * way, as the app's FacilityLimitsService.maxTenantsPerFacility
 * (lib/services/facility_limits_service.dart); tenantCapacity.test.ts fails
 * if the two values drift apart.
 */
export const MAX_ACTIVE_TENANTS_PER_FACILITY = 250;

/** Active tenants: `isActive` exactly true, as the app and every server job count them. */
export async function countActiveTenants(
  db: admin.firestore.Firestore,
  facilityId: string,
): Promise<number> {
  const snap = await db
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .where('isActive', '==', true)
    .count()
    .get();
  return snap.data().count;
}

/**
 * Whether the facility has room for another active tenant. The public website
 * reads this as well as the online move-in, so it stops offering a rental
 * that the hold would refuse.
 *
 * A failed count reads as room, as the app's check does: the cap controls cost
 * and abuse, and a renter should not be turned away by a transient read error.
 */
export async function facilityHasTenantCapacity(
  db: admin.firestore.Firestore,
  facilityId: string,
): Promise<boolean> {
  let active: number;
  try {
    active = await countActiveTenants(db, facilityId);
  } catch (error) {
    functions.logger.warn('Active tenant count failed; allowing the online move-in', {
      facilityId,
      error: (error as { message?: string } | null)?.message ?? String(error),
    });
    return true;
  }
  return active < MAX_ACTIVE_TENANTS_PER_FACILITY;
}

/**
 * Refuses an online move-in at a facility that has reached its active-tenant
 * cap. The online move-in used to create tenants with no check at all, while
 * the app refused the operator at the cap.
 */
export async function assertFacilityHasTenantCapacity(
  db: admin.firestore.Firestore,
  facilityId: string,
): Promise<void> {
  if (!(await facilityHasTenantCapacity(db, facilityId))) {
    functions.logger.warn('Online move-in refused: facility is at its active tenant limit', {
      facilityId,
      limit: MAX_ACTIVE_TENANTS_PER_FACILITY,
    });
    // Nothing about the operator's account in the message: the caller is an
    // anonymous member of the public.
    throw new functions.https.HttpsError(
      'failed-precondition',
      'This facility is not taking online move-ins right now. Please contact the facility.',
    );
  }
}
