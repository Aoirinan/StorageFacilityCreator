import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  PUBLIC_MOVE_IN_PAYMENTS_COLLECTION,
  getStripeClient,
  moveInPaymentReturnedBeforeMoveIn,
  timestampToDate,
} from '@sfc/functions-shared';
import { ONLINE_MOVE_IN_REVIEW_TYPE } from './onlineMoveInReview';
import { resolveMoveInPaymentStripeAccountId } from './moveInPayment';
import {
  CHECKOUT_PAID_AT_FIELD,
  CHECKOUT_PAID_FIELD,
  CHECKOUT_REOPENED_AT_FIELD,
  CHECKOUT_SESSION_EXPIRES_FIELD,
  PAID_HOLD_MAX_HOURS,
  REPAY_AFTER_REFUND_MINUTES,
} from './checkoutHold';

/**
 * One document per PaymentIntent that has completed an online move-in, or
 * that was refunded because it could not, keyed by the PaymentIntent id. Top
 * level rather than under the facility, so a connected account shared by two
 * facilities cannot spend one payment at each. (Named in functions-shared, as
 * the Connect webhook reads it too.)
 */
export { PUBLIC_MOVE_IN_PAYMENTS_COLLECTION };

export const PAYMENT_ALREADY_USED_MESSAGE =
  'This payment has already been used to complete a move-in. Contact the facility.';

/**
 * For a payment refunded in Stripe, or disputed, before the move-in was
 * completed: the Connect webhook recorded that on its use record
 * (moveInPaymentReturnedBeforeMoveIn), which stops it moving anyone in. It
 * did not complete a move-in, so PAYMENT_ALREADY_USED_MESSAGE was untrue.
 */
export const PAYMENT_RETURNED_BEFORE_MOVE_IN_MESSAGE =
  'Part or all of this payment was refunded, or the charge was disputed with the card issuer, before the ' +
  'move-in was finished, so it cannot be used to move in. Contact the facility.';

/** For a paid Checkout Session whose payment completion refused and refunded. */
export const PAYMENT_REFUNDED_MESSAGE =
  'This payment was refunded, as the move-in could not be completed with it. To move in, pay the amount now due.';

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
  | 'portal-link'
  // Paid, and did not finish the move-in form within PAID_HOLD_MAX_HOURS
  // (the sweep, unfinishedPaidMoveInSweep.ts).
  | 'not-finished';

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
  'not-finished': `This move-in was not finished within ${PAID_HOLD_MAX_HOURS} hours of paying, so it was cancelled.`,
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
  'not-finished': `they did not finish moving in online within ${PAID_HOLD_MAX_HOURS} hours of paying`,
};

/**
 * Refusals that end the reservation. After a change in the charges the renter
 * can pay the new amount on the same reservation, if they start within
 * REPAY_AFTER_REFUND_MINUTES.
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
  /**
   * 'pending': decided, and either Stripe not yet asked (no refundId) or
   * Stripe's refund not final (refundId, stripeStatus). 'refunded' is final
   * and never overwritten. 'failed': retried by the sweep at retryAt, up to
   * MAX_REFUND_ATTEMPTS requests in all.
   */
  status: RefundState;
  refusal: PaidMoveInRefusal;
  unitId: string | null;
  unitNumber: string;
  renterName: string;
  refundId?: string | null;
  error?: string | null;
  /** Stripe's status of refundId while it is not final ('pending', 'requires_action'). */
  stripeStatus?: string | null;
  /** Refund requests made to Stripe so far. */
  attempts?: number;
  /** When the sweep next retries a failed refund; null once refunded or out of attempts. */
  retryAt?: admin.firestore.Timestamp | null;
}

/**
 * Refund requests made for one payment before the sweep stops and leaves the
 * refund to the owner. Stripe keeps a failed request's answer under its
 * idempotency key for a day, so each retry has its own key
 * (refundIdempotencyKey). A refund Stripe did make is not made again: each
 * request refunds the whole payment, and Stripe refuses one already refunded
 * (charge_already_refunded), which is recorded as refunded.
 */
export const MAX_REFUND_ATTEMPTS = 4;

/** Minutes after failed request n (1-based) before the sweep tries again. */
const RETRY_AFTER_MINUTES = [15, 60, 6 * 60];

/** The first request's key, as before; each retry has its own, so Stripe really tries again. */
export function refundIdempotencyKey(paymentIntentId: string, attempt: number): string {
  const base = `public_move_in_refund_${paymentIntentId}`;
  return attempt <= 1 ? base : `${base}_attempt_${attempt}`;
}

