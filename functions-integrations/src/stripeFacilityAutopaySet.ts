import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { canAccessFacility, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { createAutopayNotificationAndEvent } from './stripeAutopayEvents';

/**
 * setTenantAutopay — Enable or disable autopay for a tenant. Creates notification + AutopayEvents log.
 * source: "TENANT" | "FACILITY" | "SYSTEM"
 */
export const setTenantAutopay = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  if (!context.app) {
    functions.logger.warn('setTenantAutopay: App Check token missing – allowing for auth-only');
  }
  rejectClientSuppliedStripeKeys(data || {});

  const payload = data && typeof data === 'object' ? data : {};
  const facilityId = typeof payload.facilityId === 'string' ? payload.facilityId.trim() : '';
  const tenantId = typeof payload.tenantId === 'string' ? payload.tenantId.trim() : '';
  let enabled: boolean;
  if (typeof payload.enabled === 'boolean') {
    enabled = payload.enabled;
  } else if (typeof payload.enabled === 'string') {
    enabled = payload.enabled === 'true' || payload.enabled === '1';
  } else if (payload.enabled === 1) {
    enabled = true;
  } else if (payload.enabled === 0) {
    enabled = false;
  } else {
    functions.logger.warn('setTenantAutopay: invalid payload', {
      hasFacilityId: !!facilityId,
      hasTenantId: !!tenantId,
      enabledType: typeof payload.enabled,
      uid: context.auth?.uid?.slice(0, 8),
    });
    throw new functions.https.HttpsError(
      'invalid-argument',
      'facilityId (string), tenantId (string), and enabled (boolean or "true"/"false") are required.',
    );
  }
  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'facilityId and tenantId must be non-empty strings.',
    );
  }
  const source = payload.source;
  const src = (source === 'TENANT' || source === 'FACILITY' || source === 'SYSTEM') ? source : 'SYSTEM';

  const hasAccess = await canAccessFacility(context.auth.uid, facilityId);
  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'Access denied');
  }

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

  const tenantRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
  const tenantDoc = await tenantRef.get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data()!;
  const tenantName = (tenantData.name as string) || 'Tenant';
  const stripe = tenantData.stripe as { defaultPaymentMethodId?: string } | undefined;
  const hasPm = !!(stripe?.defaultPaymentMethodId);

  const now = admin.firestore.FieldValue.serverTimestamp();

  if (enabled) {
    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Stripe is not connected for this facility. Connect Stripe in facility settings first.', { code: 'stripe_not_connected' });
    }
    if (!chargesEnabled) {
      throw new functions.https.HttpsError('failed-precondition', 'Stripe onboarding is not complete for this facility. Complete setup in facility settings.', { code: 'stripe_not_ready' });
    }
    if (!hasPm) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant must have a saved payment method before enabling autopay. Add a card first.', { code: 'missing_payment_method' });
    }
    await tenantRef.update({
      'autopay.requested': true,
      'autopay.enabled': true,
      'autopay.status': 'ON',
      'autopay.enabledAt': now,
      'autopay.disabledAt': null,
      'autopay.disabledReason': null,
      'autopay.updatedBy': src,
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(
      facilityId, tenantId, tenantName,
      'AUTOPAY_ENABLED', 'ENABLED', src,
      `${tenantName} autopay enabled.`,
      null,
    );
    return { enabled: true, status: 'ON' };
  } else {
    const disabledReason = src === 'TENANT' ? 'Tenant disabled in portal' : src === 'FACILITY' ? 'Disabled by facility' : 'System';
    await tenantRef.update({
      'autopay.requested': false,
      'autopay.enabled': false,
      'autopay.status': 'OFF',
      'autopay.disabledAt': now,
      'autopay.disabledReason': disabledReason,
      'autopay.updatedBy': src,
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(
      facilityId, tenantId, tenantName,
      'AUTOPAY_DISABLED', 'DISABLED', src,
      `${tenantName} turned off autopay.`,
      disabledReason,
    );
    return { enabled: false, status: 'OFF' };
  }
});
