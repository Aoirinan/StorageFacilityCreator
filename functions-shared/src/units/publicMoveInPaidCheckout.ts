/**
 * What an online move-in's paid Checkout Session means for the reservation
 * and the unit, wherever the payment is first seen: the Connect webhook
 * (functions-integrations, checkout.session.completed), the move-in page
 * confirming the session (functions-public-website confirmPublicMoveInCheckout),
 * or the sweep that asks Stripe about a recorded session nobody reported
 * (functions-public-website unfinishedPaidMoveInSweep.ts). One copy, so the
 * three cannot drift apart.
 *
 * Before, only the renter coming back reacted to a payment: a renter who paid
 * and closed the tab kept the unit only until checkout's hold lapsed (10
 * minutes after the Checkout page closed), another renter could then hold and
 * pay for it, and the first payer's money stayed with the owner, who was told
 * nothing.
 */
import * as admin from 'firebase-admin';

/**
 * One document per PaymentIntent that completed an online move-in or was
 * refunded because it could not (functions-public-website paidMoveInRefund.ts).
 * Its existence is what makes a payment used: every writer below reads it in
 * its transaction and stops when it is there.
 */
export const PUBLIC_MOVE_IN_PAYMENTS_COLLECTION = 'publicMoveInPayments';

/**
 * On a use record (PUBLIC_MOVE_IN_PAYMENTS_COLLECTION): refunds and card
 * disputes made on the payment before it moved anyone in, keyed by the Stripe
 * refund or dispute id. The Connect webhook writes them (functions-integrations
 * moveInPaymentTenant.ts), with no tenant, because there is none to post them to.
 */
export const UNTENANTED_REFUNDS_FIELD = 'untenantedRefunds';
export const UNTENANTED_DISPUTES_FIELD = 'untenantedDisputes';

function hasEntries(value: unknown): boolean {
  return Boolean(value) && typeof value === 'object' && Object.keys(value as object).length > 0;
}

/**
 * Whether a use record says only that the payment was refunded in Stripe, or
 * disputed, before the move-in was completed: it holds UNTENANTED_REFUNDS_FIELD
 * or UNTENANTED_DISPUTES_FIELD, no tenant, and no `refund` of the move-in's own
 * (paidMoveInRefund.ts). Such a payment moved nobody in and can no longer
 * (completion and refusePaidMoveIn both stop at a use record), and nothing here
 * refunds the rest of it: the webhook told the owner to deal with it in Stripe.
 * Read as "moved in", it had the owner's "has not finished" alert rewritten to
 * say the renter had finished, and the renter told the payment had completed a
 * move-in.
 */
export function moveInPaymentReturnedBeforeMoveIn(use: Record<string, unknown> | null | undefined): boolean {
  if (!use || use.refund) return false;
  if (typeof use.tenantId === 'string' && use.tenantId.trim() !== '') return false;
  return hasEntries(use[UNTENANTED_REFUNDS_FIELD]) || hasEntries(use[UNTENANTED_DISPUTES_FIELD]);
}

/**
 * One document per PaymentIntent of a paid online move-in checkout that is not
 * yet known to be used or refunded, keyed by the PaymentIntent id. The sweep
 * reads these oldest first: it tells the owner about a renter who paid and has
 * not finished, refunds one who can no longer move in or has not finished
 * within PAID_HOLD_MAX_HOURS, and deletes the document once the payment has a
 * use record.
 */
export const PUBLIC_MOVE_IN_PAID_CHECKOUTS_COLLECTION = 'publicMoveInPaidCheckouts';

/**
 * On the reservation: the PaymentIntent its paid Checkout Session took. While
 * it holds the unit, the renter counts as paying (holderMayBePaying). Removed
 * when a refund of it leaves the reservation open.
 */
export const CHECKOUT_PAID_FIELD = 'checkoutPaidPaymentIntentId';

/** On the reservation: when that payment was made, as first seen (the earliest time recorded wins). */
export const CHECKOUT_PAID_AT_FIELD = 'checkoutPaidAt';

/**
 * On the reservation: the latest a Checkout Session of its checkout can be
 * paid until. Checkout writes it before Stripe is asked (the new session's
 * expiry, never earlier than one it may hand back) and narrows it to the
 * session it hands back; a refund that leaves the reservation open sets it to
 * the refund's time, as its paid session can take nothing more.
 */
export const CHECKOUT_SESSION_EXPIRES_FIELD = 'checkoutSessionExpiresAt';

