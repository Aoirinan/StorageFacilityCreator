import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';

/**
 * Handle successful payment intent (for tenant payments via Stripe Connect / embedded)
 */
export async function handlePaymentIntentSucceeded(paymentIntent: Stripe.PaymentIntent) {
  try {
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;
    const invoiceId = paymentIntent.metadata?.invoiceId;
    const paymentDocId = paymentIntent.metadata?.paymentDocId;

    if (!facilityId || !tenantId) {
      functions.logger.warn('Payment intent missing facilityId or tenantId metadata');
      return;
    }

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

    // Update facility-level payment record (for ledger/reconciliation)
    const paymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('payments');

    const existingPayments = await paymentsRef.where('externalPaymentId', '==', paymentIntent.id).limit(1).get();

    if (!existingPayments.empty) {
      const now = admin.firestore.FieldValue.serverTimestamp();
      await existingPayments.docs[0].ref.update({
        status: 'completed',
        paidAt: now,
        paidDate: now,
        updatedAt: now,
      });
    } else {
      // Create new payment record (embedded or Connect)
      const now = admin.firestore.FieldValue.serverTimestamp();
      await paymentsRef.add({
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
    }

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
      const ledgerRef = admin.firestore().collection('facilities').doc(facilityId).collection('ledgers').doc();

      await ledgerRef.set({
        tenantId: tenantId,
        facilityId: facilityId,
        type: 'payment',
        amount: -(paymentIntent.amount / 100), // Negative for payments
        description: `Payment via Stripe - ${paymentIntent.id}`,
        referenceId: existingPayments.empty ? null : existingPayments.docs[0].id,
        entryDate: admin.firestore.FieldValue.serverTimestamp(),
        status: 'posted',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: 'system@stripe-webhook',
        metadata: {
          paymentIntentId: paymentIntent.id,
          invoiceId: invoiceId || null,
        },
      });
    }

    functions.logger.info(`Payment intent succeeded: ${paymentIntent.id} for tenant ${tenantId}`);
  } catch (error: any) {
    functions.logger.error('Error handling payment intent succeeded:', error);
  }
}
