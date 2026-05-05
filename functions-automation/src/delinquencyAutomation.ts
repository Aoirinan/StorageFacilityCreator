import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { sendFacilityEmailWithCompliance } from '@sfc/functions-shared';
import { writeAuditLog } from './guardrails';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

/**
 * Scheduled function to process delinquency automation daily
 * Runs at 3:00 AM UTC every day
 */
export const processDelinquencyAutomation = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 3 * * *')
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting delinquency automation processing...');

    try {
      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalProcessed = 0;
      let totalLateFees = 0;
      let totalNotices = 0;
      let totalLockouts = 0;
      let totalErrors = 0;

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        functions.logger.info(`Processing delinquency for facility: ${facilityId}`);

        try {
          // Call the delinquency processing function (never dry-run for scheduled)
          const result = await processDelinquencyForFacility(facilityId, false);
          
          if (result.success) {
            totalProcessed += result.processedCount || 0;
            totalLateFees += result.lateFeeAppliedCount || 0;
            totalNotices += result.noticeSentCount || 0;
            totalLockouts += result.lockoutCount || 0;
            totalErrors += result.errorCount || 0;

            functions.logger.info(`✅ Processed facility ${facilityId}:`, {
              processed: result.processedCount,
              lateFees: result.lateFeeAppliedCount,
              notices: result.noticeSentCount,
              lockouts: result.lockoutCount,
            });
          } else {
            totalErrors++;
            functions.logger.error(`❌ Error processing facility ${facilityId}:`, result.error);
          }
        } catch (error: any) {
          totalErrors++;
          functions.logger.error(`❌ Error processing facility ${facilityId}:`, {
            error: error.message,
            stack: error.stack,
          });
        }
      }

      functions.logger.info('✅ Delinquency automation complete:', {
        facilitiesProcessed: facilitiesSnapshot.size,
        totalProcessed,
        totalLateFees,
        totalNotices,
        totalLockouts,
        totalErrors,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in delinquency automation:', {
        error: error.message,
        stack: error.stack,
      });
      throw error;
    }
  });

/**
 * Process delinquency for a single facility
 * This can be called manually or by the scheduled function
 */
