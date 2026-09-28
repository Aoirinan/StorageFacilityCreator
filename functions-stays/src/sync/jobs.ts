import * as functions from 'firebase-functions/v1';
import { FieldValue, Firestore } from 'firebase-admin/firestore';

import { STAY_TOP_LEVEL_COLLECTIONS, SyncJobStatus } from '@sfc/functions-shared/stays/contracts';
import { jobId } from '@sfc/functions-shared/stays/ids';

import { isAlreadyExists } from '../common/errors';

/**
 * The 30-minute fan-out's bookkeeping, copied from functions-automation's
 * facilityJobEnqueue.ts and facilityJobHelpers.ts (the money jobs there are
 * untouched): one staySyncJobs doc per facility per slot, so
 *  - enqueueing is idempotent: the id is (slot, facilityId), and re-running a
 *    slot finds its jobs already there;
 *  - claiming is transactional: pending → processing, so an at-least-once
 *    redelivery of the onCreate event cannot run a facility twice.
 */

export const SYNC_JOBS_COLLECTION = STAY_TOP_LEVEL_COLLECTIONS.syncJobs;

export interface SyncJobData {
  facilityId?: string;
  runDate?: string;
  status?: SyncJobStatus;
}

/** Only 'pending' is claimable; a missing status is not assumed pending. */
export function canClaimSyncJob(job: SyncJobData | undefined | null): boolean {
  return job?.status === 'pending';
}

/** Firestore caps a batch at 500 writes. */
export function chunkForBatchedWrites<T>(items: readonly T[], size = 500): T[][] {
  if (size <= 0) throw new Error('chunk size must be positive');
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) chunks.push(items.slice(i, i + size));
  return chunks;
}

/**
 * One job per facility, tolerating ones that already exist. A batch is
 * all-or-nothing, so one existing job would sink its whole chunk: the batch
 * is tried first (one round trip in the usual case) and, if it fails, each
 * facility is created on its own so a duplicate only skips itself.
 * Returns how many jobs were newly created.
 */
export async function enqueueSyncJobs(db: Firestore, runDate: string, facilityIds: readonly string[]): Promise<number> {
  const col = db.collection(SYNC_JOBS_COLLECTION);
  const payload = (facilityId: string) => ({
    facilityId,
    runDate,
    status: 'pending',
    createdAt: FieldValue.serverTimestamp(),
    finishedAt: null,
    summary: null,
  });
  let enqueued = 0;
  for (const chunk of chunkForBatchedWrites([...new Set(facilityIds)])) {
    const batch = db.batch();
    for (const facilityId of chunk) batch.create(col.doc(jobId(runDate, facilityId)), payload(facilityId));
    try {
      await batch.commit();
      enqueued += chunk.length;
      continue;
    } catch (error) {
      functions.logger.warn('stays: sync job batch failed; enqueuing one by one', {
        runDate,
        count: chunk.length,
        error: error instanceof Error ? error.message : String(error),
      });
    }
    for (const facilityId of chunk) {
      try {
        await col.doc(jobId(runDate, facilityId)).create(payload(facilityId));
        enqueued += 1;
      } catch (error) {
        // Already enqueued is the expected outcome of a re-run slot.
        if (!isAlreadyExists(error)) {
          functions.logger.error('stays: could not enqueue a sync job', {
            facilityId,
            runDate,
            error: error instanceof Error ? error.message : String(error),
          });
        }
      }
    }
  }
  return enqueued;
}

/** pending → processing, once. */
export async function claimSyncJob(db: Firestore, id: string): Promise<SyncJobData | null> {
  const ref = db.collection(SYNC_JOBS_COLLECTION).doc(id);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? (snap.data() as SyncJobData) : null;
    if (!canClaimSyncJob(data)) return null;
    tx.update(ref, { status: 'processing', startedAt: FieldValue.serverTimestamp() });
    return data;
  });
}
