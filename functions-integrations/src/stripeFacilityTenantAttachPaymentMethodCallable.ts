import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { canAccessFacility, getStripeClient, rejectClientSuppliedStripeKeys } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isTenantAutopayAllowedForFacility } from './stripeFacilityFeatureFlags';
import { writeAutopayEvent } from './stripeAutopayEvents';

/**
 * Attach a payment method to a customer on a connected account after SetupIntent confirmation
 * Feature-flagged: Requires tenantAutopayEnabledGlobal OR facilityId in allowlist
 */
export const attachTenantPaymentMethod = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  if (!context.app) {
    functions.logger.warn('attachTenantPaymentMethod: App Check token missing – allowing for auth-only');
  }

  const { facilityId, tenantId, paymentMethodId, setupIntentId } = data;

  if (!facilityId || !tenantId || !paymentMethodId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility. Connect and complete Stripe onboarding first.');
  }

  try {
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

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

    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data();
    const stripe = getStripeClient();

    if (setupIntentId) {
      const setupIntent = await stripe.setupIntents.retrieve(setupIntentId, {
        stripeAccount: connectAccountId,
      });
      if (setupIntent.status !== 'succeeded') {
        throw new functions.https.HttpsError('failed-precondition', 'SetupIntent not succeeded');
      }
    }

    const customerId = tenantData?.stripeConnectedCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer on connected account');
    }

    const paymentMethod = await stripe.paymentMethods.retrieve(paymentMethodId, {
      stripeAccount: connectAccountId,
    });

    await stripe.paymentMethods.attach(paymentMethodId, {
      customer: customerId,
    }, {
      stripeAccount: connectAccountId,
    });

    await stripe.customers.update(customerId, {
      invoice_settings: { default_payment_method: paymentMethodId },
    }, { stripeAccount: connectAccountId });

    const card = paymentMethod.card;
    const displayInfo = {
      last4: card?.last4 || null,
      brand: card?.brand || null,
      expMonth: card?.exp_month || null,
      expYear: card?.exp_year || null,
    };

    const paymentMethodSummary = {
      brand: displayInfo.brand,
      last4: displayInfo.last4,
      expMonth: displayInfo.expMonth,
      expYear: displayInfo.expYear,
    };

    const tenantUpdate: Record<string, unknown> = {
      'stripe.customerId': customerId,
      'stripe.defaultPaymentMethodId': paymentMethodId,
      'stripe.paymentMethodSummary': paymentMethodSummary,
      stripeConnectedCustomerId: customerId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    await tenantDoc.ref.update(tenantUpdate);

    const paymentMethodRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('paymentMethods')
      .doc();

    await paymentMethodRef.set({
      tenantId,
      facilityId,
      type: 'creditCard',
      stripePaymentMethodId: paymentMethodId,
      stripeCustomerId: customerId,
      stripeConnectedAccountId: connectAccountId,
      last4: displayInfo.last4,
      brand: displayInfo.brand,
      expiryMonth: displayInfo.expMonth,
      expiryYear: displayInfo.expYear,
      isDefault: true,
      autopayEnabled: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: context.auth.uid,
      isActive: true,
    });

    functions.logger.info(`Payment method attached on connected account: ${paymentMethodId} for tenant ${tenantId}`);

    const tenantNameForEvent = (tenantData?.name as string) || 'Tenant';
    await writeAutopayEvent(facilityId, tenantId, tenantNameForEvent, 'CARD_ADDED', 'FACILITY', null);

    return {
      success: true,
      paymentMethodId: paymentMethodRef.id,
      displayInfo,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to attach payment method';
    functions.logger.error('Error attaching tenant payment method on connected account:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to attach payment method: ${safeError}`);
  }
});
