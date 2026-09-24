import type Stripe from 'stripe';

/**
 * A paid online move-in, handed from the Stripe webhook to the code that
 * completes the move-in.
 *
 * The renter's browser used to be the only thing that completed an online
 * move-in: a renter who paid on Stripe's page and then closed the tab, or was
 * not redirected back, had paid for a unit and got no tenancy. The webhook
 * (functions-integrations) now records each paid move-in Checkout Session as
 * one of these, and a trigger in functions-public-website completes the
 * move-in from it, through the same code the browser uses.
 *
 * Writer and reader live in different codebases, so the collection and the
 * record's shape are defined here, once.
 */

/** `metadata.type` on a move-in Checkout Session and its PaymentIntent. */
export const PUBLIC_MOVE_IN_PAYMENT_TYPE = 'public_move_in';

/** One document per paid move-in Checkout Session, keyed by the session id. Server-only. */
export const PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION = 'publicMoveInCheckouts';

/** Where a recorded checkout has got to. Only `paid` is waiting on the trigger. */
export type PublicMoveInCheckoutStatus =
  /** Recorded by the webhook; the move-in has not been attempted yet. */
  | 'paid'
  /** This payment completed the move-in. */
  | 'completed'
  /** The move-in for this payment had already been completed, usually by the renter's browser. */
  | 'alreadyCompleted'
  /**
   * The move-in cannot be completed with this payment; the owner was told to
   * refund it, and it is marked in publicMoveInPayments so it cannot complete
   * the move-in later.
   */
  | 'refused'
  /** The move-in form was not saved, so only the renter can finish; the owner was told. */
  | 'awaitingForm'
  /** Completing kept failing for an hour; the owner was told. */
  | 'failed';

export type PaidPublicMoveInCheckout = {
  checkoutSessionId: string;
  reservationId: string;
  facilityId: string;
  /** The facility's connected account, from the event: move-in checkouts are direct charges. */
  connectedAccountId: string;
  paymentIntentId: string;
  amountTotalCents: number;
  currency: string;
  livemode: boolean;
  stripeEventId: string;
  status: PublicMoveInCheckoutStatus;
};

/** Whether a Checkout Session was created by createPublicMoveInCheckout. */
export function isPublicMoveInCheckoutSession(session: Pick<Stripe.Checkout.Session, 'metadata'>): boolean {
  return session.metadata?.type === PUBLIC_MOVE_IN_PAYMENT_TYPE;
}

/**
 * The record for a completed move-in Checkout Session, or why there is none.
 *
 * The webhook only says the renter paid; it is not trusted for anything else.
 * The trigger that reads this retrieves the PaymentIntent from the facility's
 * connected account and checks its amount, status and reservation before
 * anything is written, as the browser's completion does.
 */
export function paidPublicMoveInCheckoutFromSession(
  session: Pick<
    Stripe.Checkout.Session,
    'id' | 'metadata' | 'payment_status' | 'payment_intent' | 'amount_total' | 'currency' | 'livemode'
  >,
  connectedAccountId: string | null | undefined,
  stripeEventId: string,
): { record: PaidPublicMoveInCheckout } | { ignored: string } {
  if (!isPublicMoveInCheckoutSession(session)) {
    return { ignored: 'not a public move-in checkout' };
  }
  const account = String(connectedAccountId || '').trim();
  if (!account) {
    // Move-in checkouts are created on the facility's connected account, so
    // their events always name it.
    return { ignored: 'no connected account on the event' };
  }
  const reservationId = String(session.metadata?.reservationId || '').trim();
  const facilityId = String(session.metadata?.facilityId || '').trim();
  if (!reservationId || !facilityId) {
    return { ignored: 'no reservation or facility in the session metadata' };
  }
  if (session.payment_status !== 'paid') {
    return { ignored: `payment status is ${session.payment_status || 'unknown'}` };
  }
  const paymentIntent = session.payment_intent;
  const paymentIntentId = String(
    (typeof paymentIntent === 'string' ? paymentIntent : paymentIntent?.id) || '',
  ).trim();
  if (!paymentIntentId) {
    return { ignored: 'no payment intent on the session' };
  }
  return {
    record: {
      checkoutSessionId: session.id,
      reservationId,
      facilityId,
      connectedAccountId: account,
      paymentIntentId,
      amountTotalCents: Number(session.amount_total) || 0,
      currency: String(session.currency || 'usd'),
      livemode: session.livemode === true,
      stripeEventId,
      status: 'paid',
    },
  };
}
