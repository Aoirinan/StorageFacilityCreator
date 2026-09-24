import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';
import { isAlreadyExistsError } from './firestoreErrors';

export type DisputeEventType =
  | 'charge.dispute.created'
  | 'charge.dispute.updated'
  | 'charge.dispute.closed';

/**
 * Record a card dispute against the tenant.
 *
 * Three things this has to get right, none of which it previously did:
 *
 * 1. Tenant charges live on the facility's *connected* account, so the
 *    PaymentIntent must be retrieved with `stripeAccount` (the event's
 *    `account`). Without it the lookup failed with "No such charge", the error
 *    was swallowed, and no tenant dispute was ever recorded. The dispute
 *    carries `payment_intent` itself, so the charge is only fetched as a
 *    fallback.
 *
 * 2. The ledger entry has a deterministic id (`dispute_{disputeId}`) written
 *    with create(), so a redelivered event cannot post it twice.
 *
 * 3. Only `charge.dispute.created` posts to the ledger. The same handler also
 *    runs for `.updated` and `.closed` (several per dispute); each of those
 *    used to post the disputed amount again. They now only record the
 *    dispute's status on the payment, which is how an operator sees won/lost.
 *
 * Errors propagate: the webhook returns 500 and Stripe redelivers, rather than
 * a dispute being marked processed with nothing recorded.
 *
 * Open question for the owner: whether a *won* dispute should post a
 * reversal. Until that is decided, the +amount from `created` stays on the
 * ledger after a win, and the payment shows disputeStatus 'won'.
 */
export async function handleDisputeCreated(
  dispute: Stripe.Dispute,
  connectedAccountId?: string,
  eventType: DisputeEventType = 'charge.dispute.created',
) {
  const stripe = getStripeClient();
  const requestOptions: Stripe.RequestOptions = connectedAccountId ? { stripeAccount: connectedAccountId } : {};
  const chargeId = typeof dispute.charge === 'string' ? dispute.charge : dispute.charge?.id || null;

  let paymentIntentId =
    typeof dispute.payment_intent === 'string' ? dispute.payment_intent : dispute.payment_intent?.id || null;
  if (!paymentIntentId && chargeId) {
    const charge = await stripe.charges.retrieve(chargeId, {}, requestOptions);
    paymentIntentId =
      typeof charge.payment_intent === 'string' ? charge.payment_intent : charge.payment_intent?.id || null;
  }
  if (!paymentIntentId) {
    functions.logger.warn('Dispute has no payment intent', { disputeId: dispute.id, chargeId });
    return;
  }

  const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId, {}, requestOptions);
  const facilityId = paymentIntent.metadata?.facilityId;
  const tenantId = paymentIntent.metadata?.tenantId;

  if (!facilityId) {
    functions.logger.warn('Dispute payment intent has no facilityId metadata', {
      disputeId: dispute.id,
      paymentIntentId,
    });
    return;
  }

  const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
  const existingPayments = await facilityRef
    .collection('payments')
    .where('externalPaymentId', '==', paymentIntentId)
    .limit(1)
    .get();
  const paymentDoc = existingPayments.empty ? null : existingPayments.docs[0];

  if (eventType !== 'charge.dispute.created') {
    if (paymentDoc) {
      await paymentDoc.ref.update({
        disputeId: dispute.id,
        disputeStatus: dispute.status || null,
        disputeUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    functions.logger.info(`Dispute ${eventType}: ${dispute.id} is ${dispute.status}`);
    return;
  }

  if (paymentDoc) {
    await paymentDoc.ref.update({
      status: 'disputed',
      disputeId: dispute.id,
      disputeStatus: dispute.status || null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      notes: `Dispute created: ${dispute.reason || 'Unknown reason'}`,
    });
  }

  try {
    await facilityRef.collection('ledgers').doc(`dispute_${dispute.id}`).create({
      tenantId: tenantId || null,
      facilityId: facilityId,
      type: 'dispute',
      // Positive: the disputed money has left the facility's account, so the
      // tenant owes it again. Payments are stored negative, charges positive.
      amount: dispute.amount / 100,
      description: `Dispute created: ${dispute.reason || 'Unknown reason'}`,
      referenceId: paymentDoc ? paymentDoc.id : null,
      entryDate: admin.firestore.FieldValue.serverTimestamp(),
      status: 'posted',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'system@stripe-webhook',
      metadata: {
        disputeId: dispute.id,
        chargeId: chargeId,
        paymentIntentId: paymentIntentId,
        reason: dispute.reason || null,
        connectedAccountId: connectedAccountId || null,
      },
    });
  } catch (error) {
    if (!isAlreadyExistsError(error)) throw error;
    functions.logger.info(`Dispute ${dispute.id} already on the ledger`);
    return;
  }

  functions.logger.info(`Dispute created: ${dispute.id} for payment intent ${paymentIntentId}` +
    (connectedAccountId ? ' on connected account' : ''));
}
