import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

export const cancelFacilitySubscription = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }
    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }
    const subscriptionId = facilityData.stripePlatformSubscriptionId as string | undefined;
    if (!subscriptionId) {
      throw new functions.https.HttpsError('failed-precondition', 'No platform subscription found for this facility');
    }

    const stripe = getStripeClient();
    await stripe.subscriptions.update(subscriptionId, { cancel_at_period_end: true });
    await admin.firestore().collection('facilities').doc(facilityId).update({
      platformSubscriptionCancelAtPeriodEnd: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Facility ${facilityId} platform subscription set to cancel at period end`);
    return { success: true, message: 'Subscription will cancel at end of billing period.' };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) throw error;
    functions.logger.error('Error cancelling facility subscription', error);
    throw new functions.https.HttpsError('internal', `Failed to cancel: ${error.message}`);
  }
});
