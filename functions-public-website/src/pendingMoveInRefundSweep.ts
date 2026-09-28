import * as functions from 'firebase-functions/v1';
import { STRIPE_SECRETS } from './secrets';
import { sweepStalledMoveInRefunds } from './paidMoveInRefund';

/**
 * Every 15 minutes: finishes automatic move-in refunds that were decided but
 * never made (paidMoveInRefund.ts sweepStalledMoveInRefunds).
 *
 * Here rather than in functions-automation, beside the refund code and the
 * collection it reads: the refund's decision, idempotency key and alert
 * wording live in this codebase, and a second copy elsewhere could drift
 * from them.
 */
export const resumeStalledMoveInRefunds = functions
  .runWith({ secrets: STRIPE_SECRETS, timeoutSeconds: 300, memory: '256MB' })
  .pubsub.schedule('every 15 minutes')
  .timeZone('UTC')
  .onRun(async () => {
    await sweepStalledMoveInRefunds(new Date());
    return null;
  });