/** The owner pays for an automatic refund: Stripe keeps its fee on the original payment. */
const STRIPE_FEE_NOTE = 'Stripe does not return its processing fee on a refund.';

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

function paymentUseRef(paymentIntentId: string): admin.firestore.DocumentReference {
  return admin.firestore().collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntentId);
}

/**
 * Whether completion refused [paymentIntentId] and refunded it: its one-use
 * record holds a refund, in whatever state. Such a payment can never
 * complete a move-in. A refusal for changed charges leaves the reservation
 * open to pay the new amount, and its Checkout Session still shows paid.
 */
export async function isRefundedMoveInPayment(paymentIntentId: string): Promise<boolean> {
  const snap = await paymentUseRef(paymentIntentId).get();
  return Boolean(snap.exists && (snap.data() || {}).refund);
}

/**
 * Why [paymentIntentId] can no longer complete a move-in, from its use
 * record: 'refunded' when completion refused it and refunded it
 * ([isRefundedMoveInPayment]), 'returned' when it was refunded in Stripe or
 * disputed before the move-in (moveInPaymentReturnedBeforeMoveIn). Null
 * when neither applies.
 */
export async function moveInPaymentStoppedBy(paymentIntentId: string): Promise<'refunded' | 'returned' | null> {
  const snap = await paymentUseRef(paymentIntentId).get();
  const use = snap.exists ? ((snap.data() || {}) as Record<string, unknown>) : null;
  if (use?.refund) return 'refunded';
  return moveInPaymentReturnedBeforeMoveIn(use) ? 'returned' : null;
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
  progress: { stripePending?: boolean; attempts?: number; willRetry?: boolean } = {},
): string {
  const head =
    `${ctx.renterName} paid ${dollars(amountCents)} online for unit ${ctx.unitNumber}, ` +
    `but was not moved in because ${OWNER_TEXT[refusal]}.`;
  if (state === 'refunded') return `${head} The payment was refunded to them automatically. ${STRIPE_FEE_NOTE}`;
  if (state === 'failed') {
    if (progress.willRetry) {
      return `${head} The automatic refund failed (${error || 'unknown error'}) and will be tried again ` +
        `automatically, up to ${MAX_REFUND_ATTEMPTS} times in all. If this alert still says it failed after that, ` +
        `refund payment ${paymentIntentId} in your Stripe dashboard.`;
    }
    const tries = (progress.attempts ?? 0) > 1 ? ` ${progress.attempts} times` : '';
    return `${head} The automatic refund failed${tries} (${error || 'unknown error'}). ` +
      `Refund payment ${paymentIntentId} in your Stripe dashboard.`;
  }
  if (progress.stripePending) {
    return `${head} Stripe has accepted the refund and shows it as pending; this alert will say when it has ` +
      `gone through. ${STRIPE_FEE_NOTE}`;
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
  refundStarted = false,
): functions.https.HttpsError {
  const suffix = state === 'refunded'
    ? ` Your payment of ${dollars(amountCents)} has been refunded to your card; it can take 5 to 10 business days to appear.`
    : state === 'pending' && refundStarted
      ? ` Your payment of ${dollars(amountCents)} is being refunded to your card; it can take 5 to 10 business days to appear.`
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

export type PaymentOwnership = 'this-reservation' | 'another' | 'unknown';

/**
 * Whether [payment] was made for this reservation, which is what makes a
 * refund safe: refunding a payment made for something else would take the
 * owner's money on a stranger's say-so. Completion asks it too before a
 * payment naming no reservation finishes a move-in whose hold has lapsed.
 * Its metadata says so (checkout sets it from now on), or else the Checkout
 * Session that took it does (older sessions set only their own metadata).
 * 'unknown' when Stripe cannot be asked.
 */
export async function paymentOwnership(
  ctx: Pick<PaidMoveInContext, 'facilityId' | 'connectAccountId' | 'reservationId'>,
  payment: OfferedPayment,
): Promise<PaymentOwnership> {
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

/** What Stripe said to one refund request. */
type RefundAnswer =
  | { state: 'refunded'; refundId: string | null }
  | { state: 'pending'; refundId: string; stripeStatus: string }
  | { state: 'failed'; refundId: string | null; error: string };

/** Stripe's refund status, as a record's state. A refund object with no status is taken as made. */
function answerOf(refund: { id?: string | null; status?: string | null; failure_reason?: string | null }): RefundAnswer {
  const refundId = refund.id || null;
  const status = String(refund.status || 'succeeded');
  if (status === 'succeeded') return { state: 'refunded', refundId };
  if ((status === 'pending' || status === 'requires_action') && refundId) {
    return { state: 'pending', refundId, stripeStatus: status };
  }
  return { state: 'failed', refundId, error: `Stripe ${status}${refund.failure_reason ? `: ${refund.failure_reason}` : ''}` };
}

/**
 * Refunds the whole payment on the connected account that holds it. Request
 * [attempt]'s idempotency key (refundIdempotencyKey) makes a retried request
 * of the same attempt one refund; a later attempt's request is refused by
 * Stripe as already refunded if an earlier one was made.
 */
async function issueRefund(
  ctx: Pick<PaidMoveInContext, 'facilityId' | 'connectAccountId' | 'reservationId'>,
  paymentIntentId: string,
  refusal: PaidMoveInRefusal,
  attempt: number,
): Promise<RefundAnswer> {
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
      { stripeAccount: ctx.connectAccountId, idempotencyKey: refundIdempotencyKey(paymentIntentId, attempt) },
    );
    return answerOf(refund);
  } catch (err: any) {
    if (err?.code === 'charge_already_refunded') return { state: 'refunded', refundId: null };
    functions.logger.error('Public move-in: automatic refund failed', {
      facilityId: ctx.facilityId,
      reservationId: ctx.reservationId,
      paymentIntentId,
      refusal,
      attempt,
      error: err?.message || String(err),
    });
    return { state: 'failed', refundId: null, error: String(err?.message || err || 'unknown error').slice(0, 300) };
  }
}

/**
 * What asking Stripe now changes about [refund], or null when there is
 * nothing to ask: refunded already; a failed one out of attempts, or not yet
 * due (retryAt); or a refund Stripe still shows pending, or could not be read.
 * A refund Stripe has (refundId) and has not finished is looked up, not asked
 * for again: Stripe answers a repeated request with its first answer.
 */
async function askStripe(
  ctx: Pick<PaidMoveInContext, 'facilityId' | 'connectAccountId' | 'reservationId'>,
  paymentIntentId: string,
  refund: RefundRecord,
  now: Date,
): Promise<Partial<RefundRecord> | null> {
  const attempts = Number(refund.attempts) || (refund.status === 'failed' ? 1 : 0);
  let answer: RefundAnswer;
  let attempt = attempts;
  if (refund.status === 'refunded') return null;
  if (refund.status === 'pending' && refund.refundId) {
    try {
      const current = await getStripeClient().refunds.retrieve(refund.refundId, {}, { stripeAccount: ctx.connectAccountId });
      answer = answerOf(current);
    } catch (err: any) {
      functions.logger.warn('Public move-in: could not look up a pending refund', {
        facilityId: ctx.facilityId,
        paymentIntentId,
        refundId: refund.refundId,
        error: err?.message || String(err),
      });
      return null;
    }
    if (answer.state === 'pending') return null;
  } else {
    if (refund.status === 'failed') {
      const due = timestampToDate(refund.retryAt);
      if (attempts >= MAX_REFUND_ATTEMPTS || !due || due > now) return null;
    }
    attempt = attempts + 1;
    answer = await issueRefund(ctx, paymentIntentId, refund.refusal, attempt);
  }
  if (answer.state === 'refunded') {
    return { status: 'refunded', refundId: answer.refundId, error: null, stripeStatus: null, attempts: attempt, retryAt: null };
  }
  if (answer.state === 'pending') {
    return {
      status: 'pending',
      refundId: answer.refundId,
      error: null,
      stripeStatus: answer.stripeStatus,
      attempts: attempt,
      retryAt: null,
    };
  }
  const retryMinutes = RETRY_AFTER_MINUTES[attempt - 1];
  return {
    status: 'failed',
    refundId: answer.refundId,
    error: answer.error,
    stripeStatus: null,
    attempts: attempt,
    retryAt: attempt < MAX_REFUND_ATTEMPTS && retryMinutes
      ? admin.firestore.Timestamp.fromMillis(now.getTime() + retryMinutes * 60 * 1000)
      : null,
  };
}

/**
 * Asks Stripe for (or about) the refund a record holds, records how it went
 * and tells the renter. The outcome is written in a transaction that reads
 * the record first: a refund another finisher recorded as made is never
 * overwritten (a request that failed here after one that succeeded there
 * wrote 'failed' over 'refunded' before, and told the owner to refund by hand
 * a payment already refunded), nor is a later attempt's outcome.
 */
async function finishRefund(
  ctx: Pick<PaidMoveInContext, 'facilityId' | 'connectAccountId' | 'reservationId'>,
  paymentIntentId: string,
  amountCents: number,
  refund: RefundRecord,
  now: Date = new Date(),
): Promise<never> {
  let stored: RefundRecord = refund;
  const change = await askStripe(ctx, paymentIntentId, refund, now);
  if (change) {
    const next: RefundRecord = { ...refund, ...change };
    try {
      stored = await admin.firestore().runTransaction(async (tx): Promise<RefundRecord> => {
        const snap = await tx.get(paymentUseRef(paymentIntentId));
        const current = ((snap.data() || {}) as Record<string, any>).refund as RefundRecord | undefined;
        if (!current) return next;
        if (current.status === 'refunded') return current;
        if ((Number(current.attempts) || 0) > (Number(next.attempts) || 0)) return current;
        const merged: RefundRecord = { ...current, ...change };
        tx.set(
          paymentUseRef(paymentIntentId),
          { refund: merged, updatedAt: admin.firestore.FieldValue.serverTimestamp() },
          { merge: true },
        );
        const changed = current.status !== merged.status ||
          (current.refundId ?? null) !== (merged.refundId ?? null) ||
          (current.attempts ?? 0) !== (merged.attempts ?? 0);
        if (changed) {
          tx.set(
            alertRef(ctx.facilityId, refundAlertId(paymentIntentId)),
            {
              message: ownerMessage(merged, merged.refusal, amountCents, merged.status, paymentIntentId, merged.error, {
                stripePending: merged.status === 'pending' && Boolean(merged.refundId),
                attempts: merged.attempts,
                willRetry: merged.status === 'failed' && merged.retryAt != null,
              }),
              metadata: { refundStatus: merged.status, refundId: merged.refundId ?? null },
              // Shown again even if read: the outcome says whether the owner
              // has a refund to make by hand, or no longer has one.
              readAt: null,
            },
            { merge: true },
          );
        }
        return merged;
      });
    } catch (err: any) {
      // The decision and the alert were written first, so a failure here
      // leaves the record as it was, and the next completion or the sweep
      // asks Stripe again (with the same attempt's key).
      stored = next;
      functions.logger.error('Public move-in: could not record a refund outcome', {
        facilityId: ctx.facilityId,
        paymentIntentId,
        state: next.status,
        error: err?.message || String(err),
      });
    }
  }
  throw renterError(stored.refusal, amountCents, stored.status, paymentIntentId, Boolean(stored.refundId));
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
  /** Already shown to be this reservation's (paymentOwnership), so Stripe is not asked again. */
  knownToBeThisReservations?: boolean;
}): Promise<never> {
  const { refusal, payment } = params;
  const ownership = params.knownToBeThisReservations
    ? 'this-reservation' as const
    : await paymentOwnership(params, payment);
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
      // Refunded already: finish that one. Refunded or disputed in Stripe
      // before any move-in: left to the owner, whom the webhook told. Used:
      // it completed a move-in, and is not refunded.
      if (used.refund) return { kind: 'resume' as const, record: used };
      if (moveInPaymentReturnedBeforeMoveIn(used)) {
        throw new functions.https.HttpsError('failed-precondition', PAYMENT_RETURNED_BEFORE_MOVE_IN_MESSAGE);
      }
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
    } else if (reservationSnap.exists && ['pending', 'confirmed', 'expired'].includes(reservationStatus)) {
      // Left open to pay the new amount. Until the renter starts paying
      // again they are paying for nothing: their session was paid, and this
      // payment is being refunded. Counted as paying (holderMayBePaying), a
      // renter whose own hold had lapsed was refunded for them.
      //
      // The reservation and its hold on the unit are cut back to
      // REPAY_AFTER_REFUND_MINUTES from now (one ending sooner is left as it
      // is): the webhook had held both until a day after the payment (each
      // confirmation of it, for an hour), which kept the unit from everyone
      // for that time if this renter did not pay again. Checkout's
      // MAX_HOLD_MINUTES count from now (CHECKOUT_REOPENED_AT_FIELD), so the
      // renter can pay again however long ago the unit was first held. Not
      // done while the reservation records another payment, not yet used:
      // the hold is that payment's.
      const now = admin.firestore.Timestamp.now();
      const paidWith = reservation[CHECKOUT_PAID_FIELD];
      const reopens = !paidWith || paidWith === payment.paymentIntentId;
      const repayUntil = admin.firestore.Timestamp.fromMillis(
        now.toMillis() + REPAY_AFTER_REFUND_MINUTES * 60 * 1000,
      );
      const endsLater = (expiry: unknown): boolean =>
        (timestampToDate(expiry)?.getTime() ?? 0) > repayUntil.toMillis();
      const hold = (holdSnap?.data() || null) as Record<string, unknown> | null;
      if (reopens && holdRef && hold?.reservationId === params.reservationId && endsLater(hold.expiresAt)) {
        tx.update(holdRef, { expiresAt: repayUntil, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
      }
      tx.update(reservationRef, {
        [CHECKOUT_SESSION_EXPIRES_FIELD]: now,
        ...(reopens
          ? {
            [CHECKOUT_REOPENED_AT_FIELD]: now,
            ...(endsLater(reservation.expiresAt) ? { expiresAt: repayUntil } : {}),
          }
          : {}),
        ...(paidWith === payment.paymentIntentId
          ? {
            [CHECKOUT_PAID_FIELD]: admin.firestore.FieldValue.delete(),
            [CHECKOUT_PAID_AT_FIELD]: admin.firestore.FieldValue.delete(),
          }
          : {}),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
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
 *
 * On the account the record names, which is the one that took the payment:
 * [ctx]'s (the facility's account now) only for a record written before
 * records kept it. The facility's current account refunded nothing, or the
 * wrong payment, once the owner had moved to another Stripe account.
 */
export async function resumePaidMoveInRefund(
  ctx: Pick<PaidMoveInContext, 'facilityId' | 'connectAccountId'>,
  paymentIntentId: string,
  record: Record<string, any>,
  now: Date = new Date(),
): Promise<never> {
  const refund = record.refund as RefundRecord;
  return finishRefund(
    {
      facilityId: String(record.facilityId || ctx.facilityId),
      connectAccountId: String(record.connectAccountId || '').trim() || ctx.connectAccountId,
      reservationId: String(record.reservationId || ''),
    },
    paymentIntentId,
    Number(record.amountReceivedCents) || 0,
    refund,
    now,
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
 * Finishes refunds decided but never made, looks again at refunds Stripe
 * showed pending, and retries failed ones that are due. Before, only the
 * renter trying again finished one: a renter who gave up was never refunded,
 * and the owner's alert still said the refund was under way; a failed one
 * waited for the owner.
 *
 * Only refunds already stalled are read, oldest first (index: refund.status,
 * createdAt in firestore.indexes.json). Read unordered and unfiltered, a
 * batch could fill with refunds too recent to finish, and older stalled ones
 * behind them waited for good. Failed refunds are read by refund.retryAt,
 * which is set only while one has attempts left, so one given up on leaves
 * the query (a single-field index, which Firestore keeps by default).
 */
export async function sweepStalledMoveInRefunds(now: Date): Promise<{ finished: number; skipped: number }> {
  const stalledBefore = admin.firestore.Timestamp.fromMillis(now.getTime() - STALLED_REFUND_MINUTES * 60 * 1000);
  const collection = admin.firestore().collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION);
  const [stalled, retries] = await Promise.all([
    collection
      .where('refund.status', '==', 'pending')
      .where('createdAt', '<=', stalledBefore)
      .orderBy('createdAt', 'asc')
      .limit(STALLED_REFUND_BATCH)
      .get(),
    collection
      .where('refund.retryAt', '<=', admin.firestore.Timestamp.fromDate(now))
      .orderBy('refund.retryAt', 'asc')
      .limit(STALLED_REFUND_BATCH)
      .get(),
  ]);
  let finished = 0;
  let skipped = 0;
  const seen = new Set<string>();
  for (const doc of [...stalled.docs, ...retries.docs]) {
    if (seen.has(doc.id)) continue;
    seen.add(doc.id);
    const record = (doc.data() || {}) as Record<string, any>;
    const refund = (record.refund || {}) as Partial<RefundRecord>;
    if (refund.status === 'pending') {
      const decidedAt = typeof record.createdAt?.toMillis === 'function' ? Number(record.createdAt.toMillis()) : null;
      if (decidedAt == null || now.getTime() - decidedAt < STALLED_REFUND_MINUTES * 60 * 1000) {
        skipped += 1;
        continue;
      }
    } else if (refund.status !== 'failed') {
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
      await resumePaidMoveInRefund({ facilityId, connectAccountId }, doc.id, record, now);
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
