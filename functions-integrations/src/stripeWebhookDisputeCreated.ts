import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';

export async function handleDisputeCreated(dispute: Stripe.Dispute) {
  try {
    const chargeId = dispute.charge as string;
    if (!chargeId) {
      functions.logger.warn('Dispute created but no charge ID');
      return;
    }

    const stripe = getStripeClient();
    const charge = await stripe.charges.retrieve(chargeId);
    const paymentIntentId = charge.payment_intent as string;

    if (!paymentIntentId) {
      functions.logger.warn('Dispute created but no payment intent ID');
      return;
    }

    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;

    if (!facilityId) {
      functions.logger.warn('Dispute created but missing facilityId metadata');
      return;
    }

    const paymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('payments');

    const existingPayments = await paymentsRef.where('externalPaymentId', '==', paymentIntentId).limit(1).get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        status: 'disputed',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        notes: `Dispute created: ${dispute.reason || 'Unknown reason'}`,
      });
    }

    const ledgerRef = admin.firestore().collection('facilities').doc(facilityId).collection('ledgers').doc();

    await ledgerRef.set({
      tenantId: tenantId || null,
      facilityId: facilityId,
      type: 'dispute',
      amount: dispute.amount / 100,
      description: `Dispute created: ${dispute.reason || 'Unknown reason'}`,
      referenceId: existingPayments.empty ? null : existingPayments.docs[0].id,
      entryDate: admin.firestore.FieldValue.serverTimestamp(),
      status: 'posted',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'system@stripe-webhook',
      metadata: {
        disputeId: dispute.id,
        chargeId: chargeId,
        paymentIntentId: paymentIntentId,
        reason: dispute.reason || null,
      },
    });

    functions.logger.info(`Dispute created: ${dispute.id} for charge ${chargeId}`);
  } catch (error: any) {
    functions.logger.error('Error handling dispute created:', error);
  }
}
