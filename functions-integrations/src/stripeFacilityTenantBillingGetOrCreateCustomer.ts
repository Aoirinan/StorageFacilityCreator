import * as functions from 'firebase-functions/v1';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import * as stripeTenantBilling from './stripe/tenant_billing';
import { STRIPE_SECRETS } from './secrets';

/**
 * Get or create Stripe Customer for tenant (embedded payments)
 */
export const getOrCreateStripeCustomer = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.getOrCreateStripeCustomer(data, context, getStripeClient());
});
