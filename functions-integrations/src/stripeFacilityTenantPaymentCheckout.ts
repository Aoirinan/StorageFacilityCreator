import * as functions from 'firebase-functions/v1';
import { STRIPE_SECRETS } from './secrets';
import { executeCreateTenantPaymentCheckout } from './stripeFacilityTenantPaymentCheckoutLogic';

/**
 * Create a payment checkout session for tenant rent payment
 * Routes payment to the facility owner's Stripe Connect account (0% platform fee)
 */
export const createTenantPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }

  const { facilityId, tenantId, amount, description } = data;

  if (!facilityId || !tenantId || !amount) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, tenantId, and amount are required');
  }

  return executeCreateTenantPaymentCheckout({ facilityId, tenantId, amount, description });
});
