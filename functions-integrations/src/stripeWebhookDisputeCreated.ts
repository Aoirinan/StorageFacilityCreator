import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';
import { eventAccountMatchesFacility } from './connectedAccountGuard';

export type DisputeEventType =
  | 'charge.dispute.created'
  | 'charge.dispute.updated'
  | 'charge.dispute.closed'
  | 'charge.dispute.funds_withdrawn'
  | 'charge.dispute.funds_reinstated';

/** An inquiry (status `warning_*`): the bank has asked a question and no money has moved. */
export function isDisputeInquiry(dispute: Pick<Stripe.Dispute, 'status'>): boolean {
  return typeof dispute.status === 'string' && dispute.status.startsWith('warning_');
}

export type DisputeMoneyMovement = { withdrawn: boolean; reinstated: boolean };

/**
 * What one dispute event shows has happened to the disputed money.
 *
 * withdrawn: the event is `charge.dispute.funds_withdrawn`, or the dispute is
 * not an inquiry and its `balance_transactions` hold a withdrawal (a negative
 * amount). The status alone is not enough: an inquiry never withdraws, and a
 * dispute can be open before its money moves, so only a withdrawal Stripe has
 * booked counts.
 *
 * reinstated: the event is `charge.dispute.funds_reinstated`, the dispute is
 * `won`, or its `balance_transactions` hold a reinstatement (positive).
 *
 * Reinstated also counts as withdrawn: money only comes back after it left,
 * so a return seen first (events arrive in any order) posts both entries and
 * nets to zero, and the late withdrawal event then finds its entry there.
 */
export function disputeMoneyMovement(
  dispute: Pick<Stripe.Dispute, 'status' | 'balance_transactions'>,
  eventType: DisputeEventType,
): DisputeMoneyMovement {
  let withdrawalBooked = false;
  let reinstatementBooked = false;
  const balanceTransactions = Array.isArray(dispute.balance_transactions) ? dispute.balance_transactions : [];
  for (const txn of balanceTransactions as unknown[]) {
    // An unexpanded id says nothing about which way the money went.
    const amount = txn && typeof txn === 'object' ? (txn as { amount?: unknown }).amount : null;
    if (typeof amount !== 'number') continue;
    if (amount < 0) withdrawalBooked = true;
    if (amount > 0) reinstatementBooked = true;
  }
  const reinstated =
    eventType === 'charge.dispute.funds_reinstated' || dispute.status === 'won' || reinstatementBooked;
  const withdrawn =
    eventType === 'charge.dispute.funds_withdrawn' ||
    (!isDisputeInquiry(dispute) && withdrawalBooked) ||
    reinstated;
  return { withdrawn, reinstated };
}

/**
 * Record a card dispute against the tenant, for every `charge.dispute.*` event.
 *
 * The tenant owes the disputed amount again only while the money is actually
 * out of the facility's account. Posting it for every dispute charged tenants
 * who owed nothing: inquiries withdraw no money, won disputes return it, and
 * both the delinquency job (late fees, lien, gate lockout) and autopay sum
 * the ledger. So:
 *
 * - `ledgers/dispute_{id}` (+amount) is created once, when an event shows the
 *   funds withdrawn (see [disputeMoneyMovement]). Never for an inquiry.
 * - `ledgers/dispute_{id}_reinstated` (minus the original's amount) is created
 *   once, when an event shows the funds returned, and only alongside or after
 *   the original, so it can never credit a tenant who was not charged.
 * - Both are created in one transaction with the payment's dispute status, so
 *   redelivered and concurrent events converge on one of each.
 * - The payment records `disputeStatus` on every event, from the newest event
 *   by Stripe's `created` time; `created` also marks it `disputed`.
 *
 * Tenant charges live on the facility's connected account, so lookups use
 * `stripeAccount`, and the account must be the facility's own before anything
 * is written. Errors propagate: the webhook returns 500 and Stripe redelivers.
 */
