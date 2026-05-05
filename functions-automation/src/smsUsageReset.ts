import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { capSmsLimit, SMS_LIMIT_PER_ACCOUNT, SMS_LIMIT_PER_FACILITY } from './smsCaps';

/**
 * Scheduled function: Reset monthly SMS usage counters at UTC month rollover
 * Runs at 00:00 UTC on the 1st of each month
 */
export const resetMonthlySMSUsage = functions.pubsub.schedule('0 0 1 * *').timeZone('UTC').onRun(async (context) => {
  try {
    functions.logger.info('Starting monthly SMS usage reset...');

    const now = new Date();
    const currentMonthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    // Reset facility usage
    const facilitiesSnapshot = await admin.firestore().collection('facilities').get();
    const facilityResets = facilitiesSnapshot.docs.map(async (facilityDoc) => {
      const usageRef = facilityDoc.ref.collection('smsUsage').doc(currentMonthKey);
      await usageRef.set({
        smsMonthlyCount: 0,
        smsMonthlyLimit: capSmsLimit(SMS_LIMIT_PER_FACILITY),
        smsMonth: currentMonthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    // Reset account usage
    const accountsSnapshot = await admin.firestore().collection('facilityCreatorAccounts').get();
    const accountResets = accountsSnapshot.docs.map(async (accountDoc) => {
      const usageRef = accountDoc.ref.collection('smsUsage').doc(currentMonthKey);
      await usageRef.set({
        smsMonthlyCount: 0,
        smsMonthlyLimit: capSmsLimit(SMS_LIMIT_PER_ACCOUNT),
        smsMonth: currentMonthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    await Promise.all([...facilityResets, ...accountResets]);

    functions.logger.info(`Monthly SMS usage reset completed for ${facilitiesSnapshot.size} facilities and ${accountsSnapshot.size} accounts`);
    return null;
  } catch (error: any) {
    functions.logger.error('Error resetting monthly SMS usage', error);
    throw error;
  }
});
