import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
  writeAuditLog,
} from '@sfc/functions-shared';

/**
 * Start a 30-day trial for an account
 */
export const startTrial = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.accountId,
    key: 'startTrial',
    limit: 10,
    windowSeconds: 600,
    userId: context.auth.uid,
  });

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

    const currentStatus = accountData.subscriptionStatus as string;
    if (currentStatus === 'active' || currentStatus === 'trialing') {
      throw new functions.https.HttpsError('failed-precondition', 'Account already has an active subscription or trial');
    }

    const now = new Date();
    const trialEnd = new Date(now);
    trialEnd.setDate(trialEnd.getDate() + 30);

    await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
      subscriptionStatus: 'trialing',
      subscriptionTrialEnd: admin.firestore.Timestamp.fromDate(trialEnd),
      subscriptionCurrentPeriodStart: admin.firestore.Timestamp.fromDate(now),
      subscriptionCurrentPeriodEnd: admin.firestore.Timestamp.fromDate(trialEnd),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    functions.logger.info(`30-day trial started for account ${accountId}`);

    const result = {
      success: true,
      trialEnd: trialEnd.toISOString(),
      message: '30-day trial started successfully',
    };
    await writeAuditLog(accountId, {
      action: 'trial_started',
      userId: context.auth.uid,
      trialEnd: trialEnd.toISOString(),
    });
    return result;
  } catch (error: any) {
    functions.logger.error('Error starting trial', error);

    let errorMessage: string;
    if (error instanceof functions.https.HttpsError) {
      throw error;
    } else if (error.message) {
      errorMessage = error.message;
    } else if (typeof error === 'string') {
      errorMessage = error;
    } else {
      errorMessage = JSON.stringify(error);
    }

    functions.logger.error(`Trial start error details: ${errorMessage}`, {
      accountId,
      userId: context.auth?.uid,
      errorStack: error.stack,
    });

    await writeAuditLog(data?.accountId, {
      action: 'trial_start_failed',
      userId: context.auth.uid,
      error: errorMessage,
    });
    throw new functions.https.HttpsError('internal', `Failed to start trial: ${errorMessage}`);
  }
});
