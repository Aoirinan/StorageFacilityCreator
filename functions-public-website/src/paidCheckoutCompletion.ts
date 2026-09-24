import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION } from '@sfc/functions-shared';
import type { PublicMoveInCheckoutStatus } from '@sfc/functions-shared';
import { SENDGRID_API_KEY, STRIPE_SECRETS } from './secrets';
import { completeMoveInForReservation } from './publicMoveIn';
import { MOVE_IN_FORM_NOT_SAVED_REASON } from './moveInForm';
import { resolveMoveInPaymentStripeAccountId } from './moveInPayment';
import { paidMoveInNotCompletedNotification } from './onlineMoveInReview';
import type { PaidMoveInProblem } from './onlineMoveInReview';

/**
 * Completes an online move-in when Stripe reports the payment, whether or not
 * the renter comes back.
 *
 * The renter's browser was the only thing that completed a move-in. A renter
 * who paid and closed the tab, or was not redirected back, had paid for a unit
 * and had no tenancy, and the owner found out only from Stripe. The Stripe
 * webhook (functions-integrations) now records each paid move-in Checkout
 * Session in publicMoveInCheckouts, and this completes the move-in from it
 * with the form saved at checkout, through completeMoveInForReservation, the
 * code the browser uses. The browser may be completing the same reservation
 * at the same moment; that code lets one of them do it.
 *
 * A payment that cannot complete the move-in (the unit was rented meanwhile,
 * the reservation ended, the payment does not match) is recorded here and
 * raised to the owner as an alert, since the renter has paid and needs a
 * refund.
 */

/**
 * How long a failing completion is retried (the function's failure policy)
 * before the owner is told. Refusals are not retried: the same checks would
 * refuse again.
 */
export const PAID_CHECKOUT_RETRY_MS = 60 * 60 * 1000;

/** Refusals no retry will change. Anything else (Stripe or Firestore unavailable, contention) is retried. */
const PERMANENT_REFUSAL_CODES = new Set([
  'invalid-argument',
  'failed-precondition',
  'permission-denied',
  'not-found',
  'already-exists',
  'out-of-range',
]);

type Settlement = {
  status: Exclude<PublicMoveInCheckoutStatus, 'paid'>;
  fields?: Record<string, unknown>;
  problem?: PaidMoveInProblem;
};

function checkoutRef(checkoutSessionId: string): admin.firestore.DocumentReference {
  return admin.firestore().collection(PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION).doc(checkoutSessionId);
}

/**
 * Why the payment cannot be for this reservation's facility, or null. The
 * payment is retrieved from the facility's connected account when it is
 * verified, so a payment on any other account would only fail there, as a
 * Stripe error that would be retried for an hour.
 */
async function paymentAccountProblem(
  record: Record<string, any>,
  reservation: Record<string, any> | null,
): Promise<string | null> {
  if (!reservation) return null; // Refused by completeMoveInForReservation as not found.
  const facilityId = String(reservation.facilityId || '');
  if (facilityId !== String(record.facilityId || '')) {
    return 'The payment was made for a different facility';
  }
  const facilitySnap = await admin.firestore().collection('facilities').doc(facilityId).get();
  const account = resolveMoveInPaymentStripeAccountId((facilitySnap.data() || {}) as Record<string, unknown>);
  if (account !== String(record.connectedAccountId || '')) {
    return 'The payment was taken on a Stripe account this facility is no longer connected to';
  }
  return null;
}

/** What completing the move-in for [record] came to. Throws to have the failure policy retry. */
async function attemptMoveIn(
  checkoutSessionId: string,
  record: Record<string, any>,
  reservation: Record<string, any> | null,
  receivedAt: Date,
  now: Date,
): Promise<Settlement> {
  const paymentIntentId = String(record.paymentIntentId || '');
  try {
    const accountProblem = await paymentAccountProblem(record, reservation);
    if (accountProblem) {
      return { status: 'refused', problem: { kind: 'refused', refusal: accountProblem } };
    }
    const result = await completeMoveInForReservation({
      reservationId: String(record.reservationId || ''),
      caller: { kind: 'paidCheckout', checkoutSessionId },
      formSource: { kind: 'saved' },
      paymentIntentId,
      skipPayment: false,
    });
    if (result.status === 'completed') {
      return { status: 'completed', fields: { tenantId: result.tenantId, contractId: result.contractId } };
    }
    if (result.paymentIntentId === paymentIntentId) {
      // The renter's browser completed it with this payment first.
      return { status: 'alreadyCompleted', fields: { tenantId: result.tenantId } };
    }
    // The renter paid twice, on two Checkout Sessions: one payment moved them
    // in, and this one is owed back.
    return {
      status: 'refused',
      problem: { kind: 'refused', refusal: 'The reservation was already completed with another payment' },
    };
  } catch (err: unknown) {
    if (err instanceof functions.https.HttpsError) {
      if ((err.details as { reason?: string } | undefined)?.reason === MOVE_IN_FORM_NOT_SAVED_REASON) {
        return { status: 'awaitingForm', problem: { kind: 'formNotSaved' } };
      }
      if (PERMANENT_REFUSAL_CODES.has(err.code)) {
        return { status: 'refused', problem: { kind: 'refused', refusal: err.message } };
      }
    }
    const message = (err as { message?: string } | null)?.message || String(err);
    if (now.getTime() - receivedAt.getTime() < PAID_CHECKOUT_RETRY_MS) {
      functions.logger.warn('Paid move-in checkout: completion failed; it will be retried', {
        checkoutSessionId,
        reservationId: record.reservationId,
        error: message,
      });
      throw err;
    }
    return { status: 'failed', problem: { kind: 'failed', error: message } };
  }
}