async function processDelinquencyForFacility(
  facilityId: string,
  dryRun: boolean = false,
): Promise<{
  success: boolean;
  processedCount?: number;
  lateFeeAppliedCount?: number;
  noticeSentCount?: number;
  lockoutCount?: number;
  errorCount?: number;
  error?: string;
  dryRun?: boolean;
  preview?: {
    tenantsToProcess: number;
    estimatedLateFees: number;
    estimatedNotices: number;
    estimatedLockouts: number;
  };
}> {
  try {
    // Get facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      return { success: false, error: 'Facility not found' };
    }

    const facilityData = facilityDoc.data();
    const billingSettings = facilityData?.billingSettings || {};

    // Get delinquency rules
    const rules = {
      gracePeriodDays: billingSettings.gracePeriodDays || 3,
      baseLateFee: billingSettings.baseLateFee || 25.0,
      dailyLateFee: billingSettings.dailyLateFee || 5.0,
      noticeDays: billingSettings.noticeDays || 7,
      finalNoticeDays: billingSettings.finalNoticeDays || 14,
      lienDays: billingSettings.lienDays || 30,
      lockoutDays: billingSettings.lockoutDays || 45,
      enableAutoLateFees: billingSettings.enableAutoLateFees !== false,
      enableAutoNotices: billingSettings.enableAutoNotices !== false,
      enableAutoLockout: billingSettings.enableAutoLockout === true,
    };

    // Get all active tenants (with safety checks)
    const tenantsSnapshot = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .where('isActive', '==', true)
      .get();

    // Filter out moved-out tenants
    const eligibleTenants = tenantsSnapshot.docs.filter(doc => {
      const data = doc.data();
      // Skip if moved out
      if (data.moveOutDate) {
        return false;
      }
      return true;
    });

    let processedCount = 0;
    let lateFeeAppliedCount = 0;
    let noticeSentCount = 0;
    let lockoutCount = 0;
    let errorCount = 0;
    let estimatedLateFees = 0;
    const estimatedNotices = 0;
    let estimatedLockouts = 0;

    for (const tenantDoc of tenantsSnapshot.docs) {
      try {
        const tenantData = tenantDoc.data();
        const tenantId = tenantDoc.id;

        // Check if tenant is late (simplified check - in production use full logic)
        const paidThrough = tenantData.paidThrough?.toDate();
        const now = new Date();
        const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1);
        const graceBoundary = new Date(startOfMonth);
        graceBoundary.setDate(graceBoundary.getDate() - rules.gracePeriodDays);

        const isLate = !paidThrough || paidThrough < graceBoundary;
        
        if (!isLate) {
          continue; // Skip non-delinquent tenants
        }

        // Calculate days late
        const daysLate = Math.max(0, Math.floor((now.getTime() - graceBoundary.getTime()) / (1000 * 60 * 60 * 24)));

        // Get ledger balance
        const ledgerSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('ledger')
          .get();

        let balance = 0;
        for (const entry of ledgerSnapshot.docs) {
          const entryData = entry.data();
          if (entryData.status === 'posted' || entryData.status === 'pending') {
            if (entryData.type === 'payment' || entryData.type === 'credit') {
              balance -= entryData.amount || 0;
            } else {
              balance += entryData.amount || 0;
            }
          }
        }

        if (balance <= 0) {
          continue; // Balance is paid
        }

        // Apply late fee if needed
        if (rules.enableAutoLateFees && daysLate > rules.gracePeriodDays) {
          const lateFee = rules.baseLateFee + ((daysLate - rules.gracePeriodDays) * rules.dailyLateFee);
          
          // Check if late fee already applied this month
          const thisMonth = new Date(now.getFullYear(), now.getMonth(), 1);
          const lateFeeSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(tenantId)
            .collection('ledger')
            .where('type', '==', 'lateFee')
            .where('status', '==', 'posted')
            .where('entryDate', '>=', admin.firestore.Timestamp.fromDate(thisMonth))
            .get();

          if (lateFeeSnapshot.empty && lateFee > 0) {
            if (dryRun) {
              // In dry-run mode, just count it
              estimatedLateFees += lateFee;
            } else {
              // Create late fee ledger entry
              const ledgerEntryRef = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('ledger')
                .add({
                  type: 'lateFee',
                  amount: lateFee,
                  description: `Late Fee - ${daysLate} days overdue`,
                  entryDate: admin.firestore.FieldValue.serverTimestamp(),
                  dueDate: admin.firestore.FieldValue.serverTimestamp(),
                  status: 'posted',
                  facilityId,
                  tenantId,
                  createdAt: admin.firestore.FieldValue.serverTimestamp(),
                  metadata: {
                    daysOverdue: daysLate,
                    automated: true,
                  },
                });

              // Log audit event
              await writeAuditLog(facilityId, {
                eventType: 'delinquency.lateFeeApplied',
                actorUid: 'system',
                targetType: 'ledgerEntry',
                targetId: ledgerEntryRef.id,
                tenantId,
                after: {
                  amount: lateFee,
                  daysOverdue: daysLate,
                  automated: true,
                },
                metadata: {
                  baseLateFee: rules.baseLateFee,
                  dailyLateFee: rules.dailyLateFee,
                  gracePeriodDays: rules.gracePeriodDays,
                },
              });
            }
            lateFeeAppliedCount++;
          }
        }

        // Send notices if needed
        if (rules.enableAutoNotices) {
          let shouldSendNotice = false;
          let noticeType = '';
          
          if (daysLate >= rules.finalNoticeDays) {
            shouldSendNotice = true;
            noticeType = 'final';
          } else if (daysLate >= rules.noticeDays) {
            shouldSendNotice = true;
            noticeType = 'late';
          }

          if (shouldSendNotice) {
            try {
              // Get tenant contact info for notices
              const tenantEmail = tenantData?.email;
              const tenantPhone = tenantData?.phone;
              const tenantName = tenantData?.name || 'Tenant';
              
              // Check if notice was already sent today
              const today = new Date();
              today.setHours(0, 0, 0, 0);
              const noticesSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('notices')
                .where('type', '==', noticeType)
                .where('sentDate', '>=', admin.firestore.Timestamp.fromDate(today))
                .limit(1)
                .get();

              if (noticesSnapshot.empty) {
                let emailDelinquencyNoticeSent = false;
                // Send email notice
                if (tenantEmail && tenantEmail.trim() !== '') {
                  try {
                    const subject = noticeType === 'final' 
                      ? `Final Notice: Payment Overdue - ${facilityData?.name || 'Storage Facility'}`
                      : `Payment Reminder: Account Past Due - ${facilityData?.name || 'Storage Facility'}`;
                    
                    const emailContent = `
Dear ${tenantName},

This is a ${noticeType === 'final' ? 'FINAL' : ''} notice regarding your overdue payment.

Your account is currently ${daysLate} days overdue with a balance of $${balance.toFixed(2)}.

${noticeType === 'final' ? 'This is your final notice before further action is taken. ' : ''}Please contact us immediately to resolve this matter.

${facilityData?.phone ? `You can reach us at ${facilityData.phone}.` : ''}
${facilityData?.email ? `Or email us at ${facilityData.email}.` : ''}

Thank you,
${facilityData?.name || 'Management Team'}
                    `.trim();

                    const sendResult = await sendFacilityEmailWithCompliance(
                      {
                        to: tenantEmail,
                        from: {
                          email: SENDGRID_FROM_EMAIL.value(),
                          name: facilityData?.name || SENDGRID_FROM_NAME.value(),
                        },
                        subject: subject,
                      },
                      emailContent.replace(/\n/g, '<br>'),
                      emailContent,
                      {
                        facilityId,
                        tenantId,
                        facilityName: facilityData?.name || 'Storage Facility',
                        facilityAddress: facilityData?.address,
                        facilityPhone: facilityData?.phone,
                      },
                    );

                    if (sendResult.sent) {
                      emailDelinquencyNoticeSent = true;
                      await admin.firestore()
                        .collection('facilities')
                        .doc(facilityId)
                        .collection('tenants')
                        .doc(tenantId)
                        .collection('notices')
                        .add({
                          type: noticeType,
                          sentDate: admin.firestore.FieldValue.serverTimestamp(),
                          daysLate: daysLate,
                          balance: balance,
                          method: 'email',
                          recipient: tenantEmail,
                          createdAt: admin.firestore.FieldValue.serverTimestamp(),
                        });
                    } else {
                      functions.logger.info(`Delinquency email skipped (unsubscribed): ${tenantEmail}`);
                    }
                  } catch (emailError: any) {
                    functions.logger.error(`Failed to send email notice to ${tenantEmail}:`, emailError);
                  }
                }

                // Send SMS notice if phone available
                if (tenantPhone && tenantPhone.trim() !== '') {
                  try {
                    const smsMessage = noticeType === 'final'
                      ? `FINAL NOTICE: Your account is ${daysLate} days overdue. Balance: $${balance.toFixed(2)}. Contact us immediately.`
                      : `Payment reminder: Your account is ${daysLate} days overdue. Balance: $${balance.toFixed(2)}. Please make a payment.`;
                    
                    // Note: SMS sending would require Twilio integration
                    // For now, we log it - implement actual SMS sending if needed
                    functions.logger.info(`SMS notice would be sent to ${tenantPhone}: ${smsMessage}`);
                  } catch (smsError: any) {
                    functions.logger.error(`Failed to send SMS notice to ${tenantPhone}:`, smsError);
                  }
                }

                if (emailDelinquencyNoticeSent) {
                  noticeSentCount++;
                }
              }
            } catch (noticeError: any) {
              functions.logger.error(`Error sending notice to tenant ${tenantId}:`, noticeError);
            }
          }
        }

        // Update tenant delinquency status
        let delinquencyStatus = '';
        if (daysLate >= rules.lockoutDays) {
          delinquencyStatus = 'lockout';
        } else if (daysLate >= rules.lienDays) {
          delinquencyStatus = 'lien';
        } else if (daysLate >= rules.finalNoticeDays) {
          delinquencyStatus = 'final_notice';
        } else if (daysLate >= rules.noticeDays) {
          delinquencyStatus = 'late';
        }

        if (delinquencyStatus) {
          await tenantDoc.ref.update({
            delinquencyStatus: delinquencyStatus,
            lastLateFeeDate: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          // Set lien eligible date if applicable
          if (daysLate >= rules.lienDays) {
            const lienEligibleDate = new Date(now);
            lienEligibleDate.setDate(lienEligibleDate.getDate() - rules.lienDays);
            await tenantDoc.ref.update({
              lienEligibleDate: admin.firestore.Timestamp.fromDate(lienEligibleDate),
            });
          }
        }

        // Trigger lockout if needed
        if (rules.enableAutoLockout && daysLate >= rules.lockoutDays) {
          // Disable gate access
          const gateAccessSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('gateAccess')
            .where('tenantId', '==', tenantId)
            .where('isActive', '==', true)
            .get();

          const deactivatedAccessIds: string[] = [];
          
          if (dryRun) {
            // In dry-run mode, just count it
            estimatedLockouts++;
            deactivatedAccessIds.push(...gateAccessSnapshot.docs.map(doc => doc.id));
          } else {
            // Actually disable gate access
            for (const accessDoc of gateAccessSnapshot.docs) {
              await accessDoc.ref.update({
                isActive: false,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                notes: `Gate access disabled due to delinquency (${daysLate} days overdue)`,
              });
              deactivatedAccessIds.push(accessDoc.id);
            }

            // Log audit event if lockout was triggered
            if (deactivatedAccessIds.length > 0) {
              await writeAuditLog(facilityId, {
                eventType: 'delinquency.lockoutTriggered',
                actorUid: 'system',
                targetType: 'tenant',
                targetId: tenantId,
                tenantId,
                after: {
                  lockoutStatus: 'locked',
                  daysLate,
                },
                metadata: {
                  automated: true,
                  deactivatedAccessIds,
                },
              });
            }
          }

          lockoutCount++;
        }

        processedCount++;
      } catch (error: any) {
        errorCount++;
        functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
      }
    }

    return {
      success: true,
      processedCount,
      lateFeeAppliedCount,
      noticeSentCount,
      lockoutCount,
      errorCount,
      dryRun,
      ...(dryRun ? {
        preview: {
          tenantsToProcess: processedCount,
          estimatedLateFees,
          estimatedNotices,
          estimatedLockouts,
        },
      } : {}),
    };
  } catch (error: any) {
    return {
      success: false,
      error: error.message,
    };
  }
}
