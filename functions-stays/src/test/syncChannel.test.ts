import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';

import type { StayDoc } from '@sfc/functions-shared/stays/contracts';

import { syncChannel } from '../sync/syncChannel';
import { FakeFirestore } from './support/fakeFirestore';
import { EMPLOYEE, OWNER, makeStay } from './support/staysFixtures';
import {
  CHANNEL,
  FAC,
  LISTING,
  MIN,
  NOW,
  P,
  SyncWorld,
  nightsOf,
  notificationTypes,
  seedChannel,
  slotOf,
  syncWorld,
} from './support/syncFixtures';

const all: FakeFirestore[] = [];

function world(opts: Parameters<typeof syncWorld>[0] = {}): SyncWorld {
  const w = syncWorld(opts);
  all.push(w.fake);
  return w;
}

/** A scheduled run at the world's current time. */
function run(w: SyncWorld, channelId = CHANNEL) {
  return syncChannel(FAC, channelId, 'scheduled', { deps: w.deps, slot: slotOf(w.now.ms) });
}

function stayDoc(w: SyncWorld, id: string): StayDoc | undefined {
  return w.fake.read(`${P.stays}/${id}`) as StayDoc | undefined;
}

function channel(w: SyncWorld, id = CHANNEL): Record<string, unknown> {
  return w.fake.read(`${P.channels}/${id}`) as Record<string, unknown>;
}

function channelSync(w: SyncWorld, id = CHANNEL): Record<string, unknown> {
  return channel(w, id).sync as Record<string, unknown>;
}

const FIRST = [
  { code: 'HMFIRST001', checkIn: '2026-10-03', checkOut: '2026-10-06', phone: '0199' },
  { code: 'HMFIRST002', checkIn: '2026-10-06', checkOut: '2026-10-09', phone: '0142' },
  { code: 'HMPAST0001', checkIn: '2026-09-10', checkOut: '2026-09-12' },
  { checkIn: '2026-10-15', checkOut: '2026-10-20' },
  { checkIn: '2026-10-20', checkOut: '2026-10-22' },
];

test('first sync: bookings become stays, blocks become soft locks, and one summary notification is written', async () => {
  const w = world();
  w.feed.set(FIRST);
  const r = await run(w);
  assert.equal(r.status, 'ok');
  assert.equal(r.created, 3);
  assert.equal(r.blocks, 1);

  const s1 = stayDoc(w, 'airbnb_HMFIRST001')!;
  assert.equal(s1.origin, 'feed');
  assert.equal(s1.source, 'airbnb');
  assert.equal(s1.status, 'confirmed');
  assert.equal(s1.arrivalState, 'upcoming');
  assert.equal(s1.paymentStatus, 'channel_collected');
  assert.equal(s1.checkInTime, '16:00');
  assert.equal(s1.guestDisplayName, '');
  assert.equal(s1.listingName, 'Airbnb 1');
  assert.deepEqual(s1.external, {
    provider: 'airbnb',
    uid: 'uid-hmfirst001@airbnb.com',
    uidHistory: [],
    confirmationCode: 'HMFIRST001',
    reservationUrl: 'https://www.airbnb.com/hosting/reservations/details/HMFIRST001',
    summary: 'Reserved',
  });
  assert.equal(s1.sync?.channelId, CHANNEL);
  assert.equal(s1.version, 1);
  // A stay that ended before the feed was connected is history, not an overdue departure.
  assert.equal(stayDoc(w, 'airbnb_HMPAST0001')?.arrivalState, 'checked_out');

  // The phone last 4 is private (owner/manager), and the door code in phone-last-4 mode.
  assert.equal(w.fake.read(`${P.private}/airbnb_HMFIRST001`)?.phoneLast4, '0199');
  assert.deepEqual(
    (({ doorCode, source }) => ({ doorCode, source }))(w.fake.read(`${P.access}/airbnb_HMFIRST001`) as { doorCode: string; source: string }),
    { doorCode: '0199', source: 'phone_last4' },
  );
  // ...and nowhere a viewer can read.
  assert.equal(JSON.stringify(stayDoc(w, 'airbnb_HMFIRST001')).includes('0199'), false);

  const october = nightsOf(w.fake, '2026-10');
  assert.deepEqual(october['2026-10-03'], { s: 'airbnb_HMFIRST001', h: true, src: 'airbnb', k: 'reservation' });
  assert.deepEqual(october['2026-10-16'], { s: `blk:${CHANNEL}`, h: false, src: 'airbnb', k: 'channel_block' });
  assert.deepEqual(w.fake.read(`${P.blocks}/${CHANNEL}`)?.ranges, [{ checkIn: '2026-10-15', checkOut: '2026-10-22', echo: false }]);

  assert.deepEqual(notificationTypes(w.fake), ['STAY_FEED_FIRST_SYNC']);
  const note = w.fake.list(P.notifications)[0];
  assert.equal(note.id, `stay_feed_${CHANNEL}_first_sync_2026-10-01`);
  assert.match(note.data.message as string, /Airbnb calendar connected for Airbnb 1: 2 upcoming bookings and 1 blocked range\. Next arrival Oct 3\./);

  const sync = channelSync(w);
  assert.equal(sync.lastStatus, 'ok');
  assert.equal(sync.consecutiveFailures, 0);
  assert.equal(sync.futureReservationCount, 2);
  assert.equal(sync.blockCount, 1);
  assert.equal(sync.eventCount, 5);
  assert.equal(sync.lease, null);
  assert.ok(sync.firstSyncCompletedAt);
  assert.match(sync.contentSha256 as string, /^[a-f0-9]{64}$/);
  const log = w.fake.read(`${P.syncLog}/${slotOf(NOW)}_${CHANNEL}`)!;
  assert.deepEqual([log.trigger, log.status, log.created, log.blocks], ['scheduled', 'ok', 3, 1]);
});

