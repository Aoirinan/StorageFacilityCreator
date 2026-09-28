import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  DISPUTE_LEDGER_TYPE,
  DISPUTE_REVERSAL_LEDGER_TYPE,
  getStripeClient,
} from '@sfc/functions-shared';
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
 * How far along a dispute status is. Two events can carry the same
 * `created` second (closed as lost, then an `updated` still reading
 * under_review); the later stage wins the tie, so the payment does not go
 * back to showing an open dispute that has ended.
 */
export function disputeStatusRank(status: unknown): number {
  switch (status) {
    case 'warning_needs_response':
    case 'needs_response':
      return 1;
    case 'warning_under_review':
    case 'under_review':
      return 2;
    case 'won':
    case 'lost':
    case 'warning_closed':
    case 'prevented':
    case 'charge_refunded':
      return 3;
    default:
      return 0;
  }
}

/**
 * Dispute statuses that end with the payment standing: won, an inquiry
 * closed, or a dispute prevented before any chargeback.
 */
const DISPUTE_ENDED_FOR_FACILITY = new Set(['won', 'warning_closed', 'prevented']);

/**
 * Whether an event is older than the dispute status already on the payment:
 * strictly older by `created`, or from the same second and an earlier stage.
 */
export function isStaleDisputeStatus(params: {
  eventCreated: number | undefined;
  eventStatus: unknown;
  seenAt: unknown;
  seenStatus: unknown;
}): boolean {
  const { eventCreated, eventStatus, seenAt, seenStatus } = params;
  if (typeof eventCreated !== 'number' || typeof seenAt !== 'number') return false;
  if (eventCreated !== seenAt) return eventCreated < seenAt;
  return disputeStatusRank(eventStatus) < disputeStatusRank(seenStatus);
}

/**
 * What one dispute event shows has happened to the disputed money.
 *
 * withdrawn: the event is `charge.dispute.funds_withdrawn`, or the dispute is
 * not an inquiry and its `balance_transactions` hold a withdrawal (a negative
 * amount), or it is `lost`. An open status alone is not enough: an inquiry
 * never withdraws, and a dispute can be open before its money moves, so only
 * a withdrawal Stripe has booked counts. `lost` is the exception: the money
 * is gone for good whatever the object lists, and without it a lost dispute
 * whose withdrawal event never arrived charged the tenant nothing.
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
    dispute.status === 'lost' ||
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
 *   by Stripe's `created` time (a same-second tie goes to the later stage);
 *   `created` also marks it `disputed`, keeping the status it had in
 *   `statusBeforeDispute`, and a win (or the money coming back) restores it.
 * - Once reversed, the original counts as settled (`metadata.allocatedAmount`)
 *   so the app never offers it for an invoice again, and any unpaid invoice
 *   staff made from it is voided: a won dispute leaves nothing to bill.
 * - Autopay, the delinquency job and the payment reminders leave both rows
 *   out of what they collect or ask for (functions-shared
 *   ledger/disputeEntries.ts), and the tenant portal leaves the `disputed`
 *   payment out of its balance: a disputed amount is collected by staff, by
 *   hand.
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
  eventId?: string,
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
    eventId,
    tenantId: tenantId ?? null,
    amount: dispute.amount / 100,
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

    const existingAmount = originalSnap.exists ? originalSnap.get('amount') : null;
    const postedOriginal = !originalSnap.exists && movement.withdrawn;
    const originalAmount: number | null = postedOriginal
      ? dispute.amount / 100
      : typeof existingAmount === 'number'
        ? existingAmount
        : null;
    const postedReversal = movement.reinstated && !reversalSnap.exists && originalAmount !== null;
    const reversed = reversalSnap.exists || postedReversal;

    if (paymentSnap?.exists) {
      const update: Record<string, unknown> = { disputeId: dispute.id, updatedAt: now };
      // Redelivery can bring an older event after a newer one; the status
      // shown is the one from the newest event.
      const stale = isStaleDisputeStatus({
        eventCreated,
        eventStatus: dispute.status,
        seenAt: paymentSnap.get('disputeStatusEventAt'),
        seenStatus: paymentSnap.get('disputeStatus'),
      });
      if (!stale) {
        update.disputeStatus = dispute.status || null;
        update.disputeStatusEventAt = typeof eventCreated === 'number' ? eventCreated : null;
        update.disputeUpdatedAt = now;
      }
      const newestStatus = stale ? paymentSnap.get('disputeStatus') : dispute.status;
      const currentStatus = paymentSnap.get('status');
      if (reversed || DISPUTE_ENDED_FOR_FACILITY.has(String(newestStatus))) {
        // A won dispute left the payment `disputed` for good: the app and the
        // portal kept treating a payment that stands as taken back.
        if (currentStatus === 'disputed') {
          update.status = paymentSnap.get('statusBeforeDispute') || 'completed';
          update.notes = `Dispute closed in the facility's favour (${newestStatus || 'funds returned'})`;
        }
      } else if (eventType === 'charge.dispute.created') {
        if (currentStatus !== 'disputed') update.statusBeforeDispute = currentStatus ?? null;
        update.status = 'disputed';
        update.notes = `Dispute created: ${reason}`;
      }
      tx.update(paymentSnap.ref, update);
    }

    // A reversed dispute is settled: the app's invoice selection and payment
    // allocation skip a charge whose allocatedAmount covers it, so a won
    // dispute is never billed again.
    const settledBy = { allocatedAmount: originalAmount, settledByEntryId: reversalRef.id };

    if (postedOriginal) {
      tx.create(originalRef, {
        tenantId: tenantId || null,
        facilityId,
        type: DISPUTE_LEDGER_TYPE,
        // Positive: the disputed money has left the facility's account, so
        // the tenant owes it again. Payments are stored negative, charges positive.
        amount: originalAmount,
        description: `Dispute: funds withdrawn (${reason})`,
        referenceId: paymentRef ? paymentRef.id : null,
        entryDate: now,
        status: 'posted',
        createdAt: now,
        createdBy: 'system@stripe-webhook',
        metadata: postedReversal ? { ...ledgerMetadata, ...settledBy } : ledgerMetadata,
      });
    }

    if (postedReversal && originalAmount !== null) {
      if (!postedOriginal) {
        tx.update(originalRef, {
          'metadata.allocatedAmount': settledBy.allocatedAmount,
          'metadata.settledByEntryId': settledBy.settledByEntryId,
        });
      }
      tx.create(reversalRef, {
        tenantId: tenantId || null,
        facilityId,
        type: DISPUTE_REVERSAL_LEDGER_TYPE,
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
    }
    return { postedOriginal, postedReversal, reversed };
  });

  // Every time, not only when the reversal was just posted: a delivery that
  // died after the transaction is retried by Stripe, and this must still run.
  const voidedInvoices = posted.reversed
    ? await voidInvoicesForReversedDispute({
        facilityRef,
        ledgerEntryId: originalRef.id,
        disputeId: dispute.id,
        tenantId: tenantId || null,
      })
    : [];

  functions.logger.info(`Dispute ${eventType}: ${dispute.id} is ${dispute.status}`, {
    paymentIntentId,
    connectedAccount: !!connectedAccountId,
    inquiry: isDisputeInquiry(dispute),
    ...movement,
    ...posted,
    voidedInvoices,
  });
}

/** Invoice statuses that still ask the tenant for money. */
const UNPAID_INVOICE_STATUSES = new Set(['draft', 'sent', 'overdue']);

