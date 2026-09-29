import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { facilityTakesOnlineRentals } from '@sfc/functions-shared';
import { facilityHasTenantCapacity } from './tenantCapacity';

/**
 * Whether a member of the public can start an online rental at [facilityId]
 * now: the facility-wide checks createPublicReservationHold makes before it
 * looks at a unit, in its order. First the owner's online rentals switch
 * (settings/public publicRentalsEnabled), then room for another tenant. The
 * per-unit rules are already in each published unit's isRentable, and the
 * do-not-rent screening is about the renter, not the facility.
 *
 * The public website offered "Rent now" and "Reserve Now" from the per-unit
 * rules alone, so at a facility with online rentals off every one of them
 * ended in the hold's refusal.
 *
 * A failed settings read counts as off: a page without a rent button still
 * works, and a rent button that ends in a refusal does not. A failed tenant
 * count reads as room, as the hold reads it.
 */
export async function facilityAcceptsPublicRentals(
  db: admin.firestore.Firestore,
  facilityId: string,
): Promise<boolean> {
  if (!facilityId) return false;
  let settings: Record<string, unknown> | undefined;
  try {
    const snap = await db
      .collection('facilities')
      .doc(facilityId)
      .collection('settings')
      .doc('public')
      .get();
    settings = snap.data();
  } catch (error) {
    functions.logger.warn('Public settings read failed; not offering online rentals', {
      facilityId,
      error: (error as { message?: string } | null)?.message ?? String(error),
    });
    return false;
  }
  if (!facilityTakesOnlineRentals(settings)) return false;
  return facilityHasTenantCapacity(db, facilityId);
}
