import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getFacilityDataForUserOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Check Stripe Connect account status (legacy shape; prefer stripeConnectGetStatus for state machine)
 * Returns the current status of the connected account.
 * Any facility staff (owner, manager, employee, user_roles) may read status; only owners should start onboarding (enforced in UI / createAccount).
 */
export const getStripeConnectAccountStatus = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);

    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    if (!connectAccountId) {
      return {
        connected: false,
        onboardingComplete: false,
      };
    }

    const stripe = getStripeClient();

    // Retrieve account details
    const account = await stripe.accounts.retrieve(connectAccountId);

    // Check if onboarding is complete
    const onboardingComplete = account.details_submitted && account.charges_enabled && account.payouts_enabled;

    // Update facility with full Connect status (persist to Firestore)
    const connectStatus = onboardingComplete ? 'active' : (account.details_submitted ? 'pending' : 'needs_action');

    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .update({
        stripeConnectOnboardingComplete: onboardingComplete,
        stripeConnectStatus: connectStatus,
        chargesEnabled: account.charges_enabled,
        payoutsEnabled: account.payouts_enabled,
        stripeConnectUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    return {
      connected: true,
      accountId: connectAccountId,
      onboardingComplete: onboardingComplete,
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      detailsSubmitted: account.details_submitted,
      email: account.email,
      status: connectStatus,
    };
  } catch (error: any) {
    if (error?.code && typeof error.code === 'string' && error.message) {
      throw error;
    }
    functions.logger.error('Error getting Stripe Connect account status', error);
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error?.message || 'Unknown error'}`);
  }
});
