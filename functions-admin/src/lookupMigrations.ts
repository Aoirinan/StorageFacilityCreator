import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import { isSuperAdmin } from '@sfc/functions-shared';

import { runAllMigrations } from './migrations/phase2_migrations';

/**
 * Lookup user by email for invite purposes.
 * Returns minimal user data (uid, email, name) for security.
 */
export const lookupUserByEmail = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const { email } = data;
  if (!email) {
    throw new functions.https.HttpsError('invalid-argument', 'Email is required');
  }

  try {
    const emailLower = email.toLowerCase().trim();

    const usersSnapshot = await admin
      .firestore()
      .collection('users')
      .where('emailLower', '==', emailLower)
      .limit(1)
      .get();

    if (usersSnapshot.empty) {
      const fallbackSnapshot = await admin
        .firestore()
        .collection('users')
        .where('email', '==', emailLower)
        .limit(1)
        .get();

      if (fallbackSnapshot.empty) {
        return { found: false };
      }

      const userData = fallbackSnapshot.docs[0].data();
      return {
        found: true,
        uid: fallbackSnapshot.docs[0].id,
        email: userData.email || emailLower,
        name: userData.name || null,
      };
    }

    const userData = usersSnapshot.docs[0].data();

    return {
      found: true,
      uid: usersSnapshot.docs[0].id,
      email: userData.email || emailLower,
      name: userData.name || null,
    };
  } catch (error: any) {
    functions.logger.error('Error looking up user by email', { error: error.message, email });
    throw new functions.https.HttpsError('internal', 'Failed to lookup user');
  }
});

export const runPhase2Migrations = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can run migrations');
  }

  try {
    await runAllMigrations();
    return { success: true, message: 'All migrations completed' };
  } catch (error: any) {
    functions.logger.error('Migration error:', error);
    throw new functions.https.HttpsError('internal', `Migration failed: ${error.message}`);
  }
});
