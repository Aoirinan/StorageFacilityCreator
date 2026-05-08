import * as functions from 'firebase-functions/v1';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import * as stripeTenantBilling from './stripe/tenant_billing';
import { STRIPE_SECRETS } from './secrets';

/**
 * Create one-time PaymentIntent for embedded Payment Element
 */
export const createOneTimePaymentIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.createOneTimePaymentIntent(data, context, getStripeClient());
});
