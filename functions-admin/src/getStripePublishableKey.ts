import * as functions from 'firebase-functions/v1';
import { getPlatformPublishableKey } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Get Stripe publishable key (platform key only; safe to expose to clients).
 * Uses Firebase secrets and validates TEST/LIVE consistency via shared Stripe helpers.
 */
export const getStripePublishableKey = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (_data, _context) => {
  try {
    const publishableKey = getPlatformPublishableKey();
    return { publishableKey };
  } catch (error: any) {
    functions.logger.error('Error getting Stripe publishable key:', { message: error?.message });
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', 'Stripe publishable key is not configured or key mode mismatch.');
  }
});
