import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { canAccessFacility, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';
import { writeAutopayEvent } from './stripeAutopayEvents';

/**
 * attachTenantPaymentMethodFromRedirect — When Stripe Link (or 3DS) redirects for verification,
 * the Payment Element iframe never gets the result. This function handles the redirect return:
 * retrieves the SetupIntent, gets the payment_method, and attaches it to the tenant.
 */
export const attachTenantPaymentMethodFromRedirect = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const { setupIntentId, facilityId, tenantId } = data;
  if (!setupIntentId || !facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'setupIntentId, facilityId, and tenantId are required');
  }
  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility.');
  }
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data();
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }
  const hasAccess = await canAccessFacility(context.auth!.uid, facilityId);
  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
  }
  const tenantDoc = await admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data();
  const stripe = getStripeClient();
  const setupIntent = await stripe.setupIntents.retrieve(setupIntentId, { stripeAccount: connectAccountId });
  if (setupIntent.status !== 'succeeded') {
    throw new functions.https.HttpsError('failed-precondition', `SetupIntent not succeeded (status: ${setupIntent.status})`);
  }
  const paymentMethodId = typeof setupIntent.payment_method === 'string' ? setupIntent.payment_method : setupIntent.payment_method?.id;
  if (!paymentMethodId) {
    throw new functions.https.HttpsError('failed-precondition', 'SetupIntent has no payment method');
  }
  const customerId = tenantData?.stripeConnectedCustomerId as string | undefined;
  if (!customerId) {
    throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer');
  }
  const paymentMethod = await stripe.paymentMethods.retrieve(paymentMethodId, { stripeAccount: connectAccountId });
  await stripe.paymentMethods.attach(paymentMethodId, { customer: customerId }, { stripeAccount: connectAccountId });
  await stripe.customers.update(customerId, {
    invoice_settings: { default_payment_method: paymentMethodId },
  }, { stripeAccount: connectAccountId });
  const card = paymentMethod.card;
  const displayInfo = { last4: card?.last4, brand: card?.brand, expMonth: card?.exp_month, expYear: card?.exp_year };
  const paymentMethodSummary = { last4: displayInfo.last4, brand: displayInfo.brand, expMonth: displayInfo.expMonth, expYear: displayInfo.expYear };
  await tenantDoc.ref.update({
    'stripe.customerId': customerId,
    'stripe.defaultPaymentMethodId': paymentMethodId,
    'stripe.paymentMethodSummary': paymentMethodSummary,
    stripeConnectedCustomerId: customerId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  const paymentMethodRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).collection('paymentMethods').doc();
  await paymentMethodRef.set({
    tenantId, facilityId, type: 'creditCard',
    stripePaymentMethodId: paymentMethodId, stripeCustomerId: customerId, stripeConnectedAccountId: connectAccountId,
    last4: displayInfo.last4, brand: displayInfo.brand, expiryMonth: displayInfo.expMonth, expiryYear: displayInfo.expYear,
    isDefault: true, autopayEnabled: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdBy: context.auth.uid, isActive: true,
  });
  const tenantNameForEvent = (tenantData?.name as string) || 'Tenant';
  await writeAutopayEvent(facilityId, tenantId, tenantNameForEvent, 'CARD_ADDED', 'FACILITY', null);
  functions.logger.info(`Payment method attached from redirect: ${paymentMethodId} for tenant ${tenantId}`);
  return { success: true, paymentMethodId: paymentMethodRef.id };
});
