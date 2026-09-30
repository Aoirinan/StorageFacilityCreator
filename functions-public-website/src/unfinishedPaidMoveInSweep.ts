/**
 * Renters who paid for an online move-in and never finished it.
 *
 * Only the renter coming back used to react to a paid Checkout Session: one
 * who paid and closed the tab was never moved in or refunded, the owner was
 * never told, and once the hold lapsed another renter could hold and pay for
 * the unit, which then refunded the first payer as 'unit-held' if they came
 * back. Now every paid session is recorded as a paid checkout
 * (functions-shared recordPaidPublicMoveInCheckout): by the Connect webhook as
 * it is paid, by the move-in page confirming it, or by
 * findPaidSessionsNobodyReported below once the Checkout page has closed. The
 * webhook and the page hold the unit for the payer until PAID_HOLD_MAX_HOURS
 * after payment. Then settleUnfinishedPaidMoveIns, for a payment with no use
 * record UNFINISHED_ALERT_MINUTES after it was made:
 *
 * - refunds it (refusePaidMoveIn, paidMoveInRefund.ts) when the renter can no
 *   longer move in with it: the reservation is closed or gone, or the unit is
 *   gone or taken; or when PAID_HOLD_MAX_HOURS have passed ('not-finished');
 * - otherwise tells the owner once that the renter paid and has not finished.
 *
 * It never moves anyone in: completion needs the renter's signed agreement
 * and details, which only the renter can give.
 *
 * Exactly once: completion and refusePaidMoveIn each decide in a transaction
 * that reads the payment's use record (publicMoveInPayments/{PaymentIntent})
 * and writes it with the tenancy or the refund decision, so whichever commits
 * first wins and the other finds the record: completion then finishes the
 * refund and moves nobody in, refusePaidMoveIn refuses a used payment and
 * refunds nothing. The refund itself is keyed public_move_in_refund_{PI}.
 */
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import {
  CHECKOUT_SESSION_EXPIRES_FIELD,
  PAID_HOLD_MAX_HOURS,
  PUBLIC_MOVE_IN_PAID_CHECKOUTS_COLLECTION,
  PUBLIC_MOVE_IN_PAYMENTS_COLLECTION,
  getStripeClient,
  isLiveHold,
  paidHoldCap,
  readActiveTenantUnitClaims,
  recordPaidPublicMoveInCheckout,
  timestampToDate,
  unitHoldRef,
} from '@sfc/functions-shared';
import { paymentIntentIdOf, recordedCheckoutSession } from './checkoutSessionReuse';
import { resolveMoveInPaymentStripeAccountId } from './moveInPayment';
import { ONLINE_MOVE_IN_REVIEW_TYPE } from './onlineMoveInReview';
import { paymentOwnership, refusePaidMoveIn } from './paidMoveInRefund';
import type { PaidMoveInRefusal } from './paidMoveInRefund';
import { unitIsTaken } from './unitTaken';

/** How long after paying a renter who has not finished is looked at (and the owner told). */
export const UNFINISHED_ALERT_MINUTES = 30;

/**
 * How long after a reservation's last Checkout Session stopped taking payment
 * it is asked about: long enough for Stripe to have settled it.
 */
export const SESSION_SETTLED_MINUTES = 5;

/**
 * On the reservation: the recorded Checkout Session findPaidSessionsNobodyReported
 * has asked Stripe about and settled, so it is not asked again.
 */
export const SWEPT_SESSION_FIELD = 'checkoutSessionSweptId';

const PAGE_SIZE = 50;
const MAX_PAGES = 4;
const DAY_MS = 24 * 60 * 60 * 1000;
const MINUTE_MS = 60 * 1000;

