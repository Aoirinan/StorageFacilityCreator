import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { recordPaidPublicMoveInCheckout } from '@sfc/functions-shared';

/** The type online move-in checkout (functions-public-website createPublicMoveInCheckout) sets on its sessions. */
export const PUBLIC_MOVE_IN_CHECKOUT_TYPE = 'public_move_in';

function textOf(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/**
 * A paid online move-in Checkout Session, from the Connect destination (a
 * facility's connected account: [connectedAccountId] is the event's account).
 *
 * Before, nothing server-side reacted to one: a renter who paid and closed
 * the tab kept the unit only until checkout's hold lapsed, and was never
 * moved in or refunded. Now the payment is recorded and the unit held for the
 * payer until PAID_HOLD_MAX_HOURS after payment (functions-shared
 * recordPaidPublicMoveInCheckout, the same code the move-in page's
 * confirmation runs), and functions-public-website's 15-minute sweep then
 * refunds them or tells the owner. Nothing is moved in or refunded here.
 *
 * [paidAtSeconds] is the event's creation, when Stripe saw the session
 * complete. A failure is thrown, so Stripe retries the event; recording is
 * idempotent, and does nothing once the payment has moved someone in or been
 * refunded.
 */
export async function handlePublicMoveInCheckoutCompleted(
  session: Stripe.Checkout.Session,
  connectedAccountId: string | undefined,
  paidAtSeconds: number | undefined,
): Promise<void> {
  const reservationId = textOf(session.metadata?.reservationId);
  const facilityId = textOf(session.metadata?.facilityId);
  const rawIntent = session.payment_intent;
  const paymentIntentId = typeof rawIntent === 'string' ? rawIntent.trim() : textOf(rawIntent?.id);
  const context = { sessionId: session.id, reservationId, facilityId, paymentIntentId };
  if (!connectedAccountId) {
    // Online move-in takes payment on the facility's connected account; a
    // session on the platform account is not one of its sessions.
    functions.logger.warn('Online move-in checkout completed on the platform account; ignored', context);
    return;
  }
  if (session.payment_status !== 'paid') {
    functions.logger.info('Online move-in checkout completed unpaid; nothing to record', {
      ...context,
      paymentStatus: session.payment_status,
    });
    return;
  }
  if (!reservationId || !facilityId || !paymentIntentId) {
    functions.logger.error('Online move-in checkout completed without its reservation, facility or payment', context);
    return;
  }
  const now = new Date();
  const paidAt = typeof paidAtSeconds === 'number' && Number.isFinite(paidAtSeconds) && paidAtSeconds * 1000 < now.getTime()
    ? new Date(paidAtSeconds * 1000)
    : now;
  const outcome = await recordPaidPublicMoveInCheckout(admin.firestore(), {
    paymentIntentId,
    checkoutSessionId: session.id || null,
    reservationId,
    facilityId,
    connectAccountId: connectedAccountId,
    amountCents: typeof session.amount_total === 'number' ? session.amount_total : null,
    paidAt,
    now,
    holdMinutes: 'until-cap',
    recordedBy: 'stripeWebhook',
  });
  const log = outcome === 'held' || outcome === 'settled' ? functions.logger.info : functions.logger.warn;
  log('Online move-in checkout paid: recorded', { ...context, connectedAccountId, outcome });
}
