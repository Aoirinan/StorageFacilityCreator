import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION } from '@sfc/functions-shared';
import type { PublicMoveInCheckoutStatus } from '@sfc/functions-shared';
import { SENDGRID_API_KEY, STRIPE_SECRETS } from './secrets';
import {
  completeMoveInForReservation,
  OTHER_RESERVATION_PAYMENT_MESSAGE,
  PUBLIC_MOVE_IN_PAYMENTS_COLLECTION,
} from './publicMoveIn';
import { MOVE_IN_FORM_NOT_SAVED_REASON } from './moveInForm';
import { resolveMoveInPaymentStripeAccountId } from './moveInPayment';
import { timestampToDate } from './checkoutHold';
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
 * A record is taken up by the trigger when it is written, and by the sweep
 * (sweepPaidMoveInCheckouts) while it stays unsettled: after a failure that
 * may pass, or when the trigger never ran for it (a record written before the
 * trigger was deployed, or a lost run).
 *
 * A payment that cannot complete the move-in (the unit was rented meanwhile,
 * the reservation ended, the payment does not match) is recorded here and
 * raised to the owner as an alert, since the renter has paid and needs a
 * refund.
 */

/**
 * How long, from when the webhook recorded it, a failing completion is
 * retried before the owner is told. Refusals are not retried: the same checks
 * would refuse again.
 */
export const PAID_CHECKOUT_RETRY_MS = 60 * 60 * 1000;

/**
 * How long a record stays unsettled before the sweep takes it up. Long enough
 * for the trigger's own run, which the sweep would otherwise duplicate.
 */
export const PAID_CHECKOUT_SWEEP_AFTER_MS = 3 * 60 * 1000;

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
  /**
   * Whether the payment, refused for this reservation, is marked so that it
   * cannot complete the move-in later. The owner is told to refund it, and
   * may have by the time the renter comes back.
   */
  blockPayment?: boolean;
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