function textOf(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

function unfinishedAlertRef(facilityId: string, paymentIntentId: string): admin.firestore.DocumentReference {
  return admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('Notifications')
    .doc(`move-in-unfinished-${paymentIntentId}`);
}

/** Reads every page of [query] (ordered), up to MAX_PAGES of PAGE_SIZE. */
async function readPages(query: admin.firestore.Query): Promise<admin.firestore.QueryDocumentSnapshot[]> {
  const docs: admin.firestore.QueryDocumentSnapshot[] = [];
  let page = await query.limit(PAGE_SIZE).get();
  for (let n = 1; ; n += 1) {
    docs.push(...page.docs);
    if (page.docs.length < PAGE_SIZE || n >= MAX_PAGES) return docs;
    page = await query.startAfter(page.docs[page.docs.length - 1]).limit(PAGE_SIZE).get();
  }
}

/**
 * The backstop for a paid session neither the webhook nor the renter
 * reported (a webhook never delivered, or functions-integrations deployed
 * after this codebase): each reservation whose last Checkout Session stopped
 * taking payment in the last day, and has not been asked about, is asked
 * about once. A paid one is recorded as the webhook would record it, with
 * the session's creation as its payment time (no later than the payment).
 */
export async function findPaidSessionsNobodyReported(now: Date): Promise<{ recorded: number; checked: number }> {
  const db = admin.firestore();
  const docs = await readPages(
    db.collection('publicReservations')
      .where(CHECKOUT_SESSION_EXPIRES_FIELD, '>=', admin.firestore.Timestamp.fromMillis(now.getTime() - DAY_MS))
      .where(
        CHECKOUT_SESSION_EXPIRES_FIELD,
        '<=',
        admin.firestore.Timestamp.fromMillis(now.getTime() - SESSION_SETTLED_MINUTES * MINUTE_MS),
      )
      .orderBy(CHECKOUT_SESSION_EXPIRES_FIELD, 'asc'),
  );
  let recorded = 0;
  let checked = 0;
  for (const doc of docs) {
    const reservation = (doc.data() || {}) as Record<string, unknown>;
    const session = recordedCheckoutSession(reservation);
    if (!session || reservation.status === 'completed' || textOf(reservation[SWEPT_SESSION_FIELD]) === session.id) {
      continue;
    }
    const facilityId = textOf(reservation.facilityId);
    if (!facilityId) continue;
    let account = session.accountId || '';
    if (!account) {
      const facility = await db.collection('facilities').doc(facilityId).get();
      account = resolveMoveInPaymentStripeAccountId(facility.data() || {}) || '';
    }
    if (!account) continue;
    checked += 1;
    let settled = true;
    try {
      const found = await getStripeClient().checkout.sessions.retrieve(session.id, {}, { stripeAccount: account });
      const paymentIntentId = paymentIntentIdOf(found);
      if (found.metadata?.reservationId !== doc.id) {
        // Not this reservation's: nothing to do with it.
      } else if (found.payment_status === 'paid' && paymentIntentId) {
        const outcome = await recordPaidPublicMoveInCheckout(db, {
          paymentIntentId,
          checkoutSessionId: found.id || session.id,
          reservationId: doc.id,
          facilityId,
          connectAccountId: account,
          amountCents: typeof found.amount_total === 'number' ? found.amount_total : null,
          paidAt: typeof found.created === 'number' && found.created * 1000 < now.getTime()
            ? new Date(found.created * 1000)
            : now,
          now,
          holdMinutes: 'until-cap',
          recordedBy: 'moveInSweep',
        });
        if (outcome !== 'settled' && outcome !== 'not-this-facility') recorded += 1;
        functions.logger.warn('Public move-in: found a paid Checkout Session nobody reported', {
          facilityId,
          reservationId: doc.id,
          sessionId: session.id,
          paymentIntentId,
          outcome,
        });
      } else if (found.status === 'open') {
        // Not settled yet: asked again next run.
        settled = false;
      }
    } catch (err: unknown) {
      if ((err as { code?: string }).code !== 'resource_missing') {
        settled = false;
        functions.logger.warn('Public move-in: could not ask Stripe about a recorded Checkout Session', {
          facilityId,
          reservationId: doc.id,
          sessionId: session.id,
          message: err instanceof Error ? err.message : String(err),
        });
      }
    }
    if (settled) {
      try {
        await doc.ref.set({ [SWEPT_SESSION_FIELD]: session.id }, { merge: true });
      } catch (err: unknown) {
        functions.logger.warn('Public move-in: could not mark a Checkout Session as looked at', {
          reservationId: doc.id,
          message: err instanceof Error ? err.message : String(err),
        });
      }
    }
  }
  return { recorded, checked };
}

/**
 * Deletes the paid-checkout record of a payment that now has a use record
 * (it moved the renter in, or it is being refunded), and marks the owner's
 * "has not finished" alert, if one was sent, as dealt with. 'open' while the
 * payment has no use record.
 */
async function closePaidCheckout(paymentIntentId: string): Promise<'open' | 'moved-in' | 'refunded'> {
  const db = admin.firestore();
  const paidRef = db.collection(PUBLIC_MOVE_IN_PAID_CHECKOUTS_COLLECTION).doc(paymentIntentId);
  const useRef = db.collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntentId);
  return db.runTransaction(async (tx) => {
    const useSnap = await tx.get(useRef);
    const paidSnap = await tx.get(paidRef);
    if (!useSnap.exists) return 'open' as const;
    const outcome = (useSnap.data() || {}).refund ? 'refunded' as const : 'moved-in' as const;
    if (!paidSnap.exists) return outcome;
    const paid = (paidSnap.data() || {}) as Record<string, unknown>;
    const facilityId = textOf(paid.facilityId);
    const alertRef = paid.ownerAlertedAt && facilityId ? unfinishedAlertRef(facilityId, paymentIntentId) : null;
    const alertSnap = alertRef ? await tx.get(alertRef) : null;
    tx.delete(paidRef);
    if (alertRef && alertSnap?.exists) {
      const meta = ((alertSnap.data() || {}).metadata || {}) as Record<string, unknown>;
      const who = `${textOf(meta.renterName) || 'The renter'} paid online for unit ${textOf(meta.unitNumber) || '?'}`;
      tx.set(alertRef, {
        message: outcome === 'refunded'
          ? `${who} and did not finish moving in, so the payment went to a refund instead. ` +
            'The refund alert for this payment says how that went.'
          : `${who} and has now finished moving in.`,
        readAt: admin.firestore.FieldValue.serverTimestamp(),
        metadata: { resolution: outcome },
      }, { merge: true });
    }
    return outcome;
  });
}

