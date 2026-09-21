import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { computeAccountRollup, type FacilitySubscriptionSnapshot } from '@sfc/functions-shared';

/**
 * Nightly reconciliation of account subscription status.
 *
 * Trials granted by `startPlatformTrial` exist only in Firestore: there is no
 * Stripe subscription behind them, so no webhook can ever fire to end one. The
 * status field therefore stayed `trialing` forever. Access was still blocked
 * once the trial date passed (the Flutter model checks the date), but the data
 * said the opposite, which hid expired accounts from every report and from the
 * operators themselves, and blocked them from starting a fresh trial.
 *
 * This sweep walks accounts whose status still claims a trial and rewrites the
 * ones whose trial has ended, using the same rollup the webhooks use so a
 * facility subscription always wins over a lapsed trial.
 */

/** Firestore `in` queries take at most 30 values. */
const STATUSES_TO_SWEEP = ['trialing'];
/** Cap per run so one bad day cannot spend the whole function budget. */
const MAX_ACCOUNTS_PER_RUN = 500;

export type TrialSweepSummary = {
  scanned: number;
  changed: number;
  unchanged: number;
  failed: number;
};

async function facilitiesForAccount(accountId: string): Promise<FacilitySubscriptionSnapshot[]> {
  const snap = await admin
    .firestore()
    .collection('facilities')
    .where('facilityCreatorAccountId', '==', accountId)
    .get();
  return snap.docs.map((d) => ({
    facilityId: d.id,
    platformSubscriptionStatus: (d.get('platformSubscriptionStatus') as string | undefined) ?? null,
  }));
}

/** Exported for direct invocation from the scheduler and from admin tooling. */
export async function sweepExpiredAccountTrials(nowMs: number = Date.now()): Promise<TrialSweepSummary> {
  const db = admin.firestore();
  const summary: TrialSweepSummary = { scanned: 0, changed: 0, unchanged: 0, failed: 0 };

  const snap = await db
    .collection('facilityCreatorAccounts')
    .where('subscriptionStatus', 'in', STATUSES_TO_SWEEP)
    .limit(MAX_ACCOUNTS_PER_RUN)
    .get();

  for (const doc of snap.docs) {
    summary.scanned += 1;
    try {
      const data = doc.data() ?? {};
      const trialEnd = data.subscriptionTrialEnd as admin.firestore.Timestamp | undefined;
      const facilities = await facilitiesForAccount(doc.id);

      const rollup = computeAccountRollup({
        currentStatus: (data.subscriptionStatus as string | undefined) ?? null,
        localTrialEndMs: trialEnd?.toMillis() ?? null,
        facilities,
        nowMs,
      });

      if (!rollup.changed) {
        summary.unchanged += 1;
        continue;
      }

      await doc.ref.update({
        subscriptionStatus: rollup.status,
        subscriptionRollupReason: rollup.reason,
        subscriptionRollupAt: admin.firestore.FieldValue.serverTimestamp(),
        // Kept so support can tell an expired trial apart from a cancelled plan.
        trialExpiredAt:
          rollup.status === 'cancelled' && trialEnd
            ? trialEnd
            : (data.trialExpiredAt ?? null),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      summary.changed += 1;
      functions.logger.info('Trial sweep updated account', {
        accountId: doc.id,
        to: rollup.status,
        reason: rollup.reason,
      });
    } catch (err: unknown) {
      summary.failed += 1;
      functions.logger.error('Trial sweep failed for account', { accountId: doc.id, err });
    }
  }

  functions.logger.info('Account trial sweep finished', summary);
  return summary;
}

export const sweepAccountTrialExpiry = functions
  .runWith({ timeoutSeconds: 540, memory: '256MB' })
  .pubsub.schedule('30 5 * * *') // Daily at 05:30 UTC, before the offboarding sweep
  .timeZone('UTC')
  .onRun(async () => {
    await sweepExpiredAccountTrials();
    return null;
  });
