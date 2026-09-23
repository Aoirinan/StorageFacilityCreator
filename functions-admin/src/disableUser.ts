import * as functions from 'firebase-functions/v1';
import { isSuperAdmin } from '@sfc/functions-shared/auth/superAdmin';

/** The Auth calls superAdminDisableUser makes: admin.auth() in production. */
export interface DisableUserAuth {
  getUser(uid: string): Promise<{ email?: string }>;
  updateUser(uid: string, properties: { disabled: boolean }): Promise<unknown>;
  revokeRefreshTokens(uid: string): Promise<void>;
}

export interface DisableUserDeps {
  auth: DisableUserAuth;
  /** Merges [fields] into users/{uid}. */
  mergeUserDoc(uid: string, fields: Record<string, unknown>): Promise<unknown>;
  serverTimestamp(): unknown;
}

/**
 * superAdminDisableUser's body, with Auth and Firestore passed in so tests can
 * check what it does. The suspend flow in the super admin console calls it too.
 */
export async function disableUserHandler(
  data: { uid?: unknown } | undefined,
  context: { auth?: { token?: { email?: string } } } | undefined,
  deps: DisableUserDeps,
): Promise<{ success: true }> {
  if (!context?.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can disable users');
  }
  const uid = String(data?.uid ?? '').trim();
  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'uid is required');
  }
  const targetUser = await deps.auth.getUser(uid);
  if (isSuperAdmin(targetUser.email)) {
    throw new functions.https.HttpsError('permission-denied', 'Cannot disable a super admin account');
  }
  await deps.auth.updateUser(uid, { disabled: true });
  // Disabling alone left sessions already signed in to run on until the
  // client happened to re-check with Auth, and to resume if the account was
  // re-enabled. Revoked refresh tokens cannot mint a new ID token, so every
  // session ends within the hour at most and must sign in again afterwards.
  await deps.auth.revokeRefreshTokens(uid);
  await deps.mergeUserDoc(uid, { authDisabled: true, authDisabledAt: deps.serverTimestamp() });
  functions.logger.info('superAdminDisableUser', { uid, disabledBy: callerEmail });
  return { success: true };
}