/**
 * Why a renter who paid for [reservation] ([reservationId]) at [paidAt] can
 * no longer move in with it, or null while they still can. The same rules as
 * completion's, for what can be told without the renter: a closed or missing
 * reservation, a missing or taken unit, and the time since paying.
 */
async function refusalFor(
  reservationId: string,
  facilityId: string,
  paidAt: Date,
  now: Date,
): Promise<{ refusal: PaidMoveInRefusal | null; reservation: Record<string, unknown>; unit: Record<string, unknown> | null }> {
  const db = admin.firestore();
  const reservationSnap = await db.collection('publicReservations').doc(reservationId).get();
  const reservation = (reservationSnap.data() || {}) as Record<string, unknown>;
  const status = String(reservation.status || '');
  if (!reservationSnap.exists || !['pending', 'confirmed', 'expired'].includes(status)) {
    return { refusal: 'reservation-closed', reservation, unit: null };
  }
  const unitId = textOf(reservation.unitId);
  let unit: Record<string, unknown> | null = null;
  if (unitId && !unitId.includes('/')) {
    const facilityRef = db.collection('facilities').doc(facilityId);
    const unitSnap = await facilityRef.collection('units').doc(unitId).get();
    if (!unitSnap.exists) return { refusal: 'unit-missing', reservation, unit: null };
    unit = (unitSnap.data() || {}) as Record<string, unknown>;
    if (unitIsTaken(unitId, unit, await readActiveTenantUnitClaims(facilityRef.collection('tenants')))) {
      return { refusal: 'unit-taken', reservation, unit };
    }
  }
  if (now >= paidHoldCap(paidAt)) return { refusal: 'not-finished', reservation, unit };
  return { refusal: null, reservation, unit };
}

