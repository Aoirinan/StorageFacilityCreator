import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { isPublicLinkPaymentIntent, notifyIfDisputeOverpaid } from '@sfc/functions-shared';
import { isAlreadyExistsError } from './firestoreErrors';
import { eventAccountMatchesFacility } from './connectedAccountGuard';

/**
 * Payment statuses a success may set to completed: not yet paid, or a
 * failure the PaymentIntent has since recovered from. A payment already
 * completed, refunded, part-refunded or disputed is left as it is.
 */
const SUCCESS_MAY_OVERWRITE = new Set<unknown>([undefined, null, 'pending', 'processing', 'requires_payment_method', 'failed']);

export function successMayOverwrite(status: unknown): boolean {
  return SUCCESS_MAY_OVERWRITE.has(status);
}

/**
 * Handle successful payment intent (for tenant payments via Stripe Connect / embedded).
 *
 * This is the one place a public payment-link payment is recorded: the link's
 * Checkout Session puts facilityId/tenantId on the PaymentIntent
 * (`payment_intent_data.metadata`, sfcKind 'tenant_link') for exactly this.
 *
 * [connectedAccountId] is the event's `account`. A connected-account payment
 * is only credited when that account is the facility's own: the metadata that
 * names the facility is written by whoever created the PaymentIntent.
 */