test('the same feed again changes nothing: 304 or an identical body skips the diff', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  const writesBefore = w.fake.writesTo('stays').length;
  w.now.ms += 30 * MIN;
  // The server honours the stored ETag: a 304.
  const r304 = await run(w);
  assert.equal(r304.status, 'not_modified');
  assert.equal(r304.httpStatus, 304);
  // A server without ETags sends the same body: the hash matches.
  w.feed.setText(w.feed.body);
  w.now.ms += 30 * MIN;
  const same = await run(w);
  assert.equal(same.status, 'not_modified');
  assert.equal(w.fake.writesTo('stays').length, writesBefore);
  assert.deepEqual(notificationTypes(w.fake), ['STAY_FEED_FIRST_SYNC']);
});

test('an altered Airbnb booking moves its dates on the same doc, and the old nights are freed', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  // Staff check the guest in and name them meanwhile; the sync must not undo it.
  w.fake.seed(`${P.stays}/airbnb_HMFIRST001`, {
    ...(stayDoc(w, 'airbnb_HMFIRST001') as unknown as Record<string, unknown>),
    guestDisplayName: 'Pat Q.',
    staffNotes: 'Late arrival',
  });
  w.now.ms += 30 * MIN;
  w.feed.set([{ ...FIRST[0], checkIn: '2026-10-02', checkOut: '2026-10-05' }, ...FIRST.slice(1)]);
  const r = await run(w);
  assert.equal(r.dateChanged, 1);
  assert.equal(r.created, 0);
  const s = stayDoc(w, 'airbnb_HMFIRST001')!;
  assert.deepEqual([s.checkIn, s.checkOut, s.nights, s.version], ['2026-10-02', '2026-10-05', 3, 2]);
  assert.equal(s.guestDisplayName, 'Pat Q.');
  assert.equal(s.staffNotes, 'Late arrival');
  const october = nightsOf(w.fake, '2026-10');
  assert.equal(october['2026-10-02'].s, 'airbnb_HMFIRST001');
  assert.equal(october['2026-10-05'], undefined);
  const changed = w.fake.list(P.notifications).find((n) => n.data.type === 'STAY_BOOKING_CHANGED')!;
  assert.equal(changed.id, 'stay_booking_changed_airbnb_HMFIRST001_2');
  assert.match(changed.data.message as string, /moved to Oct 2–5 \(was Oct 3–6\)/);
  assert.equal(w.fake.list(P.stays).length, 3);
});

