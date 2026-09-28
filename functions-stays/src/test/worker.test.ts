import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import type { StayDoc } from '@sfc/functions-shared/stays/contracts';

import { resetStaysGateCacheForTests } from '../common/serverConfig';
import { briefMessage } from '../sync/daily';
import { runScheduledSync } from '../sync/scheduler';
import { processSyncJob } from '../sync/worker';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, makeStay } from './support/staysFixtures';
import { CHANNEL, FAC, LISTING, MIN, NOW, P, SyncWorld, nightsOf, seedControls, seedGate, slotOf, syncWorld } from './support/syncFixtures';

const all: FakeFirestore[] = [];

function world(opts: Parameters<typeof syncWorld>[0] = {}): SyncWorld {
  const w = syncWorld(opts);
  all.push(w.fake);
  return w;
}

function seedJob(w: SyncWorld, slot: string, facilityId = FAC): string {
  const id = `${slot}_${facilityId}`;
  w.fake.seed(`staySyncJobs/${id}`, { facilityId, runDate: slot, status: 'pending', createdAt: Timestamp.fromMillis(w.now.ms), finishedAt: null, summary: null });
  return id;
}

function stay(w: SyncWorld, id: string, checkIn: string, checkOut: string, patch: Partial<StayDoc> = {}): void {
  w.fake.seed(`${P.stays}/${id}`, makeStay(patch.listingId ?? LISTING, checkIn, checkOut, patch) as unknown as Record<string, unknown>);
}

test('the scheduler enqueues one job per enabled, allowed facility, and re-running the slot adds none', async () => {
  const w = world();
  // Enabled but not on the allowlist, and on the allowlist but not enabled.
  w.fake.seed('facilities/fac-other/stayControls/current', { moduleEnabled: true });
  w.fake.seed('facilities/fac-off/stayControls/current', { moduleEnabled: false });
  seedGate(w.fake, { allowlistFacilityIds: [FAC, 'fac-off'] });
  const deps = { db: () => w.fake.firestore(), now: () => w.now.ms };
  const first = await runScheduledSync(deps);
  assert.equal(first.slot, slotOf(NOW));
  assert.deepEqual([first.facilities, first.enqueued], [1, 1]);
  assert.deepEqual(w.fake.list('staySyncJobs').map((j) => [j.id, j.data.status, j.data.runDate]), [[`${slotOf(NOW)}_${FAC}`, 'pending', slotOf(NOW)]]);
  const again = await runScheduledSync(deps);
  assert.equal(again.enqueued, 0);
  assert.equal(w.fake.list('staySyncJobs').length, 1);
  // The next slot gets its own job.
  w.now.ms += 30 * MIN;
  assert.equal((await runScheduledSync(deps)).enqueued, 1);
});

test('the scheduler does nothing when paused or unconfigured, and trims old jobs and expired sync logs', async () => {
  const paused = world({ gate: { killSwitch: true } });
  assert.equal((await runScheduledSync({ db: () => paused.fake.firestore(), now: () => paused.now.ms })).skipped, 'paused');
  assert.equal(paused.fake.list('staySyncJobs').length, 0);

  const bare = world();
  bare.fake.seed('staysServerConfig/current', {});
  resetStaysGateCacheForTests();
  await bare.fake.firestore().collection('staysServerConfig').doc('current').delete();
  assert.equal((await runScheduledSync({ db: () => bare.fake.firestore(), now: () => bare.now.ms })).skipped, 'no_config');

  const w = world();
  w.fake.seed('staySyncJobs/old_job', { facilityId: FAC, status: 'completed', createdAt: Timestamp.fromMillis(NOW - 4 * 24 * 60 * MIN) });
  w.fake.seed('staySyncJobs/recent_job', { facilityId: FAC, status: 'completed', createdAt: Timestamp.fromMillis(NOW - 60 * MIN) });
  w.fake.seed(`${P.syncLog}/expired`, { expireAt: Timestamp.fromMillis(NOW - 1) });
  w.fake.seed(`${P.syncLog}/fresh`, { expireAt: Timestamp.fromMillis(NOW + 60 * MIN) });
  const r = await runScheduledSync({ db: () => w.fake.firestore(), now: () => w.now.ms });
  assert.deepEqual([r.deletedJobs, r.deletedLogs], [1, 1]);
  assert.equal(w.fake.has('staySyncJobs/old_job'), false);
  assert.equal(w.fake.has('staySyncJobs/recent_job'), true);
  assert.deepEqual(w.fake.list(P.syncLog).map((d) => d.id), ['fresh']);
});

