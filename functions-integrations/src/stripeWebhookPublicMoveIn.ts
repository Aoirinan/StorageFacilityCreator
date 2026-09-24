import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION,
  paidPublicMoveInCheckoutFromSession,
} from '@sfc/functions-shared';

export type PaidMoveInCheckoutRecording = 'recorded' | 'duplicate' | 'ignored';

/** gRPC ALREADY_EXISTS, which `create()` rejects with when the document is there. */
const ALREADY_EXISTS = 6;

/**
 * Records a paid online move-in Checkout Session (a connected account's
 * checkout.session.completed) for functions-public-website to complete the
 * move-in from, whether or not the renter comes back from Stripe.
 *
 * Only the record is written here. The move-in, and the checks on the
 * payment it rests on, belong to the public website's completion code, which
 * a Firestore trigger on this collection runs (paidCheckoutCompletion.ts).
 *
 * Stripe delivers events at least once, so the record is created only if it
 * is not there: a redelivered event, or one whose processed-marker write
 * failed, finds it and changes nothing. A failed write throws, so the
 * webhook answers 500 and Stripe sends the event again.
 */
export async function recordPaidPublicMoveInCheckout(
  session: Stripe.Checkout.Session,
  connectedAccountId: string | null | undefined,
  stripeEventId: string,
  db: admin.firestore.Firestore = admin.firestore(),
): Promise<PaidMoveInCheckoutRecording> {
  const result = paidPublicMoveInCheckoutFromSession(session, connectedAccountId, stripeEventId);
  if ('ignored' in result) {
    functions.logger.warn('Public move-in checkout completed but not recorded', {
      checkoutSessionId: session.id,
      connectedAccountId: connectedAccountId || null,
      reason: result.ignored,
    });
    return 'ignored';
  }
  const { record } = result;
  try {
    await db.collection(PUBLIC_MOVE_IN_CHECKOUTS_COLLECTION).doc(record.checkoutSessionId).create({
      ...record,
      receivedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (err: unknown) {
    if ((err as { code?: unknown } | null)?.code === ALREADY_EXISTS) {
      functions.logger.info('Public move-in checkout already recorded', {
        checkoutSessionId: record.checkoutSessionId,
        stripeEventId,
      });
      return 'duplicate';
    }
    throw err;
  }
  functions.logger.info('Public move-in checkout recorded for completion', {
    checkoutSessionId: record.checkoutSessionId,
    reservationId: record.reservationId,
    facilityId: record.facilityId,
    paymentIntentId: record.paymentIntentId,
  });
  return 'recorded';
}
