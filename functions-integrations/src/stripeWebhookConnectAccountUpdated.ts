import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';

/** Handle Stripe Connect account updates — updates facility when connected account status changes */
export async function handleConnectAccountUpdated(account: Stripe.Account) {
  try {
    const facilityId = account.metadata?.facilityId;
    if (!facilityId) {
      functions.logger.warn('Connect account updated but no facilityId in metadata');
      return;
    }

    const onboardingComplete = account.details_submitted && account.charges_enabled && account.payouts_enabled;

    await admin.firestore().collection('facilities').doc(facilityId).update({
      stripeConnectOnboardingComplete: onboardingComplete,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    functions.logger.info(
      `Updated Connect account status for facility ${facilityId}: onboardingComplete=${onboardingComplete}`,
    );
  } catch (error: any) {
    functions.logger.error('Error handling Connect account update', error);
  }
}
