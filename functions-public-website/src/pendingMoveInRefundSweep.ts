import * as functions from 'firebase-functions/v1';
import { STRIPE_SECRETS } from './secrets';
import { sweepStalledMoveInRefunds } from './paidMoveInRefund';
import { findPaidSessionsNobodyReported, settleUnfinishedPaidMoveIns } from './unfinishedPaidMoveInSweep';

/**
 * Every 15 minutes:
 * 1. finishes automatic move-in refunds that were decided but never made,
 *    looks again at ones Stripe showed pending, and retries failed ones that
 *    are due (paidMoveInRefund.ts sweepStalledMoveInRefunds);
 * 2. asks Stripe about recorded Checkout Sessions that closed with nobody
 *    reporting a payment (unfinishedPaidMoveInSweep.ts
 *    findPaidSessionsNobodyReported);
 * 3. refunds, or tells the owner about, renters who paid and have not
 *    finished moving in (settleUnfinishedPaidMoveIns).
 * Each runs even if an earlier one fails.
 *
 * Here rather than in functions-automation, beside the refund code and the
 * collections it reads: the refund's decision, idempotency key and alert
 * wording live in this codebase, and a second copy elsewhere could drift
 * from them.
 */
export const resumeStalledMoveInRefunds = functions
  .runWith({ secrets: STRIPE_SECRETS, timeoutSeconds: 300, memory: '256MB' })
  .pubsub.schedule('every 15 minutes')
  .timeZone('UTC')
  .onRun(async () => {
    const steps: Array<[string, (now: Date) => Promise<unknown>]> = [
      ['sweepStalledMoveInRefunds', sweepStalledMoveInRefunds],
      ['findPaidSessionsNobodyReported', findPaidSessionsNobodyReported],
      ['settleUnfinishedPaidMoveIns', settleUnfinishedPaidMoveIns],
    ];
    for (const [name, step] of steps) {
      try {
        await step(new Date());
      } catch (err: unknown) {
        functions.logger.error(`resumeStalledMoveInRefunds: ${name} failed`, {
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
    return null;
  });
