import * as admin from 'firebase-admin';

/**
 * How long a reservation's hold lasts once the renter goes to pay.
 *
 * A hold is at most 15 minutes (public) or 60 (tenant portal). Stripe's
 * Checkout page stayed payable for 24 hours, and after paying the renter still
 * has to come back, fill in the move-in form and sign. The hold ran out under
 * them: completePublicMoveIn then refused a renter who had paid, and the unit
 * could be held and rented by someone else meanwhile.
 *
 * So checkout gives the Checkout Session a short expiry and extends the hold
 * just past it; once Stripe shows the session paid, confirming it gives the
 * renter the time to finish. A renter who paid can still finish after a hold
 * has lapsed if the unit has not been taken.
 */

/** Stripe allows 30 minutes to 24 hours; the margin covers clock skew and latency. */
export const CHECKOUT_SESSION_MINUTES = 35;

/**
 * How long the hold outlasts the Checkout page, for a renter who pays at its
 * last moment to be sent back and confirm the payment. Only a paid session
 * earns more (FINISH_AFTER_PAYMENT_MINUTES): an unpaid checkout that took the
 * full hour kept the unit from everyone else on nobody's money.
 */
export const RETURN_AFTER_CHECKOUT_MINUTES = 10;

/** Time, once the payment is confirmed, to fill in the form and sign. */
export const FINISH_AFTER_PAYMENT_MINUTES = 60;

/**
 * No checkout extends a hold past this, counted from when the unit was held,
 * however often checkout is restarted: a hold keeps the unit from everyone
 * else. Room for a 60-minute portal hold with checkout begun at its end.
 */
export const MAX_HOLD_MINUTES = 3 * 60;

export const CHECKOUT_RUN_OUT_MESSAGE =
  'This reservation has run out of time. Please choose your unit again.';

const MINUTE_MS = 60 * 1000;

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

/** Whether [value] is a Timestamp at exactly [date]. */
function isInstant(value: unknown, date: Date): boolean {
  return timestampToDate(value)?.getTime() === date.getTime();
}

/** Whether a hold doc keeps its unit from anyone but its own reservation now. */
function isLiveHold(hold: Record<string, unknown> | null | undefined, now: Date): boolean {
  const heldUntil = timestampToDate(hold?.expiresAt);
  return heldUntil != null && heldUntil > now;
}

/**
 * How long a reservation whose checkout has started stays loadable after its
 * hold runs out. A Checkout Session could be paid for 24 hours, and a hold
 * lasts at most 15 minutes, so a renter slow on the Stripe page came back paid
 * to "Reservation not found or has expired", with no way to finish or be
 * refunded.
 */
export const CHECKOUT_RETURN_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Whether [reservation] went to checkout within CHECKOUT_RETURN_WINDOW_MS, so it may have been paid. */
export function checkoutMayHaveBeenPaid(reservation: Record<string, unknown> | undefined): boolean {
  const started = reservation?.checkoutUpdatedAt as { toMillis?: () => number } | undefined;
  return typeof started?.toMillis === 'function' &&
    Date.now() - started.toMillis() < CHECKOUT_RETURN_WINDOW_MS;
}

/**
 * Whether [holder], the reservation whose live hold is on a unit (undefined
 * when its doc is gone), may be paying for it: still open, and gone to
 * checkout. A renter who has paid and whose own hold ran out gives the unit
 * up only to such a holder. One who has not gone to pay has paid nothing:
 * refunding the paid renter for them left the unit empty when they walked
 * away, and told the renter it had been rented.
 */
export function holderMayBePaying(holder: Record<string, unknown> | undefined): boolean {
  if (!holder || (holder.status !== 'pending' && holder.status !== 'confirmed')) return false;
  return checkoutMayHaveBeenPaid(holder);
}

