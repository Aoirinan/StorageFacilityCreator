import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { eventAccountMatchesFacility } from './connectedAccountGuard';

/**
 * Payment statuses a failure may overwrite: nothing has been paid yet. An
 * allowlist, so a status added later is left alone until someone decides.
 *
 * Stripe sends events in any order and more than once, and a PaymentIntent
 * can fail and then succeed on a retry. A failure that arrived after the
 * success (or raced it) set a paid payment back to `failed`: the portal then
 * counted it as owed and offered Pay now for money already taken, and Process
 * in the app would mark it paid again and move paid-through with no money.
 * A refunded or disputed payment is past the point a failure can say
 * anything about.
 */
const FAILURE_MAY_OVERWRITE = new Set<unknown>([undefined, null, 'pending', 'processing', 'requires_payment_method', 'failed']);

/** Tenant payment-row statuses a failure may overwrite (tenants/{id}/payments, Stripe's spelling). */
const TENANT_ROW_FAILURE_MAY_OVERWRITE = new Set<unknown>([
  undefined,
  null,
  'pending',
  'processing',
  'requires_payment_method',
  'requires_action',
  'requires_confirmation',
  'failed',
]);

export function failureMayOverwrite(status: unknown): boolean {
  return FAILURE_MAY_OVERWRITE.has(status);
}

/**
 * Handle failed payment intent (for tenant payments via Stripe Connect / embedded)
 *
 * [connectedAccountId] is the event's `account`. As with a success, the
 * facility named in metadata is whatever the PaymentIntent's creator wrote:
 * another account could mark a tenant's payment failed or add failed payment
 * rows to any facility. Only the facility's own account may.
 *
 * The facility payment record is the one the success handler writes for the
 * same PaymentIntent: the record already carrying its id (externalPaymentId),
 * or else `payments/stripe_{pi}`. Read and written in one transaction, so a
 * redelivered failure, or a failure racing its own success, converges on one
 * record, and a failure never overwrites a payment that went through
 * ([failureMayOverwrite]). A failed record only says an attempt failed: the
 * portal does not count it as owed and the app does not let it be processed
 * (the rent it was for is still on the ledger), so an autopay decline
 * followed by a successful retry on a new PaymentIntent leaves nothing owed.
 */
export async function handlePaymentIntentFailed(
  paymentIntent: Stripe.PaymentIntent,
  connectedAccountId?: string,
  eventId?: string,
) {
  try {
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;
    const paymentDocId = paymentIntent.metadata?.paymentDocId;
    const lastError = paymentIntent.last_payment_error;
    const failureCode = lastError?.code || null;
    const failureMessage = lastError?.message || null;

    if (!facilityId || !tenantId) {
      functions.logger.warn('Payment intent missing facilityId or tenantId metadata');
      return;
    }

    // Before any write.
    const accountMatches = await eventAccountMatchesFacility({
      facilityId,
      connectedAccountId,
      eventType: 'payment_intent.payment_failed',
      objectId: paymentIntent.id,
      eventId,
      tenantId,
      amount: paymentIntent.amount / 100,
      // A failed payment moved no money: logged and sent to Sentry, not recorded.
      record: false,
    });
    if (!accountMatches) return;

    const db = admin.firestore();
    const facilityRef = db.collection('facilities').doc(facilityId);
    const tenantRef = facilityRef.collection('tenants').doc(tenantId);

    // Update tenant payments subcollection (embedded one-time payments)
    if (paymentDocId) {
      const tenantPaymentRef = tenantRef.collection('payments').doc(paymentDocId);
      const billingRef = tenantRef.collection('billing').doc('default');
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(tenantPaymentRef);
        // A row the success already marked (or that does not exist) is left alone.
        if (!snap.exists || !TENANT_ROW_FAILURE_MAY_OVERWRITE.has(snap.get('status'))) return;
        const now = admin.firestore.FieldValue.serverTimestamp();
        tx.update(tenantPaymentRef, { status: 'failed', failureCode, failureMessage, updatedAt: now });
        tx.set(
          billingRef,
          {
            lastPaymentStatus: 'failed',
            lastPaymentAt: now,
            lastFailureCode: failureCode,
            lastFailureMessage: failureMessage,
            updatedAt: now,
          },
          { merge: true },
        );
      });
    }

    // Update facility-level payment record
    const paymentsRef = facilityRef.collection('payments');
    const byPaymentIntent = paymentsRef.where('externalPaymentId', '==', paymentIntent.id).limit(1);
    const deterministicRef = paymentsRef.doc(`stripe_${paymentIntent.id}`);
    const notes = failureMessage ? `Payment failed: ${failureMessage}` : 'Payment failed: Unknown error';
    const outcome = await db.runTransaction(async (tx) => {
      const existing = await tx.get(byPaymentIntent);
      const deterministic = await tx.get(deterministicRef);
      const current = existing.empty ? deterministic : existing.docs[0];
      const now = admin.firestore.FieldValue.serverTimestamp();
      if (current.exists) {
        if (!failureMayOverwrite(current.get('status'))) return 'kept';
        tx.update(current.ref, { status: 'failed', updatedAt: now, notes });
        return 'updated';
      }
      // The id the success handler uses, so a success arriving later updates
      // this record instead of adding a second one.
      tx.create(deterministicRef, {
        tenantId,
        facilityId,
        contractId: paymentIntent.metadata?.contractId || '',
        amount: paymentIntent.amount / 100,
        status: 'failed',
        method: 'stripe',
        externalPaymentId: paymentIntent.id,
        transactionId: paymentIntent.id,
        createdAt: now,
        updatedAt: now,
        createdBy: 'system@stripe-webhook',
        isActive: true,
        notes,
      });
      return 'created';
    });

    functions.logger.info(`Payment intent failed: ${paymentIntent.id} for tenant ${tenantId}`, { outcome });
  } catch (error: any) {
    functions.logger.error('Error handling payment intent failed:', error);
  }
}
