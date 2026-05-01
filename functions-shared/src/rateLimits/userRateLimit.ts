import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

/**
 * Enforce per-user rate limit (e.g. 10 requests per user per minute).
 * Uses users/{uid}/rateLimits/{key}_{windowStart}.
 */
export async function enforceUserRateLimit(
  userId: string,
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  const windowStart = Math.floor(now / windowSeconds) * windowSeconds;
  const docId = `${key}_${windowStart}`;
  const ref = admin
    .firestore()
    .collection('users')
    .doc(userId)
    .collection('rateLimits')
    .doc(docId);

  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? (snap.data()?.count as number) || 0 : 0;
    if (current >= limit) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Rate limit exceeded. Maximum ${limit} requests per minute. Try again shortly.`,
      );
    }
    tx.set(
      ref,
      {
        count: current + 1,
        windowStart: new Date(windowStart * 1000),
        windowSeconds,
        key,
        userId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}
