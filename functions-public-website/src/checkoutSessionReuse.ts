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
 * due. A recorded session that is open but for another amount, about to
 * close, or on the facility's previous Stripe account, is expired before a
 * new one is made. A paid one is never followed by another, unless completion
 * refused its payment and refunded it (isRefundedMoveInPayment). And when
 * checkout refuses because the move-in cannot go ahead, the recorded session
 * is expired too: paid, it would take money for a move-in that is then
 * refused.
 */
import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';
import { isRefundedMoveInPayment } from './paidMoveInRefund';

/** On the reservation: the Checkout Session its checkout made last. */
export const CHECKOUT_SESSION_ID_FIELD = 'checkoutSessionId';

/** On the reservation: the connected account that session is on. */
export const CHECKOUT_SESSION_ACCOUNT_FIELD = 'checkoutSessionAccountId';

/**
 * A session with less time than this left is replaced, not handed back: the
 * renter needs time to enter a card before Stripe closes the page.
 */
export const MIN_REUSE_MINUTES = 10;

export const CHECKOUT_ALREADY_PAID_MESSAGE =
  'This reservation has already been paid for. Please do not pay again. Contact the facility to finish your move-in.';

export const CHECKOUT_STARTING_MESSAGE = 'Payment is already being started. Please try again.';

/**
 * createPublicMoveInCheckout's refusals that mean the move-in cannot go
 * ahead, so a session paid now would be refused at completion. Listed, not
 * inferred from the code: a refusal not here (a new one included) leaves the
 * session as it is. Left out on purpose: the hold running out of time (the
 * hold already covers a session made earlier, which can still be paid and
 * finished), Stripe setup (a flag that can flicker while Stripe updates the
 * account), and a page too old to send the move-in form.
 */
const REFUSALS_THAT_END_CHECKOUT = new Set([
  // Rented, unlisted, internal use, archived, deleted, a type not offered,
  // or held by another renter.
  'Unit is not currently available',
  // Cancelled, completed, or marked expired.
  'Reservation is not active',
  'Reservation has expired',
  'Facility not found',
  // tenantCapacity.ts: the facility is at its active tenant limit.
  'This facility is not taking online move-ins right now. Please contact the facility.',
  // dnrScreening.ts: the renter is on a do-not-rent list.
  'Online move-in is not available. Please contact the facility directly.',
]);

/** A Checkout Session to send the renter to. */
export type PayableSession = { id: string; url: string };

/** The session recorded on a reservation. No account: recorded before accounts were. */
export type RecordedSession = { id: string; accountId: string | null };

type CheckoutSessions = Pick<Stripe.Checkout.SessionsResource, 'retrieve' | 'expire'>;

export type CheckoutSessionLookup = {
  reservationId: string;
  /** The amount due now, in cents. */
  cents: number;
  /** The facility's connected account now, where a new session is made. */
  stripeAccount: string;
  now: Date;
};

