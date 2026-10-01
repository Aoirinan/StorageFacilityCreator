import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { UNTENANTED_DISPUTES_FIELD, UNTENANTED_REFUNDS_FIELD } from '@sfc/functions-shared';

/**
 * Online move-in payments and the tenant they paid for.
 *
 * An online move-in's PaymentIntent carries only `type: 'public_move_in'` and
 * `reservationId` (functions-public-website publicMoveIn.ts); ones made
 * before checkout stopped adding it carry `facilityId` too. The renter is not
 * a tenant yet when they pay. So a refund or a card dispute on one found no
 * `tenantId`, and the webhook wrote its ledger row with `tenantId: null`: on
 * no tenant's ledger, and nobody told. With no `facilityId` either, the
 * refund and dispute handlers stopped before looking: the facility is found
 * through the same records ([moveInPaymentFacilityId]).
 *
 * The tenant is found where completing the move-in recorded it, in the same
 * transaction that created them: `publicMoveInPayments/{paymentIntentId}`
 * (from when that record existed), or else the reservation, which keeps the
 * PaymentIntent and the tenant it became (`publicReservations/{id}`
 * `paymentIntentId`, `tenantId`).
 *
 * When there is no tenant (the renter was refunded, or disputed the charge,
 * before the move-in was completed) nothing goes on any ledger. The refund or
 * dispute is recorded on `publicMoveInPayments/{paymentIntentId}` and the
 * owner gets an in-app notification. That record also stops the payment from
 * completing a move-in afterwards (completePublicMoveIn refuses a payment
 * that has one), which is right: the money has been handed back or taken
 * back.
 */
export const PUBLIC_MOVE_IN_PAYMENTS_COLLECTION = 'publicMoveInPayments';
export const PUBLIC_MOVE_IN_PAYMENT_TYPE = 'public_move_in';

type PaymentIntentLike = { id: string; metadata?: Record<string, string> | null };

export function isMoveInPaymentIntent(paymentIntent: PaymentIntentLike): boolean {
  return paymentIntent.metadata?.type === PUBLIC_MOVE_IN_PAYMENT_TYPE;
}

export type UntenantedMoveInMoney =
  | { kind: 'refund'; id: string; amountCents: number; status: string | null }
  | { kind: 'dispute'; id: string; amountCents: number; status: string | null; reason: string | null };

export type MoveInTenantResolution =
  /** The tenant the payment moved in. */
  | { tenantId: string; source: 'move_in_payment' | 'reservation' }
  /** No tenant: recorded on the move-in payment record instead (and the owner told, once). */
  | { tenantId: null; recorded: true }
  /** The records name another facility: nothing written anywhere. */
  | { tenantId: null; recorded: false };

const DOC_ID = /^[^/]{1,128}$/;

function docIdOf(value: unknown): string | null {
  const text = typeof value === 'string' ? value.trim() : '';
  return DOC_ID.test(text) ? text : null;
}

/**
 * The facility an online move-in PaymentIntent paid, when its metadata does
 * not name one: checkout leaves `facilityId` off the PaymentIntent, so the
 * old charge.refunded handler could not post a move-in's refund to a ledger
 * the move-in had never posted its payment to. Without this, every refund
 * and dispute on such a payment was dropped before the tenant lookup below:
 * a renter who disputed the charge, or was refunded from the Dashboard,
 * could still complete the move-in, and one who had completed it never had
 * the refund or dispute posted.
 *
 * Read from the move-in's own records, both written by the server: the use
 * record (`publicMoveInPayments/{paymentIntentId}.facilityId`), else the
 * reservation the PaymentIntent names (`publicReservations/{reservationId}`).
 * Null when neither names one. The caller still checks that the event came
 * from that facility's own connected account (eventAccountMatchesFacility):
 * anyone can put a reservation id in a PaymentIntent's metadata.
 */
export async function moveInPaymentFacilityId(paymentIntent: PaymentIntentLike): Promise<string | null> {
  const db = admin.firestore();
  const payment = await db.collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntent.id).get();
  const fromPayment = payment.exists ? docIdOf(payment.get('facilityId')) : null;
  if (fromPayment) return fromPayment;
  const reservationId = docIdOf(paymentIntent.metadata?.reservationId);
  if (!reservationId) return null;
  const reservation = await db.collection('publicReservations').doc(reservationId).get();
  return reservation.exists ? docIdOf(reservation.get('facilityId')) : null;
}

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

function alertId(money: UntenantedMoveInMoney): string {
  return money.kind === 'refund' ? `moveInPaymentRefund_${money.id}` : `moveInPaymentDispute_${money.id}`;
}

