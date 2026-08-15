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
import {
  AUTOPAY_JOBS_COLLECTION,
  autopayJobId,
  autopayRunDate,
  canClaimAutopayJob,
  chunkForBatchedWrites,
} from './autopayJobHelpers';

/**
 * Nightly autopay, fanned out one job per facility.
 *
 * This used to be a single invocation that walked every facility and every
 * tenant. That is sequential O(facilities x tenants) work against a 60s gen-1
 * timeout — one real facility with ~70 tenants already took 5-7s, so it ran out
 * of budget at roughly eight facilities, and a timed-out scheduler dies with no
 * checkpoint. Facilities late in the iteration order would silently never be
 * charged, night after night.
 *
 * `processAutopayPayments` now only enqueues work; `processFacilityAutopayJob`
 * charges a single facility per invocation.
 */
export const processAutopayPayments = functions
  .runWith({ timeoutSeconds: 300, memory: '256MB' })
  .pubsub.schedule('0 2 * * *') // Daily at 2:00 AM UTC
  .timeZone('UTC')
  .onRun(async () => {
    try {
      const runDate = autopayRunDate(new Date());
      functions.logger.info(`Enqueuing autopay jobs for run ${runDate}`);

      const facilitiesSnapshot = await admin
        .firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      const facilityIds = facilitiesSnapshot.docs.map((doc) => doc.id);
      functions.logger.info(`Found ${facilityIds.length} active facilities`);

      let enqueued = 0;
      // Batched writes cap at 500, so a thousand-facility fan-out needs chunking.
      for (const chunk of chunkForBatchedWrites(facilityIds)) {
        const batch = admin.firestore().batch();
        for (const facilityId of chunk) {
          const ref = admin
            .firestore()
            .collection(AUTOPAY_JOBS_COLLECTION)
            .doc(autopayJobId(runDate, facilityId));
          // Deterministic id + create() means a second scheduler run on the same
          // day cannot enqueue a duplicate charge run for a facility.
          batch.create(ref, {
            facilityId,
            runDate,
            status: 'pending',
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        try {
          await batch.commit();
          enqueued += chunk.length;
        } catch (error: any) {
          // ALREADY_EXISTS means this run was already enqueued — not an error.
          functions.logger.warn(
            `Autopay job batch for ${runDate} partially or fully already existed: ${error?.message}`,
          );
        }
      }

      functions.logger.info(`Autopay fan-out complete for ${runDate}: ${enqueued} job(s) enqueued`);
      return { runDate, enqueued };
    } catch (error: any) {
      functions.logger.error('Error enqueuing autopay jobs:', error);
      throw error;
    }
  });

/**
 * Charges one facility's due autopay schedules.
 *
 * Firestore triggers are at-least-once, so the job is claimed transactionally
 * (pending -> processing) before any money moves; a redelivered event finds the
 * job already claimed and exits.
 */
export const processFacilityAutopayJob = functions
  .runWith({ secrets: STRIPE_SECRETS, timeoutSeconds: 540, memory: '512MB' })
  .firestore.document(`${AUTOPAY_JOBS_COLLECTION}/{jobId}`)
  .onCreate(async (snapshot) => {
    const jobRef = snapshot.ref;
    const facilityId = snapshot.data()?.facilityId as string | undefined;

    if (!facilityId) {
      functions.logger.error(`Autopay job ${snapshot.id} has no facilityId; marking failed`);
      await jobRef.update({ status: 'failed', error: 'missing facilityId' });
      return;
    }

    // Claim the job so a redelivered event cannot start a second charge run.
    const claimed = await admin.firestore().runTransaction(async (tx) => {
      const fresh = await tx.get(jobRef);
      if (!canClaimAutopayJob(fresh.data())) return false;
      tx.update(jobRef, {
        status: 'processing',
        startedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return true;
    });

    if (!claimed) {
      functions.logger.info(`Autopay job ${snapshot.id} already claimed; skipping`);
      return;
    }

    try {
      const processed = await chargeFacilityAutopay(facilityId);
      await jobRef.update({
        status: 'completed',
        paymentsProcessed: processed,
        finishedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info(
        `Autopay job ${snapshot.id} completed: ${processed} payment(s) for facility ${facilityId}`,
      );
    } catch (error: any) {
      functions.logger.error(`Autopay job ${snapshot.id} failed for facility ${facilityId}:`, error);
      await jobRef.update({
        status: 'failed',
        error: String(error?.message ?? error),
        finishedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      throw error;
    }
  });

/**
 * Charge every due autopay schedule for a single facility.
 * Returns the number of successful payments.
 */
async function chargeFacilityAutopay(facilityId: string): Promise<number> {
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  const facilityData = facilityDoc.data();
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

  if (!isFacilityChargeReady(facilityData)) {
    functions.logger.warn(
      `Skipping autopay for facility ${facilityId}: Stripe Connect not ready ` +
        `(connectAccountId=${!!connectAccountId}, ` +
        `chargesEnabled=${!!facilityData?.stripeStatus?.chargesEnabled})`,
    );
    return 0;
  }

  const tenantsSnapshot = await admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .where('isActive', '==', true)
    .get();

  let processed = 0;

  for (const tenantDoc of tenantsSnapshot.docs) {
    try {
      const tenantData = tenantDoc.data();
      const tenantId = tenantDoc.id;

      const paymentMethodsSnapshot = await admin
        .firestore()
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
          if (!isAutopayDue(nextRun, new Date())) continue;

          const ledgerSnapshot = await admin
            .firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('ledgers')
            .where('tenantId', '==', tenantId)
            .where('status', '==', 'posted')
            .get();

          const balance = sumLedgerBalance(ledgerSnapshot.docs.map((entry) => entry.data()));
          const amount = resolveChargeAmount(balance, autopaySchedule, facilityData);

          if (!shouldAttemptCharge(amount, methodData.stripePaymentMethodId)) continue;

          const stripe = getStripeClient();
          const paymentIntent = await stripe.paymentIntents.create(
            {
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
            },
            {
              // Charge on the facility's connected account, not the platform account.
              stripeAccount: connectAccountId,
            },
          );

          if (paymentIntent.status !== 'succeeded') continue;

          const paymentEntryRef = admin
            .firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('ledgers')
            .doc();

          await paymentEntryRef.set({
            tenantId,
            facilityId,
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

          // Advancing next-run is also what stops a retry re-charging this tenant.
          await methodDoc.ref.update({
            autopayLastRun: admin.firestore.FieldValue.serverTimestamp(),
            autopayLastResult: 'success',
            autopayNextRun: admin.firestore.Timestamp.fromDate(
              calculateNextAutopayRun(autopaySchedule, new Date()),
            ),
          });

          await admin
            .firestore()
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
              tenantId,
              details: {
                amount,
                paymentIntentId: paymentIntent.id,
                scheduled: true,
              },
              at: admin.firestore.FieldValue.serverTimestamp(),
            });

          processed += 1;
          functions.logger.info(`Autopay processed: ${tenantData.name} - $${amount}`);
        } catch (error: any) {
          functions.logger.error(
            `Error processing autopay for payment method ${methodDoc.id}:`,
            error,
          );
          await methodDoc.ref.update({
            autopayLastRun: admin.firestore.FieldValue.serverTimestamp(),
            autopayLastResult: 'failed',
            autopayLastError: error?.message ?? String(error),
          });
        }
      }
    } catch (error: any) {
      functions.logger.error(`Error processing autopay for tenant ${tenantDoc.id}:`, error);
    }
  }

  return processed;
}
