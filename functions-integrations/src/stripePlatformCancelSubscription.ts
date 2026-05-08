import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow, getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

/**
 * Cancel subscription at period end (in-app, no Stripe portal required)
 */
export const cancelSubscription = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId } = data;
  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    const accountDoc = await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).get();
    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }
    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }
    const subscriptionId = accountData.stripeSubscriptionId as string | undefined;
    if (!subscriptionId) {
      throw new functions.https.HttpsError('failed-precondition', 'No active subscription to cancel');
    }
    const stripe = getStripeClient();
    await stripe.subscriptions.update(subscriptionId, { cancel_at_period_end: true });
    await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
      subscriptionCancelAtPeriodEnd: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Subscription set to cancel at period end for account ${accountId}`);
    return { success: true, message: 'Your subscription will cancel at the end of the current billing period.' };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) throw error;
    functions.logger.error('Error cancelling subscription', error);
    throw new functions.https.HttpsError('internal', `Failed to cancel: ${error.message}`);
  }
});
