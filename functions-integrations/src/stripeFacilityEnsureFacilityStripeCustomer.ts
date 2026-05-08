import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  enforceAppCheckOrThrow,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Create or get Stripe Customer for a facility (for SaaS billing)
 */
export const ensureFacilityStripeCustomer = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId');
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
    const ownerUid = facilityData?.ownerUid;

    if (ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    // Check if customer already exists
    let customerId = facilityData?.stripeCustomerId as string | undefined;

    if (customerId) {
      // Verify customer still exists in Stripe
      const stripe = getStripeClient();
      try {
        await stripe.customers.retrieve(customerId);
        return { customerId, created: false };
      } catch {
        // Customer doesn't exist, create new one
        customerId = undefined;
      }
    }

    if (!customerId) {
      // Get owner email from auth
      const ownerDoc = await admin.firestore()
        .collection('users')
        .doc(ownerUid)
        .get();

      const ownerData = ownerDoc.data();
      const stripe = getStripeClient();

      const customer = await stripe.customers.create({
        email: ownerData?.email as string | undefined,
        name: ownerData?.displayName as string | undefined,
        metadata: {
          facilityId,
          ownerUid,
        },
      });

      customerId = customer.id;

      // Store customer ID in facility document
      await facilityDoc.ref.update({
        stripeCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      functions.logger.info(`Stripe customer created: ${customerId} for facility ${facilityId}`);
    }

    return { customerId, created: !facilityData?.stripeCustomerId };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to ensure Stripe customer';
    functions.logger.error('Error ensuring Stripe customer:', {
      facilityId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to ensure Stripe customer: ${safeError}`);
  }
});
