// Ledger entries live at facilities/{facilityId}/ledgers, tagged with
// tenantId. This file used facilities/{id}/tenants/{id}/ledger — a different
// collection at a different depth — so everything it wrote was invisible to the
// twelve other writers, to the autopay balance query, and to every ledger read
// in the app. A late fee charged there would never be collected and never shown.
import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { writeAuditLog } from './guardrails';
import { isPaymentSafetyFeatureEnabled } from './paymentSafetyFlags';
import {
  buildRentChargeDescription,
  isRentChargeForMonth,
  rentChargeDateFor,
  rentChargeMonthAt,
  rentChargeMonthFromInput,
} from './rentChargeHelpers';

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

    // The billing month: the one named by forDate, or the current UTC month.
    //
    // forDate used to become the charge date as-is. The Automation Preview
    // screen sends whatever day was picked in its date picker, so charges were
    // dated mid-month at 00:00 UTC (the previous evening in US time zones).
    // Only the month is taken from it now; the charge is dated like the
    // scheduled job's, at noon UTC on the 1st (see rentChargeDateFor).
    const targetMonthRef = forDate
      ? rentChargeMonthFromInput(forDate)
      : rentChargeMonthAt(new Date());
    if (!targetMonthRef) {
      throw new functions.https.HttpsError('invalid-argument', 'forDate is not a valid date');
    }
    const targetDate = rentChargeDateFor(targetMonthRef.year, targetMonthRef.month);

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

    const targetMonth = targetMonthRef.month; // 1-based, as stored in metadata
    const targetYear = targetMonthRef.year;

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
                .collection('ledgers')
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
        //
        // Must be scoped to this tenant. The collection holds every tenant's
        // entries, so without the filter this duplicate-charge guard would see
        // any tenant's rent charge and skip charging everyone after the first.
        // It also bounds the read, which matters for a facility with thousands
        // of tenants and years of history.
        const ledgerSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .where('tenantId', '==', tenantId)
          .where('type', '==', 'rentCharge')
          .where('status', '==', 'posted')
          .get();

        // Same match as the scheduled job, so a charge either path posted
        // (including older ones dated 00:00 UTC) is recognised here.
        const existingCharge = ledgerSnapshot.docs.find((doc) =>
          isRentChargeForMonth(doc.data(), targetMonth, targetYear),
        );

        if (existingCharge) {
          // Store idempotency key for future checks (if enabled)
          if (idempotencyEnabled && chargeIdempotencyKey) {
            const idempotencyRef = admin.firestore()
              .collection('facilities')
              .doc(facilityId)
              .collection('idempotencyKeys')
              .doc(chargeIdempotencyKey);
            
            await idempotencyRef.set({
              ledgerEntryId: existingCharge.id,
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
        const description = buildRentChargeDescription(targetYear, targetMonth);

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
            .collection('ledgers')
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
                .collection('ledgers')
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
    // Pass deliberate errors (auth, permission, bad input) through unchanged
    // rather than reporting them to the app as internal failures.
    if (error instanceof functions.https.HttpsError) throw error;
    functions.logger.error('Error generating monthly rent charges:', error);
    throw new functions.https.HttpsError('internal', `Failed to generate charges: ${error.message}`);
  }
});
