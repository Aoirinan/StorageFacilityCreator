import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getStripeClient } from '@sfc/functions-shared';
import { ONLINE_MOVE_IN_REVIEW_TYPE } from './onlineMoveInReview';
import { resolveMoveInPaymentStripeAccountId } from './moveInPayment';

/**
 * One document per PaymentIntent that has completed an online move-in, or
 * that was refunded because it could not, keyed by the PaymentIntent id. Top
 * level rather than under the facility, so a connected account shared by two
 * facilities cannot spend one payment at each.
 */
export const PUBLIC_MOVE_IN_PAYMENTS_COLLECTION = 'publicMoveInPayments';

export const PAYMENT_ALREADY_USED_MESSAGE =
  'This payment has already been used to complete a move-in. Contact the facility.';

/**
 * Why a renter who has paid is not moved in. Each is a state no move-in can
 * safely overwrite: someone else has the unit, it is gone, the owner will not
 * rent to this person, or the payment no longer matches what is owed.
 */
export type PaidMoveInRefusal =
  | 'unit-missing'
  | 'unit-taken'
  // Their own hold ran out, and another renter who may be paying holds it.
  | 'unit-held'
  | 'do-not-rent'
  | 'reservation-closed'
  | 'charges-changed'
  | 'portal-link';

/** Said to the renter. Kept clear of "not currently available", which the move-in page replaces with its own text. */
const RENTER_TEXT: Record<PaidMoveInRefusal, string> = {
  'unit-missing': 'This unit was removed while you were paying, so your move-in could not be completed.',
  'unit-taken':
    'This unit was rented or taken out of service while you were paying, so your move-in could not be completed.',
  'unit-held':
    'Your hold on this unit ran out, and another renter is now paying for it, so your move-in could not be completed.',
  // The screening's own words: the renter is not told they are on a list.
  'do-not-rent': 'Online move-in is not available. Please contact the facility directly.',
  'reservation-closed': 'This reservation was already completed or cancelled, so this payment could not be used.',
  'charges-changed':
    'The move-in charges changed while you were paying. Refresh the page to see the new amount before paying again.',
  'portal-link': 'This move-in could not be linked to your tenant portal account.',
};

/** Said to the owner, after "was not moved in because". */
const OWNER_TEXT: Record<PaidMoveInRefusal, string> = {
  'unit-missing': 'the unit was deleted',
  'unit-taken': 'the unit was already rented or out of service',
  'unit-held': 'their hold on the unit ran out and another renter was paying for it',
  'do-not-rent': 'they match a Do Not Rent entry',
  'reservation-closed': 'their reservation had already been completed or cancelled',
  'charges-changed': 'the move-in charges changed while they were paying',
  'portal-link': 'their tenant portal account did not match the one they rented from',
};

/**
 * Refusals that end the reservation. After a change in the charges the renter
 * can pay the new amount on the same reservation.
 */
function closesReservation(refusal: PaidMoveInRefusal): boolean {
  return refusal !== 'charges-changed' && refusal !== 'reservation-closed';
}

/** The verified payment a completion offered. */
export interface OfferedPayment {
  paymentIntentId: string;
  amountReceivedCents: number;
  metadata: Record<string, string>;
}

interface PaidMoveInContext {
  facilityId: string;
  connectAccountId: string;
  reservationId: string;
  unitId: string | null;
  unitNumber: string;
  renterName: string;
}

type RefundState = 'pending' | 'refunded' | 'failed';

/** What the one-use record holds about a refund. */
interface RefundRecord {
  status: RefundState;
  refusal: PaidMoveInRefusal;
  unitId: string | null;
  unitNumber: string;
  renterName: string;
  refundId?: string | null;
  error?: string | null;
}

/** The owner pays for an automatic refund: Stripe keeps its fee on the original payment. */
const STRIPE_FEE_NOTE = 'Stripe does not return its processing fee on a refund.';

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

function paymentUseRef(paymentIntentId: string): admin.firestore.DocumentReference {
  return admin.firestore().collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntentId);
}

function alertRef(facilityId: string, alertId: string): admin.firestore.DocumentReference {
  return admin.firestore().collection('facilities').doc(facilityId).collection('Notifications').doc(alertId);
}

