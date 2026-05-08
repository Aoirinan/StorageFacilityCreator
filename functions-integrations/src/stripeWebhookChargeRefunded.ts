import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';

export async function handleChargeRefunded(charge: Stripe.Charge) {
  try {
    const paymentIntentId = charge.payment_intent as string;
    if (!paymentIntentId) {
      functions.logger.warn('Charge refunded but no payment intent ID');
      return;
    }

    const stripe = getStripeClient();
    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);

    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;

    if (!facilityId) {
      functions.logger.warn('Charge refunded but missing facilityId metadata');
      return;
    }

    const paymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('payments');

    const existingPayments = await paymentsRef.where('externalPaymentId', '==', paymentIntentId).limit(1).get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        status: 'refunded',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const ledgerRef = admin.firestore().collection('facilities').doc(facilityId).collection('ledgers').doc();

    await ledgerRef.set({
      tenantId: tenantId || null,
      facilityId: facilityId,
      type: 'refund',
      amount: charge.amount_refunded / 100,
      description: `Refund for charge ${charge.id}`,
      referenceId: existingPayments.empty ? null : existingPayments.docs[0].id,
      entryDate: admin.firestore.FieldValue.serverTimestamp(),
      status: 'posted',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'system@stripe-webhook',
      metadata: {
        chargeId: charge.id,
        paymentIntentId: paymentIntentId,
      },
    });

    functions.logger.info(`Charge refunded: ${charge.id} for payment intent ${paymentIntentId}`);
  } catch (error: any) {
    functions.logger.error('Error handling charge refunded:', error);
  }
}
