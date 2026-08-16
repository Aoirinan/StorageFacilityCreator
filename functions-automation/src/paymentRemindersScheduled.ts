import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { initializeSendGrid, sendFacilityEmailWithCompliance } from '@sfc/functions-shared';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

/**
 * Scheduled function: Payment Reminders
 * Sends payment reminders to tenants 3 days before their due date
 * Runs daily at 9:00 AM UTC
 */
// Walks facilities -> tenants -> ledgers sequentially. One facility with no
// reminders due already took ~1s, so the gen-1 default 60s timeout would be
// exhausted at roughly sixty facilities — and a timed-out scheduler dies with
// no checkpoint, silently skipping every facility after the cut-off. 540s is
// the gen-1 maximum; past a few hundred facilities this needs the same
// per-facility fan-out as processAutopayPayments.
export const processPaymentReminders = functions
  .runWith({ secrets: SENDGRID_SECRETS, timeoutSeconds: 540, memory: '512MB' })
  .pubsub
  .schedule('0 9 * * *') // Daily at 9:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Payment Reminder processing...');

    try {
      initializeSendGrid();

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalRemindersSent = 0;
      const now = new Date();
      const threeDaysFromNow = new Date(now);
      threeDaysFromNow.setDate(threeDaysFromNow.getDate() + 3);

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if payment reminders are enabled (default to true if not set)
          const remindersEnabled = facilityData?.billingSettings?.enablePaymentReminders !== false;

          if (!remindersEnabled) {
            functions.logger.info(`Payment reminders disabled for facility ${facilityId}`);
            continue;
          }

          // Get reminder days setting (default to 3)
          const reminderDays = facilityData?.billingSettings?.paymentReminderDays || 3;

          // Calculate target due date
          const targetDueDate = new Date(now);
          targetDueDate.setDate(targetDueDate.getDate() + reminderDays);

          // Get all active tenants
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .get();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;

              // Calculate next due date based on paidThrough
              const paidThrough = tenantData.paidThrough?.toDate();
              if (!paidThrough) continue; // Skip if never paid

              // Next due date is first day of month after paidThrough
              let nextDueDate: Date;
              if (paidThrough.getMonth() === 11) {
                nextDueDate = new Date(paidThrough.getFullYear() + 1, 0, 1);
              } else {
                nextDueDate = new Date(paidThrough.getFullYear(), paidThrough.getMonth() + 1, 1);
              }

              // Check if due date matches target (within 1 day window for safety)
              const daysUntilDue = Math.floor((nextDueDate.getTime() - now.getTime()) / (1000 * 60 * 60 * 24));
              
              if (daysUntilDue !== reminderDays) {
                continue; // Not the right day to send reminder
              }

              // Get ledger balance to check if already paid
              const ledgerSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .where('tenantId', '==', tenantId)
                .where('status', '==', 'posted')
                .get();

              let balance = 0;
              for (const entryDoc of ledgerSnapshot.docs) {
                const entryData = entryDoc.data();
                balance += entryData.amount || 0;
              }

              // Skip if already paid (negative or zero balance means paid)
              if (balance <= 0) {
                continue;
              }

              // Check if we already sent a reminder for this due date
              // We'll track this by storing lastReminderSentDate on the tenant
              const lastReminderDate = tenantData.lastPaymentReminderDate?.toDate();
              const shouldSendReminder = !lastReminderDate || 
                lastReminderDate.getTime() < (now.getTime() - (24 * 60 * 60 * 1000)); // At least 24 hours since last reminder

              if (!shouldSendReminder) {
                continue;
              }

              // Get monthly rate for the reminder message
              const monthlyRate = tenantData.monthlyRate || 0;

              // Send email reminder
              const reminderTo = tenantData.email && String(tenantData.email).trim();
              if (!reminderTo) {
                continue;
              }
              try {
                const emailHtml = `
                  <h2>Payment Reminder</h2>
                  <p>Dear ${tenantData.name},</p>
                  <p>This is a friendly reminder that your payment of \$${monthlyRate.toFixed(2)} is due in ${reminderDays} days (${nextDueDate.toLocaleDateString()}).</p>
                  <p><strong>Current Balance:</strong> \$${balance.toFixed(2)}</p>
                  <p>Please ensure payment is received by the due date to avoid late fees.</p>
                  <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                  ${facilityData.phone ? `<p>Phone: ${facilityData.phone}</p>` : ''}
                `;

                const reminderSend = await sendFacilityEmailWithCompliance(
                  {
                    to: reminderTo,
                    from: {
                      email: SENDGRID_FROM_EMAIL.value(),
                      name: facilityData?.name || SENDGRID_FROM_NAME.value(),
                    },
                    subject: `Payment Reminder - Due ${nextDueDate.toLocaleDateString()}`,
                  },
                  emailHtml,
                  null,
                  {
                    facilityId,
                    tenantId,
                    facilityName: facilityData?.name || 'Storage Facility',
                    facilityAddress: facilityData?.address,
                    facilityPhone: facilityData?.phone,
                  },
                );

                if (reminderSend.sent) {
                  await tenantDoc.ref.update({
                    lastPaymentReminderDate: admin.firestore.FieldValue.serverTimestamp(),
                  });
                  totalRemindersSent++;
                  functions.logger.info(`Payment reminder sent to ${reminderTo} (tenant: ${tenantId})`);
                } else {
                  functions.logger.info(`Payment reminder skipped (unsubscribed): ${reminderTo}`);
                }
              } catch (emailError: any) {
                functions.logger.error(`Error sending payment reminder to ${reminderTo}: ${emailError.message}`);
              }
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id} for reminders:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId} for reminders:`, error);
        }
      }

      functions.logger.info(`✅ Payment Reminder processing complete: ${totalRemindersSent} reminders sent`);
      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Payment Reminder processing:', error);
      throw error;
    }
  });