/** Deterministic, so a retried completion finds the same alert rather than adding one. */
function refundAlertId(paymentIntentId: string): string {
  return `move-in-refund-${paymentIntentId}`;
}

function reviewAlertId(paymentIntentId: string): string {
  return `move-in-payment-review-${paymentIntentId}`;
}

function ownerMessage(
  ctx: Pick<PaidMoveInContext, 'renterName' | 'unitNumber'>,
  refusal: PaidMoveInRefusal,
  amountCents: number,
  state: RefundState,
  paymentIntentId: string,
  error?: string | null,
): string {
  const head =
    `${ctx.renterName} paid ${dollars(amountCents)} online for unit ${ctx.unitNumber}, ` +
    `but was not moved in because ${OWNER_TEXT[refusal]}.`;
  if (state === 'refunded') return `${head} The payment was refunded to them automatically. ${STRIPE_FEE_NOTE}`;
  if (state === 'failed') {
    return `${head} The automatic refund failed (${error || 'unknown error'}). ` +
      `Refund payment ${paymentIntentId} in your Stripe dashboard.`;
  }
  // Written before Stripe is asked, so it cannot promise the refund: an
  // instance that dies in between leaves it here until the sweep
  // (pendingMoveInRefundSweep.ts) finishes the refund and rewrites it.
  return `${head} An automatic refund has been started, and this alert will say when Stripe has made it. ` +
    `If it still says this in an hour, check payment ${paymentIntentId} in your Stripe dashboard. ${STRIPE_FEE_NOTE}`;
}

function renterError(
  refusal: PaidMoveInRefusal,
  amountCents: number,
  state: RefundState,
  paymentIntentId: string,
): functions.https.HttpsError {
  const suffix = state === 'refunded'
    ? ` Your payment of ${dollars(amountCents)} has been refunded to your card; it can take 5 to 10 business days to appear.`
    : ` The facility has been told and will refund your payment of ${dollars(amountCents)}.`;
  return new functions.https.HttpsError('failed-precondition', `${RENTER_TEXT[refusal]}${suffix}`, {
    refunded: state === 'refunded',
    paymentIntentId,
  });
}

/**
 * For a renter who paid when Stripe could not say whose the payment is, so
 * nothing was refunded and the owner was asked to check it. The unpaid
 * error ('Unit is no longer available') read, on the move-in page, as
 * 'choose another unit': nothing about the money they had paid.
 */
function paymentUnderReviewError(refusal: PaidMoveInRefusal, payment: OfferedPayment): functions.https.HttpsError {
  return new functions.https.HttpsError(
    'failed-precondition',
    `${RENTER_TEXT[refusal]} Your payment of ${dollars(payment.amountReceivedCents)} could not be checked ` +
      'automatically just now, so it has not been refunded yet. The facility has been told and will look at ' +
      'your payment.',
    { refunded: false, paymentIntentId: payment.paymentIntentId },
  );
}

/**
 * Whether [payment] was made for this reservation, which is what makes a
 * refund safe: refunding a payment made for something else would take the
 * owner's money on a stranger's say-so. Its metadata says so (checkout sets it
 * from now on), or else the Checkout Session that took it does (older
 * sessions set only their own metadata). 'unknown' when Stripe cannot be
 * asked.
 */
async function paymentOwnership(
  ctx: PaidMoveInContext,
  payment: OfferedPayment,
): Promise<'this-reservation' | 'another' | 'unknown'> {
  const meta = payment.metadata || {};
  if (meta.type || meta.reservationId) {
    return meta.type === 'public_move_in' && meta.reservationId === ctx.reservationId
      ? 'this-reservation'
      : 'another';
  }
  try {
    const sessions = await getStripeClient().checkout.sessions.list(
      { payment_intent: payment.paymentIntentId, limit: 1 },
      { stripeAccount: ctx.connectAccountId },
    );
    const sessionMeta = sessions.data[0]?.metadata || {};
    return sessionMeta.type === 'public_move_in' && sessionMeta.reservationId === ctx.reservationId
      ? 'this-reservation'
      : 'another';
  } catch (err: any) {
    functions.logger.error('Public move-in: could not look up the Checkout Session of a payment', {
      facilityId: ctx.facilityId,
      reservationId: ctx.reservationId,
      paymentIntentId: payment.paymentIntentId,
      error: err?.message || String(err),
    });
    return 'unknown';
  }
}

