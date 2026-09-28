import * as functions from 'firebase-functions/v1';
import { FieldValue } from 'firebase-admin/firestore';

import { StaysChannelSyncResult } from '@sfc/functions-shared/stays/contracts';
import { canonicalIanaZone, facilityLocalHour, facilityLocalMinute, facilityToday } from '@sfc/functions-shared/stays/dates';

import { loadControls } from '../common/controls';
import { STAYS_RUNTIME } from '../common/guards';
import { evaluateStaysGate, loadStaysGate } from '../common/serverConfig';
import { SyncDeps, channelsCol, defaultSyncDeps } from './common';
import { runDriftRebuild, writeDailyBrief } from './daily';
import { SYNC_JOBS_COLLECTION, claimSyncJob } from './jobs';
import { syncChannel } from './syncChannel';

/**
 * staysProcessSyncJob (spec §6.7): one facility per invocation.
 *  1. Claims its staySyncJobs doc (pending → processing), so a redelivered
 *     event does nothing.
 *  2. If icalSyncEnabled: syncs each active channel in turn within 240 s.
 *  3. In the slot's first half hour of dailyBriefLocalHour (facility time),
 *     if dailyBriefEnabled: the in-app daily brief, once a day.
 *  4. At facility-local 03:00: the lock drift rebuild.
 *  5. Marks the job completed or failed. It never rethrows: a failed
 *     facility waits for the next slot instead of retrying, and one
 *     facility's failure never touches another's.
 */

export const WORKER_CHANNEL_BUDGET_MS = 240_000;
export const DRIFT_LOCAL_HOUR = 3;

const SLOT_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/;

export interface FacilitySyncSummary {
  skipped: string | null;
  channels: { channelId: string; status: string; skipped: boolean }[];
  brief: 'created' | 'existed' | 'failed' | null;
  drift: { listings: number; changedBuckets: number } | null;
}

export async function runFacilitySync(facilityId: string, slot: string, deps: SyncDeps): Promise<FacilitySyncSummary> {
  const db = deps.db();
  const nowMs = deps.now();
  const summary: FacilitySyncSummary = { skipped: null, channels: [], brief: null, drift: null };

  const gate = await loadStaysGate(db, nowMs);
  if (!evaluateStaysGate(gate, facilityId).allowed) return { ...summary, skipped: 'not_allowed' };
  const controls = await loadControls(db, facilityId);
  if (controls.moduleEnabled !== true) return { ...summary, skipped: 'module_disabled' };
  const tz = canonicalIanaZone(controls.timeZone);
  if (!tz || !controls.timeZoneConfirmedAt) return { ...summary, skipped: 'timezone_unconfirmed' };

  // The slot's own time, not the (possibly late) moment this runs: every
  // once-a-day step is decided by the slot, so a redelivery cannot repeat it.
  const slotMs = SLOT_RE.test(slot) ? Date.parse(`${slot}:00Z`) : nowMs;

  if (controls.icalSyncEnabled === true) {
    const channels = await channelsCol(db, facilityId).where('active', '==', true).get();
    for (const channel of channels.docs.sort((a, b) => (a.id < b.id ? -1 : 1))) {
      if (deps.now() - nowMs > WORKER_CHANNEL_BUDGET_MS) {
        summary.channels.push({ channelId: channel.id, status: 'not_modified', skipped: true });
        continue;
      }
      try {
        const r: StaysChannelSyncResult = await syncChannel(facilityId, channel.id, 'scheduled', {
          deps,
          slot,
          controls,
          gate,
        });
        summary.channels.push({ channelId: channel.id, status: r.status, skipped: r.skipped === true });
      } catch (error) {
        functions.logger.error('stays: scheduled channel sync failed', {
          facilityId,
          channelId: channel.id,
          error: error instanceof Error ? error.message : String(error),
        });
        summary.channels.push({ channelId: channel.id, status: 'http_error', skipped: false });
      }
    }
  }

  const localHour = facilityLocalHour(tz, slotMs);
  const firstHalf = facilityLocalMinute(tz, slotMs) < 30;
  const todayYmd = facilityToday(tz, slotMs);
  if (controls.dailyBriefEnabled === true && firstHalf && localHour === controls.dailyBriefLocalHour) {
    try {
      const res = await writeDailyBrief(db, facilityId, todayYmd, deps.now());
      summary.brief = res.created.length ? 'created' : res.existed.length ? 'existed' : 'failed';
    } catch (error) {
      functions.logger.error('stays: daily brief failed', { facilityId, error: error instanceof Error ? error.message : String(error) });
      summary.brief = 'failed';
    }
  }
  if (firstHalf && localHour === DRIFT_LOCAL_HOUR) {
    const drift = await runDriftRebuild(db, facilityId, controls, facilityToday(tz, deps.now()), deps.now(), slot);
    summary.drift = { listings: drift.listings, changedBuckets: drift.changedBuckets };
  }
  return summary;
}

export async function processSyncJob(jobId: string, deps: SyncDeps = defaultSyncDeps()): Promise<'completed' | 'failed' | 'not_claimed'> {
  const db = deps.db();
  const ref = db.collection(SYNC_JOBS_COLLECTION).doc(jobId);
  const job = await claimSyncJob(db, jobId);
  if (!job) return 'not_claimed';
  if (typeof job.facilityId !== 'string' || !job.facilityId) {
    await ref.update({ status: 'failed', finishedAt: FieldValue.serverTimestamp(), summary: { error: 'missing facilityId' } });
    return 'failed';
  }
  try {
    const summary = await runFacilitySync(job.facilityId, typeof job.runDate === 'string' ? job.runDate : '', deps);
    await ref.update({ status: 'completed', finishedAt: FieldValue.serverTimestamp(), summary });
    return 'completed';
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    functions.logger.error('stays: sync job failed', { jobId, facilityId: job.facilityId, error: message });
    await ref.update({ status: 'failed', finishedAt: FieldValue.serverTimestamp(), summary: { error: message.slice(0, 500) } });
    return 'failed';
  }
}

export const staysProcessSyncJob = functions
  .runWith(STAYS_RUNTIME.worker)
  .firestore.document(`${SYNC_JOBS_COLLECTION}/{jobId}`)
  .onCreate(async (snap) => {
    await processSyncJob(snap.id);
  });
