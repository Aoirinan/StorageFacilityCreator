import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { isStripeFeatureEnabled } from './stripeFacilityFeatureFlags';

/**
 * Create a Stripe Connect login link for facility owners to access their Stripe Dashboard
 * Feature-flagged: Requires connectEnabledGlobal OR facilityId in allowlist
 */
export const createStripeConnectLoginLink = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  // Feature flag check
  const connectEnabled = await isStripeFeatureEnabled('connect', facilityId);
  if (!connectEnabled) {
    throw new functions.https.HttpsError('failed-precondition', 'Stripe Connect is not enabled for this facility');
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

    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Stripe Connect account not created');
    }

    const stripe = getStripeClient();

    // Create login link for Stripe Dashboard access
    const loginLink = await stripe.accounts.createLoginLink(connectAccountId);

    return {
      url: loginLink.url,
    };
  } catch (error: any) {
    functions.logger.error('Error creating Stripe Connect login link', error);
    throw new functions.https.HttpsError('internal', `Failed to create login link: ${error.message}`);
  }
});
