import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { enqueueFacilityJobs } from './facilityJobEnqueue';
import {
  canClaimFacilityJob,
  chunkForBatchedWrites,
  facilityJobId,
  jobRunDate,
} from './facilityJobHelpers';
import {
  buildRentChargeDescription,
  hasRentChargeForMonth,
  shouldChargeTenant,
} from './rentChargeHelpers';

export const RENT_CHARGE_JOBS_COLLECTION = 'rentChargeJobs';

/**
 * Enqueues one rent-charge job per active facility.
 *
 * Raising the monthly rent charges is what every other billing feature bills
 * against, so a partial run is worse here than almost anywhere else: facilities
 * missed by a timeout would simply have no charges that month, and the owner
 * gets no signal. Fanning out keeps each invocation to a single facility.
 */
// Keeps the original exported name so the existing Cloud Scheduler job and
// deployed function are reused rather than torn down and recreated — only the
// implementation changed, from one big walk to a per-facility fan-out.
export const scheduledGenerateMonthlyRentCharges = functions
  .runWith({ timeoutSeconds: 300, memory: '256MB' })
  .pubsub.schedule('0 0 1 * *') // 1st of each month, 00:00 UTC
  .timeZone('UTC')
  .onRun(async () => {
    const runDate = jobRunDate(new Date());
    functions.logger.info(`Enqueuing rent-charge jobs for run ${runDate}`);

    const facilitiesSnapshot = await admin
      .firestore()
      .collection('facilities')
      .where('active', '==', true)
      .get();

    const facilityIds = facilitiesSnapshot.docs.map((doc) => doc.id);
    functions.logger.info(`Found ${facilityIds.length} active facilities`);

    const enqueued = await enqueueFacilityJobs({
      collection: RENT_CHARGE_JOBS_COLLECTION,
      runDate,
      facilityIds,
      label: 'Rent-charge job',
    });

    functions.logger.info(`Rent-charge fan-out complete for ${runDate}: ${enqueued} job(s) enqueued`);
    return { runDate, enqueued };
  });

/** Raises this month's rent charges for a single facility. */
export const processFacilityRentChargeJob = functions
  .runWith({ timeoutSeconds: 540, memory: '512MB' })
  .firestore.document(`${RENT_CHARGE_JOBS_COLLECTION}/{jobId}`)
  .onCreate(async (snapshot) => {
    const jobRef = snapshot.ref;
    const facilityId = snapshot.data()?.facilityId as string | undefined;

    if (!facilityId) {
      functions.logger.error(`Rent-charge job ${snapshot.id} has no facilityId; marking failed`);
      await jobRef.update({ status: 'failed', error: 'missing facilityId' });
      return;
    }

    const claimed = await admin.firestore().runTransaction(async (tx) => {
      const fresh = await tx.get(jobRef);
      if (!canClaimFacilityJob(fresh.data())) return false;
      tx.update(jobRef, {
        status: 'processing',
        startedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return true;
    });

    if (!claimed) {
      functions.logger.info(`Rent-charge job ${snapshot.id} already claimed; skipping`);
      return;
    }

    try {
      const result = await generateFacilityRentCharges(facilityId);
      await jobRef.update({
        status: 'completed',
        ...result,
        finishedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info(
        `Rent-charge job ${snapshot.id} completed for ${facilityId}: ` +
          `${result.successCount} raised, ${result.skippedCount} skipped, ${result.errorCount} errors`,
      );
    } catch (error: any) {
      functions.logger.error(`Rent-charge job ${snapshot.id} failed for ${facilityId}:`, error);
      await jobRef.update({
        status: 'failed',
        error: String(error?.message ?? error),
        finishedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      throw error;
    }
  });

async function generateFacilityRentCharges(facilityId: string): Promise<{
  successCount: number;
  skippedCount: number;
  errorCount: number;
}> {
  const targetDate = new Date();
  targetDate.setDate(1); // charges are dated to the 1st of the month
  const targetMonth = targetDate.getMonth() + 1;
  const targetYear = targetDate.getFullYear();

  // Half-open [monthStart, nextMonthStart) window for the duplicate check.
  const monthStart = new Date(targetDate.getFullYear(), targetDate.getMonth(), 1);
  const nextMonthStart = new Date(targetDate.getFullYear(), targetDate.getMonth() + 1, 1);

  const tenantsSnapshot = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .where('isActive', '==', true)
    .get();

  let successCount = 0;
  let skippedCount = 0;
  let errorCount = 0;

  for (const tenantDoc of tenantsSnapshot.docs) {
    const tenantData = tenantDoc.data();
    const tenantId = tenantDoc.id;

    if (!shouldChargeTenant(tenantData)) {
      skippedCount += 1;
      continue;
    }

    try {
      const ledgerSnapshot = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .where('tenantId', '==', tenantId)
        .where('type', '==', 'rentCharge')
        .where('status', '==', 'posted')
        // Bounded to the target month. The duplicate check only cares whether
        // *this* month's charge exists, so reading a tenant's entire rent
        // history is wasted work that grows every month they stay — by year
        // five that is ~60 documents per tenant, every tenant, every run.
        .where('entryDate', '>=', admin.firestore.Timestamp.fromDate(monthStart))
        .where('entryDate', '<', admin.firestore.Timestamp.fromDate(nextMonthStart))
        .get();

      if (
        hasRentChargeForMonth(
          ledgerSnapshot.docs.map((doc) => doc.data()),
          targetMonth,
          targetYear,
        )
      ) {
        skippedCount += 1;
        continue;
      }

      const monthlyRate = tenantData.monthlyRate as number;
      const ledgerEntryRef = admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .doc();

      await ledgerEntryRef.set({
        tenantId,
        facilityId,
        type: 'rentCharge',
        amount: monthlyRate,
        description: buildRentChargeDescription(targetDate),
        entryDate: admin.firestore.Timestamp.fromDate(targetDate),
        dueDate: admin.firestore.Timestamp.fromDate(targetDate),
        status: 'posted',
        metadata: {
          recurringCharge: true,
          chargeType: 'monthlyRent',
          month: targetMonth,
          year: targetYear,
          generatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: 'system',
      });

      await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('auditLogs')
        .add({
          action: 'recurringCharge.generated',
          actorUid: 'system',
          actorEmail: 'system@scheduled-job',
          targetId: ledgerEntryRef.id,
          entityType: 'ledgerEntry',
          entityId: ledgerEntryRef.id,
          tenantId,
          details: {
            amount: monthlyRate,
            chargeType: 'monthlyRent',
            month: targetMonth,
            year: targetYear,
            scheduled: true,
          },
          at: admin.firestore.FieldValue.serverTimestamp(),
        });

      successCount += 1;
    } catch (error: any) {
      errorCount += 1;
      functions.logger.error(
        `Error generating charge for tenant ${tenantId} in facility ${facilityId}:`,
        error,
      );
    }
  }

  return { successCount, skippedCount, errorCount };
}
