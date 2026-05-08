import * as functions from 'firebase-functions/v1';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import * as stripeTenantBilling from './stripe/tenant_billing';
import { STRIPE_SECRETS } from './secrets';

/**
 * List saved payment methods for tenant
 */
export const listSavedPaymentMethods = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.listSavedPaymentMethods(data, context, getStripeClient());
});
