import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { resolvePortalTenantSession, extractCallableClientIp, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { writeAutopayEvent } from './stripeAutopayEvents';

/**
 * attachTenantPaymentMethodFromPortal — Portal (no Firebase Auth). Email + accessCode + paymentMethodId → attach PM.
 */
export const attachTenantPaymentMethodFromPortal = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const paymentMethodId = data.paymentMethodId as string;
  const setupIntentId = data.setupIntentId as string | undefined;
  const requestedTenantId = (data.tenantId || '').toString().trim();
  const clientIp = extractCallableClientIp(context.rawRequest);

  if (!paymentMethodId) {
    throw new functions.https.HttpsError('invalid-argument', 'Email, access code, and paymentMethodId are required');
  }

  const session = await resolvePortalTenantSession(
    email,
    accessCode,
    clientIp,
    requestedTenantId || undefined,
  );
  const tenantDoc = session.tenantDoc;
  const facilityId = session.facilityId;
  const tenantId = session.tenantId;
  const tenantData = session.tenantData as Record<string, any>;
  const connectAccountId = (await admin.firestore().collection('facilities').doc(facilityId).get()).data()?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }
  const customerId = tenantData.stripeConnectedCustomerId as string | undefined;
  if (!customerId) {
    throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer');
  }
  const stripeClient = getStripeClient();
  if (setupIntentId) {
    const si = await stripeClient.setupIntents.retrieve(setupIntentId, { stripeAccount: connectAccountId });
    if (si.status !== 'succeeded') {
      throw new functions.https.HttpsError('failed-precondition', 'SetupIntent not succeeded');
    }
  }
  const paymentMethod = await stripeClient.paymentMethods.retrieve(paymentMethodId, { stripeAccount: connectAccountId });
  await stripeClient.paymentMethods.attach(paymentMethodId, { customer: customerId }, { stripeAccount: connectAccountId });
  await stripeClient.customers.update(customerId, { invoice_settings: { default_payment_method: paymentMethodId } }, { stripeAccount: connectAccountId });
  const card = paymentMethod.card;
  const paymentMethodSummary = { brand: card?.brand ?? null, last4: card?.last4 ?? null, expMonth: card?.exp_month ?? null, expYear: card?.exp_year ?? null };
  await tenantDoc.ref.update({
    'stripe.customerId': customerId,
    'stripe.defaultPaymentMethodId': paymentMethodId,
    'stripe.paymentMethodSummary': paymentMethodSummary,
    stripeConnectedCustomerId: customerId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  const tenantName = (tenantData.name as string) || 'Tenant';
  await writeAutopayEvent(facilityId, tenantId, tenantName, 'CARD_ADDED', 'TENANT', null);
  return { success: true, displayInfo: paymentMethodSummary };
});
