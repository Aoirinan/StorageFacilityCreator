/**
 * Job bookkeeping for the fanned-out autopay run.
 *
 * The scheduled job used to walk every facility and every tenant inside one
 * invocation. That is O(facilities x tenants) sequential work against a 60s
 * gen-1 timeout, which in practice ran out at roughly eight facilities — and a
 * timed-out scheduler dies without a checkpoint, so facilities late in the
 * iteration order would silently never be charged.
 *
 * Instead the scheduler now only enqueues one job document per facility, and a
 * Firestore-triggered worker charges a single facility per invocation. That
 * scales horizontally and isolates one facility's failure from the rest.
 *
 * Money is involved, so both stages are idempotent:
 *  - enqueue: the job id is derived from (runDate, facilityId), so re-running
 *    the scheduler on the same day cannot create a second job for a facility.
 *  - claim: the worker transitions pending -> processing inside a transaction,
 *    so a redelivered Firestore event cannot start a second charge run.
 */

export const AUTOPAY_JOBS_COLLECTION = 'autopayJobs';

export type AutopayJobStatus = 'pending' | 'processing' | 'completed' | 'failed';

export interface AutopayJobData {
  facilityId?: string;
  runDate?: string;
  status?: AutopayJobStatus;
}

/**
 * UTC calendar day for a run. The schedule is expressed in UTC, so the run key
 * must be too — using local time would produce two different keys either side
 * of midnight and allow a duplicate job for the same night.
 */
export function autopayRunDate(now: Date): string {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

/**
 * Deterministic job id. Same facility + same run date always maps to the same
 * document, which is what makes enqueueing idempotent.
 *
 * Firestore document ids may not contain '/', so it is stripped defensively;
 * facility ids are generated ids in practice, but this collection is keyed on
 * external input and a malformed id would otherwise write to a nested path.
 */
export function autopayJobId(runDate: string, facilityId: string): string {
  return `${runDate}_${facilityId.replace(/\//g, '_')}`;
}

/**
 * Whether a worker may take this job.
 *
 * Only 'pending' is claimable: 'processing' means another invocation already
 * holds it, and 'completed'/'failed' are terminal. A missing status is treated
 * as unclaimable rather than assumed pending — charging on the basis of a
 * malformed job document is the wrong default when real money moves.
 */
export function canClaimAutopayJob(job: AutopayJobData | undefined | null): boolean {
  return job?.status === 'pending';
}

/**
 * Split facility ids into Firestore batched-write chunks.
 *
 * Firestore caps a batch at 500 writes, so a thousand-facility fan-out needs
 * more than one batch.
 */
export function chunkForBatchedWrites<T>(items: readonly T[], size = 500): T[][] {
  if (size <= 0) throw new Error('chunk size must be positive');
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}
