import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type { UnitNotOfferedReason } from '@sfc/functions-shared';

/**
 * The facility notification type the app shows as an alert banner
 * (FacilityNotificationType.onlineMoveInReview).
 */
export const ONLINE_MOVE_IN_REVIEW_TYPE = 'ONLINE_MOVE_IN_REVIEW';

const REASON_TEXT: Record<UnitNotOfferedReason, string> = {
  'archived': 'archived',
  'internal-use': 'set to internal use',
  'unlisted': 'taken off your public website',
};

/**
 * Tells the owner, in the app, that a renter who had already paid was moved
 * into a unit that was taken off online rental after they reserved it.
 *
 * completePublicMoveIn used to refuse that renter after Checkout had charged
 * them, with no tenancy, no refund and nothing said to the owner. It now
 * completes the move-in, and the owner decides what to do with the unit.
 * Best effort: the move-in has already happened, so a failed write is logged
 * rather than failing the renter's call.
 */
export async function notifyOwnerOfMoveInToUnitNotOffered(params: {
  facilityId: string;
  tenantId: string;
  tenantName: string;
  unitId: string;
  unitNumber: string;
  reason: UnitNotOfferedReason;
  reservationId: string;
  paymentIntentId: string | null;
}): Promise<void> {
  const message =
    `${params.tenantName} paid online and was moved into unit ${params.unitNumber}, ` +
    `which was ${REASON_TEXT[params.reason]} after they reserved it. ` +
    'Check the unit and the new tenancy.';
  functions.logger.warn('Paid online move-in completed into a unit no longer offered online', {
    facilityId: params.facilityId,
    tenantId: params.tenantId,
    unitId: params.unitId,
    reason: params.reason,
    reservationId: params.reservationId,
  });
  try {
    await admin.firestore()
      .collection('facilities')
      .doc(params.facilityId)
      .collection('Notifications')
      .doc()
      .set({
        type: ONLINE_MOVE_IN_REVIEW_TYPE,
        facilityId: params.facilityId,
        tenantId: params.tenantId,
        tenantName: params.tenantName,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        readAt: null,
        message,
        metadata: {
          reason: params.reason,
          unitId: params.unitId,
          unitNumber: params.unitNumber,
          reservationId: params.reservationId,
          paymentIntentId: params.paymentIntentId,
        },
      });
  } catch (err: any) {
    functions.logger.error('Could not tell the owner about a paid move-in into a unit no longer offered', {
      facilityId: params.facilityId,
      tenantId: params.tenantId,
      unitId: params.unitId,
      error: err?.message || String(err),
    });
  }
}