test('after the first sync, a new future booking is announced once; a stay is never duplicated', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.now.ms += 30 * MIN;
  w.feed.set([...FIRST, { code: 'HMNEWBOOK1', checkIn: '2026-11-01', checkOut: '2026-11-04' }]);
  const r = await run(w);
  assert.equal(r.created, 1);
  const imported = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_IMPORTED');
  assert.deepEqual(imported.map((n) => n.id), ['stay_booking_imported_airbnb_HMNEWBOOK1_1']);
  assert.equal(imported[0].data.message, 'New Airbnb booking at Airbnb 1: Nov 1–4 (3 nights).');
  assert.deepEqual(imported[0].data.metadata, {
    stayId: 'airbnb_HMNEWBOOK1',
    listingId: LISTING,
    channelId: CHANNEL,
    route: `/stays/booking?facilityId=${FAC}&stayId=airbnb_HMNEWBOOK1`,
  });
  w.now.ms += 30 * MIN;
  w.feed.setText(w.feed.body + '\r\n');
  await run(w);
  assert.equal(w.fake.list(P.stays).length, 4);
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_IMPORTED').length, 1);
});

test('a booking that leaves the feed is removed only after 3 misses 30 minutes apart and 90 minutes on', async () => {
  const w = world();
  const extra = [
    { code: 'HMKEEP0001', checkIn: '2026-11-01', checkOut: '2026-11-03' },
    { code: 'HMKEEP0002', checkIn: '2026-11-05', checkOut: '2026-11-07' },
  ];
  w.feed.set([...FIRST, ...extra]);
  await run(w);
  const without = [FIRST[1], ...FIRST.slice(2), ...extra];
  w.feed.set(without);

  const t0 = w.now.ms + 30 * MIN;
  const seen: [number, number, string][] = [];
  for (const [offset, manual] of [
    [0, false],
    [10, true], // a Sync now 10 minutes later does not count as another miss
    [30, false],
    [60, false],
    [90, false],
  ] as [number, boolean][]) {
    w.now.ms = t0 + offset * MIN;
    const r = manual ? await syncChannel(FAC, CHANNEL, 'manual', { deps: w.deps }) : await run(w);
    const s = stayDoc(w, 'airbnb_HMFIRST001')!;
    seen.push([offset, s.sync?.missCount ?? 0, s.status]);
    if (offset < 90) assert.equal(r.removed, 0);
    else assert.equal(r.removed, 1);
  }
  assert.deepEqual(seen, [
    [0, 1, 'confirmed'],
    [10, 1, 'confirmed'],
    [30, 2, 'confirmed'],
    [60, 3, 'confirmed'],
    [90, 4, 'removed_from_feed'],
  ]);
  const removed = stayDoc(w, 'airbnb_HMFIRST001')!;
  assert.equal(removed.cancelledBy, 'feed');
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-03'], undefined);
  const note = w.fake.list(P.notifications).find((n) => n.data.type === 'STAY_BOOKING_REMOVED')!;
  assert.match(note.data.message as string, /Oct 3–6, is no longer in the Airbnb calendar/);

  // It comes back: restored, nights re-held.
  w.now.ms += 30 * MIN;
  w.feed.set([...FIRST, ...extra]);
  const back = await run(w);
  assert.equal(back.restored, 1);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.status, 'confirmed');
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.cancelledBy, null);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-03'].s, 'airbnb_HMFIRST001');
});

