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
 * past it, and a renter who paid can still finish after a hold has lapsed if
 * the unit has not been taken.
 */

/** Stripe allows 30 minutes to 24 hours; the margin covers clock skew and latency. */
export const CHECKOUT_SESSION_MINUTES = 35;

/** Time after the Checkout page closes to come back, fill in the form and sign. */
export const FINISH_AFTER_PAYMENT_MINUTES = 60;

/**
 * No checkout extends a hold past this, counted from when the unit was held,
 * however often checkout is restarted: a hold keeps the unit from everyone
 * else. Room for a 60-minute portal hold with checkout begun at its end.
 */
export const MAX_HOLD_MINUTES = 3 * 60;

/**
 * How long after its hold lapses a reservation that went to checkout stays
 * open, for a renter who paid but was not sent straight back to finish.
 */
export const FINISH_AFTER_LAPSE_HOURS = 24;

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
  const holdUntil = new Date(sessionExpiresAt.getTime() + FINISH_AFTER_PAYMENT_MINUTES * MINUTE_MS);
  if (reservedAt && holdUntil.getTime() > reservedAt.getTime() + MAX_HOLD_MINUTES * MINUTE_MS) {
    return null;
  }
  return { sessionExpiresAt, holdUntil };
}

/**
 * Whether a reservation whose hold has lapsed is still open to a renter who
 * paid: it went to checkout (checkoutUpdatedAt is written when a Checkout
 * Session is created), and the hold lapsed within FINISH_AFTER_LAPSE_HOURS.
 * Payment itself is proved at completion, not here.
 */
export function mayFinishAfterLapsedHold(reservation: Record<string, unknown>, now: Date): boolean {
  const lapsedAt = timestampToDate(reservation.expiresAt);
  return (
    reservation.checkoutUpdatedAt != null &&
    lapsedAt != null &&
    now.getTime() - lapsedAt.getTime() < FINISH_AFTER_LAPSE_HOURS * 60 * MINUTE_MS
  );
}