test('a job is claimed once: a redelivered event does nothing', async () => {
  const w = world();
  w.feed.set([{ code: 'HMWORKER01', checkIn: '2026-10-03', checkOut: '2026-10-06' }]);
  const id = seedJob(w, slotOf(NOW));
  assert.equal(await processSyncJob(id, w.deps), 'completed');
  assert.equal(await processSyncJob(id, w.deps), 'not_claimed');
  assert.equal(w.feed.calls.length, 1);
  const job = w.fake.read(`staySyncJobs/${id}`)!;
  assert.equal(job.status, 'completed');
  assert.deepEqual((job.summary as { channels: unknown[] }).channels, [{ channelId: CHANNEL, status: 'ok', skipped: false }]);
  assert.ok(w.fake.has(`${P.stays}/airbnb_HMWORKER01`));
  assert.ok(w.fake.has(`${P.syncLog}/${slotOf(NOW)}_${CHANNEL}`));
});

test('feeds are synced only when the owner turned import on', async () => {
  const w = world({ controls: { icalSyncEnabled: false } });
  w.feed.set([{ code: 'HMWORKER02', checkIn: '2026-10-03', checkOut: '2026-10-06' }]);
  assert.equal(await processSyncJob(seedJob(w, slotOf(NOW)), w.deps), 'completed');
  assert.equal(w.feed.calls.length, 0);
  assert.equal(w.fake.list(P.stays).length, 0);

  const off = world({ controls: { moduleEnabled: false } });
  const id = seedJob(off, slotOf(NOW));
  assert.equal(await processSyncJob(id, off.deps), 'completed');
  assert.equal((off.fake.read(`staySyncJobs/${id}`)?.summary as { skipped: string }).skipped, 'module_disabled');
});

test('the daily brief is written once, in the first half hour of the chosen local hour', async () => {
  const w = world({ controls: { dailyBriefEnabled: true, dailyBriefLocalHour: 7, icalSyncEnabled: false } });
  // Today in Denver is 2026-10-01; 13:00Z is 07:00 MDT.
  stay(w, 'man_arrive', '2026-10-01', '2026-10-03', { guestDisplayName: 'A. Guest' });
  stay(w, 'man_leave', '2026-09-28', '2026-10-01', { guestDisplayName: 'B. Guest' });
  stay(w, 'man_rv_leave', '2026-09-29', '2026-10-01', { listingId: 'lst_rv1', listingKind: 'rv_site' });
  stay(w, 'man_overdue', '2026-09-25', '2026-09-30', { listingId: 'lst_rv2', listingKind: 'rv_site', arrivalState: 'checked_in' });
  stay(w, 'man_conflict', '2026-10-08', '2026-10-10', { listingId: 'lst_x', status: 'conflict' });
  stay(w, 'man_noname', '2026-10-03', '2026-10-05', { listingId: 'lst_y', guestDisplayName: '' });
  stay(w, 'man_cancelled', '2026-10-01', '2026-10-02', { listingId: 'lst_z', status: 'cancelled' });
  w.fake.seed(`facilities/${FAC}/stayTasks/turnover_man_leave`, { category: 'turnover', status: 'todo', dueDate: '2026-10-01', assigneeUid: null });
  w.fake.seed(`facilities/${FAC}/stayTasks/turnover_man_rv_leave`, { category: 'turnover', status: 'todo', dueDate: '2026-10-01', assigneeUid: EMPLOYEE });
  w.fake.seed(`${P.channels}/${CHANNEL}`, { ...w.fake.read(`${P.channels}/${CHANNEL}`), sync: { consecutiveFailures: 4, lastStatus: 'timeout' } });

  assert.equal(await processSyncJob(seedJob(w, '2026-10-01T12:00'), w.deps), 'completed');
  assert.equal(w.fake.list(P.notifications).length, 0, 'not at 06:00 (the first half of the wrong hour)');
  assert.equal(await processSyncJob(seedJob(w, '2026-10-01T12:30'), w.deps), 'completed');
  assert.equal(w.fake.list(P.notifications).length, 0, 'not at 06:30');
  assert.equal(await processSyncJob(seedJob(w, '2026-10-01T13:30'), w.deps), 'completed');
  assert.equal(w.fake.list(P.notifications).length, 0, 'not in the second half of the hour');
  assert.equal(await processSyncJob(seedJob(w, '2026-10-01T13:00'), w.deps), 'completed');
  const notes = w.fake.list(P.notifications);
  assert.deepEqual(notes.map((n) => [n.id, n.data.type]), [['stay_brief_2026-10-01', 'STAY_DAILY_BRIEF']]);
  assert.equal(
    notes[0].data.message,
    'Today: 1 arrival, 1 same-day turn, 2 departures (1 RV), 1 unassigned turnover. Needs attention: 1 guest still checked in past checkout, 1 double booking, 1 calendar feed failing, 1 arrival in the next 3 days with no guest name.',
  );
  // A second job for that slot (a manual re-run) finds the brief already there.
  w.fake.seed(`staySyncJobs/rerun`, { facilityId: FAC, runDate: '2026-10-01T13:00', status: 'pending' });
  assert.equal(await processSyncJob('rerun', w.deps), 'completed');
  assert.equal(w.fake.list(P.notifications).length, 1);
  assert.equal((w.fake.read('staySyncJobs/rerun')?.summary as { brief: string }).brief, 'existed');
  // No staff-visible names in it.
  assert.equal(String(notes[0].data.message).includes('Guest'), false);
});

