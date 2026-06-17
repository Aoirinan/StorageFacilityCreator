import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import type { StripeConnectState } from './stripeFacilityConnectTypes';

/** Handle Stripe Connect account updates — updates facility when connected account status changes */
export async function handleConnectAccountUpdated(account: Stripe.Account) {
  try {
    const facilityId = account.metadata?.facilityId;
    if (!facilityId) {
      functions.logger.warn('Connect account updated but no facilityId in metadata');
      return;
    }

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

    const onboardingComplete = chargesEnabled && detailsSubmitted;

    await admin.firestore().collection('facilities').doc(facilityId).update({
      stripeStatus: {
        state,
        chargesEnabled,
        payoutsEnabled,
        detailsSubmitted,
        currentlyDue,
        pastDue,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      stripeConnectOnboardingComplete: onboardingComplete,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    functions.logger.info(
      `Updated Connect account status for facility ${facilityId}: state=${state}, onboardingComplete=${onboardingComplete}`,
    );
  } catch (error: any) {
    functions.logger.error('Error handling Connect account update', error);
  }
}
