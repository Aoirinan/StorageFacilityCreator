/**
 * Shared bookkeeping for scheduled jobs that fan out one unit of work per
 * facility.
 *
 * A single invocation that walks every facility and every tenant is O(F x T)
 * sequential work against a gen-1 timeout, and a timed-out scheduler dies with
 * no checkpoint — so facilities late in the stable iteration order silently
 * never get processed. Instead the scheduler enqueues a job document per
 * facility and a Firestore-triggered worker handles one facility per
 * invocation.
 *
 * These jobs move money (rent charges, autopay), so both stages are idempotent:
 *  - enqueue: the job id is derived from (UTC run date, facilityId), so
 *    re-running the scheduler cannot create a second job for a facility.
 *  - claim: the worker transitions pending -> processing in a transaction, so
 *    an at-least-once Firestore redelivery cannot start a second run.
 */

export type FacilityJobStatus = 'pending' | 'processing' | 'completed' | 'failed';

export interface FacilityJobData {
  facilityId?: string;
  runDate?: string;
  status?: FacilityJobStatus;
}

/**
 * UTC calendar day for a run. Schedules are expressed in UTC, so the run key
 * must be too — local time would produce two different keys either side of
 * midnight and allow a duplicate job for the same run.
 */
export function jobRunDate(now: Date): string {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, '0');
  const day = String(now.getUTCDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

/**
 * Deterministic job id: same facility + same run date always maps to the same
 * document, which is what makes enqueueing idempotent.
 *
 * Firestore document ids may not contain '/', so it is stripped defensively —
 * a malformed facility id would otherwise write to a nested path.
 */
export function facilityJobId(runDate: string, facilityId: string): string {
  return `${runDate}_${facilityId.replace(/\//g, '_')}`;
}

/**
 * Whether a worker may take this job.
 *
 * Only 'pending' is claimable: 'processing' means another invocation holds it,
 * and 'completed'/'failed' are terminal. A missing status is treated as
 * unclaimable rather than assumed pending — acting on a malformed job document
 * is the wrong default when real money moves.
 */
export function canClaimFacilityJob(job: FacilityJobData | undefined | null): boolean {
  return job?.status === 'pending';
}

/**
 * Split work into Firestore batched-write chunks. Firestore caps a batch at
 * 500 writes, so a thousand-facility fan-out needs more than one batch.
 */
export function chunkForBatchedWrites<T>(items: readonly T[], size = 500): T[][] {
  if (size <= 0) throw new Error('chunk size must be positive');
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}
