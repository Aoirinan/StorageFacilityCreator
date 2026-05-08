import * as functions from 'firebase-functions/v1';
import { getFacilityDataForUserOrThrow, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';

/**
 * Staff POS: process payment on a specific Stripe Terminal reader.
 * Creates a card_present PaymentIntent on connected account and triggers reader processing.
 */
export const processPosTerminalPayment = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }

  const { facilityId, amountCents, readerId, tenantId } = data || {};
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }
  if (!readerId || typeof readerId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'readerId is required');
  }
  if (amountCents == null || typeof amountCents !== 'number' || amountCents < 50) {
    throw new functions.https.HttpsError('invalid-argument', 'amountCents (min 50) is required');
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
    chargeType: 'pos_terminal',
    staffUid: context.auth.uid,
    readerId,
  };
  if (tenantId && typeof tenantId === 'string' && tenantId.length > 0) {
    metadata.tenantId = tenantId;
  }

  const paymentIntent = await stripe.paymentIntents.create(
    {
      amount: Math.round(amountCents),
      currency: 'usd',
      payment_method_types: ['card_present'],
      capture_method: 'automatic',
      description: 'Retail / POS purchase (Terminal reader)',
      metadata,
    },
    {
      stripeAccount: connectAccountId,
    },
  );

  await stripe.terminal.readers.processPaymentIntent(
    readerId,
    {
      payment_intent: paymentIntent.id,
    },
    {
      stripeAccount: connectAccountId,
    },
  );

  return {
    paymentIntentId: paymentIntent.id,
    status: paymentIntent.status,
    connectedAccountId: connectAccountId,
  };
});
