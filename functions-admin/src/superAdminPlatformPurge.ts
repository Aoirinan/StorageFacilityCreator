import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getSuperAdminEmails, isSuperAdmin } from '@sfc/functions-shared/auth/superAdmin';
import { getStripeClient } from '@sfc/functions-shared/stripe/client';
import { adminDeleteDocumentTree, adminDeleteEntireCollection } from './admin_delete_document_tree';
import { STRIPE_SECRETS } from './secrets';

const PURGE_CONFIRMATION_PHRASE = 'PURGE PLATFORM';

/** Top-level Firestore collections wiped by platform purge (operational / customer data). */
const PURGE_ROOT_COLLECTIONS = [
  'facilities',
  'facilityCreatorAccounts',
  'publicReservations',
  'publicFacilityMaps',
  'publicPaymentLinks',
  'marketing_leads',
  'referralLookup',
  'referralRewardsPending',
  'user_roles',
  'rateLimits',
  'global_dnr_entries',
  'bug_reports',
  'commission_payout_periods',
  'superAdminNotes',
  'stripeWebhookEvents',
  'quickbooks_oauth_states',
] as const;

interface SuperAdminPurgePlatformData {
  confirmationPhrase?: string;
  callerEmailConfirmation?: string;
}

export type PlatformPurgeStats = {
  facilitiesDeleted: number;
  facilityCreatorAccountsDeleted: number;
  rootCollectionsDeleted: Record<string, number>;
  firestoreUsersDeleted: number;
  authUsersDeleted: number;
  stripeSubscriptionsCancelled: number;
  storagePrefixCleared: boolean;
  preservedSuperAdminEmails: string[];
};

async function deleteStoragePrefixBestEffort(prefix: string): Promise<boolean> {
  try {
    const bucket = admin.storage().bucket();
    await bucket.deleteFiles({ prefix, force: true });
    functions.logger.info('platformPurge: removed storage prefix', { prefix });
    return true;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    functions.logger.warn('platformPurge: storage prefix delete failed', { prefix, error: msg });
    return false;
  }
}

async function cancelAllStripeSubscriptionsBestEffort(
  db: admin.firestore.Firestore,
): Promise<number> {
  let cancelled = 0;
  const stripe = getStripeClient();
  const accountsSnap = await db.collection('facilityCreatorAccounts').get();
  for (const doc of accountsSnap.docs) {
    const subId = String(doc.data().stripeSubscriptionId || '').trim();
    if (!subId) {
      continue;
    }
    try {
      await stripe.subscriptions.cancel(subId);
      cancelled += 1;
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err);
      functions.logger.warn('platformPurge: stripe subscription cancel failed', {
        accountId: doc.id,
        subscriptionId: subId,
        error: msg,
      });
    }
  }
  return cancelled;
}

async function deleteNonSuperAdminAuthUsers(
  preservedEmailsLower: Set<string>,
): Promise<number> {
  let deleted = 0;
  let pageToken: string | undefined;
  for (;;) {
    const list = await admin.auth().listUsers(1000, pageToken);
    for (const user of list.users) {
      const emailLower = (user.email || '').trim().toLowerCase();
      if (emailLower && preservedEmailsLower.has(emailLower)) {
        continue;
      }
      if (isSuperAdmin(user.email)) {
        continue;
      }
      try {
        await admin.auth().deleteUser(user.uid);
        deleted += 1;
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        functions.logger.warn('platformPurge: auth user delete failed', {
          uid: user.uid,
          email: user.email,
          error: msg,
        });
      }
    }
    if (!list.pageToken) {
      break;
    }
    pageToken = list.pageToken;
  }
  return deleted;
}

async function deleteNonSuperAdminFirestoreUsers(
  db: admin.firestore.Firestore,
  preservedUids: Set<string>,
): Promise<number> {
  let deleted = 0;
  const usersSnap = await db.collection('users').get();
  for (const doc of usersSnap.docs) {
    if (preservedUids.has(doc.id)) {
      continue;
    }
    const emailLower = String(doc.data().email || '').trim().toLowerCase();
    if (isSuperAdmin(emailLower)) {
      continue;
    }
    await adminDeleteDocumentTree(doc.ref);
    deleted += 1;
  }
  return deleted;
}

/**
 * Super admin only: irreversibly remove all platform customer/operator data while
 * preserving super-admin Firebase Auth accounts and their `users/{uid}` profiles.
 *
 * Requires typing `PURGE PLATFORM` and the caller's super-admin email.
 */
export const superAdminPurgePlatformData = functions
  .runWith({ timeoutSeconds: 540, secrets: STRIPE_SECRETS })
  .https.onCall(async (data: SuperAdminPurgePlatformData, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }

    const callerEmail = (context.auth.token?.email as string | undefined)?.trim();
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only super admins can purge platform data',
      );
    }

    const phrase = (data?.confirmationPhrase || '').trim();
    const emailConfirmation = (data?.callerEmailConfirmation || '').trim().toLowerCase();
    if (phrase !== PURGE_CONFIRMATION_PHRASE) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        `confirmationPhrase must be exactly "${PURGE_CONFIRMATION_PHRASE}"`,
      );
    }
    if (!callerEmail || emailConfirmation !== callerEmail.toLowerCase()) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'callerEmailConfirmation must match your signed-in super-admin email',
      );
    }

    const db = admin.firestore();
    const preservedEmails = getSuperAdminEmails();
    const preservedEmailsLower = new Set(preservedEmails.map((e) => e.toLowerCase()));
    const preservedUids = new Set<string>();
    for (const email of preservedEmails) {
      try {
        const user = await admin.auth().getUserByEmail(email);
        preservedUids.add(user.uid);
      } catch (err: unknown) {
        const code = (err as { code?: string })?.code;
        if (code !== 'auth/user-not-found') {
          throw err;
        }
      }
    }

    functions.logger.warn('platformPurge: starting', {
      deletedBy: callerEmail,
      preservedSuperAdminEmails: preservedEmails,
    });

    const stripeSubscriptionsCancelled = await cancelAllStripeSubscriptionsBestEffort(db);

    const rootCollectionsDeleted: Record<string, number> = {};
    let facilitiesDeleted = 0;
    let facilityCreatorAccountsDeleted = 0;

    for (const collectionName of PURGE_ROOT_COLLECTIONS) {
      const count = await adminDeleteEntireCollection(db.collection(collectionName));
      rootCollectionsDeleted[collectionName] = count;
      if (collectionName === 'facilities') {
        facilitiesDeleted = count;
      }
      if (collectionName === 'facilityCreatorAccounts') {
        facilityCreatorAccountsDeleted = count;
      }
    }

    const firestoreUsersDeleted = await deleteNonSuperAdminFirestoreUsers(db, preservedUids);
    const authUsersDeleted = await deleteNonSuperAdminAuthUsers(preservedEmailsLower);
    const storagePrefixCleared = await deleteStoragePrefixBestEffort('facilities/');

    const stats: PlatformPurgeStats = {
      facilitiesDeleted,
      facilityCreatorAccountsDeleted,
      rootCollectionsDeleted,
      firestoreUsersDeleted,
      authUsersDeleted,
      stripeSubscriptionsCancelled,
      storagePrefixCleared,
      preservedSuperAdminEmails: preservedEmails,
    };

    functions.logger.warn('platformPurge: completed', {
      deletedBy: callerEmail,
      ...stats,
    });

    return { success: true, ...stats };
  });