/** The reservation named by a hold doc, read in [tx]; undefined when the hold names none or it is gone. */
export async function readHoldersReservation(
  tx: admin.firestore.Transaction,
  hold: Record<string, unknown> | null,
): Promise<Record<string, unknown> | undefined> {
  const holderId = typeof hold?.reservationId === 'string' ? hold.reservationId.trim() : '';
  if (!holderId || holderId.includes('/')) return undefined;
  const snap = await tx.get(admin.firestore().collection('publicReservations').doc(holderId));
  return snap.exists ? (snap.data() as Record<string, unknown>) : undefined;
}

/**
 * When a Checkout Session created at [now] expires, and when the hold covering
 * it ends. Null when that hold would outlive MAX_HOLD_MINUTES from [reservedAt];
 * both holds record reservedAt, so a reservation without one is not capped.
 */
export function checkoutHoldWindow(
  now: Date,
  reservedAt: Date | null,
): { sessionExpiresAt: Date; holdUntil: Date } | null {
  const sessionExpiresAt = new Date(now.getTime() + CHECKOUT_SESSION_MINUTES * MINUTE_MS);
  const holdUntil = new Date(sessionExpiresAt.getTime() + RETURN_AFTER_CHECKOUT_MINUTES * MINUTE_MS);
  if (reservedAt && holdUntil.getTime() > reservedAt.getTime() + MAX_HOLD_MINUTES * MINUTE_MS) {
    return null;
  }
  return { sessionExpiresAt, holdUntil };
}

/** The map hold doc of a unit: one per unit, naming the reservation that holds it. */
export function unitHoldRef(facilityId: string, unitId: string): admin.firestore.DocumentReference {
  return admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('mapEngine')
    .doc('activeHolds')
    .collection('items')
    .doc(unitId);
}

/**
 * On the reservation: which checkout last priced it and extended its hold.
 * A checkout Stripe refused puts back what it wrote only while this is still
 * its own; a later checkout's writes are left alone.
 */
export const CHECKOUT_ATTEMPT_FIELD = 'checkoutAttemptId';

/** The reservation fields a checkout writes besides expiresAt, as they were before it. */
const CHECKOUT_FIELDS = [
  'checkoutUpdatedAt',
  'expectedCheckoutAmountCents',
  'checkoutMoveInDate',
  CHECKOUT_ATTEMPT_FIELD,
] as const;

/** What a checkout's extension replaced, so a checkout Stripe refused can put it back. */
export interface ReplacedHold {
  reservationExpiresAt: unknown;
  /** CHECKOUT_FIELDS as they were; null for a field that was not there. */
  checkoutFields: Record<(typeof CHECKOUT_FIELDS)[number], unknown>;
  /** The hold's expiry when it was already this reservation's; null when checkout created it. */
  holdExpiresAt: unknown | null;
}

/** [reservation]'s CHECKOUT_FIELDS, for ReplacedHold.checkoutFields. */
export function checkoutFieldsOf(reservation: Record<string, unknown>): ReplacedHold['checkoutFields'] {
  const fields = {} as ReplacedHold['checkoutFields'];
  for (const field of CHECKOUT_FIELDS) fields[field] = reservation[field] ?? null;
  return fields;
}

/**
 * Undoes a checkout's hold extension after Stripe refused to create its
 * session: there is nothing to pay, so the unit goes back on the market when
 * the hold was going to end anyway, not up to an hour later, and a facility
 * whose Stripe account refuses sessions does not lose its units to each try.
 * The amount and day it priced go back too, so an earlier session still open
 * in another tab completes at the price it was made for. Only what that
 * checkout wrote is put back: a later checkout, or a confirmed payment, may
 * have extended or priced it since.
 */