test('the brief is off unless the owner turned it on', async () => {
  const w = world({ controls: { dailyBriefLocalHour: 7, icalSyncEnabled: false } });
  await processSyncJob(seedJob(w, '2026-10-01T13:00'), w.deps);
  assert.equal(w.fake.list(P.notifications).length, 0);
  assert.equal(briefMessage({ arrivals: 0, departures: 0, rvDepartures: 0, sameDayTurns: 0, unassignedTurnovers: 0, overdueDepartures: 0, openConflicts: 0, failingFeeds: 0, unnamedSoon: 0 }), 'Today: no arrivals or departures.');
  assert.equal(briefMessage({ arrivals: 0, departures: 3, rvDepartures: 3, sameDayTurns: 0, unassignedTurnovers: 0, overdueDepartures: 0, openConflicts: 0, failingFeeds: 0, unnamedSoon: 0 }), 'Today: 3 RV departures.');
});

test('at 03:00 local the drift rebuild heals a lock bucket that no longer matches its stays', async () => {
  const w = world({ controls: { icalSyncEnabled: false } });
  stay(w, 'man_a', '2026-10-05', '2026-10-07');
  // A bucket that says someone else holds the nights, and one for a stay that is gone.
  w.fake.seed(`${P.locks}/${LISTING}_2026-10`, {
    facilityId: FAC,
    listingId: LISTING,
    month: '2026-10',
    nights: { '2026-10-05': { s: 'man_ghost', h: true, src: 'direct', k: 'reservation' } },
    digest: 'stale',
  });
  // 09:00Z is 03:00 MDT; 08:00Z is the first half of 02:00, and 09:30Z the second half of 03:00.
  await processSyncJob(seedJob(w, '2026-10-01T08:00'), w.deps);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-05'].s, 'man_ghost', 'not at 02:00');
  await processSyncJob(seedJob(w, '2026-10-01T09:30'), w.deps);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-05'].s, 'man_ghost', 'not at 03:30');
  await processSyncJob(seedJob(w, '2026-10-01T09:00'), w.deps);
  const nights = nightsOf(w.fake, '2026-10');
  assert.equal(nights['2026-10-05'].s, 'man_a');
  assert.equal(nights['2026-10-06'].s, 'man_a');
  const log = w.fake.read(`${P.syncLog}/2026-10-01T09:00_drift_${LISTING}`)!;
  assert.deepEqual([log.trigger, log.changedBuckets], ['drift', 1]);
  // Stay statuses are not what the drift job is for: nothing else was written to stays.
  assert.equal(w.fake.read(`${P.stays}/man_a`)?.status, 'confirmed');
});

test('one facility failing does not stop another', async () => {
  const w = world({ controls: { icalSyncEnabled: false } });
  w.fake.seed('facilities/fac-two', { ownerUid: 'uid-2' });
  seedControls(w.fake);
  w.fake.seed('facilities/fac-two/stayControls/current', { moduleEnabled: true, timeZone: 'America/Denver', timeZoneConfirmedAt: Timestamp.fromMillis(NOW) });
  seedGate(w.fake, { allowlistFacilityIds: [FAC, 'fac-two'] });
  resetStaysGateCacheForTests();
  w.fake.failReads = (p) => p === 'facilities/fac-two/stayControls/current';
  const bad = seedJob(w, slotOf(NOW), 'fac-two');
  const good = seedJob(w, slotOf(NOW));
  assert.equal(await processSyncJob(bad, w.deps), 'failed');
  assert.equal(await processSyncJob(good, w.deps), 'completed');
  assert.equal(w.fake.read(`staySyncJobs/${bad}`)?.status, 'failed');
});

test('isolation: the scheduler and worker never touched a storage collection', () => {
  for (const fake of all) fake.assertIsolation();
});
