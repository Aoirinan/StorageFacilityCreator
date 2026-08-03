import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Cancel the $25 website add-on at period end for one facility.
 */
export const cancelWebsiteSubscription = functions
  .runWith({ secrets: STRIPE_SECRETS })
  .https.onCall(async (data: { facilityId?: string }, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    const facilityId = String(data?.facilityId || '').trim();
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
      const subscriptionId = facilityData.stripeWebsiteSubscriptionId as string | undefined;
      if (!subscriptionId) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'No website subscription found for this facility',
        );
      }

      const stripe = getStripeClient();
      await stripe.subscriptions.update(subscriptionId, { cancel_at_period_end: true });
      await facilityRef.update({
        websiteSubscriptionCancelAtPeriodEnd: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info(`Facility ${facilityId} website subscription set to cancel at period end`);
      return { success: true, message: 'Website subscription will cancel at end of billing period.' };
    } catch (error: unknown) {
      if (error instanceof functions.https.HttpsError) throw error;
      const message = error instanceof Error ? error.message : String(error);
      functions.logger.error('Error cancelling website subscription', { facilityId, message });
      throw new functions.https.HttpsError('internal', `Failed to cancel: ${message}`);
    }
  });
