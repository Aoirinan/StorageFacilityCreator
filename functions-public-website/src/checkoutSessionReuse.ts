/**
 * One payable Checkout Session per reservation.
 *
 * On 2026-09-24, in a live $1 move-in at Keepsake, the first press of the
 * move-in page's pay button opened no window, so the renter pressed again,
 * and createPublicMoveInCheckout made a second session for the same
 * reservation 14 seconds after the first. Both were open and payable. Paying
 * both takes the money twice: completePublicMoveIn's one-payment-one-move-in
 * record refuses the second payment only after it has been taken, and the
 * owner has to refund it by hand.
 *
 * So checkout records the session it makes on the reservation, and a repeat
 * call hands back that session while Stripe still offers it for the amount
 * due. A recorded session that is open but for another amount, or about to
 * close, is expired before a new one is made. A paid one is never followed by
 * another.
 */
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';

/** On the reservation: the Checkout Session its checkout made last. */
export const CHECKOUT_SESSION_ID_FIELD = 'checkoutSessionId';

/**
 * A session with less time than this left is replaced, not handed back: the
 * renter needs time to enter a card before Stripe closes the page.
 */
export const MIN_REUSE_MINUTES = 10;

export const CHECKOUT_ALREADY_PAID_MESSAGE =
  'This reservation has already been paid for. Please do not pay again. Contact the facility to finish your move-in.';

export const CHECKOUT_STARTING_MESSAGE = 'Payment is already being started. Please try again.';

/** A Checkout Session to send the renter to. */
export type PayableSession = { id: string; url: string };

type CheckoutSessions = Pick<Stripe.Checkout.SessionsResource, 'retrieve' | 'expire'>;

export type CheckoutSessionLookup = {
  reservationId: string;
  /** The amount due now, in cents. */
  cents: number;
  /** The facility's connected account, where its sessions are. */
  stripeAccount: string;
  now: Date;
};

function sessionIdOf(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * The session recorded for the reservation, when it can be handed out again:
 * open, unpaid, made for this reservation, for the amount due, with time left
 * to pay. A recorded session that is open but cannot be handed out is expired,
 * so the one about to be made is the only payable one. Null when a new session
 * should be made. Throws when the recorded session has been paid, and when
 * Stripe cannot say what state it is in: nothing should be made then.
 */
export async function reusableCheckoutSession(
  sessions: CheckoutSessions,
  recordedSessionId: unknown,
  lookup: CheckoutSessionLookup,
): Promise<PayableSession | null> {
  const id = sessionIdOf(recordedSessionId);
  if (!id) return null;
  const options = { stripeAccount: lookup.stripeAccount };
  let session: Stripe.Checkout.Session;
  try {
    session = await sessions.retrieve(id, {}, options);
  } catch (err: unknown) {
    // Only a session Stripe does not have (the facility has since connected
    // another account, say) is passed over. Any other failure leaves the
    // recorded one possibly payable, so it is thrown.
    if ((err as { code?: string }).code !== 'resource_missing') throw err;
    functions.logger.warn('createPublicMoveInCheckout: recorded session not found', {
      reservationId: lookup.reservationId,
      sessionId: id,
    });
    return null;
  }
  // Every session checkout makes names its reservation. One that does not is
  // not this reservation's to reuse or expire.
  if (session.metadata?.reservationId !== lookup.reservationId) return null;
  if (session.status === 'complete' || session.payment_status === 'paid') {
    throw new functions.https.HttpsError('failed-precondition', CHECKOUT_ALREADY_PAID_MESSAGE);
  }
  if (session.status !== 'open') return null;
  const msLeft = (session.expires_at ?? 0) * 1000 - lookup.now.getTime();
  if (session.url && session.amount_total === lookup.cents && msLeft >= MIN_REUSE_MINUTES * 60 * 1000) {
    functions.logger.info('createPublicMoveInCheckout: handing back open session', {
      reservationId: lookup.reservationId,
      sessionId: session.id,
    });
    return { id: session.id, url: session.url };
  }
  // Expired before a new one is made. If Stripe refuses (it has just been
  // paid, say), this throws and no second session is made.
  await sessions.expire(session.id, {}, options);
  return null;
}

/**
 * Records [created] as the reservation's session, and returns the session to
 * send the renter to: [created], unless another call recorded one after
 * [seenSessionId] was read, when two presses each made a session at once.
 * Then the one recorded first stands: [created] is expired before anyone has
 * its link, and the other is handed out if it can still be paid.
 */
export async function recordCheckoutSession(
  sessions: CheckoutSessions,
  reservationRef: admin.firestore.DocumentReference,
  seenSessionId: unknown,
  created: PayableSession,
  lookup: CheckoutSessionLookup,
): Promise<PayableSession> {
  const seen = sessionIdOf(seenSessionId);
  const recordedMeanwhile = await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(reservationRef);
    const recorded = sessionIdOf(snap.data()?.[CHECKOUT_SESSION_ID_FIELD]);
    if (recorded && recorded !== seen) return recorded;
    tx.update(reservationRef, { [CHECKOUT_SESSION_ID_FIELD]: created.id });
    return null;
  });
  if (!recordedMeanwhile) return created;
  await sessions.expire(created.id, {}, { stripeAccount: lookup.stripeAccount });
  const recorded = await reusableCheckoutSession(sessions, recordedMeanwhile, lookup);
  if (recorded) return recorded;
  throw new functions.https.HttpsError('aborted', CHECKOUT_STARTING_MESSAGE);
}
