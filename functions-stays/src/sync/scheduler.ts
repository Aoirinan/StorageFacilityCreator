import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { Firestore, Timestamp } from 'firebase-admin/firestore';

import { STAYS_CURRENT_DOC_ID, STAY_COLLECTIONS } from '@sfc/functions-shared/stays/contracts';
import { slotKey } from '@sfc/functions-shared/stays/dates';

import { evaluateStaysGate, loadStaysGate } from '../common/serverConfig';
import { syncLogCol } from './common';
import { SYNC_JOBS_COLLECTION, enqueueSyncJobs } from './jobs';

/**
 * staysScheduledSync (spec §6.7): every 30 minutes, the only Stays
 * scheduler. It does no syncing itself: it enqueues one staySyncJobs doc per
 * facility that has Stays on and is allowed by the platform gate, and the
 * worker (staysProcessSyncJob) handles each facility in its own invocation.
 * It also trims jobs older than 3 days and expired sync-log rows (≤200 each
 * per run).
 */

export const OLD_JOB_MS = 3 * 24 * 60 * 60_000;
export const CLEANUP_BATCH = 200;

export interface ScheduledSyncDeps {
  db: () => Firestore;
  now: () => number;
}

export interface ScheduledSyncResult {
  slot: string;
  skipped: 'paused' | 'no_config' | null;
  facilities: number;
  enqueued: number;
  deletedJobs: number;
  deletedLogs: number;
}

export async function runScheduledSync(deps: ScheduledSyncDeps): Promise<ScheduledSyncResult> {
  const db = deps.db();
  const nowMs = deps.now();
  const slot = slotKey(nowMs);
  const result: ScheduledSyncResult = { slot, skipped: null, facilities: 0, enqueued: 0, deletedJobs: 0, deletedLogs: 0 };

  // Fails closed: no config doc (or a failed read) and nothing runs.
  const gate = await loadStaysGate(db, nowMs);
  if (gate.source !== 'doc') return { ...result, skipped: 'no_config' };
  if (gate.killSwitch) return { ...result, skipped: 'paused' };

  const enabled = await db.collectionGroup(STAY_COLLECTIONS.controls).where('moduleEnabled', '==', true).get();
  const facilityIds = enabled.docs
    .filter((d) => d.id === STAYS_CURRENT_DOC_ID)
    .map((d) => d.ref.parent.parent?.id)
    .filter((id): id is string => typeof id === 'string' && evaluateStaysGate(gate, id).allowed)
    .sort();
  result.facilities = facilityIds.length;
  result.enqueued = await enqueueSyncJobs(db, slot, facilityIds);

  try {
    const old = await db
      .collection(SYNC_JOBS_COLLECTION)
      .where('createdAt', '<', Timestamp.fromMillis(nowMs - OLD_JOB_MS))
      .limit(CLEANUP_BATCH)
      .get();
    if (!old.empty) {
      const batch = db.batch();
      old.docs.forEach((d) => batch.delete(d.ref));
      await batch.commit();
      result.deletedJobs = old.size;
    }
    let budget = CLEANUP_BATCH;
    for (const facilityId of facilityIds) {
      if (budget <= 0) break;
      const expired = await syncLogCol(db, facilityId)
        .where('expireAt', '<', Timestamp.fromMillis(nowMs))
        .limit(budget)
        .get();
      if (expired.empty) continue;
      const batch = db.batch();
      expired.docs.forEach((d) => batch.delete(d.ref));
      await batch.commit();
      result.deletedLogs += expired.size;
      budget -= expired.size;
    }
  } catch (error) {
    // Housekeeping never stops the sync.
    functions.logger.warn('stays: scheduled cleanup failed', { error: error instanceof Error ? error.message : String(error) });
  }
  return result;
}

export const staysScheduledSync = functions
  .runWith({ memory: '256MB', timeoutSeconds: 120 })
  .pubsub.schedule('every 30 minutes')
  .timeZone('UTC')
  .onRun(async () => {
    const result = await runScheduledSync({ db: () => admin.firestore(), now: () => Date.now() });
    functions.logger.info('stays: scheduled sync fan-out', { ...result });
    return null;
  });