export async function handlePaymentIntentSucceeded(
  paymentIntent: Stripe.PaymentIntent,
  connectedAccountId?: string,
  eventId?: string,
) {
  try {
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;
    const invoiceId = paymentIntent.metadata?.invoiceId;
    const paymentDocId = paymentIntent.metadata?.paymentDocId;
    // Set on a public link staff sent to collect a card dispute
    // (createPublicPaymentLink checked it is this tenant's open dispute).
    const disputeId = paymentIntent.metadata?.disputeId || null;

    if (!facilityId || !tenantId) {
      functions.logger.warn('Payment intent missing facilityId or tenantId metadata');
      return;
    }

    // Before any write: a PaymentIntent on another facility's account carrying
    // this facility's id must not credit this facility's tenant.
    const accountMatches = await eventAccountMatchesFacility({
      facilityId,
      connectedAccountId,
      eventType: 'payment_intent.succeeded',
      objectId: paymentIntent.id,
      eventId,
      tenantId,
      amount: paymentIntent.amount / 100,
    });
    if (!accountMatches) return;

    // Update tenant payments subcollection (embedded one-time payments)
    if (paymentDocId) {
      const tenantPaymentRef = admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .collection('payments')
        .doc(paymentDocId);
      await tenantPaymentRef.update({
        status: 'succeeded',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      const billingRef = admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .collection('billing')
        .doc('default');
      await billingRef.set(
        {
          lastPaymentStatus: 'succeeded',
          lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
          lastFailureCode: null,
          lastFailureMessage: null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }

    // Update facility-level payment record (for ledger/reconciliation).
    //
    // One transaction over the record already carrying this PaymentIntent
    // (externalPaymentId) and `stripe_{pi}`, the id this handler and the
    // failure handler both create: two deliveries, or a success racing its
    // own failure event, converge on one record. A record that is already
    // paid, refunded or disputed keeps its status: a resent success set a
    // refunded payment back to completed. One the failure handler wrote is
    // upgraded, as a PaymentIntent that failed and was then retried did go
    // through.
    const paymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('payments');
    const byPaymentIntent = paymentsRef.where('externalPaymentId', '==', paymentIntent.id).limit(1);
    const deterministicRef = paymentsRef.doc(`stripe_${paymentIntent.id}`);
    const paymentRecordId = await admin.firestore().runTransaction(async (tx) => {
      const existing = await tx.get(byPaymentIntent);
      const deterministic = await tx.get(deterministicRef);
      const current = existing.empty ? deterministic : existing.docs[0];
      const now = admin.firestore.FieldValue.serverTimestamp();
      if (current.exists) {
        if (successMayOverwrite(current.get('status'))) {
          tx.update(current.ref, { status: 'completed', paidAt: now, paidDate: now, updatedAt: now });
        }
        return current.ref.id;
      }
      tx.create(deterministicRef, {
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: paymentIntent.metadata?.contractId || '',
        amount: paymentIntent.amount / 100, // Convert from cents
        status: 'completed',
        method: 'stripe',
        externalPaymentId: paymentIntent.id,
        transactionId: paymentIntent.id,
        paidAt: now,
        paidDate: now,
        createdAt: now,
        updatedAt: now,
        createdBy: 'system@stripe-webhook',
        isActive: true,
      });
      return deterministicRef.id;
    });

    // If invoiceId provided, mark invoice as paid
    if (invoiceId) {
      const invoiceRef = admin.firestore().collection('facilities').doc(facilityId).collection('invoices').doc(invoiceId);

      await invoiceRef.update({
        status: 'paid',
        paidDate: admin.firestore.FieldValue.serverTimestamp(),
        balance: 0,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create ledger entry for payment (skip if chargeTenantOffSession already created it)
    const chargeType = paymentIntent.metadata?.chargeType;
    if (chargeType !== 'tenant_one_time_card_on_file') {
      // Deterministic id, keyed on the payment intent, so a charge that is also
      // recorded by its originating job (autopay does this) converges on one
      // document instead of being credited to the tenant twice. An allowlist of
      // chargeTypes was too easy to fall out of date: autopay never set one, so
      // every autopay charge was double-credited.
      const ledgerRef = admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .doc(`payment_${paymentIntent.id}`);

      const metadata: Record<string, unknown> = {
        paymentIntentId: paymentIntent.id,
        invoiceId: invoiceId || null,
        // Nets the payment against the dispute instead of counting it as
        // rent: autopay and the delinquency job read only the rest.
        ...(disputeId ? { disputeId } : {}),
      };
      try {
        await ledgerRef.create({
          tenantId: tenantId,
          facilityId: facilityId,
          type: 'payment',
          amount: -(paymentIntent.amount / 100), // Negative for payments
          description: disputeId
            ? `Card dispute payment via Stripe - ${paymentIntent.id}`
            : `Payment via Stripe - ${paymentIntent.id}`,
          referenceId: paymentRecordId,
          entryDate: admin.firestore.FieldValue.serverTimestamp(),
          status: 'posted',
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          createdBy: 'system@stripe-webhook',
          metadata,
        });
      } catch (error) {
        if (!isAlreadyExistsError(error)) throw error;
        // Written already: by autopay (same id), or by an earlier delivery of
        // this event (a resend, or a retry after the processed mark failed).
        // Its status is left alone: a set() here put a row staff had voided
        // back to 'posted', crediting the tenant again. Only what this event
        // adds is merged: the payment record link and the metadata.
        const existing = await ledgerRef.get();
        const existingMetadata = (existing.get('metadata') as Record<string, unknown> | undefined) ?? {};
        const update: Record<string, unknown> = { referenceId: paymentRecordId };
        for (const [key, value] of Object.entries(metadata)) {
          if (value !== null && existingMetadata[key] === undefined) update[`metadata.${key}`] = value;
        }
        await ledgerRef.update(update);
      }
    }

    // A dispute link paid after the dispute was won (or paid by hand, or
    // voided) is money the tenant is owed back. It is still booked: the card
    // was charged. Staff are told to refund it (the ledger counts it as a
    // credit until they do).
    if (disputeId) {
      await notifyIfDisputeOverpaid({
        db: admin.firestore(),
        facilityId,
        tenantId,
        disputeId,
        createdBy: 'system@stripe-webhook',
      });
    }

    functions.logger.info(`Payment intent succeeded: ${paymentIntent.id} for tenant ${tenantId}`);
  } catch (error: any) {
    functions.logger.error('Error handling payment intent succeeded:', error);
    // Swallowing marks the event processed and the credit is never retried.
    // Nothing else records a payment-link payment (no job writes it, and the
    // link completion deliberately does not), so let Stripe redeliver it.
    // Every write above is keyed on the PaymentIntent, so a retry converges.
    if (isPublicLinkPaymentIntent(paymentIntent)) {
      throw error;
    }
  }
}