test('a failed fetch never counts as a miss; three in a row (or a dead link) alert once a day', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.feed.set(FIRST.slice(1));
  w.now.ms += 30 * MIN;
  await run(w);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.sync?.missCount, 1);

  w.feed.fail('timeout');
  for (let i = 1; i <= 4; i++) {
    w.now.ms += 30 * MIN;
    const r = await run(w);
    assert.equal(r.status, 'timeout');
    assert.equal(channelSync(w).consecutiveFailures, i);
    assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.sync?.missCount, 1);
  }
  const failing = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_FEED_FAILING');
  assert.equal(failing.length, 1);
  assert.equal(failing[0].id, `stay_feed_${CHANNEL}_failing_2026-10-01`);
  assert.equal(channelSync(w).lease, null);

  // The feed recovers: the failure count resets.
  w.feed.set(FIRST.slice(1));
  w.now.ms += 30 * MIN;
  await run(w);
  assert.equal(channelSync(w).consecutiveFailures, 0);

  // A dead link (404) alerts at once.
  const g = world();
  g.feed.fail('gone', 404);
  const r = await run(g);
  assert.deepEqual([r.status, r.httpStatus], ['gone', 404]);
  assert.deepEqual(notificationTypes(g.fake), ['STAY_FEED_FAILING']);
  assert.match(g.fake.list(P.notifications)[0].data.message as string, /stopped working/);
});

test('an HTML login page or a cut-off calendar is invalid_feed and changes no stay', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  const before = w.fake.writesTo('stays').length;
  w.now.ms += 30 * MIN;
  w.feed.setText('BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\n');
  const r = await run(w);
  assert.equal(r.status, 'invalid_feed');
  assert.equal(w.fake.writesTo('stays').length, before);
  assert.equal(channelSync(w).lastErrorCode, 'invalid_feed');
});

test('the lease stops a second sync of the same channel from running alongside', async () => {
  const w = world();
  w.feed.set(FIRST);
  let release: () => void = () => undefined;
  w.feed.gate = new Promise<void>((r) => {
    release = r;
  });
  const first = run(w);
  // Wait until the first run holds the lease and is fetching.
  while (w.feed.calls.length === 0) await new Promise((r) => setImmediate(r));
  const secondRun = syncChannel(FAC, CHANNEL, 'manual', { deps: w.deps });
  const second = await Promise.race([secondRun, new Promise<null>((r) => setTimeout(() => r(null), 300))]);
  release();
  assert.ok(second, 'the second run must return at once, not wait on the feed');
  assert.equal(second.skipped, true);
  assert.equal(w.feed.calls.length, 1);
  const r = await first;
  assert.equal(r.created, 3);
  assert.equal(channelSync(w).lease, null);

  // An expired lease (a crashed run) does not block.
  w.fake.seed(`${P.channels}/${CHANNEL}`, {
    ...channel(w),
    sync: { ...channelSync(w), lease: { runId: 'dead', expiresAt: Timestamp.fromMillis(w.now.ms - 1) } },
  });
  w.feed.gate = null;
  w.now.ms += 30 * MIN;
  assert.notEqual((await run(w)).skipped, true);
});

test('an empty feed removes nothing: it is suspicious, alerts once a day, and keeps the blocks', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.feed.set([]);
  for (let i = 1; i <= 8; i++) {
    w.now.ms += 30 * MIN;
    const r = await run(w);
    assert.equal(r.status, 'suspicious');
    assert.equal(r.removed, 0);
  }
  for (const id of ['airbnb_HMFIRST001', 'airbnb_HMFIRST002']) {
    assert.equal(stayDoc(w, id)?.status, 'confirmed');
    assert.equal(stayDoc(w, id)?.sync?.missCount, 8);
  }
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_FEED_SUSPICIOUS').length, 1);
  assert.equal(channelSync(w).futureReservationCount, 2);
  assert.ok(channelSync(w).suspiciousSince);
  assert.deepEqual(w.fake.read(`${P.blocks}/${CHANNEL}`)?.ranges, [{ checkIn: '2026-10-15', checkOut: '2026-10-22', echo: false }]);

  // The feed comes back: the flag clears and the misses reset.
  w.now.ms += 30 * MIN;
  w.feed.set(FIRST);
  const ok = await run(w);
  assert.equal(ok.status, 'ok');
  assert.equal(channelSync(w).suspiciousSince, null);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.sync?.missCount, 0);
});

