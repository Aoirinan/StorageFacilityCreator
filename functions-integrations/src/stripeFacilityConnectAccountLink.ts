import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Create an account link for Stripe Connect onboarding.
 * If facility has no connectedAccountId, creates a Standard Connect account first, then returns onboarding URL.
 * Single entry point for "Connect Stripe" and "Finish onboarding".
 */
export const createStripeConnectAccountLink = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilityDoc = await facilityRef.get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const stripe = getStripeClient();
    let connectAccountId = facilityData.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      const account = await stripe.accounts.create({
        type: 'standard',
        country: 'US',
        email: (facilityData.email as string) || (context.auth.token?.email as string) || undefined,
        metadata: { facilityId, ownerUid: context.auth.uid },
      });
      connectAccountId = account.id;
      await facilityRef.update({
        stripeConnectAccountId: connectAccountId,
        stripeConnectOnboardingComplete: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info(`Created Stripe Connect account ${connectAccountId} for facility ${facilityId}`);
    }

    const baseUrl = 'https://www.storagefacilitycreator.com';
    const accountLink = await stripe.accountLinks.create({
      account: connectAccountId,
      refresh_url: `${baseUrl}/#/stripe-connect?facilityId=${facilityId}&refresh=1`,
      return_url: `${baseUrl}/#/stripe-connect?facilityId=${facilityId}`,
      type: 'account_onboarding',
    });

    return { url: accountLink.url };
  } catch (error: any) {
    if (error?.code && typeof error.code === 'string' && error.message) {
      throw error;
    }
    functions.logger.error('Error creating Stripe Connect account link', { message: error?.message });
    throw new functions.https.HttpsError('internal', `Failed to create account link: ${error?.message || 'Unknown error'}`);
  }
});