function textOf(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/** The PaymentIntent [session] was paid with, expanded or not; '' for none. */
export function paymentIntentIdOf(session: Pick<Stripe.Checkout.Session, 'payment_intent'>): string {
  const raw = session.payment_intent;
  return typeof raw === 'string' ? raw.trim() : textOf(raw?.id);
}

/** The session recorded on [reservation], if any. */
export function recordedCheckoutSession(reservation: Record<string, unknown> | undefined): RecordedSession | null {
  const id = textOf(reservation?.[CHECKOUT_SESSION_ID_FIELD]);
  if (!id) return null;
  return { id, accountId: textOf(reservation?.[CHECKOUT_SESSION_ACCOUNT_FIELD]) || null };
}

/**
 * The session recorded for the reservation, when it can be handed out again:
 * open, unpaid, made for this reservation on the facility's current account,
 * for the amount due, with time left to pay. A recorded session that is open
 * but cannot be handed out is expired, so the one about to be made is the
 * only payable one. Null when a new session should be made. Throws when the
 * recorded session has been paid, and when Stripe cannot say what state it is
 * in: nothing should be made then.
 */
export async function reusableCheckoutSession(
  sessions: CheckoutSessions,
  recorded: RecordedSession | null,
  lookup: CheckoutSessionLookup,
): Promise<PayableSession | null> {
  if (!recorded) return null;
  const account = recorded.accountId || lookup.stripeAccount;
  const options = { stripeAccount: account };
  let session: Stripe.Checkout.Session;
  try {
    session = await sessions.retrieve(recorded.id, {}, options);
  } catch (err: unknown) {
    // Only a session Stripe does not have is passed over. Any other failure
    // leaves the recorded one possibly payable, so it is thrown.
    if ((err as { code?: string }).code !== 'resource_missing') throw err;
    functions.logger.warn('createPublicMoveInCheckout: recorded session not found', {
      reservationId: lookup.reservationId,
      sessionId: recorded.id,
    });
    return null;
  }
  // Every session checkout makes names its reservation. One that does not is
  // not this reservation's to reuse or expire.
  if (session.metadata?.reservationId !== lookup.reservationId) return null;
  if (session.status === 'complete' || session.payment_status === 'paid') {
    // Unless completion refused that payment and refunded it: the charges
    // changed while the renter paid, which leaves the reservation open to
    // pay the new amount. Refused as already paid, the renter was refunded
    // and told to pay again, with no way to.
    const paidWith = paymentIntentIdOf(session);
    if (paidWith && await isRefundedMoveInPayment(paidWith)) return null;
    throw new functions.https.HttpsError('failed-precondition', CHECKOUT_ALREADY_PAID_MESSAGE);
  }
  if (session.status !== 'open') return null;
  const msLeft = (session.expires_at ?? 0) * 1000 - lookup.now.getTime();
  if (
    account === lookup.stripeAccount &&
    session.url &&
    session.amount_total === lookup.cents &&
    msLeft >= MIN_REUSE_MINUTES * 60 * 1000
  ) {
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
 * [seen] was read, when two presses each made a session at once. Then the one
 * recorded first stands: [created] is expired before anyone has its link, and
 * the other is handed out if it can still be paid.
 */
export async function recordCheckoutSession(
  sessions: CheckoutSessions,
  reservationRef: admin.firestore.DocumentReference,
  seen: RecordedSession | null,
  created: PayableSession,
  lookup: CheckoutSessionLookup,
): Promise<PayableSession> {
  const recordedMeanwhile = await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(reservationRef);
    const recorded = recordedCheckoutSession(snap.data());
    if (recorded && recorded.id !== seen?.id) return recorded;
    tx.update(reservationRef, {
      [CHECKOUT_SESSION_ID_FIELD]: created.id,
      [CHECKOUT_SESSION_ACCOUNT_FIELD]: lookup.stripeAccount,
    });
    return null;
  });
  if (!recordedMeanwhile) return created;
  await sessions.expire(created.id, {}, { stripeAccount: lookup.stripeAccount });
  const recorded = await reusableCheckoutSession(sessions, recordedMeanwhile, lookup);
  if (recorded) return recorded;
  throw new functions.https.HttpsError('aborted', CHECKOUT_STARTING_MESSAGE);
}

/** Whether a refusal from createPublicMoveInCheckout is one of REFUSALS_THAT_END_CHECKOUT. */
function refusalEndsCheckout(err: unknown): boolean {
  return (
    err instanceof functions.https.HttpsError &&
    (err.code === 'failed-precondition' || err.code === 'not-found') &&
    REFUSALS_THAT_END_CHECKOUT.has(err.message)
  );
}

/**
 * Expires the session recorded on the reservation, for a caller holding its
 * move-in token. Best effort: a session no longer open (paid, expired) or a
 * Stripe failure leaves the refusal to stand as it is.
 */
async function expireRecordedSession(data: Record<string, unknown> | undefined): Promise<void> {
  const reservationId = textOf(data?.reservationId);
  const token = textOf(data?.token);
  if (!/^[^/]{1,128}$/.test(reservationId) || !token) return;
  try {
    const snap = await admin.firestore().collection('publicReservations').doc(reservationId).get();
    const reservation = snap.data() as Record<string, unknown> | undefined;
    if (!reservation || reservation.moveInToken !== token) return;
    const recorded = recordedCheckoutSession(reservation);
    if (!recorded) return;
    let account = recorded.accountId;
    if (!account) {
      const facilityId = textOf(reservation.facilityId);
      const facilitySnap = facilityId
        ? await admin.firestore().collection('facilities').doc(facilityId).get()
        : null;
      account = textOf(facilitySnap?.data()?.stripeConnectAccountId) || null;
    }
    if (!account) return;
    await getStripeClient().checkout.sessions.expire(recorded.id, {}, { stripeAccount: account });
    functions.logger.info('createPublicMoveInCheckout: refused, so its recorded session was expired', {
      reservationId,
      sessionId: recorded.id,
    });
  } catch (err: unknown) {
    functions.logger.warn('createPublicMoveInCheckout: refused; recorded session not expired', {
      reservationId,
      message: err instanceof Error ? err.message : String(err),
    });
  }
}

/**
 * Wraps createPublicMoveInCheckout's handler: a refusal that means the
 * move-in cannot go ahead (REFUSALS_THAT_END_CHECKOUT) expires the
 * reservation's recorded session before it reaches the caller. Otherwise a
 * renter still on Stripe's page could pay for a unit that has been rented, or
 * a facility that is now full, and be refused the move-in afterwards. Only
 * for a caller that passed App Check,
 * as the handler requires before it touches Stripe: its refusal of one that
 * did not is failed-precondition too.
 */
export function expireRecordedSessionOnRefusal<T>(
  handler: (data: any, context: functions.https.CallableContext) => Promise<T>,
): (data: any, context: functions.https.CallableContext) => Promise<T> {
  return async (data, context) => {
    try {
      return await handler(data, context);
    } catch (err: unknown) {
      if (context?.app && refusalEndsCheckout(err)) {
        await expireRecordedSession(data);
      }
      throw err;
    }
  };
}