test('a missing booking that is checked in or paid is flagged for review, never removed', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.fake.seed(`${P.stays}/airbnb_HMFIRST001`, {
    ...(stayDoc(w, 'airbnb_HMFIRST001') as unknown as Record<string, unknown>),
    arrivalState: 'checked_in',
    checkedInAt: Timestamp.fromMillis(w.now.ms),
  });
  w.fake.seed(`${P.income}/man_00000000000000000000000000000001`, { facilityId: FAC, stayId: 'airbnb_HMFIRST002', status: 'posted', netCents: 5000 });
  w.feed.set(FIRST.slice(2));
  const t0 = w.now.ms;
  for (const offset of [30, 60, 90, 120, 150]) {
    w.now.ms = t0 + offset * MIN;
    await run(w);
  }
  for (const id of ['airbnb_HMFIRST001', 'airbnb_HMFIRST002']) {
    assert.equal(stayDoc(w, id)?.status, 'confirmed', id);
    assert.equal(stayDoc(w, id)?.sync?.needsReview, true, id);
  }
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.arrivalState, 'checked_in');
  const reviews = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_NEEDS_REVIEW');
  assert.equal(reviews.length, 2);
});

test('a booking entered by hand with its Airbnb code is adopted by the feed, keeping what staff typed', async () => {
  const w = world();
  w.fake.seed(`${P.stays}/airbnb_HMFIRST001`, makeStay(LISTING, '2026-10-03', '2026-10-06', {
    source: 'airbnb',
    origin: 'sfc',
    guestDisplayName: 'Jane D.',
    external: { provider: 'airbnb', uid: null, uidHistory: [], confirmationCode: 'HMFIRST001', reservationUrl: null, summary: null },
    createdAtMs: NOW - 1000,
    version: 3,
  }) as unknown as Record<string, unknown>);
  w.feed.set(FIRST);
  const r = await run(w);
  assert.equal(r.created, 2);
  const s = stayDoc(w, 'airbnb_HMFIRST001')!;
  assert.equal(s.origin, 'sfc');
  assert.equal(s.guestDisplayName, 'Jane D.');
  assert.equal(s.sync?.channelId, CHANNEL);
  assert.equal(s.external?.uid, 'uid-hmfirst001@airbnb.com');
  assert.equal(s.version, 4);
  assert.equal(w.fake.list(P.stays).length, 3);
});

test('a feed booking over nights SFC already sold is recorded as a double booking, not refused', async () => {
  const w = world();
  w.fake.seed(`${P.stays}/man_walkup`, makeStay(LISTING, '2026-10-04', '2026-10-05', { source: 'walk_up', createdAtMs: NOW - 5000 }) as unknown as Record<
    string,
    unknown
  >);
  w.feed.set(FIRST);
  const r = await run(w);
  assert.equal(r.conflicts, 1);
  const feedStay = stayDoc(w, 'airbnb_HMFIRST001')!;
  assert.equal(feedStay.status, 'conflict');
  assert.deepEqual(feedStay.conflict?.stayIds, ['man_walkup']);
  assert.deepEqual(feedStay.conflict?.nights, ['2026-10-04']);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-04'].s, 'man_walkup');
  const conflict = w.fake.list(P.notifications).find((n) => n.data.type === 'STAY_CONFLICT')!;
  assert.match(conflict.data.message as string, /Double booking at .*: Airbnb guest, Oct 3–6, overlaps another booking\./);
  assert.match(conflict.id, /^stay_conflict_airbnb_HMFIRST001_[a-f0-9]{12}$/);
});

