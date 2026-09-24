import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

/**
 * The server's half of the email code the app asks for before a sensitive
 * action (TwoFactorHelper.require2FA).
 *
 * The app's check is client side only: it asks for a code when
 * users/{uid}.twoFactorEnabled is true and calls verifyOTP
 * (functions-account-security), which marks the code used. Nothing on the
 * server tied the action to that verification, so a direct call skipped it.
 *
 * users/{uid}/otpCodes is server-only (no rule matches it), so a code there
 * is a signal the caller cannot forge. verifyOTP marks a code used when it
 * matches, and marks an expired code used only once it has expired, so a
 * used code that has not yet expired was verified. Each one authorizes one
 * action: it is marked consumed here.
 *
 * twoFactorEnabled itself lives on the user's own doc, which the rules let
 * them write (the app's Security screen turns it off that way), so this is
 * only as strong as that: it mirrors the app, it does not add a factor.
 */

/** The purpose the app requests and verifies the code under. */
export const DELETE_FACILITY_OTP_PURPOSE = 'delete_facility';

export const TWO_FACTOR_REQUIRED_MESSAGE =
  "Nothing was deleted: confirm it's you with the code we email you, then try again.";

export function timestampMs(value: unknown): number | null {
  if (value instanceof Date) return value.getTime();
  if (value && typeof (value as { toMillis?: unknown }).toMillis === 'function') {
    return (value as { toMillis: () => number }).toMillis();
  }
  return null;
}

/** A code verifyOTP accepted, still inside its 10 minutes, not yet spent on an action. */
export function isVerifiedUnspentCode(code: Record<string, unknown>, nowMs: number): boolean {
  const expiresAt = timestampMs(code.expiresAt);
  return code.used === true && expiresAt !== null && expiresAt > nowMs && code.consumedAt == null;
}

/**
 * Returns when [uid] has 2FA off, or after consuming one verified code for
 * [purpose]. Otherwise throws failed-precondition with
 * details.reason 'two-factor-required'.
 */
export async function consumeRecentTwoFactor(
  db: admin.firestore.Firestore,
  uid: string,
  purpose: string,
  action: string,
  nowMs: number,
): Promise<'off' | 'verified'> {
  const userRef = db.collection('users').doc(uid);
  const user = await userRef.get();
  if (user.get('twoFactorEnabled') !== true) return 'off';

  const spent = await db.runTransaction(async (tx) => {
    // Equality on purpose only: served by the single-field index.
    const codes = await tx.get(userRef.collection('otpCodes').where('purpose', '==', purpose));
    const code = codes.docs.find((d) => isVerifiedUnspentCode(d.data(), nowMs));
    if (!code) return false;
    tx.update(code.ref, {
      consumedAt: admin.firestore.FieldValue.serverTimestamp(),
      consumedBy: action,
    });
    return true;
  });
  if (!spent) {
    throw new functions.https.HttpsError('failed-precondition', TWO_FACTOR_REQUIRED_MESSAGE, {
      reason: 'two-factor-required',
    });
  }
  return 'verified';
}
