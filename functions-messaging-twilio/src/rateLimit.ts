import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

export type RateLimitConfig = {
  facilityId: string | undefined;
  key: string;
  limit: number;
  windowSeconds: number;
  userId?: string | null;
};

export async function enforceRateLimit(config: RateLimitConfig): Promise<void> {
  const { facilityId, key, limit, windowSeconds, userId } = config;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required for rate limiting');
  }

  const now = Math.floor(Date.now() / 1000);
  const windowStart = Math.floor(now / windowSeconds) * windowSeconds;
  const docId = `${key}_${windowStart}`;
  const ref = admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('rateLimits')
    .doc(docId);

  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? (snap.data()?.count as number) || 0 : 0;
    if (current >= limit) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Rate limit exceeded for ${key}. Try again shortly.`,
      );
    }
    tx.set(
      ref,
      {
        count: current + 1,
        windowStart: new Date(windowStart * 1000),
        windowSeconds,
        key,
        facilityId,
        lastUserId: userId || null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}
