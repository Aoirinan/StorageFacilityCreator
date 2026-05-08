import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { canAccessFacility, getPlatformPublishableKey, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';

/**
 * Create a one-time PaymentIntent on connected account for paying with a NEW card.
 * User enters card in Payment Element; payment is not saved to customer.
 * Returns clientSecret, publishableKey, connectedAccountId for embedded payment form.
 */
export const createOneTimePaymentIntentOnConnectedAccount = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const { facilityId, tenantId, amountCents } = data;
  if (!facilityId || !tenantId || amountCents == null || amountCents < 50) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, tenantId, and amountCents (min 50) are required');
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
  const hasAccess = await canAccessFacility(context.auth.uid, facilityId);
  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'Access denied');
  }
  const tenantDoc = await admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const stripe = getStripeClient();

  // Create payment doc first for webhook to update
  const paymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).collection('payments');
  const paymentDocRef = paymentsRef.doc();
  await paymentDocRef.set({
    facilityId,
    tenantId,
    type: 'one_time',
    amountCents,
    currency: 'usd',
    stripeObjectId: null,
    status: 'processing',
    chargeType: 'tenant_one_time_new_card',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    failureCode: null,
    failureMessage: null,
  });

  const paymentIntent = await stripe.paymentIntents.create({
    amount: amountCents,
    currency: 'usd',
    metadata: {
      facilityId,
      tenantId,
      paymentDocId: paymentDocRef.id,
      chargeType: 'tenant_one_time_new_card',
    },
    automatic_payment_methods: { enabled: true },
  }, {
    stripeAccount: connectAccountId,
    idempotencyKey: paymentDocRef.id,
  });

  await paymentDocRef.update({
    stripeObjectId: paymentIntent.id,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return {
    clientSecret: paymentIntent.client_secret,
    publishableKey: getPlatformPublishableKey(),
    connectedAccountId: connectAccountId,
  };
});
