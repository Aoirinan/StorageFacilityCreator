import * as admin from 'firebase-admin';
import type { UnitNotOfferedReason } from '@sfc/functions-shared';

/**
 * The facility notification type the app shows as an alert banner
 * (FacilityNotificationType.onlineMoveInReview).
 */
export const ONLINE_MOVE_IN_REVIEW_TYPE = 'ONLINE_MOVE_IN_REVIEW';

/**
 * Why a renter who had paid was moved into a unit the owner no longer offers
 * online: the unit was taken off online rental (functions-shared
 * unitNotOfferedOnlineReason), or its type was (settings/public
 * enabledPublicUnitTypes).
 */
export type MoveInReviewReason = UnitNotOfferedReason | 'unit-type-not-offered';

const REASON_TEXT: Record<MoveInReviewReason, string> = {
  'archived': 'which was archived',
  'internal-use': 'which was set to internal use',
  'unlisted': 'which was taken off your public website',
  'unit-type-not-offered': 'whose unit type was taken off online rental',
};

/**
 * What the move-in changed on the unit besides renting it, because a renter
 * now occupies it: an archived unit is hidden from Units, the stats and the
 * reports, and an internal-use unit is left out of occupancy and revenue, so
 * either would hide a tenant who is being billed.
 */
export interface MoveInUnitChanges {
  restored: boolean;
  internalUseCleared: boolean;
}

/** The alert's doc in facilities/{id}/Notifications: one per reservation, so a retry cannot add a second. */
export function onlineMoveInReviewRef(
  facilityId: string,
  reservationId: string,
): admin.firestore.DocumentReference {
  return admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('Notifications')
    .doc(`move-in-review-${reservationId}`);
}

/**
 * The owner's in-app alert that a renter who had already paid was moved into
 * a unit taken off online rental after they reserved it.
 *
 * completePublicMoveIn used to refuse that renter after Checkout had charged
 * them, with no tenancy, no refund and nothing said to the owner. It now
 * completes the move-in, and the owner decides what to do with the unit.
 * The caller writes this in the move-in's own transaction: written after the
 * commit, an instance that died in between left the owner never told, and a
 * retry could not make up for it (the reservation is already completed).
 */
export function onlineMoveInReviewAlert(params: {
  facilityId: string;
  tenantId: string;
  tenantName: string;
  unitId: string;
  unitNumber: string;
  reason: MoveInReviewReason;
  unitChanges: MoveInUnitChanges;
  reservationId: string;
  paymentIntentId: string | null;
}): Record<string, unknown> {
  const sentences = [
    `${params.tenantName} paid online and was moved into unit ${params.unitNumber}, ` +
      `${REASON_TEXT[params.reason]} after they reserved it.`,
  ];
  if (params.unitChanges.restored) {
    sentences.push('The unit has been restored from the archive so it shows in Units again.');
  }
  if (params.unitChanges.internalUseCleared) {
    sentences.push(
      'Internal use has been turned off, since a renter now occupies it, so it counts in occupancy and revenue.',
    );
  }
  sentences.push('Check the unit and the new tenancy.');
  return {
    type: ONLINE_MOVE_IN_REVIEW_TYPE,
    facilityId: params.facilityId,
    tenantId: params.tenantId,
    tenantName: params.tenantName,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    readAt: null,
    message: sentences.join(' '),
    metadata: {
      reason: params.reason,
      unitId: params.unitId,
      unitNumber: params.unitNumber,
      unitRestored: params.unitChanges.restored,
      internalUseCleared: params.unitChanges.internalUseCleared,
      reservationId: params.reservationId,
      paymentIntentId: params.paymentIntentId,
    },
  };
}