export async function handleDisputeCreated(
  dispute: Stripe.Dispute,
  connectedAccountId?: string,
  eventType: DisputeEventType = 'charge.dispute.created',
  eventCreated?: number,
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

  // The metadata was written by whoever created the PaymentIntent; only the
  // facility's own account may put a dispute on its tenant's ledger.
  const accountMatches = await eventAccountMatchesFacility({
    facilityId,
    connectedAccountId,
    eventType,
    objectId: dispute.id,
  });
  if (!accountMatches) return;

  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  const existingPayments = await facilityRef
    .collection('payments')
    .where('externalPaymentId', '==', paymentIntentId)
    .limit(1)
    .get();
  const paymentRef = existingPayments.empty ? null : existingPayments.docs[0].ref;

  const movement = disputeMoneyMovement(dispute, eventType);
  const reason = dispute.reason || 'Unknown reason';
  const originalRef = facilityRef.collection('ledgers').doc(`dispute_${dispute.id}`);
  const reversalRef = facilityRef.collection('ledgers').doc(`dispute_${dispute.id}_reinstated`);
  const ledgerMetadata = {
    disputeId: dispute.id,
    chargeId,
    paymentIntentId,
    reason: dispute.reason || null,
    connectedAccountId: connectedAccountId || null,
  };

  // Reading both entries inside the transaction is what makes concurrent
  // deliveries safe: a delivery that loses the race is retried by Firestore
  // and then sees the entry the winner created.
  const posted = await db.runTransaction(async (tx) => {
    // Firestore wants every read before any write.
    const originalSnap = await tx.get(originalRef);
    const reversalSnap = await tx.get(reversalRef);
    const paymentSnap = paymentRef ? await tx.get(paymentRef) : null;
    const now = admin.firestore.FieldValue.serverTimestamp();

    if (paymentSnap?.exists) {
      const update: Record<string, unknown> = { disputeId: dispute.id, updatedAt: now };
      // Redelivery can bring an older event after a newer one; the status
      // shown is the one from the newest event.
      const seenAt = paymentSnap.get('disputeStatusEventAt');
      const stale = typeof eventCreated === 'number' && typeof seenAt === 'number' && eventCreated < seenAt;
      if (!stale) {
        update.disputeStatus = dispute.status || null;
        update.disputeStatusEventAt = typeof eventCreated === 'number' ? eventCreated : null;
        update.disputeUpdatedAt = now;
      }
      if (eventType === 'charge.dispute.created') {
        update.status = 'disputed';
        update.notes = `Dispute created: ${reason}`;
      }
      tx.update(paymentSnap.ref, update);
    }

    const existingAmount = originalSnap.exists ? originalSnap.get('amount') : null;
    let originalAmount: number | null = typeof existingAmount === 'number' ? existingAmount : null;
    let postedOriginal = false;
    if (!originalSnap.exists && movement.withdrawn) {
      originalAmount = dispute.amount / 100;
      tx.create(originalRef, {
        tenantId: tenantId || null,
        facilityId,
        type: 'dispute',
        // Positive: the disputed money has left the facility's account, so
        // the tenant owes it again. Payments are stored negative, charges positive.
        amount: originalAmount,
        description: `Dispute: funds withdrawn (${reason})`,
        referenceId: paymentRef ? paymentRef.id : null,
        entryDate: now,
        status: 'posted',
        createdAt: now,
        createdBy: 'system@stripe-webhook',
        metadata: ledgerMetadata,
      });
      postedOriginal = true;
    }

    let postedReversal = false;
    if (movement.reinstated && !reversalSnap.exists && originalAmount !== null) {
      tx.create(reversalRef, {
        tenantId: tenantId || null,
        facilityId,
        type: 'dispute_reversal',
        // Exactly undoes the original, whatever the event says the amount is.
        amount: -originalAmount,
        description:
          dispute.status === 'won'
            ? `Dispute won: funds returned (${reason})`
            : `Dispute funds returned (${reason})`,
        referenceId: paymentRef ? paymentRef.id : null,
        entryDate: now,
        status: 'posted',
        createdAt: now,
        createdBy: 'system@stripe-webhook',
        metadata: { ...ledgerMetadata, reversesEntryId: originalRef.id },
      });
      postedReversal = true;
    }
    return { postedOriginal, postedReversal };
  });

  functions.logger.info(`Dispute ${eventType}: ${dispute.id} is ${dispute.status}`, {
    paymentIntentId,
    connectedAccount: !!connectedAccountId,
    inquiry: isDisputeInquiry(dispute),
    ...movement,
    ...posted,
  });
}