/**
 * Refunds the whole payment on the facility's connected account. The
 * idempotency key is the PaymentIntent's, so a retried completion cannot
 * refund twice; Stripe forgets keys after a day, when a second attempt is
 * refused as already refunded instead.
 */
async function issueRefund(
  ctx: Pick<PaidMoveInContext, 'facilityId' | 'connectAccountId' | 'reservationId'>,
  paymentIntentId: string,
  refusal: PaidMoveInRefusal,
): Promise<{ state: 'refunded'; refundId: string | null } | { state: 'failed'; error: string }> {
  try {
    const refund = await getStripeClient().refunds.create(
      {
        payment_intent: paymentIntentId,
        metadata: {
          type: 'public_move_in_refund',
          facilityId: ctx.facilityId,
          reservationId: ctx.reservationId,
          refusal,
        },
      },
      { stripeAccount: ctx.connectAccountId, idempotencyKey: `public_move_in_refund_${paymentIntentId}` },
    );
    return { state: 'refunded', refundId: refund.id || null };
  } catch (err: any) {
    if (err?.code === 'charge_already_refunded') return { state: 'refunded', refundId: null };
    functions.logger.error('Public move-in: automatic refund failed', {
      facilityId: ctx.facilityId,
      reservationId: ctx.reservationId,
      paymentIntentId,
      refusal,
      error: err?.message || String(err),
    });
    return { state: 'failed', error: String(err?.message || err || 'unknown error').slice(0, 300) };
  }
}

