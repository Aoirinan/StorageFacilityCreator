import * as functions from 'firebase-functions/v1';
import {
  getPlatformPublishableKey,
  getStripeClient,
} from '@sfc/functions-shared';
import * as stripeTenantBilling from './stripe/tenant_billing';
import { STRIPE_SECRETS } from './secrets';

/**
 * Create SetupIntent for saving card via Payment Element (embedded)
 * App Check is optional here so card-add works even if reCAPTCHA is blocked; auth is still required.
 */
export const createEmbeddedSetupIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (context.app) {
    // App Check token present - enforce as usual
  } else {
    functions.logger.warn('createEmbeddedSetupIntent: App Check token missing (reCAPTCHA may be blocked) - allowing for auth-only');
  }
  try {
    const stripe = getStripeClient();
    const result = await stripeTenantBilling.createSetupIntent(data, context, stripe);
    // Return platform publishable key (validated TEST/LIVE match) so frontend matches SetupIntent (avoids 401)
    const publishableKey = getPlatformPublishableKey();
    return { ...result, publishableKey };
  } catch (err: any) {
    if (err?.code && typeof err.code === 'string' && err.message) {
      throw err;
    }
    functions.logger.error('createEmbeddedSetupIntent error', { message: err?.message, stack: err?.stack });
    throw new functions.https.HttpsError(
      'unavailable',
      err?.message && !err.message.includes('STRIPE_SECRET') ? err.message : 'Payment service is temporarily unavailable. Please try again.',
    );
  }
});