/**
 * Records how [checkoutSessionId] settled and, when the renter was not moved
 * in, raises the owner's alert, in one transaction: a run that finds it
 * already settled changes nothing, so a retried or repeated trigger raises
 * one alert.
 */
async function settle(
  checkoutSessionId: string,
  record: Record<string, any>,
  reservation: Record<string, any> | null,
  settlement: Settlement,
): Promise<boolean> {
  const db = admin.firestore();
  const ref = checkoutRef(checkoutSessionId);
  return db.runTransaction(async (tx) => {
    const current = await tx.get(ref);
    if ((current.data() as Record<string, any> | undefined)?.status !== 'paid') return false;

    let notification: { ref: admin.firestore.DocumentReference; data: Record<string, unknown> } | null = null;
    if (settlement.problem) {
      const facilityId = String(reservation?.facilityId || record.facilityId || '');
      const built = paidMoveInNotCompletedNotification({
        facilityId,
        checkoutSessionId,
        reservationId: String(record.reservationId || ''),
        renterName: String(reservation?.name || '').trim(),
        unitId: reservation?.unitId ? String(reservation.unitId) : null,
        unitNumber: String(reservation?.unitNumber || '').trim() || 'unknown',
        amountCents: Number(record.amountTotalCents) || 0,
        paymentIntentId: String(record.paymentIntentId || ''),
        problem: settlement.problem,
      });
      const notificationRef = db
        .collection('facilities')
        .doc(facilityId)
        .collection('Notifications')
        .doc(built.id);
      if (!(await tx.get(notificationRef)).exists) {
        notification = { ref: notificationRef, data: built.data };
      }
    }

    if (notification) tx.set(notification.ref, notification.data);
    tx.update(ref, {
      status: settlement.status,
      ...(settlement.fields || {}),
      ...(settlement.problem?.kind === 'refused' ? { refusal: settlement.problem.refusal } : {}),
      ...(settlement.problem?.kind === 'failed' ? { error: settlement.problem.error } : {}),
      settledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return true;
  });
}

/**
 * Completes the move-in for the paid checkout [checkoutSessionId], recorded
 * at [receivedAt]. Returns how it settled, or null when there is no record.
 * Safe to run any number of times.
 */
export async function completePaidCheckout(
  checkoutSessionId: string,
  receivedAt: Date,
  now: Date = new Date(),
): Promise<PublicMoveInCheckoutStatus | null> {
  const snap = await checkoutRef(checkoutSessionId).get();
  if (!snap.exists) {
    functions.logger.warn('Paid move-in checkout: no record', { checkoutSessionId });
    return null;
  }
  const record = snap.data() as Record<string, any>;
  if (record.status !== 'paid') {
    return record.status as PublicMoveInCheckoutStatus; // Settled by an earlier run.
  }

  const reservationSnap = await admin.firestore()
    .collection('publicReservations')
    .doc(String(record.reservationId || ''))
    .get();
  const reservation = reservationSnap.exists ? (reservationSnap.data() as Record<string, any>) : null;

  const settlement = await attemptMoveIn(checkoutSessionId, record, reservation, receivedAt, now);
  const settledNow = await settle(checkoutSessionId, record, reservation, settlement);

  const log = {
    checkoutSessionId,
    reservationId: record.reservationId,
    facilityId: record.facilityId,
    paymentIntentId: record.paymentIntentId,
    status: settlement.status,
  };
  if (!settledNow) {
    functions.logger.info('Paid move-in checkout: already settled by another run', log);
    const settled = (await checkoutRef(checkoutSessionId).get()).data() as Record<string, any> | undefined;
    return (settled?.status as PublicMoveInCheckoutStatus | undefined) ?? null;
  }
  if (settlement.problem) {
    functions.logger.error('Paid move-in checkout: renter paid and was not moved in; owner alerted', {
      ...log,
      problem: settlement.problem,
    });
  } else {
    functions.logger.info('Paid move-in checkout settled', log);
  }
  return settlement.status;
}

export const completePublicMoveInFromCheckout = functions
  .runWith({
    secrets: [...STRIPE_SECRETS, SENDGRID_API_KEY],
    // Retried while completing fails for a reason that may pass; see PAID_CHECKOUT_RETRY_MS.
    failurePolicy: true,
    timeoutSeconds: 120,
  })
  .firestore.document(`${PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION}/{checkoutSessionId}`)
  .onCreate(async (_snap, context) => {
    await completePaidCheckout(String(context.params.checkoutSessionId), new Date(context.timestamp));
  });
