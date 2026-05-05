import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { writeAuditLog } from './guardrails';
import { isPaymentSafetyFeatureEnabled } from './paymentSafetyFlags';

/**
 * Callable function to generate monthly rent charges for a facility
 * Can be called manually or by scheduled function
 */
export const generateMonthlyRentCharges = functions.https.onCall(async (data, context) => {
  try {
    // Verify authentication
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }

    const { facilityId, forDate, dryRun } = data;
    const isDryRun = dryRun === true;

    if (!facilityId) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    }

    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to generate charges for this facility');
    }

    // Parse target date or use first of current month
    let targetDate: Date;
    if (forDate) {
      targetDate = new Date(forDate);
    } else {
      const now = new Date();
      targetDate = new Date(now.getFullYear(), now.getMonth(), 1);
    }

    // Get all active tenants for the facility
    const tenantsSnapshot = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .where('isActive', '==', true)
      .get();

    // Filter tenants with safety checks
    const activeTenants = tenantsSnapshot.docs.filter(doc => {
      const data = doc.data();
      // Must have unit number
      if (!data.unitNumber || data.unitNumber.trim() === '') {
        return false;
      }
      // Must be active
      if (data.isActive !== true) {
        return false;
      }
      // Skip if moved out (has moveOutDate)
      if (data.moveOutDate) {
        return false;
      }
      return true;
    });

    functions.logger.info(`Generating charges for ${activeTenants.length} active tenants in facility ${facilityId}`);

    let successCount = 0;
    let skippedCount = 0;
    let errorCount = 0;
    const errors: string[] = [];

    const targetMonth = targetDate.getMonth() + 1; // JavaScript months are 0-indexed
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

        // Check if idempotency is enabled
        const idempotencyEnabled = await isPaymentSafetyFeatureEnabled('idempotency', facilityId);

        // Generate idempotency key for this charge (if enabled)
        // Format: charge_{facilityId}_{tenantId}_{year}_{month}
        const chargeIdempotencyKey = idempotencyEnabled
          ? `charge_${facilityId}_${tenantId}_${targetYear}_${targetMonth}`
          : null;

        // Check idempotency collection first (faster than querying all ledger entries) - if enabled
        if (idempotencyEnabled && chargeIdempotencyKey) {
          const idempotencyRef = admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('idempotencyKeys')
            .doc(chargeIdempotencyKey);

          const idempotencyDoc = await idempotencyRef.get();

          if (idempotencyDoc.exists) {
            const idempotencyData = idempotencyDoc.data();
            const existingEntryId = idempotencyData?.ledgerEntryId as string | undefined;
            
            if (existingEntryId) {
              // Verify the entry still exists
              const existingEntryRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('ledger')
                .doc(existingEntryId);
              
              const existingEntryDoc = await existingEntryRef.get();
              
              if (existingEntryDoc.exists) {
                functions.logger.info(`Charge already exists (idempotency): ${chargeIdempotencyKey} -> ${existingEntryId}`);
                skippedCount++;
                continue;
              } else {
                // Entry was deleted, remove idempotency key and continue
                await idempotencyRef.delete();
              }
            } else {
              skippedCount++;
              continue;
            }
          }
        }

        // Also check ledger entries as fallback (for backward compatibility)
        const ledgerSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('ledger')
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
          // Store idempotency key for future checks (if enabled)
          if (idempotencyEnabled && chargeIdempotencyKey) {
            const idempotencyRef = admin.firestore()
              .collection('facilities')
              .doc(facilityId)
              .collection('idempotencyKeys')
              .doc(chargeIdempotencyKey);
            
            await idempotencyRef.set({
              ledgerEntryId: ledgerSnapshot.docs[0].id,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              facilityId,
              tenantId,
              month: targetMonth,
              year: targetYear,
            });
          }
          skippedCount++;
          continue;
        }

        // Generate rent charge
        const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
          'July', 'August', 'September', 'October', 'November', 'December'];
        const description = `Monthly Rent - ${monthNames[targetDate.getMonth()]} ${targetYear}`;

        // In dry-run mode, skip actual creation
        if (isDryRun) {
          successCount++;
          continue;
        }

        // Use transaction to ensure atomicity (if idempotency enabled)
        const ledgerEntryId = idempotencyEnabled && chargeIdempotencyKey
          ? await admin.firestore().runTransaction(async (tx) => {
              // Double-check idempotency within transaction
              const idempotencyRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('idempotencyKeys')
                .doc(chargeIdempotencyKey);
              
              const idempotencyCheck = await tx.get(idempotencyRef);
              if (idempotencyCheck.exists) {
                const existingEntryId = idempotencyCheck.data()?.ledgerEntryId as string | undefined;
                if (existingEntryId) {
                  throw new Error('DUPLICATE_CHARGE'); // Will be caught and skipped
                }
              }

          // Create ledger entry
          const ledgerEntryRef = admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(tenantId)
            .collection('ledger')
            .doc();

          const ledgerEntryData = {
            type: 'rentCharge',
            amount: monthlyRate,
            description,
            entryDate: admin.firestore.Timestamp.fromDate(targetDate),
            dueDate: admin.firestore.Timestamp.fromDate(targetDate),
            status: 'posted',
            facilityId,
            tenantId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          metadata: {
            recurringCharge: true,
            chargeType: 'monthlyRent',
            month: targetMonth,
            year: targetYear,
            ...(chargeIdempotencyKey ? { idempotencyKey: chargeIdempotencyKey } : {}),
            generatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          };

          tx.set(ledgerEntryRef, ledgerEntryData);

              // Store idempotency key
              tx.set(idempotencyRef, {
                ledgerEntryId: ledgerEntryRef.id,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                facilityId,
                tenantId,
                month: targetMonth,
                year: targetYear,
              });

              return ledgerEntryRef.id;
            }).catch(async (error: any) => {
              if (error.message === 'DUPLICATE_CHARGE') {
                // This is expected - charge already exists
                return null;
              }
              throw error;
            })
          : (async () => {
              // Create ledger entry without transaction (idempotency disabled)
              const ledgerEntryRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('ledger')
                .doc();

              await ledgerEntryRef.set({
                type: 'rentCharge',
                amount: monthlyRate,
                description,
                entryDate: admin.firestore.Timestamp.fromDate(targetDate),
                dueDate: admin.firestore.Timestamp.fromDate(targetDate),
                status: 'posted',
                facilityId,
                tenantId,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                metadata: {
                  recurringCharge: true,
                  chargeType: 'monthlyRent',
                  month: targetMonth,
                  year: targetYear,
                  generatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
              });

              return ledgerEntryRef.id;
            })();

        const ledgerEntryIdResolved = await ledgerEntryId;
        if (ledgerEntryIdResolved === null) {
          skippedCount++;
          continue;
        }

        // Audit log
        await writeAuditLog(facilityId, {
          eventType: 'recurringCharge.generated',
          actorUid: context.auth.uid,
          targetType: 'ledgerEntry',
          targetId: ledgerEntryIdResolved,
          tenantId,
          after: {
            amount: monthlyRate,
            chargeType: 'monthlyRent',
            month: targetMonth,
            year: targetYear,
          },
          metadata: {
            ...(chargeIdempotencyKey ? { idempotencyKey: chargeIdempotencyKey } : {}),
          },
        });

        successCount++;
      } catch (error: any) {
        errorCount++;
        const tenantData = tenantDoc.data();
        const errorMsg = `Tenant ${tenantData.name || tenantDoc.id}: ${error.message}`;
        errors.push(errorMsg);
        functions.logger.error(`Error generating charge for tenant ${tenantDoc.id}:`, error);
      }
    }

    functions.logger.info(`Charge generation completed: ${successCount} success, ${skippedCount} skipped, ${errorCount} errors`);

    return {
      success: true,
      totalTenants: activeTenants.length,
      successCount,
      skippedCount,
      errorCount,
      errors,
      dryRun: isDryRun,
      ...(isDryRun ? {
        preview: {
          totalCharges: successCount,
          totalAmount: activeTenants.reduce((sum, doc) => {
            const data = doc.data();
            return sum + (data.monthlyRate || 0);
          }, 0),
        },
      } : {}),
    };
  } catch (error: any) {
    functions.logger.error('Error generating monthly rent charges:', error);
    throw new functions.https.HttpsError('internal', `Failed to generate charges: ${error.message}`);
  }
});
