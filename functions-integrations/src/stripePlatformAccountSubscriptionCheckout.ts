import * as functions from 'firebase-functions/v1';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { executeCreateSubscriptionCheckout } from './stripePlatformAccountSubscriptionCheckoutLogic';

/**
 * Create Stripe Checkout session for facility-based subscription
 * Pricing: $75/month base (first facility) + $75/month per additional facility
 */
export const createSubscriptionCheckout = functions
  .runWith({ timeoutSeconds: 60, memory: '256MB', secrets: STRIPE_SECRETS })
  .https.onCall(async (data: any, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    await enforceRateLimit({
      facilityId: data?.accountId,
      key: 'createSubscriptionCheckout',
      limit: 20,
      windowSeconds: 300,
      userId: context.auth.uid,
    });

    const { accountId, customerEmail, successUrl, cancelUrl } = data;

    if (!accountId || !customerEmail) {
      throw new functions.https.HttpsError('invalid-argument', 'accountId and customerEmail are required');
    }

    return executeCreateSubscriptionCheckout(
      { accountId, customerEmail, successUrl, cancelUrl },
      context,
    );
  });
