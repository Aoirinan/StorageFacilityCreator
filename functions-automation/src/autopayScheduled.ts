import * as functions from 'firebase-functions/v1';
import { resolveAutopayFailureOutcome } from './autopayFailureHelpers';
import { autopayIdempotencyKey, hasLedgerEntryForPayment } from './autopayIdempotency';
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

  // Payment methods live at facilities/{id}/tenants/{tid}/paymentMethods — that
  // is where every attach flow writes them. A collection-group query pulls this
  // facility's armed cards in one round trip instead of one query per tenant,
  // which matters for facilities with thousands of tenants.
  const methodsSnapshot = await admin
    .firestore()
    .collectionGroup('paymentMethods')
    .where('facilityId', '==', facilityId)
    .where('autopayEnabled', '==', true)
    .where('isActive', '==', true)
    .get();

  let processed = 0;

  for (const methodDoc of methodsSnapshot.docs) {
    try {
      const methodData = methodDoc.data();
      const tenantId = methodData.tenantId as string | undefined;
      if (!tenantId) {
        functions.logger.warn(`Payment method ${methodDoc.id} has no tenantId; skipping`);
        continue;
      }

      // The card carries no tenant status, so confirm the tenant is still active
      // before charging — a moved-out tenant must not keep getting billed.
      const tenantDoc = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .get();

      const tenantData = tenantDoc.data();
      if (!tenantDoc.exists || tenantData?.isActive !== true) {
        continue;
      }

      {
        try {
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
          // Scoped to the scheduled run, not the moment of the attempt, so a
          // retry after a crash between charging and bookkeeping reuses the key
          // and Stripe returns the original charge instead of making a second
          // one. Without this the tenant is billed twice for one month.
          const idempotencyKey = autopayIdempotencyKey({
            facilityId,
            tenantId,
            paymentMethodDocId: methodDoc.id,
            scheduledRun: nextRun,
            amountCents: Math.round(amount * 100),
          });
          const paymentIntent = await stripe.paymentIntents.create(
            {
              amount: Math.round(amount * 100),
              currency: 'usd',
              payment_method: methodData.stripePaymentMethodId,
              customer: methodData.stripeCustomerId,
              // No confirmation_method here: Stripe rejects it alongside
              // automatic_payment_methods, and 'automatic' was its default.
              confirm: true,
              // Nobody is present to be redirected: this runs from a scheduled
              // job hours after the tenant saved their card. Without this
              // Stripe rejects the whole PaymentIntent, because the connected
              // account has redirect-based methods enabled in its Dashboard and
              // those would need a return_url. That rejection is not
              // tenant-specific or card-specific -- it failed every autopay
              // charge for every facility, and only surfaced when a real card
              // was finally charged.
              automatic_payment_methods: {
                enabled: true,
                allow_redirects: 'never',
              },
              // Card is on file and the tenant is not in the loop; tells Stripe
              // this is a merchant-initiated transaction so the right network
              // rules and 3DS exemptions apply.
              off_session: true,
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
              idempotencyKey,
            },
          );

          if (paymentIntent.status !== 'succeeded') continue;

          // A retry gets the original succeeded PaymentIntent back, so writing
          // unconditionally would credit the tenant twice for a single charge —
          // turning a prevented double charge into a double credit.
          if (hasLedgerEntryForPayment(
            ledgerSnapshot.docs.map((entry) => entry.data()),
            paymentIntent.id,
          )) {
            functions.logger.info(
              `Autopay payment ${paymentIntent.id} already recorded for tenant ${tenantId}; skipping ledger write`,
            );
            continue;
          }

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

          // Advancing next-run is also what stops a retry re-charging this
          // tenant. It must be written to the SAME nested field the due check
          // reads (`autopaySchedule.autopayNextRun`) — writing a top-level
          // `autopayNextRun` looked correct but was never read, so the schedule
          // never advanced. The effect was not a missed update: it silently
          // turned monthly autopay into "collect any outstanding balance every
          // night", which would bill a tenant the moment a late fee posted
          // instead of on the day they agreed to.
          await methodDoc.ref.update({
            autopayLastRun: admin.firestore.FieldValue.serverTimestamp(),
            autopayLastResult: 'success',
            // Reset on success: consecutive means consecutive, otherwise a
            // single decline months ago would count toward switching autopay off.
            autopayConsecutiveFailures: 0,
            autopayLastError: null,
            'autopaySchedule.autopayNextRun': admin.firestore.Timestamp.fromDate(
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

          // A failure used to record a flag and nothing else, leaving
          // autopayNextRun in the past — so a card that can never succeed was
          // retried every night forever. Back off, and stop entirely once it is
          // clear the card needs replacing.
          const outcome = resolveAutopayFailureOutcome({
            previousFailures: methodData.autopayConsecutiveFailures,
            declineCode: error?.decline_code || error?.code,
            message: error?.message,
            now: new Date(),
          });

          await methodDoc.ref.update({
            autopayLastRun: admin.firestore.FieldValue.serverTimestamp(),
            autopayLastResult: 'failed',
            autopayLastError: outcome.reason,
            autopayConsecutiveFailures: outcome.failures,
            ...(outcome.disarm
              ? {
                  autopayEnabled: false,
                  autopayDisabledReason: outcome.reason,
                  autopayDisabledAt: admin.firestore.FieldValue.serverTimestamp(),
                }
              : {
                  'autopaySchedule.autopayNextRun': admin.firestore.Timestamp.fromDate(
                    outcome.nextRun as Date,
                  ),
                }),
          });

          // Tell somebody. A silent failure means the tenant believes rent is
          // being collected while it is not, and the operator finds out when
          // they go delinquent.
          await admin
            .firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('Notifications')
            .add({
              facilityId,
              tenantId,
              type: outcome.disarm ? 'AUTOPAY_DISABLED_AFTER_FAILURE' : 'AUTOPAY_PAYMENT_FAILED',
              title: outcome.disarm
                ? `Autopay turned off for ${tenantData.name}`
                : `Autopay payment failed for ${tenantData.name}`,
              body: outcome.needsNewCard
                ? `${outcome.reason} The tenant needs to add a new card.`
                : outcome.reason,
              severity: outcome.disarm ? 'high' : 'normal',
              read: false,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              createdBy: 'system@autopay',
            });

          functions.logger.warn(
            `Autopay failure ${outcome.failures} for tenant ${tenantId}: ` +
              `${outcome.disarm ? 'disarmed' : `retry ${outcome.nextRun?.toISOString()}`} — ${outcome.reason}`,
          );
        }
      }
    } catch (error: any) {
      functions.logger.error(
        `Error processing autopay for payment method ${methodDoc.id}:`,
        error,
      );
    }
  }

  return processed;
}
