import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Create a SetupIntent for saving a payment method for autopay
 * PCI-safe: Client only receives client_secret, never card data
 */
export const createSetupIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, tenantId } = data;

  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters: facilityId, tenantId');
  }

  try {
    // Verify user has access to this facility
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

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    // Verify tenant exists
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

    // Get or create Stripe Customer for tenant
    let customerId = tenantData?.stripeCustomerId as string | undefined;

    if (!customerId) {
      // Create Stripe Customer
      const customer = await stripe.customers.create({
        email: tenantData?.email as string | undefined,
        name: tenantData?.name as string | undefined,
        metadata: {
          facilityId,
          tenantId,
        },
      });
      customerId = customer.id;

      // Store customer ID in tenant document
      await tenantDoc.ref.update({
        stripeCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create SetupIntent
    const setupIntent = await stripe.setupIntents.create({
      customer: customerId,
      payment_method_types: ['card'],
      usage: 'off_session', // For autopay
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
      },
    });

    // Log (without sensitive data)
    functions.logger.info(`SetupIntent created: ${setupIntent.id} for tenant ${tenantId}`);

    return {
      clientSecret: setupIntent.client_secret,
      setupIntentId: setupIntent.id,
    };
  } catch (error: any) {
    // Scrub error messages to avoid leaking sensitive info
    const safeError = error?.message || 'Failed to create setup intent';
    functions.logger.error('Error creating SetupIntent:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to create setup intent: ${safeError}`);
  }
});
