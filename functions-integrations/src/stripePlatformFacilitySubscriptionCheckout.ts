import * as functions from 'firebase-functions/v1';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { executeCreateFacilitySubscriptionCheckout } from './stripePlatformFacilitySubscriptionCheckoutLogic';

/**
 * Create Stripe Checkout for ONE facility's platform subscription ($75/mo).
 */
export const createFacilitySubscriptionCheckout = functions
  .runWith({ timeoutSeconds: 60, memory: '256MB', secrets: STRIPE_SECRETS })
  .https.onCall(async (data: any, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    const { accountId, facilityId, customerEmail, successUrl, cancelUrl } = data;
    if (!accountId || !facilityId || !customerEmail) {
      throw new functions.https.HttpsError('invalid-argument', 'accountId, facilityId, and customerEmail are required');
    }

    return executeCreateFacilitySubscriptionCheckout(
      { accountId, facilityId, customerEmail, successUrl, cancelUrl },
      context,
    );
  });
