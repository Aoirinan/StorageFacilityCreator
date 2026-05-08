import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Attach a payment method to a customer after SetupIntent confirmation
 * Called after client confirms SetupIntent with Stripe Elements
 */
export const attachPaymentMethod = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, tenantId, paymentMethodId, setupIntentId } = data;

  if (!facilityId || !tenantId || !paymentMethodId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  try {
    // Verify user has access
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
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

    // Verify SetupIntent was successful
    if (setupIntentId) {
      const setupIntent = await stripe.setupIntents.retrieve(setupIntentId);
      if (setupIntent.status !== 'succeeded') {
        throw new functions.https.HttpsError('failed-precondition', 'SetupIntent not succeeded');
      }
    }

    // Get customer ID
    const customerId = tenantData?.stripeCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer');
    }

    // Retrieve payment method to get display info (safe metadata only)
    const paymentMethod = await stripe.paymentMethods.retrieve(paymentMethodId);

    // Attach payment method to customer
    await stripe.paymentMethods.attach(paymentMethodId, {
      customer: customerId,
    });

    // Extract safe display info
    const card = paymentMethod.card;
    const displayInfo = {
      last4: card?.last4 || null,
      brand: card?.brand || null,
      expMonth: card?.exp_month || null,
      expYear: card?.exp_year || null,
    };

    // Store payment method in Firestore (only safe metadata)
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
      last4: displayInfo.last4,
      brand: displayInfo.brand,
      expiryMonth: displayInfo.expMonth,
      expiryYear: displayInfo.expYear,
      isDefault: false,
      autopayEnabled: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: context.auth.uid,
      isActive: true,
    });

    functions.logger.info(`Payment method attached: ${paymentMethodId} for tenant ${tenantId}`);

    return {
      success: true,
      paymentMethodId: paymentMethodRef.id,
      displayInfo,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to attach payment method';
    functions.logger.error('Error attaching payment method:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to attach payment method: ${safeError}`);
  }
});
