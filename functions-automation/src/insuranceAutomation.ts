import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  initializeSendGrid,
  sendFacilityEmailWithCompliance,
} from '@sfc/functions-shared';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

/**
 * Scheduled function: Auto-Protect Move-In
 * Runs daily to check new move-ins and auto-enroll tenants in TPP after 14 days if no insurance proof
 * Scheduled to run at 4:00 AM UTC daily
 */
export const autoProtectMoveIn = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 4 * * *') // Daily at 4:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Auto-Protect Move-In processing...');

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

      let totalProcessed = 0;
      let totalEnrolled = 0;
      const fourteenDaysAgo = new Date();
      fourteenDaysAgo.setDate(fourteenDaysAgo.getDate() - 14);

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if Auto-Protect Move-In is enabled for this facility
          const autoProtectEnabled = facilityData?.insuranceSettings?.autoProtectMoveIn;
          if (!autoProtectEnabled) {
            functions.logger.info(`Auto-Protect Move-In disabled for facility ${facilityId}`);
            continue;
          }

          // Get default TPP settings
          const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
          const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
          const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;

          // Get all tenants created around 14 days ago (within a 2-day window)
          const startDate = new Date(fourteenDaysAgo);
          startDate.setHours(0, 0, 0, 0);
          const endDate = new Date(fourteenDaysAgo);
          endDate.setDate(endDate.getDate() + 1);
          endDate.setHours(23, 59, 59, 999);

          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .where('createdAt', '>=', admin.firestore.Timestamp.fromDate(startDate))
            .where('createdAt', '<=', admin.firestore.Timestamp.fromDate(endDate))
            .get();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;

              // Check insurance status - only enroll if status is 'none' or 'pendingProof'
              const insuranceStatus = tenantData.insuranceStatus;
              if (insuranceStatus !== 'none' && insuranceStatus !== 'pendingProof') {
                continue; // Tenant already has insurance or is enrolled
              }

              totalProcessed++;

              // Auto-enroll in TPP
              await tenantDoc.ref.update({
                insuranceStatus: 'autoEnrolled',
                tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
                tppCoverageLevel: defaultCoverage,
                coverageAmount: defaultCoverageAmount,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              });

              // Create ledger entry for TPP fee (prorated for remaining days in month)
              const now = new Date();
              const daysInMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
              const remainingDays = daysInMonth - now.getDate() + 1;
              const proratedFee = (monthlyFee / daysInMonth) * remainingDays;

              await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .add({
                  tenantId: tenantId,
                  facilityId: facilityId,
                  type: 'insuranceCharge',
                  amount: proratedFee,
                  description: `Tenant Protection Plan (Auto-Enrolled) - Prorated for ${remainingDays} days`,
                  entryDate: admin.firestore.FieldValue.serverTimestamp(),
                  status: 'posted',
                  metadata: {
                    tppEnrollment: true,
                    autoEnrolled: true,
                    coverageLevel: defaultCoverage,
                    proratedDays: remainingDays,
                  },
                  createdAt: admin.firestore.FieldValue.serverTimestamp(),
                  createdBy: 'system',
                });

              totalEnrolled++;

              // Send email notification to tenant
              const enrollEmail = tenantData.email && String(tenantData.email).trim();
              if (enrollEmail) {
                try {
                  const emailHtml = `
                  <h2>Tenant Protection Plan Enrollment</h2>
                  <p>Dear ${tenantData.name},</p>
                  <p>You have been automatically enrolled in our Tenant Protection Plan (TPP) as you have not provided proof of your own insurance coverage within the 14-day grace period.</p>
                  <p><strong>Coverage Details:</strong></p>
                  <ul>
                    <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                    <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                    <li>Prorated Fee (this month): $${proratedFee.toFixed(2)}</li>
                  </ul>
                  <p>If you have your own insurance policy, please provide proof to our facility manager to have this enrollment removed.</p>
                  <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                `;

                  const sendResult = await sendFacilityEmailWithCompliance(
                    {
                      to: enrollEmail,
                      from: {
                        email: SENDGRID_FROM_EMAIL.value(),
                        name: facilityData?.name || SENDGRID_FROM_NAME.value(),
                      },
                      subject: 'Tenant Protection Plan Enrollment Notification',
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
                  if (sendResult.sent) {
                    functions.logger.info(`Auto-enrollment email sent to ${enrollEmail}`);
                  } else {
                    functions.logger.info(`Auto-enrollment email skipped (unsubscribed): ${enrollEmail}`);
                  }
                } catch (emailError: any) {
                  functions.logger.error(`Error sending auto-enrollment email: ${emailError.message}`);
                }
              }

              functions.logger.info(`Auto-enrolled tenant ${tenantId} in TPP`);
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info('✅ Auto-Protect Move-In complete:', {
        totalProcessed,
        totalEnrolled,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Auto-Protect Move-In:', error);
      throw error;
    }
  });

/**
 * Scheduled function: Auto-Protect Audit
 * Runs monthly to audit existing tenants and notify/enroll them in TPP if no insurance
 * Scheduled to run on the 1st of each month at 5:00 AM UTC
 */
export const autoProtectAudit = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 5 1 * *') // 1st of each month at 5:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Auto-Protect Audit processing...');

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

      let totalNotified = 0;
      let totalEnrolled = 0;

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if Auto-Protect Audit is enabled
          const autoProtectAuditEnabled = facilityData?.insuranceSettings?.autoProtectAudit;
          if (!autoProtectAuditEnabled) {
            functions.logger.info(`Auto-Protect Audit disabled for facility ${facilityId}`);
            continue;
          }

          const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
          const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
          const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;
          const gracePeriodDays = facilityData?.insuranceSettings?.auditGracePeriodDays || 45;

          // Get tenants with no insurance or pending proof
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .where('insuranceStatus', 'in', ['none', 'pendingProof'])
            .get();

          const now = new Date();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;
              const insuranceNotifiedDate = tenantData.insuranceNotifiedDate?.toDate();

              if (!insuranceNotifiedDate) {
                // First notification — persist insuranceNotifiedDate only after a successful send
                const firstNoticeEmail = tenantData.email && String(tenantData.email).trim();
                if (!firstNoticeEmail) {
                  functions.logger.warn(`Auto-Protect Audit: no email for tenant ${tenantId}, skipping first notice`);
                } else {
                  try {
                    const emailHtml = `
                    <h2>Insurance Requirement Notice</h2>
                    <p>Dear ${tenantData.name},</p>
                    <p>Our facility now requires all tenants to have insurance coverage for their stored items. You currently do not have proof of insurance on file.</p>
                    <p>You have ${gracePeriodDays} days to provide proof of your own insurance policy. If proof is not provided by ${new Date(now.getTime() + gracePeriodDays * 24 * 60 * 60 * 1000).toLocaleDateString()}, you will be automatically enrolled in our Tenant Protection Plan.</p>
                    <p>Please contact our facility manager to provide your insurance documentation.</p>
                    <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                  `;

                    const sendResult = await sendFacilityEmailWithCompliance(
                      {
                        to: firstNoticeEmail,
                        from: {
                          email: SENDGRID_FROM_EMAIL.value(),
                          name: facilityData?.name || SENDGRID_FROM_NAME.value(),
                        },
                        subject: 'Insurance Requirement Notice',
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

                    if (sendResult.sent) {
                      await tenantDoc.ref.update({
                        insuranceNotifiedDate: admin.firestore.FieldValue.serverTimestamp(),
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                      });
                      totalNotified++;
                      functions.logger.info(`First notification sent to ${firstNoticeEmail}`);
                    } else {
                      functions.logger.info(`First insurance notice skipped (unsubscribed): ${firstNoticeEmail}`);
                    }
                  } catch (emailError: any) {
                    functions.logger.error(`Error sending first notification: ${emailError.message}`);
                  }
                }
              } else {
                // Check if grace period has passed
                const daysSinceNotification = Math.floor((now.getTime() - insuranceNotifiedDate.getTime()) / (1000 * 60 * 60 * 24));

                if (daysSinceNotification >= gracePeriodDays && tenantData.insuranceStatus !== 'enrolledInTPP' && tenantData.insuranceStatus !== 'autoEnrolled') {
                  // Grace period expired - auto-enroll
                  await tenantDoc.ref.update({
                    insuranceStatus: 'autoEnrolled',
                    tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
                    tppCoverageLevel: defaultCoverage,
                    coverageAmount: defaultCoverageAmount,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                  });

                  // Create ledger entry for TPP fee
                  await admin.firestore()
                    .collection('facilities')
                    .doc(facilityId)
                    .collection('ledgers')
                    .add({
                      tenantId: tenantId,
                      facilityId: facilityId,
                      type: 'insuranceCharge',
                      amount: monthlyFee,
                      description: `Tenant Protection Plan (Auto-Enrolled)`,
                      entryDate: admin.firestore.FieldValue.serverTimestamp(),
                      status: 'posted',
                      metadata: {
                        tppEnrollment: true,
                        autoEnrolled: true,
                        coverageLevel: defaultCoverage,
                      },
                      createdAt: admin.firestore.FieldValue.serverTimestamp(),
                      createdBy: 'system',
                    });

                  totalEnrolled++;

                  // Send enrollment notification
                  const auditEnrollEmail = tenantData.email && String(tenantData.email).trim();
                  if (auditEnrollEmail) {
                    try {
                      const emailHtml = `
                      <h2>Tenant Protection Plan Auto-Enrollment</h2>
                      <p>Dear ${tenantData.name},</p>
                      <p>You have been automatically enrolled in our Tenant Protection Plan as proof of insurance was not provided within the ${gracePeriodDays}-day grace period.</p>
                      <p><strong>Coverage Details:</strong></p>
                      <ul>
                        <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                        <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                      </ul>
                      <p>If you have your own insurance policy, please provide proof to have this enrollment removed.</p>
                      <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                    `;

                      const sendResult = await sendFacilityEmailWithCompliance(
                        {
                          to: auditEnrollEmail,
                          from: {
                            email: SENDGRID_FROM_EMAIL.value(),
                            name: facilityData?.name || SENDGRID_FROM_NAME.value(),
                          },
                          subject: 'Tenant Protection Plan Auto-Enrollment',
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
                      if (sendResult.sent) {
                        functions.logger.info(`Auto-enrollment email sent to ${auditEnrollEmail}`);
                      } else {
                        functions.logger.info(`Auto-enrollment email skipped (unsubscribed): ${auditEnrollEmail}`);
                      }
                    } catch (emailError: any) {
                      functions.logger.error(`Error sending auto-enrollment email: ${emailError.message}`);
                    }
                  }
                }
              }
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info('✅ Auto-Protect Audit complete:', {
        totalNotified,
        totalEnrolled,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Auto-Protect Audit:', error);
      throw error;
    }
  });

/**
 * Scheduled function: Check Insurance Compliance (daily)
 * Runs daily to check if tenants who were notified have passed the grace period
 * Scheduled to run at 4:30 AM UTC daily (after Auto-Protect Move-In)
 */
export const checkInsuranceCompliance = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('30 4 * * *') // Daily at 4:30 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Insurance Compliance check...');

    try {
      initializeSendGrid();

      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        return null;
      }

      let totalEnrolled = 0;
      const now = new Date();

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        const autoProtectAuditEnabled = facilityData?.insuranceSettings?.autoProtectAudit;
        if (!autoProtectAuditEnabled) continue;

        const gracePeriodDays = facilityData?.insuranceSettings?.auditGracePeriodDays || 45;
        const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
        const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
        const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;

        const cutoffDate = new Date(now);
        cutoffDate.setDate(cutoffDate.getDate() - gracePeriodDays);

        const tenantsSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('isActive', '==', true)
          .where('insuranceNotifiedDate', '<=', admin.firestore.Timestamp.fromDate(cutoffDate))
          .where('insuranceStatus', 'in', ['none', 'pendingProof'])
          .get();

        for (const tenantDoc of tenantsSnapshot.docs) {
          try {
            const tenantData = tenantDoc.data();
            const tenantId = tenantDoc.id;

            // Auto-enroll
            await tenantDoc.ref.update({
              insuranceStatus: 'autoEnrolled',
              tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
              tppCoverageLevel: defaultCoverage,
              coverageAmount: defaultCoverageAmount,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            await admin.firestore()
              .collection('facilities')
              .doc(facilityId)
              .collection('ledgers')
              .add({
                tenantId: tenantId,
                facilityId: facilityId,
                type: 'insuranceCharge',
                amount: monthlyFee,
                description: `Tenant Protection Plan (Auto-Enrolled)`,
                entryDate: admin.firestore.FieldValue.serverTimestamp(),
                status: 'posted',
                metadata: {
                  tppEnrollment: true,
                  autoEnrolled: true,
                  coverageLevel: defaultCoverage,
                },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                createdBy: 'system',
              });

            totalEnrolled++;

            // Send enrollment email (same as in autoProtectAudit)
            const complianceEnrollEmail = tenantData.email && String(tenantData.email).trim();
            if (complianceEnrollEmail) {
              try {
                const emailHtml = `
                <h2>Tenant Protection Plan Auto-Enrollment</h2>
                <p>Dear ${tenantData.name},</p>
                <p>You have been automatically enrolled in our Tenant Protection Plan as proof of insurance was not provided within the ${gracePeriodDays}-day grace period.</p>
                <p><strong>Coverage Details:</strong></p>
                <ul>
                  <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                  <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                </ul>
                <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
              `;

                const sendResult = await sendFacilityEmailWithCompliance(
                  {
                    to: complianceEnrollEmail,
                    from: {
                      email: SENDGRID_FROM_EMAIL.value(),
                      name: facilityData?.name || SENDGRID_FROM_NAME.value(),
                    },
                    subject: 'Tenant Protection Plan Auto-Enrollment',
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
                if (!sendResult.sent) {
                  functions.logger.info(`Compliance enrollment email skipped (unsubscribed): ${complianceEnrollEmail}`);
                }
              } catch (emailError: any) {
                functions.logger.error(`Error sending enrollment email: ${emailError.message}`);
              }
            }
          } catch (error: any) {
            functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
          }
        }
      }

      functions.logger.info(`✅ Insurance Compliance check complete: ${totalEnrolled} tenants enrolled`);
      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Insurance Compliance check:', error);
      throw error;
    }
  });
