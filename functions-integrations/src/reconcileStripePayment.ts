import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Reconcile a Stripe payment with Firestore records
 * Used by payment reconciliation service
 */
export const reconcileStripePayment = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, paymentIntentId } = data;

  if (!facilityId || !paymentIntentId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and paymentIntentId are required');
  }

  try {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    const stripe = getStripeClient();
    let paymentIntent: Stripe.PaymentIntent;

    try {
      paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
    } catch (stripeError: any) {
      if (stripeError.code === 'resource_missing') {
        return {
          found: false,
          error: 'Payment not found in Stripe',
        };
      }
      throw stripeError;
    }

    return {
      found: true,
      payment: {
        id: paymentIntent.id,
        amount: paymentIntent.amount,
        currency: paymentIntent.currency,
        status: paymentIntent.status,
        created: paymentIntent.created,
        metadata: paymentIntent.metadata,
        customer: paymentIntent.customer,
        description: paymentIntent.description,
      },
    };
  } catch (error: any) {
    functions.logger.error('Error reconciling Stripe payment:', error);
    throw new functions.https.HttpsError('internal', `Failed to reconcile payment: ${error.message}`);
  }
});
