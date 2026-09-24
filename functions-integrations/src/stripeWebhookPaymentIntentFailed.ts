import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { eventAccountMatchesFacility } from './connectedAccountGuard';

/**
 * Handle failed payment intent (for tenant payments via Stripe Connect / embedded)
 *
 * [connectedAccountId] is the event's `account`. As with a success, the
 * facility named in metadata is whatever the PaymentIntent's creator wrote:
 * another account could mark a tenant's payment failed or add failed payment
 * rows to any facility. Only the facility's own account may.
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
        status: 'failed',
        failureCode,
        failureMessage,
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
          lastPaymentStatus: 'failed',
          lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
          lastFailureCode: failureCode,
          lastFailureMessage: failureMessage,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    }

    // Update facility-level payment record
    const paymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('payments');

    const existingPayments = await paymentsRef.where('externalPaymentId', '==', paymentIntent.id).limit(1).get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        status: 'failed',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        notes: failureMessage ? `Payment failed: ${failureMessage}` : undefined,
      });
    } else {
      // Create failed payment record
      await paymentsRef.add({
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: paymentIntent.metadata?.contractId || '',
        amount: paymentIntent.amount / 100,
        status: 'failed',
        method: 'stripe',
        externalPaymentId: paymentIntent.id,
        transactionId: paymentIntent.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: 'system@stripe-webhook',
        isActive: true,
        notes: failureMessage ? `Payment failed: ${failureMessage}` : 'Payment failed: Unknown error',
      });
    }

    functions.logger.info(`Payment intent failed: ${paymentIntent.id} for tenant ${tenantId}`);
  } catch (error: any) {
    functions.logger.error('Error handling payment intent failed:', error);
  }
}
