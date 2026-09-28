import { Firestore, Timestamp } from 'firebase-admin/firestore';

import { STAY_COLLECTIONS, StayControlsDoc, StayDoc, Ymd } from '@sfc/functions-shared/stays/contracts';
import { addDays } from '@sfc/functions-shared/stays/dates';
import { notificationId } from '@sfc/functions-shared/stays/ids';
import { isActiveStatus } from '@sfc/functions-shared/stays/nightLocks';

import { NotifyResult, writeStayNotifications } from '../common/notify';
import { applyStayMutations, driftRebuildMonthChunks } from '../common/stayWriter';
import { SYNC_ACTOR, channelsCol, facilityCol, listingsCol, staysCol, syncLogCol } from './common';
import { SYNC_LOG_RETENTION_MS } from './syncChannel';

/**
 * The once-a-day jobs the worker runs in the right facility-local slot:
 *  - the daily brief (in-app only), at dailyBriefLocalHour;
 *  - the lock drift rebuild, at 03:00, which heals any bucket that drifted
 *    from its stays. Stay statuses are never changed by the brief; the
 *    rebuild only corrects locks and the conflict flags that follow them.
 */

export interface DailyBriefCounts {
  arrivals: number;
  departures: number;
  rvDepartures: number;
  sameDayTurns: number;
  unassignedTurnovers: number;
  overdueDepartures: number;
  openConflicts: number;
  failingFeeds: number;
  unnamedSoon: number;
}

const RV_KINDS = new Set(['rv_site', 'tent_site']);

function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}

/** Counts only: the brief is read by staff, so it names no guest, code or amount. */
export function briefMessage(c: DailyBriefCounts): string {
  const today: string[] = [];
  if (c.arrivals) today.push(plural(c.arrivals, 'arrival'));
  if (c.sameDayTurns) today.push(plural(c.sameDayTurns, 'same-day turn'));
  if (c.departures) {
    const rv = c.rvDepartures && c.rvDepartures < c.departures ? ` (${c.rvDepartures} RV)` : '';
    today.push(c.rvDepartures === c.departures ? plural(c.departures, 'RV departure') : `${plural(c.departures, 'departure')}${rv}`);
  }
  if (c.unassignedTurnovers) today.push(plural(c.unassignedTurnovers, 'unassigned turnover'));
  const attention: string[] = [];
  if (c.overdueDepartures) attention.push(`${plural(c.overdueDepartures, 'guest')} still checked in past checkout`);
  if (c.openConflicts) attention.push(plural(c.openConflicts, 'double booking'));
  if (c.failingFeeds) attention.push(`${plural(c.failingFeeds, 'calendar feed')} failing`);
  if (c.unnamedSoon) attention.push(`${plural(c.unnamedSoon, 'arrival')} in the next 3 days with no guest name`);
  const head = today.length ? `Today: ${today.join(', ')}.` : 'Today: no arrivals or departures.';
  return attention.length ? `${head} Needs attention: ${attention.join(', ')}.` : head;
}