test('soft blocks fill only free nights and never make a conflict', async () => {
  const w = world();
  w.fake.seed(`${P.stays}/man_owner`, makeStay(LISTING, '2026-10-16', '2026-10-18', { kind: 'owner_block', source: 'owner', createdAtMs: NOW - 5000 }) as unknown as Record<
    string,
    unknown
  >);
  w.feed.set(FIRST);
  const r = await run(w);
  assert.equal(r.conflicts, 0);
  assert.equal(stayDoc(w, 'man_owner')?.status, 'confirmed');
  const october = nightsOf(w.fake, '2026-10');
  assert.equal(october['2026-10-16'].s, 'man_owner');
  assert.equal(october['2026-10-15'].s, `blk:${CHANNEL}`);
  assert.equal(october['2026-10-15'].h, false);
});

test('our own exported blocks coming back from Airbnb are marked as echoes', async () => {
  const w = world();
  w.fake.seed(`${P.stays}/man_owner`, makeStay(LISTING, '2026-10-16', '2026-10-18', { kind: 'owner_block', source: 'owner', createdAtMs: NOW - 5000 }) as unknown as Record<
    string,
    unknown
  >);
  w.fake.seed(`${P.links}/xl_1`, { facilityId: FAC, listingId: LISTING, targetProvider: 'airbnb', scope: 'blocks_only', active: true });
  // Airbnb adds a prep night either side of what it imported from us.
  w.feed.set([{ checkIn: '2026-10-15', checkOut: '2026-10-19' }, { checkIn: '2026-11-10', checkOut: '2026-11-12' }]);
  await run(w);
  assert.deepEqual(w.fake.read(`${P.blocks}/${CHANNEL}`)?.ranges, [
    { checkIn: '2026-10-15', checkOut: '2026-10-19', echo: true },
    { checkIn: '2026-11-10', checkOut: '2026-11-12', echo: false },
  ]);
  const october = nightsOf(w.fake, '2026-10');
  assert.equal(october['2026-10-15'].e, true);
  assert.equal(nightsOf(w.fake, '2026-11')['2026-11-10'].e, undefined);
});

test('turning block import off clears the soft locks', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.fake.seed(`${P.channels}/${CHANNEL}`, { ...channel(w), importBlocks: false, sync: { ...channelSync(w), contentSha256: null, etag: null } });
  w.now.ms += 30 * MIN;
  await run(w);
  assert.deepEqual(w.fake.read(`${P.blocks}/${CHANNEL}`)?.ranges, []);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-16'], undefined);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.status, 'confirmed');
});

test('a booking another active feed already owns is left to that feed', async () => {
  const w = world();
  seedChannel(w.fake, 'ch_other');
  w.feed.set(FIRST);
  await syncChannel(FAC, 'ch_other', 'manual', { deps: w.deps });
  const owner = stayDoc(w, 'airbnb_HMFIRST001')!.sync?.channelId;
  assert.equal(owner, 'ch_other');
  w.now.ms += 5 * MIN;
  w.feed.setText(w.feed.body + '\r\n');
  const r = await run(w);
  assert.equal(r.created, 0);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')!.sync?.channelId, 'ch_other');
});

test('skipped when Stays is paused, and a missing channel or URL never throws', async () => {
  const paused = world({ gate: { killSwitch: true } });
  paused.feed.set(FIRST);
  const r = await run(paused);
  assert.equal(r.skipped, true);
  assert.equal(paused.feed.calls.length, 0);

  const missing = world();
  assert.equal((await syncChannel(FAC, 'ch_nope', 'manual', { deps: missing.deps })).skipped, true);

  const noUrl = world();
  noUrl.fake.seed(`${P.channels}/${CHANNEL}/secret/current`, {});
  const gone = await run(noUrl);
  assert.equal(gone.status, 'gone');
  assert.equal(noUrl.feed.calls.length, 0);
});

test('employees and owners never appear as the writer of feed changes', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  for (const s of w.fake.list(P.stays)) {
    assert.notEqual(s.data.updatedBy, OWNER);
    assert.notEqual(s.data.updatedBy, EMPLOYEE);
    assert.equal(s.data.createdBy, 'system:stays-sync');
  }
});

test('isolation: the sync never touched a storage collection', () => {
  for (const fake of all) fake.assertIsolation();
});
