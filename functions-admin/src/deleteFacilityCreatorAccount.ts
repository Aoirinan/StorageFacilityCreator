import * as functions from 'firebase-functions/v1';
import type * as admin from 'firebase-admin';
import { isSuperAdmin } from '@sfc/functions-shared/auth/superAdmin';
import {
  anyCancelFailed,
  collectSubscriptionsToCancel,
  summarizeCancelOutcomes,
} from '@sfc/functions-shared/stripe/subscriptionCleanup';
import type { CancelOutcome, CancellableSubscription } from '@sfc/functions-shared/stripe/subscriptionCleanup';
import { adminDeleteDocumentTree } from './admin_delete_document_tree';
import { deleteFacilityKeyedRecords } from './facilityPurge';

export interface SuperAdminDeleteFacilityCreatorAccountData {
  accountId: string;
  ownerEmailConfirmation: string;
}

/** What the account delete reaches outside Firestore: Stripe and Auth in production, fakes in the emulator test. */
export type DeleteFacilityCreatorAccountDeps = {
  db: admin.firestore.Firestore;
  cancelSubscriptions: (subscriptions: CancellableSubscription[]) => Promise<CancelOutcome[]>;
  deleteAuthUser: (uid: string) => Promise<void>;
};

/**
 * superAdminDeleteFacilityCreatorAccount's body (superAdminCallables.ts),
 * with Stripe and Auth passed in so the emulator test can run it.
 */
export async function superAdminDeleteFacilityCreatorAccountHandler(
  data: SuperAdminDeleteFacilityCreatorAccountData,
  context: functions.https.CallableContext,
  deps: DeleteFacilityCreatorAccountDeps,
): Promise<{ success: true; facilitiesDeleted: number }> {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'Only super admins can delete facility creator accounts',
    );
  }

  const accountId = (data?.accountId || '').toString().trim();
  const confirmation = (data?.ownerEmailConfirmation || '').toString().trim().toLowerCase();
  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }
  if (!confirmation) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'ownerEmailConfirmation is required',
    );
  }

  const { db } = deps;
  const accountRef = db.collection('facilityCreatorAccounts').doc(accountId);
  const accountSnap = await accountRef.get();
  if (!accountSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Account not found');
  }

  const accountData = accountSnap.data() as Record<string, unknown>;
  const ownerUid = (accountData.ownerUid || '').toString().trim();
  const ownerEmail = (accountData.ownerEmail || '').toString().trim();
  if (!ownerUid) {
    throw new functions.https.HttpsError('failed-precondition', 'Account has no ownerUid');
  }

  if (ownerEmail.toLowerCase() !== confirmation) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Email confirmation does not match this account owner',
    );
  }

  if (context.auth.uid === ownerUid) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'You cannot delete your own facility creator account while signed in as that owner',
    );
  }

  const facilitiesSnap = await db
    .collection('facilities')
    .where('ownerUid', '==', ownerUid)
    .get();

  // Every subscription this owner has, across every facility plus the legacy
  // account plan, cancelled before any of it is deleted. Collected in one
  // pass so a subscription shared by two facilities is cancelled once.
  const allSubscriptions = [
    ...facilitiesSnap.docs.flatMap((f) =>
      collectSubscriptionsToCancel(f.data() as Record<string, unknown>, null),
    ),
    ...collectSubscriptionsToCancel(null, accountData),
  ].filter(
    (sub, i, list) => list.findIndex((other) => other.id === sub.id) === i,
  );
  const accountCancelOutcomes = await deps.cancelSubscriptions(allSubscriptions);
  if (anyCancelFailed(accountCancelOutcomes)) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      `Could not cancel this account's Stripe subscriptions, so nothing was deleted: ` +
        `${summarizeCancelOutcomes(accountCancelOutcomes)}. Resolve it in Stripe and try again.`,
    );
  }
  if (accountCancelOutcomes.length > 0) {
    functions.logger.info('Cancelled account subscriptions before delete', {
      accountId,
      ownerUid,
      outcomes: summarizeCancelOutcomes(accountCancelOutcomes),
    });
  }

  for (const f of facilitiesSnap.docs) {
    // Payment links, reservations, staff roles, domain claims, link
    // exceptions and Stripe refusals name the facility from outside its
    // subtree, with tenant names and amounts: the tree delete left them
    // behind. Before the tree, as purgeFacility does, so a failure leaves
    // the facility doc for a retry to find.
    await deleteFacilityKeyedRecords(db, f.id);
    await adminDeleteDocumentTree(f.ref);
  }

  await adminDeleteDocumentTree(accountRef);

  try {
    await deps.deleteAuthUser(ownerUid);
  } catch (e: unknown) {
    const code = (e as { code?: string })?.code;
    if (code !== 'auth/user-not-found') {
      throw e;
    }
  }

  await db.collection('users').doc(ownerUid).delete();

  functions.logger.info('superAdminDeleteFacilityCreatorAccount', {
    accountId,
    ownerUid,
    deletedBy: callerEmail,
    facilitiesDeleted: facilitiesSnap.size,
  });

  return { success: true, facilitiesDeleted: facilitiesSnap.size };
}
