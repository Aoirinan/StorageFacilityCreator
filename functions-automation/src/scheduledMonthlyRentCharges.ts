import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

/**
 * Scheduled function: Generate monthly rent charges on the 1st of each month at 12:00 AM UTC
 * This function runs for all facilities
 */
export const scheduledGenerateMonthlyRentCharges = functions.pubsub
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
      const targetDate = new Date();
      targetDate.setDate(1); // First day of current month

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

          const targetMonth = targetDate.getMonth() + 1;
          const targetYear = targetDate.getFullYear();

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

              const existingCharge = ledgerSnapshot.docs.some(doc => {
                const entryData = doc.data();
                const entryDate = entryData.entryDate?.toDate();
                if (!entryDate) return false;

                const entryMonth = entryDate.getMonth() + 1;
                const entryYear = entryDate.getFullYear();

                if (entryMonth !== targetMonth || entryYear !== targetYear) return false;

                const metadata = entryData.metadata || {};
                return metadata.recurringCharge === true &&
                       metadata.chargeType === 'monthlyRent' &&
                       metadata.month === targetMonth &&
                       metadata.year === targetYear;
              });

              if (existingCharge) {
                skippedCount++;
                continue;
              }

              // Generate charge
              const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
                'July', 'August', 'September', 'October', 'November', 'December'];
              const description = `Monthly Rent - ${monthNames[targetDate.getMonth()]} ${targetYear}`;

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