/** Issues (or re-issues) the refund a record holds, records how it went and tells the renter. */
async function finishRefund(
  ctx: Pick<PaidMoveInContext, 'facilityId' | 'connectAccountId' | 'reservationId'>,
  paymentIntentId: string,
  amountCents: number,
  refund: RefundRecord,
): Promise<never> {
  let state: RefundState = refund.status;
  let error = refund.error ?? null;
  if (state !== 'refunded') {
    const outcome = await issueRefund(ctx, paymentIntentId, refund.refusal);
    state = outcome.state;
    error = outcome.state === 'failed' ? outcome.error : null;
    const refundId = outcome.state === 'refunded' ? outcome.refundId : null;
    try {
      await paymentUseRef(paymentIntentId).set(
        {
          refund: { ...refund, status: state, refundId, error },
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      await alertRef(ctx.facilityId, refundAlertId(paymentIntentId)).set(
        {
          message: ownerMessage(refund, refund.refusal, amountCents, state, paymentIntentId, error),
          metadata: { refundStatus: state, refundId },
          // Shown again even if read: the outcome says whether the owner has
          // a refund to make by hand, or no longer has one.
          readAt: null,
        },
        { merge: true },
      );
    } catch (err: any) {
      // The decision and the alert were written first, so a failure here
      // leaves the record 'pending' and the next completion retries it.
      functions.logger.error('Public move-in: could not record a refund outcome', {
        facilityId: ctx.facilityId,
        paymentIntentId,
        state,
        error: err?.message || String(err),
      });
    }
  }
  throw renterError(refund.refusal, amountCents, state, paymentIntentId);
}

/**
 * Turns away a renter who has already paid, without keeping their money.
 *
 * completePublicMoveIn used to throw its refusal after Checkout had charged,
 * leaving the renter paid with no tenancy, no refund and nothing said to the
 * owner. Now, when the payment is provably this reservation's, the refusal,
 * the payment's one-use record (so it can never complete a move-in later) and
 * the owner's alert are written in one transaction, and then the payment is
 * refunded. Otherwise the renter gets [unpaidError], as an unpaid move-in
 * would; if Stripe could not be asked, the owner is told to check it by hand.
 */
export async function refusePaidMoveIn(params: PaidMoveInContext & {
  refusal: PaidMoveInRefusal;
  unpaidError: functions.https.HttpsError;
  payment: OfferedPayment;
}): Promise<never> {
  const { refusal, payment } = params;
  const ownership = await paymentOwnership(params, payment);
  if (ownership === 'another') throw params.unpaidError;

  const useRef = paymentUseRef(payment.paymentIntentId);
  const reservationRef = admin.firestore().collection('publicReservations').doc(params.reservationId);
  const holdRef = params.unitId
    ? admin.firestore()
      .collection('facilities')
      .doc(params.facilityId)
      .collection('mapEngine')
      .doc('activeHolds')
      .collection('items')
      .doc(params.unitId)
    : null;
  const refund: RefundRecord = {
    status: 'pending',
    refusal,
    unitId: params.unitId,
    unitNumber: params.unitNumber,
    renterName: params.renterName,
  };

  const decided = await admin.firestore().runTransaction(async (tx) => {
    const useSnap = await tx.get(useRef);
    const reservationSnap = await tx.get(reservationRef);
    const holdSnap = holdRef ? await tx.get(holdRef) : null;
    if (useSnap.exists) {
      const used = (useSnap.data() || {}) as Record<string, any>;
      // Refunded already: finish that one. Used: it completed a move-in, and
      // is not refunded.
      if (used.refund) return { kind: 'resume' as const, record: used };
      throw new functions.https.HttpsError('failed-precondition', PAYMENT_ALREADY_USED_MESSAGE);
    }
    const reservation = (reservationSnap.data() || {}) as Record<string, any>;
    if (reservation.status === 'completed' && reservation.paymentIntentId === payment.paymentIntentId) {
      // It completed this reservation, its use record aside: offered again,
      // it is used, never refunded, or the renter would keep the unit for free.
      throw new functions.https.HttpsError('failed-precondition', PAYMENT_ALREADY_USED_MESSAGE);
    }

    if (ownership === 'unknown') {
      tx.set(alertRef(params.facilityId, reviewAlertId(payment.paymentIntentId)), {
        type: ONLINE_MOVE_IN_REVIEW_TYPE,
        facilityId: params.facilityId,
        tenantId: null,
        tenantName: params.renterName,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        readAt: null,
        message:
          `${params.renterName} offered payment ${payment.paymentIntentId} ` +
          `(${dollars(payment.amountReceivedCents)}) for unit ${params.unitNumber}, but was not moved in ` +
          `because ${OWNER_TEXT[refusal]}. Stripe could not confirm this payment was for this reservation, ` +
          'so it was not refunded automatically. Check it in your Stripe dashboard and refund it if it was.',
        metadata: {
          reason: refusal,
          unitId: params.unitId,
          unitNumber: params.unitNumber,
          reservationId: params.reservationId,
          paymentIntentId: payment.paymentIntentId,
          amountCents: payment.amountReceivedCents,
          refundStatus: 'not-attempted',
        },
      });
      return { kind: 'review' as const };
    }

    tx.set(useRef, {
      paymentIntentId: payment.paymentIntentId,
      facilityId: params.facilityId,
      reservationId: params.reservationId,
      tenantId: null,
      contractId: null,
      amountReceivedCents: payment.amountReceivedCents,
      refund,
      // The account holding the payment, for the sweep that finishes a refund
      // nobody retries (sweepStalledMoveInRefunds).
      connectAccountId: params.connectAccountId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'publicMoveIn',
    });
    tx.set(alertRef(params.facilityId, refundAlertId(payment.paymentIntentId)), {
      type: ONLINE_MOVE_IN_REVIEW_TYPE,
      facilityId: params.facilityId,
      tenantId: null,
      tenantName: params.renterName,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      readAt: null,
      message: ownerMessage(params, refusal, payment.amountReceivedCents, 'pending', payment.paymentIntentId),
      metadata: {
        reason: refusal,
        unitId: params.unitId,
        unitNumber: params.unitNumber,
        reservationId: params.reservationId,
        paymentIntentId: payment.paymentIntentId,
        amountCents: payment.amountReceivedCents,
        refundStatus: 'pending',
      },
    });
    const reservationStatus = String(reservation.status || '');
    if (
      closesReservation(refusal) &&
      reservationSnap.exists &&
      ['pending', 'confirmed', 'expired'].includes(reservationStatus)
    ) {
      tx.update(reservationRef, {
        status: 'cancelled',
        cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
        cancelledBy: 'publicMoveIn',
        cancelReason: `paid-move-in-refused:${refusal}`,
        refundedPaymentIntentId: payment.paymentIntentId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      // The unit is not being rented on this reservation any more.
      if (holdRef && holdSnap?.exists && holdSnap.data()?.reservationId === params.reservationId) {
        tx.delete(holdRef);
      }
    }
    return { kind: 'decided' as const };
  });

  functions.logger.warn('Public move-in refused after payment', {
    facilityId: params.facilityId,
    reservationId: params.reservationId,
    paymentIntentId: payment.paymentIntentId,
    refusal,
    ownership,
    outcome: decided.kind,
  });

  if (decided.kind === 'review') throw paymentUnderReviewError(refusal, payment);
  if (decided.kind === 'resume') {
    return resumePaidMoveInRefund(params, payment.paymentIntentId, decided.record);
  }
  return finishRefund(params, payment.paymentIntentId, payment.amountReceivedCents, refund);
}

/**
 * Finishes a refund already decided for [paymentIntentId] (its one-use record
 * holds `refund`): a completion retried after the instance died between the
 * decision and Stripe, or after Stripe failed, refunds it then.
 */
export async function resumePaidMoveInRefund(
  ctx: Pick<PaidMoveInContext, 'facilityId' | 'connectAccountId'>,
  paymentIntentId: string,
  record: Record<string, any>,
): Promise<never> {
  const refund = record.refund as RefundRecord;
  return finishRefund(
    {
      facilityId: String(record.facilityId || ctx.facilityId),
      connectAccountId: ctx.connectAccountId,
      reservationId: String(record.reservationId || ''),
    },
    paymentIntentId,
    Number(record.amountReceivedCents) || 0,
    refund,
  );
}

/**
 * A refund decided this long ago and still 'pending' was left by a
 * completion that died, or timed out, between deciding it and hearing from
 * Stripe. Longer than a completion runs, so the sweep does not race a live
 * one; the idempotency key would make that harmless anyway.
 */
export const STALLED_REFUND_MINUTES = 15;

/** Most stalled refunds one sweep finishes; any more wait for the next run. */
const STALLED_REFUND_BATCH = 50;

/**
 * Finishes refunds decided but never made. Before, only the renter trying
 * again finished one: a renter who gave up was never refunded, and the
 * owner's alert still said the refund was under way. Same idempotency key as
 * the first attempt, so a refund Stripe did make is not made again.
 */
export async function sweepStalledMoveInRefunds(now: Date): Promise<{ finished: number; skipped: number }> {
  const snap = await admin.firestore()
    .collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION)
    .where('refund.status', '==', 'pending')
    .limit(STALLED_REFUND_BATCH)
    .get();
  let finished = 0;
  let skipped = 0;
  for (const doc of snap.docs) {
    const record = (doc.data() || {}) as Record<string, any>;
    const decidedAt = typeof record.createdAt?.toMillis === 'function' ? Number(record.createdAt.toMillis()) : null;
    if (decidedAt == null || now.getTime() - decidedAt < STALLED_REFUND_MINUTES * 60 * 1000) {
      skipped += 1;
      continue;
    }
    const facilityId = String(record.facilityId || '').trim();
    let connectAccountId = String(record.connectAccountId || '').trim();
    if (!connectAccountId && facilityId) {
      // Records written before the account was kept on them.
      const facility = await admin.firestore().collection('facilities').doc(facilityId).get();
      connectAccountId = resolveMoveInPaymentStripeAccountId(facility.data() || {}) || '';
    }
    if (!facilityId || !connectAccountId) {
      functions.logger.error('Public move-in: a stalled refund has no facility or Stripe account', {
        paymentIntentId: doc.id,
        facilityId,
      });
      skipped += 1;
      continue;
    }
    try {
      await resumePaidMoveInRefund({ facilityId, connectAccountId }, doc.id, record);
    } catch (err: unknown) {
      // It ends by throwing the renter's error, once the outcome is recorded.
      if (!(err instanceof functions.https.HttpsError)) {
        functions.logger.error('Public move-in: could not finish a stalled refund', {
          paymentIntentId: doc.id,
          facilityId,
          error: err instanceof Error ? err.message : String(err),
        });
        skipped += 1;
        continue;
      }
    }
    finished += 1;
  }
  if (finished > 0) {
    functions.logger.warn('Public move-in: finished stalled refunds', { finished, skipped });
  }
  return { finished, skipped };
}
