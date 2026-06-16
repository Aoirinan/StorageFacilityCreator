import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { authenticatePortalTenant, extractCallableClientIp, getPlatformPublishableKey, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * createTenantSetupIntentFromPortal — Portal (no Firebase Auth). Email + accessCode → SetupIntent for adding card.
 */
export const createTenantSetupIntentFromPortal = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const clientIp = extractCallableClientIp(context.rawRequest);

  const session = await authenticatePortalTenant(email, accessCode, clientIp);
  const tenantDoc = session.tenantDoc;
  const facilityId = session.facilityId;
  const tenantId = session.tenantId;
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const connectAccountId = facilityDoc.data()?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility yet.');
  }
  const stripe = getStripeClient();
  const account = await stripe.accounts.retrieve(connectAccountId);
  if (!account.charges_enabled) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility yet.');
  }
  const tenantData = tenantDoc.data() as Record<string, any>;
  let customerId = tenantData.stripeConnectedCustomerId as string | undefined;
  if (!customerId) {
    const customer = await stripe.customers.create({
      email: tenantData.email,
      name: tenantData.name,
      metadata: { facilityId, tenantId },
    }, { stripeAccount: connectAccountId });
    customerId = customer.id;
    await tenantDoc.ref.update({
      stripeConnectedCustomerId: customerId,
      'stripe.customerId': customerId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  const setupIntent = await stripe.setupIntents.create({
    customer: customerId,
    payment_method_types: ['card'],
    usage: 'off_session',
    metadata: { facilityId, tenantId, chargeType: 'tenant_autopay', source: 'portal' },
  }, { stripeAccount: connectAccountId });
  const publishableKey = getPlatformPublishableKey();
  return {
    clientSecret: setupIntent.client_secret,
    setupIntentId: setupIntent.id,
    publishableKey,
    connectedAccountId: connectAccountId,
  };
});