/** Tells the owner, once, that a renter paid and has not finished. Not if the payment has been used meanwhile. */
async function alertOwnerOfUnfinishedPayment(params: {
  paymentIntentId: string;
  facilityId: string;
  reservationId: string;
  reservation: Record<string, unknown>;
  unit: Record<string, unknown> | null;
  amountCents: number | null;
}): Promise<boolean> {
  const db = admin.firestore();
  const { paymentIntentId, facilityId, reservationId, reservation, unit } = params;
  const paidRef = db.collection(PUBLIC_MOVE_IN_PAID_CHECKOUTS_COLLECTION).doc(paymentIntentId);
  const useRef = db.collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntentId);
  const unitId = textOf(reservation.unitId);
  const holdRef = unitId && !unitId.includes('/') ? unitHoldRef(db, facilityId, unitId) : null;
  const renterName = textOf(reservation.name) || 'A renter';
  const unitNumber = textOf(unit?.unitNumber) || textOf(reservation.unitNumber) || 'Unassigned';
  return db.runTransaction(async (tx) => {
    const useSnap = await tx.get(useRef);
    const paidSnap = await tx.get(paidRef);
    const holdSnap = holdRef ? await tx.get(holdRef) : null;
    if (useSnap.exists || !paidSnap.exists || (paidSnap.data() || {}).ownerAlertedAt) return false;
    const hold = (holdSnap?.data() || null) as Record<string, unknown> | null;
    const heldForThem = Boolean(hold && hold.reservationId === reservationId && isLiveHold(hold, new Date()));
    const paid = params.amountCents != null && params.amountCents > 0 ? `paid ${dollars(params.amountCents)}` : 'paid';
    tx.set(unfinishedAlertRef(facilityId, paymentIntentId), {
      type: ONLINE_MOVE_IN_REVIEW_TYPE,
      facilityId,
      tenantId: null,
      tenantName: renterName,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      readAt: null,
      message:
        `${renterName} ${paid} online for unit ${unitNumber} but has not finished moving in. ` +
        (heldForThem
          ? `The unit is held for them until ${PAID_HOLD_MAX_HOURS} hours after their payment. `
          : 'The unit is not being held for them right now. ') +
        `If they have not finished online within ${PAID_HOLD_MAX_HOURS} hours of paying, or the unit is rented ` +
        'to someone else first, the payment is refunded to them automatically. If you move them in yourself ' +
        'instead, collect their payment another way: this online payment will still be refunded.',
      metadata: {
        reason: 'payment-unfinished',
        unitId: unitId || null,
        unitNumber,
        renterName,
        reservationId,
        paymentIntentId,
        amountCents: params.amountCents ?? null,
      },
    });
    tx.set(paidRef, { ownerAlertedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
    return true;
  });
}

/**
 * Settles each paid checkout that has no use record UNFINISHED_ALERT_MINUTES
 * after payment, oldest first: refunded when the renter can no longer move in
 * with it, or PAID_HOLD_MAX_HOURS have passed; otherwise the owner is told
 * once. A payment already used has its record removed. Stripe is asked about
 * the payment only before refunding it, on the account that took it, and a
 * payment it does not show to be this reservation's is not refunded.
 */
export async function settleUnfinishedPaidMoveIns(now: Date): Promise<{
  refunded: number;
  alerted: number;
  closed: number;
  skipped: number;
}> {
  const db = admin.firestore();
  const docs = await readPages(
    db.collection(PUBLIC_MOVE_IN_PAID_CHECKOUTS_COLLECTION)
      .where('paidAt', '<=', admin.firestore.Timestamp.fromMillis(now.getTime() - UNFINISHED_ALERT_MINUTES * MINUTE_MS))
      .orderBy('paidAt', 'asc'),
  );
  const counts = { refunded: 0, alerted: 0, closed: 0, skipped: 0 };
  for (const doc of docs) {
    const paymentIntentId = doc.id;
    const paid = (doc.data() || {}) as Record<string, unknown>;
    try {
      if (await closePaidCheckout(paymentIntentId) !== 'open') {
        counts.closed += 1;
        continue;
      }
      const facilityId = textOf(paid.facilityId);
      const reservationId = textOf(paid.reservationId);
      const connectAccountId = textOf(paid.connectAccountId);
      const paidAt = timestampToDate(paid.paidAt);
      if (!facilityId || !reservationId || !connectAccountId || !paidAt) {
        functions.logger.error('Public move-in: a paid checkout record is incomplete', { paymentIntentId });
        counts.skipped += 1;
        continue;
      }
      const amountCents = typeof paid.amountCents === 'number' ? paid.amountCents : null;
      const { refusal, reservation, unit } = await refusalFor(reservationId, facilityId, paidAt, now);
      if (!refusal) {
        if (await alertOwnerOfUnfinishedPayment({ paymentIntentId, facilityId, reservationId, reservation, unit, amountCents })) {
          counts.alerted += 1;
          functions.logger.warn('Public move-in: a renter paid and has not finished moving in', {
            facilityId,
            reservationId,
            paymentIntentId,
          });
        }
        continue;
      }

      // The payment as Stripe holds it, on the account that took it.
      const intent = await getStripeClient().paymentIntents.retrieve(paymentIntentId, { stripeAccount: connectAccountId });
      const amountReceived = Number(intent.amount_received) || 0;
      if (intent.status !== 'succeeded' || amountReceived <= 0) {
        functions.logger.error('Public move-in: a paid checkout\'s payment is not a completed payment; not refunded', {
          facilityId,
          reservationId,
          paymentIntentId,
          status: intent.status,
        });
        counts.skipped += 1;
        continue;
      }
      const payment = {
        paymentIntentId,
        amountReceivedCents: amountReceived,
        metadata: (intent.metadata || {}) as Record<string, string>,
      };
      const ownership = await paymentOwnership({ facilityId, connectAccountId, reservationId }, payment);
      if (ownership !== 'this-reservation') {
        // 'unknown': asked again next run. 'another': not this reservation's
        // money to refund on its account's say-so.
        functions.logger.error('Public move-in: a paid checkout\'s payment is not shown to be its reservation\'s', {
          facilityId,
          reservationId,
          paymentIntentId,
          ownership,
        });
        counts.skipped += 1;
        continue;
      }
      try {
        await refusePaidMoveIn({
          facilityId,
          connectAccountId,
          reservationId,
          unitId: textOf(reservation.unitId) || null,
          unitNumber: textOf(unit?.unitNumber) || textOf(reservation.unitNumber) || 'Unassigned',
          renterName: textOf(reservation.name) || 'A renter',
          refusal,
          unpaidError: new functions.https.HttpsError('failed-precondition', 'Not refunded'),
          payment,
          knownToBeThisReservations: true,
        });
      } catch (err: unknown) {
        // It ends by throwing the renter's error (refunded, failed, or the
        // payment already used by a completion that won).
        if (!(err instanceof functions.https.HttpsError)) throw err;
      }
      functions.logger.warn('Public move-in: an unfinished paid move-in was refused', {
        facilityId,
        reservationId,
        paymentIntentId,
        refusal,
      });
      const closed = await closePaidCheckout(paymentIntentId);
      if (closed === 'refunded') counts.refunded += 1;
      else if (closed === 'moved-in') counts.closed += 1;
      else counts.skipped += 1;
    } catch (err: unknown) {
      functions.logger.error('Public move-in: could not settle an unfinished paid move-in', {
        paymentIntentId,
        message: err instanceof Error ? err.message : String(err),
      });
      counts.skipped += 1;
    }
  }
  return counts;
}
