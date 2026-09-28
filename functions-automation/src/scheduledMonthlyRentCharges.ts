import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  buildRentChargeDescription,
  hasRentChargeForMonth,
  rentChargeDateFor,
  rentChargeMonthAt,
} from './rentChargeHelpers';

/**
 * Scheduled function: Generate monthly rent charges on the 1st of each month at 12:00 AM UTC
 * This function runs for all facilities
 */
// SUPERSEDED by scheduleMonthlyRentChargeJobs + processFacilityRentChargeJob in
// ./rentChargeJob, which fan out one job per facility.
//
// This single-invocation version walked facilities -> tenants -> ledgers
// sequentially. It is retained, unscheduled, only so the logic can be compared
// against the fanned-out version during rollout; it is no longer exported from
// index.ts and therefore no longer deployed. Delete once the fan-out has run a
// full billing cycle.
const _supersededGenerateMonthlyRentCharges = functions
  .runWith({ timeoutSeconds: 540, memory: '512MB' })
  .pubsub
  .schedule('0 0 1 * *') // 1st of each month at 12:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    try {
      functions.logger.info('Starting scheduled monthly rent charge generation');

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      functions.logger.info(`Found ${facilitiesSnapshot.size} active facilities`);

      const results = [];
      // Same month and charge date as the live job (noon UTC on the 1st), so
      // a comparison against it is like for like.
      const { year: targetYear, month: targetMonth } = rentChargeMonthAt(new Date());
      const targetDate = rentChargeDateFor(targetYear, targetMonth);

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        try {
          const facilityData = facilityDoc.data();
          // ownerUid available if needed for future permission checks

          // Get all active tenants
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .get();

          const activeTenants = tenantsSnapshot.docs.filter(doc => {
            const data = doc.data();
            return data.unitNumber && data.unitNumber.trim() !== '';
          });

          let successCount = 0;
          let skippedCount = 0;
          let errorCount = 0;

          for (const tenantDoc of activeTenants) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;
              const monthlyRate = tenantData.monthlyRate || 0;

              if (monthlyRate <= 0) {
                skippedCount++;
                continue;
              }

              // Check if charge already exists
              const ledgerSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .where('tenantId', '==', tenantId)
                .where('type', '==', 'rentCharge')
                .where('status', '==', 'posted')
                .get();

              const existingCharge = hasRentChargeForMonth(
                ledgerSnapshot.docs.map((doc) => doc.data()),
                targetMonth,
                targetYear,
              );

              if (existingCharge) {
                skippedCount++;
                continue;
              }

              // Generate charge
              const description = buildRentChargeDescription(targetYear, targetMonth);

              const ledgerEntryRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .doc();

              await ledgerEntryRef.set({
                tenantId: tenantId,
                facilityId: facilityId,
                type: 'rentCharge',
                amount: monthlyRate,
                description: description,
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
                createdBy: 'system', // System-generated
              });

              // Audit log
              await admin.firestore()
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
                  tenantId: tenantId,
                  details: {
                    amount: monthlyRate,
                    chargeType: 'monthlyRent',
                    month: targetMonth,
                    year: targetYear,
                    scheduled: true,
                  },
                  at: admin.firestore.FieldValue.serverTimestamp(),
                });

              successCount++;
            } catch (error: any) {
              errorCount++;
              functions.logger.error(`Error generating charge for tenant ${tenantDoc.id} in facility ${facilityId}:`, error);
            }
          }

          results.push({
            facilityId,
            facilityName: facilityData.name,
            totalTenants: activeTenants.length,
            successCount,
            skippedCount,
            errorCount,
          });

          functions.logger.info(`Facility ${facilityData.name}: ${successCount} success, ${skippedCount} skipped, ${errorCount} errors`);
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
          results.push({
            facilityId,
            facilityName: facilityDoc.data()?.name || 'Unknown',
            error: error.message,
          });
        }
      }

      functions.logger.info(`Scheduled charge generation completed for ${results.length} facilities`);
      return { results };
    } catch (error: any) {
      functions.logger.error('Error in scheduled charge generation:', error);
      throw error;
    }
  });

// Referenced so the superseded implementation still type-checks while it is
// kept for comparison. It is not exported from index.ts, so it is not deployed.
void _supersededGenerateMonthlyRentCharges;