/** On the reservation: the connected account its recorded Checkout Session is on. */
export const CHECKOUT_SESSION_ACCOUNT_FIELD = 'checkoutSessionAccountId';

/**
 * How long a reservation whose checkout has started stays loadable after its
 * hold runs out, and counts as possibly paying while its session may be open.
 */
export const CHECKOUT_RETURN_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Time, each time the renter confirms a paid session, to fill in the form and sign. */
export const FINISH_AFTER_PAYMENT_MINUTES = 60;

/**
 * No paid renter keeps the unit longer than this after paying, however often
 * they confirm the session. A renter who has not finished by then is refunded
 * by the sweep (refusal 'not-finished'), so the money is kept exactly as long
 * as the unit is.
 */
export const PAID_HOLD_MAX_HOURS = 24;

const MINUTE_MS = 60 * 1000;
const OPEN_STATUSES = new Set(['pending', 'confirmed', 'expired']);

/** A Firestore Timestamp's Date, or null for anything else (missing, a pending server timestamp). */
export function timestampToDate(value: unknown): Date | null {
  if (value && typeof (value as { toDate?: unknown }).toDate === 'function') {
    return (value as { toDate: () => Date }).toDate();
  }
  return null;
}

/** The later of an existing expiry and a new one: an extension never shortens a hold. */
export function laterExpiry(existing: unknown, proposed: Date): Date {
  const current = timestampToDate(existing);
  return current && current > proposed ? current : proposed;
}

/** Whether a hold doc keeps its unit from anyone but its own reservation at [now]. */
export function isLiveHold(hold: Record<string, unknown> | null | undefined, now: Date): boolean {
  const heldUntil = timestampToDate(hold?.expiresAt);
  return heldUntil != null && heldUntil > now;
}

/** Whether [reservation] went to checkout within CHECKOUT_RETURN_WINDOW_MS of [now], so it may have been paid. */
export function checkoutMayHaveBeenPaid(
  reservation: Record<string, unknown> | undefined,
  now: Date = new Date(),
): boolean {
  const started = reservation?.checkoutUpdatedAt as { toMillis?: () => number } | undefined;
  return typeof started?.toMillis === 'function' &&
    now.getTime() - started.toMillis() < CHECKOUT_RETURN_WINDOW_MS;
}

/**
 * Whether [holder], the reservation whose live hold is on a unit (undefined
 * when its doc is gone), may be paying for it at [now]: still open, and either
 * paid (CHECKOUT_PAID_FIELD) or gone to checkout with a Checkout Session still
 * payable. A renter who has paid and whose own hold ran out gives the unit up
 * only to such a holder. One who has not gone to pay has paid nothing; nor has
 * one whose session expired unpaid, or one refunded for changed charges who
 * has not started paying again.
 *
 * A paid holder counts however long ago checkout started: its hold ends
 * PAID_HOLD_MAX_HOURS after the payment, and only a live hold is asked about.
 * Counted only within the day after checkout, a paid renter's hold stopped
 * counting before it ended.
 */
export function holderMayBePaying(holder: Record<string, unknown> | undefined, now: Date = new Date()): boolean {
  if (!holder || (holder.status !== 'pending' && holder.status !== 'confirmed')) return false;
  const paidWith = holder[CHECKOUT_PAID_FIELD];
  if (typeof paidWith === 'string' && paidWith.trim() !== '') return true;
  if (!checkoutMayHaveBeenPaid(holder, now)) return false;
  const payableUntil = timestampToDate(holder[CHECKOUT_SESSION_EXPIRES_FIELD]);
  // Went to checkout before the expiry was recorded: its session may be
  // payable for the day checkoutMayHaveBeenPaid allows.
  if (!payableUntil) return true;
  return payableUntil > now;
}

/** The latest a renter who paid at [paidAt] keeps the unit: PAID_HOLD_MAX_HOURS on. */
export function paidHoldCap(paidAt: Date): Date {
  return new Date(paidAt.getTime() + PAID_HOLD_MAX_HOURS * 60 * MINUTE_MS);
}

/** The map hold doc of a unit: one per unit, naming the reservation that holds it. */
export function unitHoldRef(
  db: admin.firestore.Firestore,
  facilityId: string,
  unitId: string,
): admin.firestore.DocumentReference {
  return db
    .collection('facilities')
    .doc(facilityId)
    .collection('mapEngine')
    .doc('activeHolds')
    .collection('items')
    .doc(unitId);
}

