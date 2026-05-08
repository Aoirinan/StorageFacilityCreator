import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import {
  type CheckoutSessionRequest,
  executeCreateOneTimeCheckoutSession,
} from './stripePlatformOneTimeCheckoutLogic';

/**
 * Example: create a Stripe Checkout session for one-time payments
 */
export const createCheckoutSession = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: CheckoutSessionRequest, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const {
    amount,
    currency = 'usd',
    successUrl,
    cancelUrl,
    description = 'Storage Facility Payment',
    customerEmail,
  } = data;

  if (!amount || amount <= 0 || !successUrl || !cancelUrl) {
    throw new functions.https.HttpsError('invalid-argument', 'amount, successUrl, and cancelUrl are required');
  }

  return executeCreateOneTimeCheckoutSession({
    amount,
    currency,
    successUrl,
    cancelUrl,
    description,
    customerEmail,
  });
});