function alertMessage(money: UntenantedMoveInMoney, reservationId: string | null): string {
  const reservation = reservationId ? ` (reservation ${reservationId})` : '';
  if (money.kind === 'refund') {
    return (
      `A refund of ${dollars(money.amountCents)} was made on an online move-in payment${reservation} ` +
      'that never completed a move-in, so there is no tenant to post it to and nothing was put on any ledger. ' +
      'That payment can no longer be used to move in. Check the reservation and the payment in your Stripe Dashboard.'
    );
  }
  return (
    `A card dispute of ${dollars(money.amountCents)}` +
    (money.reason ? ` (${money.reason})` : '') +
    ` was opened on an online move-in payment${reservation} that never completed a move-in, ` +
    'so there is no tenant to post it to and nothing was put on any ledger. That payment can no longer be used ' +
    'to move in. Respond to the dispute in your Stripe Dashboard.'
  );
}

/**
 * The tenant a move-in PaymentIntent paid for, or, when there is none, a
 * record of [money] on the move-in payment record and an owner alert.
 *
 * One transaction: completing a move-in writes its payment record in a
 * transaction too, so either the move-in finished first (and its tenant is
 * found here) or this record exists first (and the move-in is refused).
 * Throws on Firestore failure so the webhook returns 500 and Stripe retries.
 */
export async function resolveMoveInTenantOrRecord(params: {
  facilityId: string;
  paymentIntent: PaymentIntentLike;
  connectedAccountId: string | null | undefined;
  money: UntenantedMoveInMoney;
  now?: Date;
}): Promise<MoveInTenantResolution> {
  const { facilityId, paymentIntent, money } = params;
  const db = admin.firestore();
  const reservationId = docIdOf(paymentIntent.metadata?.reservationId);
  const paymentRef = db.collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntent.id);
  const reservationRef = reservationId ? db.collection('publicReservations').doc(reservationId) : null;
  const facilityRef = db.collection('facilities').doc(facilityId);
  const notificationRef = facilityRef.collection('Notifications').doc(alertId(money));
  const timestamp = admin.firestore.Timestamp.fromDate(params.now ?? new Date());

  const outcome = await db.runTransaction(async (tx): Promise<MoveInTenantResolution> => {
    const paymentSnap = await tx.get(paymentRef);
    const reservationSnap = reservationRef ? await tx.get(reservationRef) : null;
    const notificationSnap = await tx.get(notificationRef);

    const payment = paymentSnap.exists ? ((paymentSnap.data() || {}) as Record<string, unknown>) : null;
    if (payment && payment.facilityId !== facilityId) return { tenantId: null, recorded: false };
    if (payment && typeof payment.tenantId === 'string' && payment.tenantId) {
      return { tenantId: payment.tenantId, source: 'move_in_payment' };
    }

    const reservation = reservationSnap?.exists ? ((reservationSnap.data() || {}) as Record<string, unknown>) : null;
    if (
      reservation &&
      reservation.facilityId === facilityId &&
      reservation.paymentIntentId === paymentIntent.id &&
      typeof reservation.tenantId === 'string' &&
      reservation.tenantId
    ) {
      return { tenantId: reservation.tenantId, source: 'reservation' };
    }

    const field = money.kind === 'refund' ? UNTENANTED_REFUNDS_FIELD : UNTENANTED_DISPUTES_FIELD;
    const entry: Record<string, unknown> = {
      amountCents: money.amountCents,
      status: money.status,
      recordedAt: timestamp,
      connectedAccountId: params.connectedAccountId || null,
      ...(money.kind === 'dispute' ? { reason: money.reason } : {}),
    };
    tx.set(
      paymentRef,
      {
        paymentIntentId: paymentIntent.id,
        facilityId,
        reservationId,
        [field]: { [money.id]: entry },
        updatedAt: timestamp,
        updatedBy: 'system@stripe-webhook',
      },
      { merge: true },
    );
    // Once. And not for a refund the move-in itself made because it could
    // not complete: that path records `refund` here and tells the owner.
    const ownerAlreadyTold = money.kind === 'refund' && Boolean(payment?.refund);
    if (!notificationSnap.exists && !ownerAlreadyTold) {
      tx.set(notificationRef, {
        facilityId,
        tenantId: null,
        tenantName: null,
        type: 'STRIPE_ACTION_REQUIRED',
        message: alertMessage(money, reservationId),
        readAt: null,
        createdAt: timestamp,
        createdBy: 'system@stripe-webhook',
        metadata: {
          reason: money.kind === 'refund' ? 'move_in_refund_without_tenant' : 'move_in_dispute_without_tenant',
          paymentIntentId: paymentIntent.id,
          reservationId,
          [money.kind === 'refund' ? 'refundId' : 'disputeId']: money.id,
          amountCents: money.amountCents,
        },
      });
    }
    return { tenantId: null, recorded: true };
  });

  if (outcome.tenantId === null) {
    const log = outcome.recorded ? functions.logger.warn : functions.logger.error;
    log(
      outcome.recorded
        ? `Move-in payment ${money.kind} with no tenant: recorded on the move-in payment, not on a ledger`
        : `Move-in payment ${money.kind}: its move-in record names another facility; nothing written`,
      { facilityId, paymentIntentId: paymentIntent.id, [`${money.kind}Id`]: money.id },
    );
  }
  return outcome;
}
