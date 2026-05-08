import * as functions from 'firebase-functions/v1';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import * as stripeTenantBilling from './stripe/tenant_billing';
import { STRIPE_SECRETS } from './secrets';

/**
 * Detach payment method from tenant
 */
export const detachPaymentMethod = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.detachPaymentMethod(data, context, getStripeClient());
});
