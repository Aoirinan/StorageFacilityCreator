import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import type { StripeConnectState } from './stripeFacilityConnectTypes';
import { eventAccountMatchesFacility } from './connectedAccountGuard';

/**
 * Handle Stripe Connect account updates: updates the facility when its
 * connected account's status changes.
 *
 * The facility comes from the account's `metadata.facilityId`, which stays
 * on an account after the facility disconnects or reconnects to another one.
 * So an update from a facility's old account (a former owner's, still
 * connected to the platform) rewrote its Stripe status, and could mark a
 * disconnected facility ready to charge again. Only the account the facility
 * is connected to now counts. [connectedAccountId] is the event's `account`.
 */
export async function handleConnectAccountUpdated(
  account: Stripe.Account,
  connectedAccountId?: string,
  eventId?: string,
) {
  try {
    const facilityId = account.metadata?.facilityId;
    if (!facilityId) {
      functions.logger.warn('Connect account updated but no facilityId in metadata');
      return;
    }

    // An account's update is about that account: the event's account, when
    // set, must be the object's own id.
    if (connectedAccountId && connectedAccountId !== account.id) {
      functions.logger.error('Connect account update names a different account than it came from', {
        accountId: account.id,
        connectedAccountId,
      });
      return;
    }
    const accountMatches = await eventAccountMatchesFacility({
      facilityId,
      connectedAccountId: account.id,
      eventType: 'account.updated',
      objectId: account.id,
      eventId,
      // No money moves; logged and sent to Sentry only.
      record: false,
    });
    if (!accountMatches) return;

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
