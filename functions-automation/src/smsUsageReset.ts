import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { capSmsLimit, SMS_LIMIT_PER_ACCOUNT, SMS_LIMIT_PER_FACILITY } from './smsCaps';
import { chunkForBatchedWrites } from './autopayJobHelpers';

/**
 * Scheduled function: Reset monthly SMS usage counters at UTC month rollover
 * Runs at 00:00 UTC on the 1st of each month
 */
// Touches every facility and every creator account, so the work grows linearly
// with customer count against the gen-1 default 60s timeout. 540s is the gen-1
// maximum.
export const resetMonthlySMSUsage = functions
  .runWith({ timeoutSeconds: 540, memory: '512MB' })
  .pubsub.schedule('0 0 1 * *').timeZone('UTC').onRun(async (context) => {
  try {
    functions.logger.info('Starting monthly SMS usage reset...');

    const now = new Date();
    const currentMonthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    // Collect every reset first, then commit in batches. The previous version
    // mapped each write to its own promise and awaited them all at once, which
    // at a thousand facilities plus a thousand accounts would fire ~2000
    // concurrent writes from a single instance. Batching keeps that to a handful
    // of round trips regardless of customer count.
    const facilitiesSnapshot = await admin.firestore().collection('facilities').get();
    const accountsSnapshot = await admin.firestore().collection('facilityCreatorAccounts').get();

    const resets: Array<{
      ref: admin.firestore.DocumentReference;
      limit: number;
    }> = [
      ...facilitiesSnapshot.docs.map((facilityDoc) => ({
        ref: facilityDoc.ref.collection('smsUsage').doc(currentMonthKey),
        limit: capSmsLimit(SMS_LIMIT_PER_FACILITY),
      })),
      ...accountsSnapshot.docs.map((accountDoc) => ({
        ref: accountDoc.ref.collection('smsUsage').doc(currentMonthKey),
        limit: capSmsLimit(SMS_LIMIT_PER_ACCOUNT),
      })),
    ];

    for (const chunk of chunkForBatchedWrites(resets)) {
      const batch = admin.firestore().batch();
      for (const { ref, limit } of chunk) {
        batch.set(
          ref,
          {
            smsMonthlyCount: 0,
            smsMonthlyLimit: limit,
            smsMonth: currentMonthKey,
            lastReset: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
      await batch.commit();
    }

    functions.logger.info(`Monthly SMS usage reset completed for ${facilitiesSnapshot.size} facilities and ${accountsSnapshot.size} accounts`);
    return null;
  } catch (error: any) {
    functions.logger.error('Error resetting monthly SMS usage', error);
    throw error;
  }
});
