import * as functions from 'firebase-functions/v1';
import { getFacilityDataForUserOrThrow, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';

/**
 * Staff POS: check status of a Stripe Terminal payment intent.
 * Client uses this to poll until reader flow completes.
 */
export const getPosTerminalPaymentStatus = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }

  const { facilityId, paymentIntentId } = data || {};
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }
  if (!paymentIntentId || typeof paymentIntentId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'paymentIntentId is required');
  }

  const paymentsAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!paymentsAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility');
  }

  const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }

  const stripe = getStripeClient();
  const paymentIntent = await stripe.paymentIntents.retrieve(
    paymentIntentId,
    { expand: ['latest_charge'] },
    { stripeAccount: connectAccountId },
  );

  return {
    paymentIntentId: paymentIntent.id,
    status: paymentIntent.status,
    succeeded: paymentIntent.status === 'succeeded' || paymentIntent.status === 'requires_capture',
    amount: paymentIntent.amount,
    currency: paymentIntent.currency,
  };
});
