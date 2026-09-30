import * as admin from 'firebase-admin';
import {
  CHECKOUT_SESSION_EXPIRES_FIELD,
  FINISH_AFTER_PAYMENT_MINUTES,
  readHoldersReservation as readHoldersReservationIn,
  recordPaidPublicMoveInCheckout,
  timestampToDate,
  unitHoldRef as unitHoldRefIn,
} from '@sfc/functions-shared';
import type { PaidCheckoutOutcome } from '@sfc/functions-shared';

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
 * just past it. Once the session is paid, the Connect webhook holds the unit
 * for the payer until PAID_HOLD_MAX_HOURS after payment, and confirming it
 * gives the renter FINISH_AFTER_PAYMENT_MINUTES, never past that
 * (functions-shared publicMoveInPaidCheckout.ts). A renter who paid can still
 * finish after a hold has lapsed if the unit has not been taken.
 */

// Shared with the Connect webhook (functions-integrations), which records a
// paid session by the same rules.
export {
  CHECKOUT_PAID_AT_FIELD,
  CHECKOUT_PAID_FIELD,
  CHECKOUT_RETURN_WINDOW_MS,
  CHECKOUT_SESSION_EXPIRES_FIELD,
  FINISH_AFTER_PAYMENT_MINUTES,
  PAID_HOLD_MAX_HOURS,
  checkoutMayHaveBeenPaid,
  holderMayBePaying,
  laterExpiry,
  paidHoldCap,
  timestampToDate,
} from '@sfc/functions-shared';

/** The map hold doc of a unit: one per unit, naming the reservation that holds it. */
export function unitHoldRef(facilityId: string, unitId: string): admin.firestore.DocumentReference {
  return unitHoldRefIn(admin.firestore(), facilityId, unitId);
}

/** The reservation named by a hold doc, read in [tx]; undefined when the hold names none or it is gone. */
export function readHoldersReservation(
  tx: admin.firestore.Transaction,
  hold: Record<string, unknown> | null,
): Promise<Record<string, unknown> | undefined> {
  return readHoldersReservationIn(admin.firestore(), tx, hold);
}

/** Stripe allows 30 minutes to 24 hours; the margin covers clock skew and latency. */
export const CHECKOUT_SESSION_MINUTES = 35;

/**
 * How long the hold outlasts the Checkout page, for a renter who pays at its
 * last moment to be sent back and confirm the payment. Only a paid session
 * earns more (FINISH_AFTER_PAYMENT_MINUTES): an unpaid checkout that took the
 * full hour kept the unit from everyone else on nobody's money.
 */
export const RETURN_AFTER_CHECKOUT_MINUTES = 10;

/**
 * No checkout extends a hold past this, counted from when the unit was held,
 * however often checkout is restarted: a hold keeps the unit from everyone
 * else. Room for a 60-minute portal hold with checkout begun at its end.
 */
export const MAX_HOLD_MINUTES = 3 * 60;

export const CHECKOUT_RUN_OUT_MESSAGE =
  'This reservation has run out of time. Please choose your unit again.';

const MINUTE_MS = 60 * 1000;

/** Whether [value] is a Timestamp at exactly [date]. */
function isInstant(value: unknown, date: Date): boolean {
  return timestampToDate(value)?.getTime() === date.getTime();
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
  CHECKOUT_SESSION_EXPIRES_FIELD,
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
 * Narrows the reservation's CHECKOUT_SESSION_EXPIRES_FIELD to [payableUntil],
 * the expiry of an earlier session that checkout [attemptId] handed back.
 * That checkout wrote a new session's expiry before asking Stripe, and the
 * session handed back ends sooner; nothing else of the reservation's is then
 * payable (checkoutSessionReuse.ts expires the rest). Left alone once a later
 * checkout has written its own.
 */
export async function narrowCheckoutSessionExpiry(params: {
  reservationRef: admin.firestore.DocumentReference;
  attemptId: string;
  payableUntil: Date;
}): Promise<void> {
  const { reservationRef, attemptId, payableUntil } = params;
  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(reservationRef);
    const reservation = (snap.data() || {}) as Record<string, unknown>;
    if (!snap.exists || reservation[CHECKOUT_ATTEMPT_FIELD] !== attemptId) return;
    const recorded = timestampToDate(reservation[CHECKOUT_SESSION_EXPIRES_FIELD]);
    if (recorded && recorded <= payableUntil) return;
    tx.update(reservationRef, {
      [CHECKOUT_SESSION_EXPIRES_FIELD]: admin.firestore.Timestamp.fromDate(payableUntil),
    });
  });
}

/**
 * Gives a renter whose Checkout Session Stripe shows paid the time to finish
 * moving in: the reservation and the unit's hold last until
 * FINISH_AFTER_PAYMENT_MINUTES from [now], but never past PAID_HOLD_MAX_HOURS
 * after the payment. Each confirmation re-held the unit for another hour
 * before, with no end, so a renter who kept reopening the link kept the unit
 * off the market for good. The unit is held again if its hold lapsed or went,
 * since after the Stripe redirect the renter re-enters the whole form. Over
 * another reservation's live hold only when that one has not gone to pay
 * (holderMayBePaying).
 *
 * Records the payment for the sweep too (functions-shared
 * recordPaidPublicMoveInCheckout, shared with the Connect webhook), so a
 * renter who confirms and then walks away is still refunded or finished.
 */
export async function holdForPaidCheckout(params: {
  facilityId: string;
  reservationId: string;
  /** The payment the paid session took: while it holds the unit, the renter counts as paying (holderMayBePaying). */
  paymentIntentId: string;
  checkoutSessionId: string;
  connectAccountId: string;
  amountCents: number | null;
  /** When it was paid, as best known: the earliest time recorded is kept. */
  paidAt: Date;
  now: Date;
}): Promise<PaidCheckoutOutcome> {
  return recordPaidPublicMoveInCheckout(admin.firestore(), {
    ...params,
    holdMinutes: FINISH_AFTER_PAYMENT_MINUTES,
    recordedBy: 'confirmPublicMoveInCheckout',
  });
}
