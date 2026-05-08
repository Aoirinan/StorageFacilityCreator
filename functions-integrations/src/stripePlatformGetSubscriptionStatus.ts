import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enforceAppCheckOrThrow } from '@sfc/functions-shared';

/**
 * Get subscription status for an account
 */
export const getSubscriptionStatus = functions.https.onCall(async (data: any, context) => {
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

    return {
      subscriptionStatus: accountData.subscriptionStatus,
      stripeSubscriptionId: accountData.stripeSubscriptionId,
      stripeCustomerId: accountData.stripeCustomerId,
      currentPeriodEnd: accountData.subscriptionCurrentPeriodEnd,
      cancelAtPeriodEnd: accountData.subscriptionCancelAtPeriodEnd,
    };
  } catch (error: any) {
    functions.logger.error('Error getting subscription status', error);
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error.message}`);
  }
});
