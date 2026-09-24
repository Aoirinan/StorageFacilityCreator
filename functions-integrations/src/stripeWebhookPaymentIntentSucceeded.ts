import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { isPublicLinkPaymentIntent } from '@sfc/functions-shared';
import { isAlreadyExistsError } from './firestoreErrors';

/**
 * Handle successful payment intent (for tenant payments via Stripe Connect / embedded).
 *
 * This is the one place a public payment-link payment is recorded: the link's
 * Checkout Session puts facilityId/tenantId on the PaymentIntent
 * (`payment_intent_data.metadata`, sfcKind 'tenant_link') for exactly this.
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
    const markCompleted = () => {
      const now = admin.firestore.FieldValue.serverTimestamp();
      return { status: 'completed', paidAt: now, paidDate: now, updatedAt: now };
    };

    let paymentRecordId: string;
    if (!existingPayments.empty) {
      paymentRecordId = existingPayments.docs[0].id;
      await existingPayments.docs[0].ref.update(markCompleted());
    } else {
      // Create new payment record (embedded or Connect). Deterministic id and
      // create(): two deliveries of this event racing past the query above
      // (the processed-event check is not atomic) converge on one record
      // instead of each adding one.
      const paymentRef = paymentsRef.doc(`stripe_${paymentIntent.id}`);
      paymentRecordId = paymentRef.id;
      const now = admin.firestore.FieldValue.serverTimestamp();
      try {
        await paymentRef.create({
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
      } catch (error) {
        if (!isAlreadyExistsError(error)) throw error;
        await paymentRef.update(markCompleted());
      }
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

      await ledgerRef.set({
        tenantId: tenantId,
        facilityId: facilityId,
        type: 'payment',
        amount: -(paymentIntent.amount / 100), // Negative for payments
        description: `Payment via Stripe - ${paymentIntent.id}`,
        referenceId: paymentRecordId,
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
    // Swallowing marks the event processed and the credit is never retried.
    // Nothing else records a payment-link payment (no job writes it, and the
    // link completion deliberately does not), so let Stripe redeliver it.
    // Every write above is keyed on the PaymentIntent, so a retry converges.
    if (isPublicLinkPaymentIntent(paymentIntent)) {
      throw error;
    }
  }
}