/**
 * Voids every unpaid invoice that bills a dispute the facility has won.
 *
 * Staff can put a dispute row on an invoice to collect it by hand. After a
 * win the money is back and the reversal cancels the row, but the invoice
 * stayed open asking the tenant to pay it. Voiding (not editing) is what the
 * app already does to correct an invoice, and it frees the invoice's other
 * charges to go on a new one. A paid invoice is left alone: that tenant has a
 * credit for staff to refund.
 */
async function voidInvoicesForReversedDispute(params: {
  facilityRef: admin.firestore.DocumentReference;
  ledgerEntryId: string;
  disputeId: string;
  tenantId: string | null;
}): Promise<string[]> {
  const { facilityRef, ledgerEntryId, disputeId } = params;
  const invoices = await facilityRef
    .collection('invoices')
    .where('ledgerEntryIds', 'array-contains', ledgerEntryId)
    .get();
  const voided: string[] = [];
  for (const invoice of invoices.docs) {
    const status = invoice.get('status') ?? 'draft';
    if (!UNPAID_INVOICE_STATUSES.has(status)) continue;
    const otherCharges = ((invoice.get('ledgerEntryIds') as unknown[]) || []).filter((id) => id !== ledgerEntryId);
    const voidReason =
      'The card dispute on this invoice was won and the money returned, so it is no longer owed.' +
      (otherCharges.length > 0 ? ' Its other charges can go on a new invoice.' : '');
    const now = admin.firestore.FieldValue.serverTimestamp();
    await invoice.ref.update({
      status: 'voided',
      isActive: false,
      voidReason,
      updatedAt: now,
      updatedBy: 'system@stripe-webhook',
    });
    await facilityRef.collection('auditLogs').add({
      action: 'invoice.voided',
      actorUid: 'system',
      actorEmail: 'system@stripe-webhook',
      targetId: invoice.id,
      entityType: 'invoice',
      entityId: invoice.id,
      tenantId: (invoice.get('tenantId') as string | undefined) ?? params.tenantId,
      details: {
        invoiceNumber: invoice.get('invoiceNumber') ?? null,
        reason: voidReason,
        disputeId,
        ledgerEntryId,
      },
      at: now,
    });
    voided.push(invoice.id);
  }
  return voided;
}
