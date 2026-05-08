import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_CONNECT_CLIENT_ID, STRIPE_SECRETS_WITH_CONNECT } from './secrets';
import { isStripeFeatureEnabled } from './stripeFacilityFeatureFlags';

/**
 * Create a Stripe Connect account for a facility
 * This creates a Standard Connect account that facility owners will complete onboarding for
 * Feature-flagged: Requires connectEnabledGlobal OR facilityId in allowlist
 */
export const createStripeConnectAccount = functions.runWith({ secrets: STRIPE_SECRETS_WITH_CONNECT }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  // Feature flag check (additive - does not break existing behavior if flag is OFF)
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

    // If account already exists, return it so the client can proceed to get an onboarding/link URL (e.g. "Reconnect")
    const existingAccountId = facilityData.stripeConnectAccountId as string | undefined;
    if (existingAccountId) {
      functions.logger.info(`Stripe Connect account already exists for facility ${facilityId}, returning existing ID`);
      return { accountId: existingAccountId };
    }

    const stripe = getStripeClient();

    // Connect client id (`ca_…`) from Secret Manager (optional; omit secret or use placeholder if unused)
    const clientId = STRIPE_CONNECT_CLIENT_ID.value().trim() || undefined;
    if (clientId) {
      functions.logger.info(`Using Stripe Connect Client ID for facility ${facilityId}`);
    }

    // Create a Standard Connect account
    const account = await stripe.accounts.create({
      type: 'standard',
      country: 'US', // Default to US, can be made configurable
      email: facilityData.email || context.auth.token.email,
      metadata: {
        facilityId: facilityId,
        ownerUid: context.auth.uid,
      },
    });

    // Store the account ID on the facility
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .update({
        stripeConnectAccountId: account.id,
        stripeConnectOnboardingComplete: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Created Stripe Connect account ${account.id} for facility ${facilityId}`);

    return {
      accountId: account.id,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error creating Stripe Connect account', error);
    throw new functions.https.HttpsError('internal', error?.message ? `Failed to create account: ${error.message}` : 'An internal error occurred. Please try again.');
  }
});
