import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getStripeClient } from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import {
  calculateNextAutopayRun,
  isAutopayDue,
  isFacilityChargeReady,
  resolveChargeAmount,
  shouldAttemptCharge,
  sumLedgerBalance,
} from './autopayScheduledHelpers';

export const processAutopayPayments = functions.runWith({ secrets: STRIPE_SECRETS }).pubsub
  .schedule('0 2 * * *') // Daily at 2:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    try {
      functions.logger.info('Starting scheduled autopay processing');

      // Get all facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      functions.logger.info(`Found ${facilitiesSnapshot.size} active facilities`);

      const results = [];

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        try {
          const facilityData = facilityDoc.data();
          const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

          if (!isFacilityChargeReady(facilityData)) {
            functions.logger.warn(
              `Skipping autopay for facility ${facilityId}: Stripe Connect not ready ` +
                `(connectAccountId=${!!connectAccountId}, ` +
                `chargesEnabled=${!!facilityData?.stripeStatus?.chargesEnabled})`,
            );
            continue;
          }

          // Get all tenants with autopay enabled
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

              // Get payment methods for this tenant
              const paymentMethodsSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('paymentMethods')
                .where('tenantId', '==', tenantId)
                .where('autopayEnabled', '==', true)
                .where('isActive', '==', true)
                .get();

              for (const methodDoc of paymentMethodsSnapshot.docs) {
                try {
                  const methodData = methodDoc.data();
                  const autopaySchedule = methodData.autopaySchedule;
                  
                  if (!autopaySchedule) continue;

                  const nextRun = autopaySchedule.autopayNextRun?.toDate();
                  const now = new Date();

                  // Check if autopay is due
                  if (isAutopayDue(nextRun, now)) {
                    // Get ledger balance
                    const ledgerSnapshot = await admin.firestore()
                      .collection('facilities')
                      .doc(facilityId)
                      .collection('ledgers')
                      .where('tenantId', '==', tenantId)
                      .where('status', '==', 'posted')
                      .get();

                    const balance = sumLedgerBalance(
                      ledgerSnapshot.docs.map((entryDoc) => entryDoc.data()),
                    );

                    const amount = resolveChargeAmount(
                      balance,
                      autopaySchedule,
                      facilityData,
                    );

                    if (shouldAttemptCharge(amount, methodData.stripePaymentMethodId)) {
                      // Process payment via Stripe
                      const stripe = getStripeClient();
                      
                      const paymentIntent = await stripe.paymentIntents.create({
                        amount: Math.round(amount * 100),
                        currency: 'usd',
                        payment_method: methodData.stripePaymentMethodId,
                        customer: methodData.stripeCustomerId,
                        confirmation_method: 'automatic',
                        confirm: true,
                        description: `Autopay - ${tenantData.name}`,
                        metadata: {
                          facilityId,
                          tenantId,
                          paymentMethodId: methodDoc.id,
                          autopay: 'true',
                        },
                      }, {
                        stripeAccount: connectAccountId, // Charge on the facility's connected account, not the platform account
                      });

                      if (paymentIntent.status === 'succeeded') {
                        // Create payment ledger entry
                        const paymentEntryRef = admin.firestore()
                          .collection('facilities')
                          .doc(facilityId)
                          .collection('ledgers')
                          .doc();

                        await paymentEntryRef.set({
                          tenantId: tenantId,
                          facilityId: facilityId,
                          type: 'payment',
                          amount: -amount,
                          description: `Autopay Payment - ${paymentIntent.id}`,
                          referenceId: paymentIntent.id,
                          entryDate: admin.firestore.FieldValue.serverTimestamp(),
                          status: 'posted',
                          metadata: {
                            paymentMethod: 'stripe',
                            autopay: true,
                            paymentIntentId: paymentIntent.id,
                          },
                          createdAt: admin.firestore.FieldValue.serverTimestamp(),
                          createdBy: 'system',
                        });

                        // Update payment method last run
                        await methodDoc.ref.update({
                          'autopayLastRun': admin.firestore.FieldValue.serverTimestamp(),
                          'autopayLastResult': 'success',
                          'autopayNextRun': admin.firestore.Timestamp.fromDate(
                            calculateNextAutopayRun(autopaySchedule, new Date()),
                          ),
                        });

                        // Audit log
                        await admin.firestore()
                          .collection('facilities')
                          .doc(facilityId)
                          .collection('auditLogs')
                          .add({
                            action: 'autopay.processed',
                            actorUid: 'system',
                            actorEmail: 'system@scheduled-job',
                            targetId: paymentEntryRef.id,
                            entityType: 'payment',
                            entityId: paymentEntryRef.id,
                            tenantId: tenantId,
                            details: {
                              amount: amount,
                              paymentIntentId: paymentIntent.id,
                              scheduled: true,
                            },
                            at: admin.firestore.FieldValue.serverTimestamp(),
                          });

                        results.push({
                          facilityId,
                          tenantId,
                          success: true,
                          amount,
                        });

                        functions.logger.info(`Autopay processed: ${tenantData.name} - $${amount}`);
                      }
                    }
                  }
                } catch (error: any) {
                  functions.logger.error(`Error processing autopay for payment method ${methodDoc.id}:`, error);
                  // Update payment method with error
                  await methodDoc.ref.update({
                    'autopayLastRun': admin.firestore.FieldValue.serverTimestamp(),
                    'autopayLastResult': 'failed',
                    'autopayLastError': error.message,
                  });
                }
              }
            } catch (error: any) {
              functions.logger.error(`Error processing autopay for tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info(`Scheduled autopay processing completed: ${results.length} payments processed`);
      return { results };
    } catch (error: any) {
      functions.logger.error('Error in scheduled autopay processing:', error);
      throw error;
    }
  });

// Next-run scheduling now lives in ./autopayScheduledHelpers (calculateNextAutopayRun)
// so it can be unit-tested. The previous inline version computed weekly runs with
// (dayOfWeek - now.getDay()) % 7, which is negative when the target weekday is
// earlier in the week than today — scheduling the next run in the past and letting
// the following night's cron charge the tenant again.