/** The reservation named by a hold doc, read in [tx]; undefined when the hold names none or it is gone. */
export async function readHoldersReservation(
  db: admin.firestore.Firestore,
  tx: admin.firestore.Transaction,
  hold: Record<string, unknown> | null,
): Promise<Record<string, unknown> | undefined> {
  const holderId = typeof hold?.reservationId === 'string' ? hold.reservationId.trim() : '';
  if (!holderId || holderId.includes('/')) return undefined;
  const snap = await tx.get(db.collection('publicReservations').doc(holderId));
  return snap.exists ? (snap.data() as Record<string, unknown>) : undefined;
}

function textOf(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * What recordPaidPublicMoveInCheckout did:
 * - 'settled': the payment already moved someone in or was refunded; nothing written.
 * - 'not-this-facility': the reservation, facility or account does not match; nothing written.
 * - 'closed': recorded for the sweep, but the reservation is completed, cancelled or gone, so nothing is held.
 * - 'paid-with-another': recorded for the sweep; the reservation already records another payment.
 * - 'cap-passed': recorded for the sweep; PAID_HOLD_MAX_HOURS have passed since payment, so nothing is held.
 * - 'held-by-another': recorded for the sweep; another renter who may be paying holds the unit.
 * - 'held': recorded, and the reservation and the unit are held for the payer.
 */
export type PaidCheckoutOutcome =
  | 'settled'
  | 'not-this-facility'
  | 'closed'
  | 'paid-with-another'
  | 'cap-passed'
  | 'held-by-another'
  | 'held';

export interface PaidCheckoutParams {
  paymentIntentId: string;
  checkoutSessionId: string | null;
  reservationId: string;
  /** From the session's metadata or the reservation; must be the reservation's. */
  facilityId: string;
  /** The connected account that took the payment: the reservation's recorded one or the facility's. */
  connectAccountId: string;
  amountCents: number | null;
  /** When it was paid, as best the caller knows; the earliest recorded time is kept. */
  paidAt: Date;
  now: Date;
  /**
   * How long the unit is held for the payer: until PAID_HOLD_MAX_HOURS after
   * payment ('until-cap', for a payment seen without the renter), or this many
   * minutes from now, never past that (the renter confirming it).
   */
  holdMinutes: number | 'until-cap';
  /** Who saw it first ('stripeWebhook', 'confirmPublicMoveInCheckout', 'moveInSweep'). */
  recordedBy: string;
}

/**
 * Records a paid online move-in Checkout Session, in one transaction:
 *
 * 1. Nothing, if the payment already has a use record (moved in or refunded):
 *    a webhook retried after completion must not hold the rented unit again,
 *    and one retried after a refund must not mark the reservation paid again.
 * 2. Nothing, unless the reservation is the facility's and the account that
 *    took the payment is the reservation's recorded one or the facility's.
 * 3. The paid-checkout document (PUBLIC_MOVE_IN_PAID_CHECKOUTS_COLLECTION), for
 *    the sweep, keeping the earliest payment time seen.
 * 4. For an open reservation that records no other payment: the payment and
 *    its time on the reservation (so the renter counts as paying), the
 *    reservation reopened if it was marked expired, and the reservation and
 *    the unit's hold extended (laterExpiry: never shortened) as [holdMinutes]
 *    says, never past PAID_HOLD_MAX_HOURS after payment. Not over another
 *    reservation's live hold whose renter may be paying (holderMayBePaying).
 *
 * Never moves anyone in or refunds anything: completion and the sweep do,
 * each deciding in a transaction that writes the payment's use record, so a
 * payment is used once.
 */
export async function recordPaidPublicMoveInCheckout(
  db: admin.firestore.Firestore,
  params: PaidCheckoutParams,
): Promise<PaidCheckoutOutcome> {
  const paymentIntentId = textOf(params.paymentIntentId);
  const reservationId = textOf(params.reservationId);
  const facilityId = textOf(params.facilityId);
  const connectAccountId = textOf(params.connectAccountId);
  if (
    !paymentIntentId || paymentIntentId.includes('/') ||
    !reservationId || reservationId.includes('/') ||
    !facilityId || facilityId.includes('/') ||
    !connectAccountId
  ) {
    return 'not-this-facility';
  }
  const { now } = params;
  const useRef = db.collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntentId);
  const paidRef = db.collection(PUBLIC_MOVE_IN_PAID_CHECKOUTS_COLLECTION).doc(paymentIntentId);
  const reservationRef = db.collection('publicReservations').doc(reservationId);
  const facilityRef = db.collection('facilities').doc(facilityId);

  return db.runTransaction(async (tx): Promise<PaidCheckoutOutcome> => {
    const useSnap = await tx.get(useRef);
    const paidSnap = await tx.get(paidRef);
    const reservationSnap = await tx.get(reservationRef);
    const facilitySnap = await tx.get(facilityRef);
    const reservation = (reservationSnap.data() || {}) as Record<string, unknown>;
    const facility = (facilitySnap.data() || {}) as Record<string, unknown>;

    // Reads first (Firestore wants every read before any write): the hold,
    // and the reservation of whoever holds it.
    const unitId = textOf(reservation.unitId);
    const holdRef = reservationSnap.exists && unitId && !unitId.includes('/')
      ? unitHoldRef(db, facilityId, unitId)
      : null;
    const holdSnap = holdRef ? await tx.get(holdRef) : null;
    const hold = (holdSnap?.data() || null) as Record<string, unknown> | null;
    const ownHold = hold?.reservationId === reservationId;
    const holder = hold && !ownHold && isLiveHold(hold, now)
      ? await readHoldersReservation(db, tx, hold)
      : undefined;

    if (useSnap.exists) return 'settled';
    if (reservationSnap.exists && textOf(reservation.facilityId) !== facilityId) return 'not-this-facility';
    if (!facilitySnap.exists) return 'not-this-facility';
    const accountMatches =
      textOf(reservation[CHECKOUT_SESSION_ACCOUNT_FIELD]) === connectAccountId ||
      textOf(facility.stripeConnectAccountId) === connectAccountId;
    if (!accountMatches) return 'not-this-facility';

    // The earliest time this payment is known by: this caller's, the one
    // recorded for the sweep, or the one on the reservation.
    const alreadyPaidWith = textOf(reservation[CHECKOUT_PAID_FIELD]);
    let paidAt = params.paidAt;
    for (const seen of [
      timestampToDate((paidSnap.data() || {}).paidAt),
      alreadyPaidWith === paymentIntentId ? timestampToDate(reservation[CHECKOUT_PAID_AT_FIELD]) : null,
    ]) {
      if (seen && seen < paidAt) paidAt = seen;
    }
    tx.set(
      paidRef,
      {
        paymentIntentId,
        checkoutSessionId: params.checkoutSessionId ?? null,
        reservationId,
        facilityId,
        connectAccountId,
        amountCents: params.amountCents ?? null,
        paidAt: admin.firestore.Timestamp.fromDate(paidAt),
        ...(paidSnap.exists ? {} : {
          recordedBy: params.recordedBy,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        }),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    if (!reservationSnap.exists || !OPEN_STATUSES.has(String(reservation.status || ''))) return 'closed';
    if (alreadyPaidWith && alreadyPaidWith !== paymentIntentId) return 'paid-with-another';

    const cap = paidHoldCap(paidAt);
    if (cap <= now) return 'cap-passed';
    const wanted = params.holdMinutes === 'until-cap'
      ? cap
      : new Date(now.getTime() + params.holdMinutes * MINUTE_MS);
    const holdUntil = wanted < cap ? wanted : cap;

    if (holder !== undefined && holderMayBePaying(holder, now)) return 'held-by-another';

    tx.update(reservationRef, {
      // Marked expired only because its hold lapsed: this renter has paid,
      // so it is open again for them to finish.
      ...(reservation.status === 'expired' ? { status: 'pending' } : {}),
      expiresAt: admin.firestore.Timestamp.fromDate(laterExpiry(reservation.expiresAt, holdUntil)),
      [CHECKOUT_PAID_FIELD]: paymentIntentId,
      [CHECKOUT_PAID_AT_FIELD]: admin.firestore.Timestamp.fromDate(paidAt),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (holdRef && ownHold) {
      tx.update(holdRef, {
        expiresAt: admin.firestore.Timestamp.fromDate(laterExpiry(hold?.expiresAt, holdUntil)),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else if (holdRef) {
      // Lapsed, gone, or another reservation's lapsed hold (or live, with a
      // renter who has not gone to pay: their checkout is then refused
      // before it takes any money).
      tx.set(holdRef, {
        facilityId,
        unitId,
        reservationId,
        status: 'pending',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromDate(holdUntil),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    return 'held';
  });
}