export async function dailyBriefCounts(db: Firestore, facilityId: string, todayYmd: Ymd): Promise<DailyBriefCounts> {
  const [ahead, inHouse, tasks, channels] = await Promise.all([
    staysCol(db, facilityId).where('checkOut', '>=', todayYmd).get(),
    staysCol(db, facilityId).where('arrivalState', '==', 'checked_in').get(),
    facilityCol(db, facilityId, STAY_COLLECTIONS.tasks).where('dueDate', '==', todayYmd).get(),
    channelsCol(db, facilityId).where('active', '==', true).get(),
  ]);
  const stays = ahead.docs.map((d) => d.data() as StayDoc).filter((s) => isActiveStatus(s.status));
  const reservations = stays.filter((s) => s.kind === 'reservation');
  const arriving = reservations.filter((s) => s.checkIn === todayYmd);
  const departing = reservations.filter((s) => s.checkOut === todayYmd);
  const arrivingListings = new Set(arriving.map((s) => s.listingId));
  const soon = addDays(todayYmd, 3);
  return {
    arrivals: arriving.length,
    departures: departing.length,
    rvDepartures: departing.filter((s) => RV_KINDS.has(s.listingKind)).length,
    sameDayTurns: new Set(departing.filter((s) => arrivingListings.has(s.listingId)).map((s) => s.listingId)).size,
    unassignedTurnovers: tasks.docs.filter((d) => {
      const t = d.data();
      return t.category === 'turnover' && (t.status === 'todo' || t.status === 'in_progress') && !t.assigneeUid;
    }).length,
    overdueDepartures: inHouse.docs
      .map((d) => d.data() as StayDoc)
      .filter((s) => isActiveStatus(s.status) && s.checkOut < todayYmd).length,
    openConflicts: stays.filter((s) => s.status === 'conflict' && !s.conflict?.acknowledgedAt).length,
    failingFeeds: channels.docs.filter((d) => {
      const failures = d.get('sync.consecutiveFailures');
      return (typeof failures === 'number' && failures >= 3) || d.get('sync.lastStatus') === 'gone';
    }).length,
    unnamedSoon: reservations.filter((s) => s.checkIn > todayYmd && s.checkIn <= soon && !(s.guestDisplayName ?? '').trim()).length,
  };
}

/** Creates stay_brief_{ymd}; its id is the once-a-day marker. */
export async function writeDailyBrief(db: Firestore, facilityId: string, todayYmd: Ymd, nowMs: number): Promise<NotifyResult> {
  const counts = await dailyBriefCounts(db, facilityId, todayYmd);
  return writeStayNotifications(
    db,
    facilityId,
    [
      {
        id: notificationId({ kind: 'brief', ymd: todayYmd }),
        type: 'STAY_DAILY_BRIEF',
        message: briefMessage(counts),
        metadata: { route: `/stays?facilityId=${encodeURIComponent(facilityId)}&tab=today` },
      },
    ],
    Timestamp.fromMillis(nowMs),
  );
}

export interface DriftResult {
  listings: number;
  changedBuckets: number;
  statusChanges: number;
}

/**
 * Rebuilds every listing's lock buckets over the whole horizon from its
 * stays (applyStayMutations with no mutations). Only buckets whose digest
 * changed are written; listings that drifted are logged with trigger 'drift'.
 */
export async function runDriftRebuild(
  db: Firestore,
  facilityId: string,
  controls: StayControlsDoc,
  todayYmd: Ymd,
  nowMs: number,
  slot: string,
): Promise<DriftResult> {
  const listings = await listingsCol(db, facilityId).get();
  const result: DriftResult = { listings: 0, changedBuckets: 0, statusChanges: 0 };
  for (const listing of listings.docs) {
    let changed: string[] = [];
    let statusChanges = 0;
    for (const months of driftRebuildMonthChunks(todayYmd)) {
      const res = await applyStayMutations({
        db,
        facilityId,
        controls,
        mutations: [],
        rebuild: [{ listingId: listing.id, months }],
        actor: SYNC_ACTOR,
        nowMs,
      });
      changed = changed.concat(res.changedBuckets);
      statusChanges += res.statusChanges.length;
    }
    result.listings++;
    result.changedBuckets += changed.length;
    result.statusChanges += statusChanges;
    if (changed.length > 0 || statusChanges > 0) {
      await syncLogCol(db, facilityId)
        .doc(`${slot}_drift_${listing.id}`)
        .set({
          facilityId,
          channelId: '',
          listingId: listing.id,
          trigger: 'drift',
          status: 'ok',
          httpStatus: null,
          created: 0,
          dateChanged: 0,
          restored: 0,
          missesAdvanced: 0,
          removed: 0,
          needsReview: 0,
          conflicts: statusChanges,
          blocks: 0,
          changedBuckets: changed.length,
          durationMs: 0,
          finishedAt: Timestamp.fromMillis(nowMs),
          expireAt: Timestamp.fromMillis(nowMs + SYNC_LOG_RETENTION_MS),
        });
    }
  }
  return result;
}
