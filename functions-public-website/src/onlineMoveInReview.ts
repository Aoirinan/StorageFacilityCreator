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

/** Why a paid online move-in was not completed for the renter. */
export type PaidMoveInProblem =
  /** The move-in was refused: the unit was taken, the reservation ended, the payment did not match. */
  | { kind: 'refused'; refusal: string }
  /** No form was saved at checkout, so only the renter can finish it. */
  | { kind: 'formNotSaved' }
  /** Completing it kept failing. */
  | { kind: 'failed'; error: string };

/**
 * The alert telling the owner that a renter paid online and has no tenancy
 * to show for it, so they need a refund or a call. Built here and written by
 * paidCheckoutCompletion.ts in the transaction that settles the payment, so
 * one payment raises one alert however often the trigger runs.
 *
 * Before the paid-checkout trigger, a renter who paid and was refused, or who
 * never came back, left the owner nothing to see but the charge in Stripe.
 */
export function paidMoveInNotCompletedNotification(params: {
  facilityId: string;
  checkoutSessionId: string;
  reservationId: string;
  renterName: string;
  unitId: string | null;
  unitNumber: string;
  amountCents: number;
  paymentIntentId: string;
  problem: PaidMoveInProblem;
}): { id: string; data: Record<string, unknown> } {
  const who = params.renterName || 'A renter';
  const paid = `${who} paid $${(params.amountCents / 100).toFixed(2)} online for unit ${params.unitNumber}`;
  const payment = `the payment in Stripe (${params.paymentIntentId})`;
  let message: string;
  switch (params.problem.kind) {
    case 'refused':
      message =
        `${paid}, but the move-in was refused ("${params.problem.refusal}"). ` +
        `No tenancy was created. Refund ${payment} or contact them.`;
      break;
    case 'formNotSaved':
      message =
        `${paid}, but their move-in form was not saved, so the move-in could not be completed for them. ` +
        `They can still finish it from their move-in link. If no tenancy appears for them, ` +
        `contact them or refund ${payment}.`;
      break;
    case 'failed':
      message =
        `${paid}, but completing the move-in kept failing. Check whether a tenancy was created for them; ` +
        `if not, contact them or refund ${payment}.`;
      break;
  }
  return {
    id: `paidMoveIn_${params.checkoutSessionId}`,
    data: {
      type: ONLINE_MOVE_IN_REVIEW_TYPE,
      facilityId: params.facilityId,
      tenantId: null,
      tenantName: params.renterName || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      readAt: null,
      message,
      metadata: {
        kind: 'paidMoveInNotCompleted',
        problem: params.problem.kind,
        refusal: params.problem.kind === 'refused' ? params.problem.refusal : null,
        error: params.problem.kind === 'failed' ? params.problem.error : null,
        reservationId: params.reservationId,
        unitId: params.unitId,
        unitNumber: params.unitNumber,
        amountCents: params.amountCents,
        paymentIntentId: params.paymentIntentId,
        checkoutSessionId: params.checkoutSessionId,
      },
    },
  };
}

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
