import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
  writeAuditLog,
} from '@sfc/functions-shared';
import { refuseBillingForSuspendedAccount } from './stripePlatformSuspendedAccount';

/** Shown when an account billed by Stripe asks for the app trial. */
export const START_TRIAL_STRIPE_SUBSCRIPTION_MESSAGE =
  'This account already has a Stripe subscription, so an app trial cannot be added to it. ' +
  'Its free time and billing come from that subscription: see Subscription.';

/**
 * Why [account] cannot start the app trial, or null when it can.
 *
 * An account with a Stripe subscription id never gets the app trial on top: the app
 * trial writes `trialing` and a new `subscriptionTrialEnd`, which on such an account
 * would read as a card-backed free month and move its trial end away from Stripe's.
 */
export function startTrialRefusal(account: Record<string, unknown>): string | null {
  const subscriptionId = typeof account.stripeSubscriptionId === 'string' ? account.stripeSubscriptionId.trim() : '';
  if (subscriptionId) return START_TRIAL_STRIPE_SUBSCRIPTION_MESSAGE;
  const status = account.subscriptionStatus;
  if (status === 'active' || status === 'trialing') {
    return 'Account already has an active subscription or trial';
  }
  // One trial per account, ever. Expired trials are moved out of `trialing` by the
  // nightly sweep, so the status check above does not block a second grant on its own.
  if (account.subscriptionTrialEnd || account.platformTrialUsedAt) {
    return 'This account has already used its free trial. Choose a plan to continue.';
  }
  return null;
}

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
    // Suspending clears the trial end, so the one-trial check below let a
    // suspended account start a fresh one for after it is lifted.
    refuseBillingForSuspendedAccount(accountData);

    const refusal = startTrialRefusal(accountData);
    if (refusal) {
      throw new functions.https.HttpsError('failed-precondition', refusal);
    }

    const now = new Date();
    const trialEnd = new Date(now);
    trialEnd.setDate(trialEnd.getDate() + 30);

    await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
      subscriptionStatus: 'trialing',
      subscriptionTrialEnd: admin.firestore.Timestamp.fromDate(trialEnd),
      subscriptionCurrentPeriodStart: admin.firestore.Timestamp.fromDate(now),
      subscriptionCurrentPeriodEnd: admin.firestore.Timestamp.fromDate(trialEnd),
      // Permanent: checkout reads this so the owner never gets a second trial.
      platformTrialUsedAt: admin.firestore.FieldValue.serverTimestamp(),
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
