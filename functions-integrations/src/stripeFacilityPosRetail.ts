import * as functions from 'firebase-functions/v1';
import { getFacilityDataForUserOrThrow, getPlatformPublishableKey, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';

/**
 * Staff POS: PaymentIntent for retail card sales on the facility's connected account.
 * Card data is collected only in Stripe.js (Payment Element), not in Flutter.
 */
export const createPosRetailPaymentIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const { facilityId, amountCents, tenantId } = data;
  if (!facilityId || amountCents == null || typeof amountCents !== 'number' || amountCents < 50) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and amountCents (min 50) are required');
  }
  const paymentsAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!paymentsAllowed) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Card payments require Stripe Connect with charges enabled. Complete Connect onboarding in Payments settings.',
    );
  }
  const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }
  const stripe = getStripeClient();
  const metadata: Record<string, string> = {
    facilityId,
    chargeType: 'pos_retail',
    staffUid: context.auth.uid,
  };
  if (tenantId && typeof tenantId === 'string' && tenantId.length > 0) {
    metadata.tenantId = tenantId;
  }
  const paymentIntent = await stripe.paymentIntents.create({
    amount: Math.round(amountCents),
    currency: 'usd',
    automatic_payment_methods: { enabled: true },
    description: 'Retail / POS purchase',
    metadata,
  }, {
    stripeAccount: connectAccountId,
  });
  return {
    clientSecret: paymentIntent.client_secret,
    publishableKey: getPlatformPublishableKey(),
    connectedAccountId: connectAccountId,
  };
});
