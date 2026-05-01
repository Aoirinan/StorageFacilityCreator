import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

export const DAILY_AI_USER_LIMIT = 10;

/**
 * Atomically enforce and consume daily AI quota for both facility and user.
 */
export async function enforceAndConsumeDailyAiQuota(params: {
  uid: string;
  facilityId: string;
  dailyLimitPerUser: number;
  dailyLimitPerFacility: number;
}): Promise<{ refund: () => Promise<void> }> {
  const { uid, facilityId, dailyLimitPerUser, dailyLimitPerFacility } = params;
  const today = new Date().toISOString().split('T')[0];
  const db = admin.firestore();
  const facilityUsageRef = db
    .collection('facilities')
    .doc(facilityId)
    .collection('aiUsage')
    .doc(today);
  const userUsageRef = db
    .collection('users')
    .doc(uid)
    .collection('aiUsage')
    .doc(today);

  await db.runTransaction(async (tx) => {
    const [facilityUsageDoc, userUsageDoc] = await Promise.all([
      tx.get(facilityUsageRef),
      tx.get(userUsageRef),
    ]);

    const facilityUsageCount = facilityUsageDoc.exists ? (facilityUsageDoc.data()?.count || 0) : 0;
    const userUsageCount = userUsageDoc.exists ? (userUsageDoc.data()?.count || 0) : 0;

    if (facilityUsageCount >= dailyLimitPerFacility) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Daily limit reached for this facility (${dailyLimitPerFacility} messages/day). Try again tomorrow.`,
      );
    }

    if (userUsageCount >= dailyLimitPerUser) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Daily limit reached for your account (${dailyLimitPerUser} messages/day). Try again tomorrow.`,
      );
    }

    tx.set(
      facilityUsageRef,
      {
        count: facilityUsageCount + 1,
        lastUsed: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
      },
      { merge: true },
    );

    tx.set(
      userUsageRef,
      {
        count: userUsageCount + 1,
        lastUsed: admin.firestore.FieldValue.serverTimestamp(),
        userId: uid,
      },
      { merge: true },
    );
  });

  const refund = async (): Promise<void> => {
    await db.runTransaction(async (tx) => {
      const [facilityUsageDoc, userUsageDoc] = await Promise.all([
        tx.get(facilityUsageRef),
        tx.get(userUsageRef),
      ]);

      const facilityUsageCount = facilityUsageDoc.exists ? (facilityUsageDoc.data()?.count || 0) : 0;
      const userUsageCount = userUsageDoc.exists ? (userUsageDoc.data()?.count || 0) : 0;

      tx.set(
        facilityUsageRef,
        {
          count: Math.max(0, facilityUsageCount - 1),
          lastUsed: admin.firestore.FieldValue.serverTimestamp(),
          facilityId,
        },
        { merge: true },
      );

      tx.set(
        userUsageRef,
        {
          count: Math.max(0, userUsageCount - 1),
          lastUsed: admin.firestore.FieldValue.serverTimestamp(),
          userId: uid,
        },
        { merge: true },
      );
    });
  };

  return { refund };
}
