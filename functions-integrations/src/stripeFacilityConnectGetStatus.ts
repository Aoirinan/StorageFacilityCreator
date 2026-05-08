import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getFacilityDataForUserOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import type { StripeConnectState } from './stripeFacilityConnectTypes';

export const stripeConnectGetStatus = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const { facilityId } = data;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const facilityData = await getFacilityDataForUserOrThrow(context.auth!.uid, facilityId);
    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      const stripeStatusFirestore = {
        state: 'DISCONNECTED' as const,
        chargesEnabled: false,
        payoutsEnabled: false,
        detailsSubmitted: false,
        currentlyDue: [] as string[],
        pastDue: [] as string[],
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      await admin.firestore().collection('facilities').doc(facilityId).update({
        stripeStatus: stripeStatusFirestore,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return {
        state: 'DISCONNECTED',
        connectedAccountId: null,
        chargesEnabled: false,
        payoutsEnabled: false,
        detailsSubmitted: false,
        currentlyDue: [],
        pastDue: [],
        stripeStatus: { state: 'DISCONNECTED', chargesEnabled: false, payoutsEnabled: false, detailsSubmitted: false, currentlyDue: [], pastDue: [] },
      };
    }

    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    const chargesEnabled = !!account.charges_enabled;
    const payoutsEnabled = !!account.payouts_enabled;
    const detailsSubmitted = !!account.details_submitted;
    const currentlyDue = (account.requirements?.currently_due as string[] | undefined) || [];
    const pastDue = (account.requirements?.past_due as string[] | undefined) || [];
    const hasRequirementsDue = currentlyDue.length > 0 || pastDue.length > 0;

    let state: StripeConnectState;
    if (hasRequirementsDue) {
      state = 'ACTION_REQUIRED';
    } else if (chargesEnabled) {
      state = 'ENABLED';
    } else {
      state = 'ONBOARDING_INCOMPLETE';
    }

    const stripeStatusFirestore = {
      state,
      chargesEnabled,
      payoutsEnabled,
      detailsSubmitted,
      currentlyDue,
      pastDue,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await admin.firestore().collection('facilities').doc(facilityId).update({
      stripeStatus: stripeStatusFirestore,
      stripeConnectOnboardingComplete: chargesEnabled && detailsSubmitted,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const stripeStatusResponse = { state, chargesEnabled, payoutsEnabled, detailsSubmitted, currentlyDue, pastDue };
    return {
      state,
      connectedAccountId: connectAccountId,
      chargesEnabled,
      payoutsEnabled,
      detailsSubmitted,
      currentlyDue,
      pastDue,
      stripeStatus: stripeStatusResponse,
    };
  } catch (error: any) {
    if (error?.code && typeof error.code === 'string' && error.message) {
      throw error;
    }
    functions.logger.error('Error in stripeConnectGetStatus', { message: error?.message });
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error?.message || 'Unknown error'}`);
  }
});