export async function restoreHoldAfterFailedCheckout(params: {
  reservationRef: admin.firestore.DocumentReference;
  holdRef: admin.firestore.DocumentReference | null;
  reservationId: string;
  attemptId: string;
  holdUntil: Date;
  replaced: ReplacedHold;
}): Promise<void> {
  const { reservationRef, holdRef, reservationId, attemptId, holdUntil, replaced } = params;
  await admin.firestore().runTransaction(async (tx) => {
    const reservationSnap = await tx.get(reservationRef);
    const holdSnap = holdRef ? await tx.get(holdRef) : null;
    const reservation = (reservationSnap.data() || {}) as Record<string, unknown>;
    // A later checkout has since written its own: its session, not this
    // failed one, is what the hold and the price now cover.
    if (!reservationSnap.exists || reservation[CHECKOUT_ATTEMPT_FIELD] !== attemptId) return;
    const restored: Record<string, unknown> = { updatedAt: admin.firestore.FieldValue.serverTimestamp() };
    for (const field of CHECKOUT_FIELDS) {
      restored[field] = replaced.checkoutFields[field] ?? admin.firestore.FieldValue.delete();
    }
    if (isInstant(reservation.expiresAt, holdUntil)) {
      restored.expiresAt = replaced.reservationExpiresAt ?? admin.firestore.FieldValue.delete();
    }
    tx.update(reservationRef, restored);
    const hold = (holdSnap?.data() || null) as Record<string, unknown> | null;
    if (holdRef && hold && hold.reservationId === reservationId && isInstant(hold.expiresAt, holdUntil)) {
      if (replaced.holdExpiresAt) {
        tx.update(holdRef, {
          expiresAt: replaced.holdExpiresAt,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      } else {
        tx.delete(holdRef);
      }
    }
  });
}

/**
 * Gives a renter whose Checkout Session Stripe shows paid the time to finish
 * moving in: the reservation and the unit's hold last until
 * FINISH_AFTER_PAYMENT_MINUTES from [now]. The unit is held again if its hold
 * lapsed or went, since after the Stripe redirect the renter re-enters the
 * whole form, and another renter could hold the unit meanwhile. Over another
 * reservation's live hold only when that one has not gone to pay
 * (holderMayBePaying): this renter has paid, and that one's checkout is then
 * refused before it takes any money. A holder who may be paying keeps the
 * unit, and completion refunds this renter if they still hold it then.
 *
 * 'held', 'held-by-another', or 'closed' for a reservation no longer open
 * (completed or cancelled: completion decides what the payment is for).
 */
export async function holdForPaidCheckout(params: {
  reservationRef: admin.firestore.DocumentReference;
  facilityId: string;
  reservationId: string;
  now: Date;
}): Promise<'held' | 'held-by-another' | 'closed'> {
  const { reservationRef, facilityId, reservationId, now } = params;
  const finishBy = new Date(now.getTime() + FINISH_AFTER_PAYMENT_MINUTES * MINUTE_MS);
  return admin.firestore().runTransaction(async (tx) => {
    const reservationSnap = await tx.get(reservationRef);
    const reservation = (reservationSnap.data() || {}) as Record<string, any>;
    if (!reservationSnap.exists || (reservation.status !== 'pending' && reservation.status !== 'confirmed')) {
      return 'closed' as const;
    }
    const unitId = String(reservation.unitId || '').trim();
    const holdRef = unitId ? unitHoldRef(facilityId, unitId) : null;
    const holdSnap = holdRef ? await tx.get(holdRef) : null;
    const hold = (holdSnap?.data() || null) as Record<string, any> | null;
    const ownHold = hold?.reservationId === reservationId;
    if (hold && !ownHold && isLiveHold(hold, now) && holderMayBePaying(await readHoldersReservation(tx, hold))) {
      return 'held-by-another' as const;
    }

    tx.update(reservationRef, {
      expiresAt: admin.firestore.Timestamp.fromDate(laterExpiry(reservation.expiresAt, finishBy)),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (holdRef && ownHold) {
      tx.update(holdRef, {
        expiresAt: admin.firestore.Timestamp.fromDate(laterExpiry(hold?.expiresAt, finishBy)),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else if (holdRef) {
      tx.set(holdRef, {
        facilityId,
        unitId,
        reservationId,
        status: 'pending',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromDate(finishBy),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    return 'held' as const;
  });
}