/** What completing the move-in for [record] came to. Throws when it should be tried again. */
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
      // Not this facility's payment to block: it is on another account.
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
      // The move-in for this payment was done already, usually by the browser.
      return { status: 'alreadyCompleted', fields: { tenantId: result.tenantId } };
    }
    // The renter paid twice, on two Checkout Sessions: one payment moved them
    // in, and this one is owed back.
    return {
      status: 'refused',
      problem: { kind: 'refused', refusal: 'The reservation was already completed with another payment' },
      blockPayment: true,
    };
  } catch (err: unknown) {
    if (err instanceof functions.https.HttpsError) {
      if ((err.details as { reason?: string } | undefined)?.reason === MOVE_IN_FORM_NOT_SAVED_REASON) {
        return { status: 'awaitingForm', problem: { kind: 'formNotSaved' } };
      }
      if (PERMANENT_REFUSAL_CODES.has(err.code)) {
        return {
          status: 'refused',
          problem: { kind: 'refused', refusal: err.message },
          // A payment tagged for another reservation is that reservation's to use.
          blockPayment: err.message !== OTHER_RESERVATION_PAYMENT_MESSAGE,
        };
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
 * in, raises the owner's alert and marks a refused payment used, in one
 * transaction: a run that finds it already settled changes nothing, so a
 * repeated run raises one alert.
 *
 * The reservation is read again here. The renter's browser can complete it
 * with this payment after the attempt above was refused (the refusal read the
 * unit or the payment before the browser's move-in landed); that settles as
 * done, not as a refund. The browser's transaction and this one both read and
 * write the payment's record in publicMoveInPayments, so one of them sees the
 * other: either the move-in stands and nothing is marked, or the payment is
 * marked refused and the browser cannot then use it.
 */
async function settle(
  checkoutSessionId: string,
  record: Record<string, any>,
  reservation: Record<string, any> | null,
  attempted: Settlement,
): Promise<{ settledNow: boolean; settlement: Settlement }> {
  const db = admin.firestore();
  const ref = checkoutRef(checkoutSessionId);
  const paymentIntentId = String(record.paymentIntentId || '');
  return db.runTransaction(async (tx) => {
    const current = await tx.get(ref);
    if ((current.data() as Record<string, any> | undefined)?.status !== 'paid') {
      return { settledNow: false, settlement: attempted };
    }

    let settlement = attempted;
    const reservationRef = db.collection('publicReservations').doc(String(record.reservationId || ''));
    const fresh = (await tx.get(reservationRef)).data() as Record<string, any> | undefined;
    if (settlement.problem && fresh?.status === 'completed' && fresh.paymentIntentId === paymentIntentId) {
      settlement = { status: 'alreadyCompleted', fields: { tenantId: fresh.tenantId ?? null } };
    }

    const paymentUseRef = paymentIntentId
      ? db.collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntentId)
      : null;
    const markPayment =
      settlement.blockPayment === true && paymentUseRef != null && !(await tx.get(paymentUseRef)).exists;

    let notification: { ref: admin.firestore.DocumentReference; data: Record<string, unknown> } | null = null;
    const facilityId = String(reservation?.facilityId || record.facilityId || '');
    if (settlement.problem) {
      const built = paidMoveInNotCompletedNotification({
        facilityId,
        checkoutSessionId,
        reservationId: String(record.reservationId || ''),
        renterName: String(reservation?.name || '').trim(),
        unitId: reservation?.unitId ? String(reservation.unitId) : null,
        unitNumber: String(reservation?.unitNumber || '').trim() || 'unknown',
        amountCents: Number(record.amountTotalCents) || 0,
        paymentIntentId,
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
    if (markPayment && paymentUseRef && settlement.problem?.kind === 'refused') {
      tx.set(paymentUseRef, {
        paymentIntentId,
        facilityId,
        reservationId: String(record.reservationId || ''),
        checkoutSessionId,
        refusal: settlement.problem.refusal,
        refusedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: 'publicMoveInCheckout',
      });
    }
    tx.update(ref, {
      status: settlement.status,
      ...(settlement.fields || {}),
      ...(settlement.problem?.kind === 'refused' ? { refusal: settlement.problem.refusal } : {}),
      ...(settlement.problem?.kind === 'failed' ? { error: settlement.problem.error } : {}),
      settledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { settledNow: true, settlement };
  });
}

/**
 * Completes the move-in for the paid checkout [checkoutSessionId]. Returns
 * how it settled, or null when there is no record. Throws when it failed for
 * a reason that may pass, within PAID_CHECKOUT_RETRY_MS of the record being
 * written. Safe to run any number of times.
 */
export async function completePaidCheckout(
  checkoutSessionId: string,
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
  const receivedAt = timestampToDate(record.receivedAt) ?? now;

  const reservationSnap = await admin.firestore()
    .collection('publicReservations')
    .doc(String(record.reservationId || ''))
    .get();
  const reservation = reservationSnap.exists ? (reservationSnap.data() as Record<string, any>) : null;

  const attempted = await attemptMoveIn(checkoutSessionId, record, reservation, receivedAt, now);
  const { settledNow, settlement } = await settle(checkoutSessionId, record, reservation, attempted);

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

/**
 * Takes up every paid checkout still unsettled PAID_CHECKOUT_SWEEP_AFTER_MS
 * after it was recorded. Returns how many it tried.
 */
export async function sweepPaidCheckouts(now: Date = new Date()): Promise<number> {
  const unsettled = await admin.firestore()
    .collection(PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION)
    .where('status', '==', 'paid')
    .limit(100)
    .get();
  let tried = 0;
  for (const doc of unsettled.docs) {
    const receivedAt = timestampToDate((doc.data() as Record<string, any>).receivedAt);
    if (receivedAt && now.getTime() - receivedAt.getTime() < PAID_CHECKOUT_SWEEP_AFTER_MS) {
      continue; // Its trigger run may still be going.
    }
    tried += 1;
    try {
      await completePaidCheckout(doc.id, now);
    } catch (err: unknown) {
      functions.logger.warn('Paid move-in checkout sweep: completion failed; the next sweep retries it', {
        checkoutSessionId: doc.id,
        error: (err as { message?: string } | null)?.message || String(err),
      });
    }
  }
  return tried;
}

export const completePublicMoveInFromCheckout = functions
  .runWith({
    secrets: [...STRIPE_SECRETS, SENDGRID_API_KEY],
    timeoutSeconds: 120,
  })
  .firestore.document(`${PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION}/{checkoutSessionId}`)
  .onCreate(async (_snap, context) => {
    const checkoutSessionId = String(context.params.checkoutSessionId);
    try {
      await completePaidCheckout(checkoutSessionId);
    } catch (err: unknown) {
      // Left unsettled; sweepPaidMoveInCheckouts tries it again.
      functions.logger.warn('Paid move-in checkout: completion failed; the sweep retries it', {
        checkoutSessionId,
        error: (err as { message?: string } | null)?.message || String(err),
      });
    }
  });

export const sweepPaidMoveInCheckouts = functions
  .runWith({
    secrets: [...STRIPE_SECRETS, SENDGRID_API_KEY],
    timeoutSeconds: 540,
  })
  .pubsub.schedule('every 10 minutes')
  .onRun(async () => {
    const tried = await sweepPaidCheckouts();
    if (tried > 0) {
      functions.logger.info('Paid move-in checkout sweep', { tried });
    }
    return null;
  });
