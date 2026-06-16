import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { authenticatePortalTenant, extractCallableClientIp, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { createAutopayNotificationAndEvent } from './stripeAutopayEvents';

/**
 * setTenantAutopayFromPortal — For tenant portal (no Firebase Auth). Uses email + accessCode to identify tenant.
 */
export const setTenantAutopayFromPortal = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const enabled = data.enabled === true;
  const clientIp = extractCallableClientIp(context.rawRequest);

  const session = await authenticatePortalTenant(email, accessCode, clientIp);
  const tenantDoc = session.tenantDoc;
  const facilityId = session.facilityId;
  const tenantId = session.tenantId;
  const tenantData = session.tenantData as Record<string, any>;
  const tenantName = tenantData.name || 'Tenant';
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data()!;
  const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
  let chargesEnabled = false;
  if (connectAccountId) {
    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    chargesEnabled = !!account.charges_enabled;
  }
  const stripe = tenantData.stripe as { defaultPaymentMethodId?: string } | undefined;
  const hasPm = !!(stripe?.defaultPaymentMethodId);
  const tenantRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
  const now = admin.firestore.FieldValue.serverTimestamp();

  if (enabled) {
    if (!chargesEnabled || !connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility yet. The facility must complete Stripe setup first.');
    }
    if (!hasPm) {
      throw new functions.https.HttpsError('failed-precondition', 'Add a payment method first. Use "Add card" to save your card, then turn on autopay.');
    }
    await tenantRef.update({
      'autopay.requested': true,
      'autopay.enabled': true,
      'autopay.status': 'ON',
      'autopay.enabledAt': now,
      'autopay.disabledAt': null,
      'autopay.disabledReason': null,
      'autopay.updatedBy': 'TENANT',
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(facilityId, tenantId, tenantName, 'AUTOPAY_ENABLED', 'ENABLED', 'TENANT', `${tenantName} enabled autopay from portal.`, null);
    return { enabled: true, status: 'ON' };
  } else {
    const disabledReason = 'Tenant disabled in portal';
    await tenantRef.update({
      'autopay.requested': false,
      'autopay.enabled': false,
      'autopay.status': 'OFF',
      'autopay.disabledAt': now,
      'autopay.disabledReason': disabledReason,
      'autopay.updatedBy': 'TENANT',
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(facilityId, tenantId, tenantName, 'AUTOPAY_DISABLED', 'DISABLED', 'TENANT', `${tenantName} turned off autopay.`, disabledReason);
    return { enabled: false, status: 'OFF' };
  }
});
