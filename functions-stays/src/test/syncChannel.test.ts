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
  FeedServer,
  LISTING,
  MIN,
  NOW,
  P,
  SyncWorld,
  nightsOf,
  notificationTypes,
  seedChannel,
  seedListing,
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

test('an empty feed removes nothing, however long it stays empty: suspicious, alerts once a day, asks at 12 misses, keeps the blocks', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.feed.set([]);
  // 16 runs is 8 hours: well past the 12 misses a suspicious feed needs.
  for (let i = 1; i <= 16; i++) {
    w.now.ms += 30 * MIN;
    const r = await run(w);
    assert.equal(r.status, 'suspicious', `run ${i}`);
    assert.equal(r.removed, 0, `run ${i}`);
    assert.equal(r.needsReview, i === 12 ? 2 : 0, `run ${i}`);
  }
  for (const id of ['airbnb_HMFIRST001', 'airbnb_HMFIRST002']) {
    assert.equal(stayDoc(w, id)?.status, 'confirmed');
    assert.equal(stayDoc(w, id)?.sync?.needsReview, true);
    // Flagged at the 12th miss with its count reset (a person decides now); after that the doc is left alone.
    assert.deepEqual([stayDoc(w, id)?.sync?.missCount, stayDoc(w, id)?.sync?.firstMissAt], [0, null]);
  }
  // Its nights are still held.
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-03'].s, 'airbnb_HMFIRST001');
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-06'].s, 'airbnb_HMFIRST002');
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_REMOVED').length, 0);
  const reviews = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_NEEDS_REVIEW');
  assert.equal(reviews.length, 2);
  assert.match(reviews[0].data.message as string, /looks empty, so SFC kept it and its nights\./);
  const suspicious = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_FEED_SUSPICIOUS');
  assert.equal(suspicious.length, 1);
  assert.match(suspicious[0].data.message as string, /suddenly looks empty\. SFC removed nothing/);
  assert.equal(channelSync(w).futureReservationCount, 2);
  assert.ok(channelSync(w).suspiciousSince);
  assert.deepEqual(w.fake.read(`${P.blocks}/${CHANNEL}`)?.ranges, [{ checkIn: '2026-10-15', checkOut: '2026-10-22', echo: false }]);

  // The feed comes back: the flag clears and the misses and review reset.
  w.now.ms += 30 * MIN;
  w.feed.set(FIRST);
  const ok = await run(w);
  assert.equal(ok.status, 'ok');
  assert.equal(channelSync(w).suspiciousSince, null);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.sync?.missCount, 0);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.sync?.needsReview, false);
});

/** What staysReviewStay's clear_review writes: the flag off, everything else as it was, a new version. */
function clearReview(w: SyncWorld, id: string): void {
  const s = stayDoc(w, id)!;
  w.fake.seed(`${P.stays}/${id}`, { ...(s as unknown as Record<string, unknown>), sync: { ...s.sync, needsReview: false }, version: s.version + 1 });
}

test('clearing a review starts the watch over: no removal, and no new flag, at the next run', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.feed.set([]);
  for (let i = 1; i <= 12; i++) {
    w.now.ms += 30 * MIN;
    await run(w);
  }
  const ids = ['airbnb_HMFIRST001', 'airbnb_HMFIRST002'];
  for (const id of ids) assert.equal(stayDoc(w, id)?.sync?.needsReview, true);
  for (const id of ids) clearReview(w, id);
  const reviewNotes = () => w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_NEEDS_REVIEW').length;
  const asked = reviewNotes();

  // Still empty: counted again from the start, not flagged again at once.
  w.now.ms += 30 * MIN;
  const still = await run(w);
  assert.equal(still.needsReview, 0);
  for (const id of ids) assert.deepEqual([stayDoc(w, id)?.sync?.needsReview, stayDoc(w, id)?.sync?.missCount], [false, 1], id);
  assert.equal(reviewNotes(), asked);

  // The feed lists a new booking again, but not these two: their nights are not freed at the next run either.
  w.feed.set([{ code: 'HMNEWONE01', checkIn: '2026-11-01', checkOut: '2026-11-03' }, ...FIRST.slice(2)]);
  w.now.ms += 30 * MIN;
  const listed = await run(w);
  assert.equal(listed.removed, 0);
  for (const id of ids) assert.equal(stayDoc(w, id)?.status, 'confirmed', id);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-03'].s, 'airbnb_HMFIRST001');
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_REMOVED').length, 0);
});

test('a feed that empties in steps and keeps its blocks removes nothing: its bookings go to review at the 12th miss', async () => {
  const w = world();
  const four = [
    { code: 'HMSTEP0001', checkIn: '2026-10-03', checkOut: '2026-10-06' },
    { code: 'HMSTEP0002', checkIn: '2026-10-08', checkOut: '2026-10-10' },
    { code: 'HMSTEP0003', checkIn: '2026-10-12', checkOut: '2026-10-14' },
    { code: 'HMSTEP0004', checkIn: '2026-10-16', checkOut: '2026-10-18' },
  ];
  const blocks = [{ checkIn: '2026-10-25', checkOut: '2026-10-28' }];
  w.feed.set([...four, ...blocks]);
  await run(w);
  // 4 bookings, then 2, then none: no single step goes from 3 or more to 0.
  w.now.ms += 30 * MIN;
  w.feed.set([...four.slice(2), ...blocks]);
  await run(w);
  w.feed.set(blocks);
  for (let i = 1; i <= 16; i++) {
    w.now.ms += 30 * MIN;
    const r = await run(w);
    assert.deepEqual([r.status, r.removed], ['suspicious', 0], `run ${i}`);
  }
  for (const f of four) {
    const s = stayDoc(w, `airbnb_${f.code}`)!;
    assert.deepEqual([s.status, s.sync?.needsReview], ['confirmed', true], f.code);
  }
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-03'].s, 'airbnb_HMSTEP0001');
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_REMOVED').length, 0);
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_NEEDS_REVIEW').length, 4);
});

test('a feed emptied to blocks only, then byte-identical, still holds past 12 runs', async () => {
  const w = world();
  const three = [FIRST[0], FIRST[1], { code: 'HMTHIRD001', checkIn: '2026-11-01', checkOut: '2026-11-04' }];
  w.feed.set([...three, ...FIRST.slice(2)]);
  await run(w);
  // One step to blocks only; after that the server sends the very same bytes every time.
  w.feed.set(FIRST.slice(2));
  const statuses = new Set<string>();
  for (let i = 1; i <= 16; i++) {
    w.now.ms += 30 * MIN;
    const r = await run(w);
    statuses.add(`${r.status}/${r.httpStatus}`);
    assert.equal(r.removed, 0, `run ${i}`);
  }
  // A suspicious feed is fetched unconditionally and diffed in full, even when nothing changed.
  assert.deepEqual([...statuses], ['suspicious/200']);
  for (const t of three) {
    const s = stayDoc(w, `airbnb_${t.code}`)!;
    assert.deepEqual([s.status, s.sync?.needsReview], ['confirmed', true], t.code);
  }
  assert.equal(nightsOf(w.fake, '2026-11')['2026-11-01'].s, 'airbnb_HMTHIRD001');
});

test('on a 304 feed, two cancellations out of five are ordinary: removed at the 4th run, not held as suspicious', async () => {
  const w = world();
  const five = [
    { code: 'HMFIVE0001', checkIn: '2026-10-03', checkOut: '2026-10-06' },
    { code: 'HMFIVE0002', checkIn: '2026-10-08', checkOut: '2026-10-10' },
    { code: 'HMFIVE0003', checkIn: '2026-10-12', checkOut: '2026-10-14' },
    { code: 'HMFIVE0004', checkIn: '2026-10-16', checkOut: '2026-10-18' },
    { code: 'HMFIVE0005', checkIn: '2026-10-20', checkOut: '2026-10-22' },
  ];
  w.feed.set(five);
  await run(w);
  w.feed.set(five.slice(2));
  const seen: [string, number | null, number][] = [];
  for (let i = 1; i <= 4; i++) {
    w.now.ms += 30 * MIN;
    const r = await run(w);
    seen.push([r.status, r.httpStatus, r.removed]);
  }
  assert.deepEqual(seen, [
    ['ok', 200, 0],
    ['not_modified', 304, 0],
    ['not_modified', 304, 0],
    ['not_modified', 304, 2],
  ]);
  assert.equal(stayDoc(w, 'airbnb_HMFIVE0001')?.status, 'removed_from_feed');
  assert.equal(channelSync(w).suspiciousSince, null);
});

test('a feed that drops half its bookings and then answers 304 turns suspicious instead of removing them', async () => {
  const w = world();
  const four = [
    { code: 'HMMASS0001', checkIn: '2026-10-03', checkOut: '2026-10-06' },
    { code: 'HMMASS0002', checkIn: '2026-10-08', checkOut: '2026-10-10' },
    { code: 'HMMASS0003', checkIn: '2026-10-12', checkOut: '2026-10-14' },
    { code: 'HMMASS0004', checkIn: '2026-10-16', checkOut: '2026-10-18' },
  ];
  w.feed.set(four);
  await run(w);
  // Two vanish once; after that the server honours our ETag and answers 304.
  w.feed.set(four.slice(2));
  const alerts = () => w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_FEED_SUSPICIOUS').length;
  const seen: [string, number | null, number, number][] = [];
  for (let i = 1; i <= 6; i++) {
    w.now.ms += 30 * MIN;
    const r = await run(w);
    seen.push([r.status, r.httpStatus, r.removed, alerts()]);
  }
  assert.deepEqual(seen, [
    ['ok', 200, 0, 0],
    ['not_modified', 304, 0, 0],
    ['not_modified', 304, 0, 0],
    // The 4th miss would remove both of them: half the feed's bookings at once. The 304 run itself alerts.
    ['suspicious', 304, 0, 1],
    // Suspicious feeds are fetched and diffed in full, and stay suspicious.
    ['suspicious', 200, 0, 1],
    ['suspicious', 200, 0, 1],
  ]);
  for (const id of ['airbnb_HMMASS0001', 'airbnb_HMMASS0002']) {
    assert.equal(stayDoc(w, id)?.status, 'confirmed', id);
    assert.equal(stayDoc(w, id)?.sync?.missCount, 6, id);
  }
  assert.ok(channelSync(w).suspiciousSince);
  assert.equal(channelSync(w).lastStatus, 'suspicious');
  const notes = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_FEED_SUSPICIOUS');
  assert.equal(notes.length, 1);
  assert.match(notes[0].data.message as string, /suddenly missing many bookings\. SFC removed nothing and will wait about 6 hours/);
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_REMOVED').length, 0);

  // A feed that really lost half its bookings removes them at the 12th miss (spec §3.4.7).
  for (let i = 7; i <= 12; i++) {
    w.now.ms += 30 * MIN;
    await run(w);
  }
  assert.equal(stayDoc(w, 'airbnb_HMMASS0001')?.status, 'removed_from_feed');
  assert.equal(stayDoc(w, 'airbnb_HMMASS0003')?.status, 'confirmed');
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

  // Waiting on a person: later runs leave them alone instead of rewriting them every 30 minutes.
  const writes = w.fake.writesTo('stays').length;
  const misses = stayDoc(w, 'airbnb_HMFIRST001')?.sync?.missCount;
  for (let i = 1; i <= 4; i++) {
    w.now.ms += 30 * MIN;
    await run(w);
  }
  assert.equal(w.fake.writesTo('stays').length, writes);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.sync?.missCount, misses);
});

test('a guest checked in while a removal is being written is kept and flagged, not removed', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.feed.set(FIRST.slice(1));
  const t0 = w.now.ms;
  for (const offset of [30, 60, 90]) {
    w.now.ms = t0 + offset * MIN;
    await run(w);
  }
  // The next run removes it (4 misses, 90 minutes)... but staff check the guest in after the plan
  // was read and before the write (a check-in does not change the stay's version).
  const path = `${P.stays}/airbnb_HMFIRST001`;
  let checkedIn = false;
  w.fake.failReads = (p) => {
    if (p === path && !checkedIn) {
      checkedIn = true;
      w.fake.seed(path, { ...w.fake.read(path), arrivalState: 'checked_in', checkedInAt: Timestamp.fromMillis(w.now.ms) });
    }
    return false;
  };
  w.now.ms = t0 + 120 * MIN;
  const r = await run(w);
  w.fake.failReads = null;
  assert.ok(checkedIn);
  assert.deepEqual([r.removed, r.needsReview], [0, 1]);
  const s = stayDoc(w, 'airbnb_HMFIRST001')!;
  assert.deepEqual([s.status, s.arrivalState, s.sync?.needsReview], ['confirmed', 'checked_in', true]);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-03'].s, 'airbnb_HMFIRST001');
  assert.deepEqual(
    w.fake.list(P.notifications).filter((n) => /STAY_BOOKING_(REMOVED|NEEDS_REVIEW)/.test(n.data.type as string)).map((n) => n.data.type),
    ['STAY_BOOKING_NEEDS_REVIEW'],
  );
});

test('scheduled runs count misses on the slot clock, so a job that ran late still spaces the next miss', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.feed.set(FIRST.slice(1));
  // The 18:30 slot's job runs 20 minutes late; the 19:00 slot's runs on time, 11 minutes after it.
  w.now.ms = NOW + 50 * MIN;
  await run(w);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.sync?.missCount, 1);
  assert.equal((stayDoc(w, 'airbnb_HMFIRST001')?.sync?.lastMissAt as Timestamp).toMillis(), NOW + 30 * MIN);
  w.now.ms = NOW + 61 * MIN;
  await run(w);
  assert.equal(stayDoc(w, 'airbnb_HMFIRST001')?.sync?.missCount, 2);
});

test('a new phone last 4 on an otherwise unchanged booking updates the private doc and door code at once', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  // The owner typed her own code for the second booking: that one stays hers.
  w.fake.seed(`${P.access}/airbnb_HMFIRST002`, {
    facilityId: FAC,
    stayId: 'airbnb_HMFIRST002',
    doorCode: '7788',
    gateCode: null,
    accessNotes: '',
    source: 'manual',
    updatedAt: null,
    updatedBy: OWNER,
  });
  const stayWrites = w.fake.writesTo('stays').length;
  w.now.ms += 30 * MIN;
  w.feed.set([{ ...FIRST[0], phone: '2222' }, { ...FIRST[1], phone: '3333' }, ...FIRST.slice(2)]);
  await run(w);
  assert.equal(w.fake.read(`${P.private}/airbnb_HMFIRST001`)?.phoneLast4, '2222');
  const access1 = w.fake.read(`${P.access}/airbnb_HMFIRST001`)!;
  assert.deepEqual([access1.doorCode, access1.source], ['2222', 'phone_last4']);
  assert.equal(w.fake.read(`${P.private}/airbnb_HMFIRST002`)?.phoneLast4, '3333');
  const access2 = w.fake.read(`${P.access}/airbnb_HMFIRST002`)!;
  assert.deepEqual([access2.doorCode, access2.source], ['7788', 'manual']);
  // The bookings themselves did not change, so neither did their docs.
  assert.equal(w.fake.writesTo('stays').length, stayWrites);
  // The same phone again writes nothing.
  const privateWrites = w.fake.writesTo('stayPrivate').length + w.fake.writesTo('stayAccess').length;
  w.now.ms += 30 * MIN;
  w.feed.setText(w.feed.body + '\r\n');
  await run(w);
  assert.equal(w.fake.writesTo('stayPrivate').length + w.fake.writesTo('stayAccess').length, privateWrites);
});

test('a sync in flight when block import is switched off does not write back its old content hash', async () => {
  const w = world();
  w.feed.set(FIRST);
  await run(w);
  w.now.ms += 30 * MIN;
  w.feed.setText(w.feed.body + '\r\n');
  let release: () => void = () => undefined;
  w.feed.gate = new Promise<void>((r) => {
    release = r;
  });
  const inflight = run(w);
  while (w.feed.calls.length < 2) await new Promise((r) => setImmediate(r));
  // Meanwhile the owner turns block import off (staysUpsertChannel clears the hash and ETag).
  w.fake.seed(`${P.channels}/${CHANNEL}`, {
    ...channel(w),
    importBlocks: false,
    sync: { ...channelSync(w), etag: null, lastModified: null, contentSha256: null },
  });
  w.feed.gate = null;
  release();
  await inflight;
  assert.equal(channelSync(w).contentSha256, null);
  assert.equal(channelSync(w).etag, null);
  assert.equal(channelSync(w).lease, null);
  // So the next run diffs in full, without the blocks, even though the body has not changed.
  w.now.ms += 30 * MIN;
  await run(w);
  assert.deepEqual(w.fake.read(`${P.blocks}/${CHANNEL}`)?.ranges, []);
  assert.equal(nightsOf(w.fake, '2026-10')['2026-10-16'], undefined);
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

const LISTING_B = 'lst_airbnb2';
const CHANNEL_B = 'ch_airbnb2';
const URL_B = 'https://www.airbnb.com/calendar/ical/444555666.ics?s=fedcba9876543210';

/** A second Airbnb listing with its own feed (the world's feed serves the first). */
function secondListing(w: SyncWorld): FeedServer {
  seedListing(w.fake, LISTING_B, { name: 'Airbnb 2', shortCode: 'A2' });
  seedChannel(w.fake, CHANNEL_B, { listingId: LISTING_B }, URL_B);
  const feedB = new FeedServer();
  const fetchA = w.deps.fetchFeed;
  w.deps.fetchFeed = (url, opts) => (url === URL_B ? feedB.fetchFeed(url, opts) : fetchA(url, opts));
  return feedB;
}

const MOVE = { code: 'HMMOVE0001', checkIn: '2026-10-03', checkOut: '2026-10-06' };
const KEEP_A = { code: 'HMKEEPA001', checkIn: '2026-10-20', checkOut: '2026-10-22' };
const KEEP_B = { code: 'HMKEEPB001', checkIn: '2026-11-20', checkOut: '2026-11-22' };

test('a reservation Airbnb moves to another listing follows it once the old feed lets go, and is never lost', async () => {
  const w = world();
  const feedB = secondListing(w);
  w.feed.set([MOVE, KEEP_A]);
  feedB.set([KEEP_B]);
  await run(w);
  await run(w, CHANNEL_B);
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.listingId, LISTING);

  // Airbnb moves it to listing B. B happens to sync first, while A's feed has not yet dropped it.
  w.feed.set([KEEP_A]);
  feedB.set([KEEP_B, MOVE]);
  w.now.ms += 30 * MIN;
  await run(w, CHANNEL_B);
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.listingId, LISTING, 'still listed by A: left there for now');
  assert.equal(nightsOf(w.fake, '2026-10', LISTING_B)['2026-10-03'], undefined);
  const clash = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_NEEDS_REVIEW');
  assert.equal(clash.length, 1);
  assert.match(clash[0].data.message as string, /Airbnb calendar for Airbnb 2 lists a booking SFC has on Airbnb 1, Oct 3–6\. SFC left it on Airbnb 1/);
  await run(w);
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.sync?.missCount, 1);

  // A missing it is not yet letting go: B leaves it until A would remove it too, which takes
  // 3 misses and 90 minutes (at the third miss only 60 have passed).
  for (let i = 2; i <= 3; i++) {
    w.now.ms += 30 * MIN;
    await run(w);
    assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.sync?.missCount, i);
    await run(w, CHANNEL_B);
    assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.listingId, LISTING, `slot ${i}`);
  }
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_NEEDS_REVIEW').length, 1);

  // 90 minutes after A first missed it, A has let go for certain: B takes it, nights and all.
  w.now.ms += 30 * MIN;
  await run(w, CHANNEL_B);
  const moved = stayDoc(w, 'airbnb_HMMOVE0001')!;
  assert.deepEqual(
    [moved.listingId, moved.listingName, moved.status, moved.sync?.channelId, moved.sync?.missCount],
    [LISTING_B, 'Airbnb 2', 'confirmed', CHANNEL_B, 0],
  );
  assert.equal(nightsOf(w.fake, '2026-10', LISTING_B)['2026-10-03'].s, 'airbnb_HMMOVE0001');
  assert.equal(nightsOf(w.fake, '2026-10', LISTING)['2026-10-03'], undefined);
  const change = w.fake.list(P.notifications).find((n) => n.data.type === 'STAY_BOOKING_CHANGED')!;
  assert.equal(change.data.message, 'Airbnb moved the booking Oct 3–6 from Airbnb 1 to Airbnb 2. SFC moved it too.');

  // A's feed no longer owns it: it is never "removed" there.
  for (let i = 1; i <= 4; i++) {
    w.now.ms += 30 * MIN;
    const r = await run(w);
    assert.equal(r.removed, 0);
  }
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.status, 'confirmed');
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.listingId, LISTING_B);
  assert.equal(w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_REMOVED').length, 0);
  assert.equal(w.fake.list(P.stays).filter((s) => s.id === 'airbnb_HMMOVE0001').length, 1);
});

/** Both listings synced once, with MOVE on listing A. */
async function movedWorld(): Promise<{ w: SyncWorld; feedB: FeedServer }> {
  const w = world();
  const feedB = secondListing(w);
  w.feed.set([MOVE, KEEP_A]);
  feedB.set([KEEP_B]);
  await run(w);
  await run(w, CHANNEL_B);
  return { w, feedB };
}

const moveNotes = (w: SyncWorld) =>
  w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_CHANGED' && /SFC moved it too/.test(n.data.message as string));

test('one missed fetch of the old feed never moves a booking to another listing', async () => {
  const { w, feedB } = await movedWorld();
  // A's feed leaves it out once (a hiccup) while B's lists it.
  w.feed.set([KEEP_A]);
  feedB.set([KEEP_B, MOVE]);
  w.now.ms += 30 * MIN;
  await run(w);
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.sync?.missCount, 1);
  await run(w, CHANNEL_B);
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.listingId, LISTING);
  // A lists it again: it stays on A, whatever B's feed says.
  w.feed.set([MOVE, KEEP_A]);
  w.now.ms += 30 * MIN;
  await run(w);
  await run(w, CHANNEL_B);
  const s = stayDoc(w, 'airbnb_HMMOVE0001')!;
  assert.deepEqual([s.listingId, s.sync?.channelId, s.sync?.missCount], [LISTING, CHANNEL, 0]);
  assert.equal(nightsOf(w.fake, '2026-10', LISTING)['2026-10-03'].s, 'airbnb_HMMOVE0001');
  assert.equal(nightsOf(w.fake, '2026-10', LISTING_B)['2026-10-03'], undefined);
  assert.equal(moveNotes(w).length, 0);
});

test('a booking follows at once when its old feed was switched off, or had already removed it', async () => {
  // A's channel switched off (its bookings not detached).
  const off = await movedWorld();
  off.w.fake.seed(`${P.channels}/${CHANNEL}`, { ...channel(off.w), active: false });
  off.feedB.set([KEEP_B, MOVE]);
  off.w.now.ms += 30 * MIN;
  await run(off.w, CHANNEL_B);
  assert.deepEqual([stayDoc(off.w, 'airbnb_HMMOVE0001')?.listingId, stayDoc(off.w, 'airbnb_HMMOVE0001')?.sync?.channelId], [LISTING_B, CHANNEL_B]);
  assert.equal(nightsOf(off.w.fake, '2026-10', LISTING_B)['2026-10-03'].s, 'airbnb_HMMOVE0001');

  // A removed it (4 misses, 90 minutes) before B listed it: B brings it back, on B.
  const gone = await movedWorld();
  gone.w.feed.set([KEEP_A]);
  for (let i = 1; i <= 4; i++) {
    gone.w.now.ms += 30 * MIN;
    await run(gone.w);
  }
  assert.equal(stayDoc(gone.w, 'airbnb_HMMOVE0001')?.status, 'removed_from_feed');
  gone.feedB.set([KEEP_B, MOVE]);
  gone.w.now.ms += 30 * MIN;
  await run(gone.w, CHANNEL_B);
  const s = stayDoc(gone.w, 'airbnb_HMMOVE0001')!;
  assert.deepEqual([s.listingId, s.status, s.cancelledBy], [LISTING_B, 'confirmed', null]);
  assert.equal(nightsOf(gone.w.fake, '2026-10', LISTING_B)['2026-10-03'].s, 'airbnb_HMMOVE0001');
  assert.equal(moveNotes(gone.w).length, 1);
});

test('a move is re-checked when it is written: if the old feed lists the booking again meanwhile, it stays', async () => {
  const { w, feedB } = await movedWorld();
  feedB.set([KEEP_B, MOVE]);
  w.now.ms += 120 * MIN;
  // A's feed has missed it 3 times over 90 minutes: let go, as far as B's plan can tell.
  const path = `${P.stays}/airbnb_HMMOVE0001`;
  const missed = w.fake.read(path)!;
  const slotMs = Date.parse(`${slotOf(w.now.ms)}:00Z`);
  w.fake.seed(path, {
    ...missed,
    sync: {
      ...(missed.sync as Record<string, unknown>),
      missCount: 3,
      firstMissAt: Timestamp.fromMillis(slotMs - 90 * MIN),
      lastMissAt: Timestamp.fromMillis(slotMs - 30 * MIN),
    },
  });
  // Between B's plan and its write, A's sync lists it again (misses reset, a new version).
  let reads = 0;
  w.fake.failReads = (p) => {
    if (p === path && ++reads === 2) {
      const s = w.fake.read(path)!;
      w.fake.seed(path, {
        ...s,
        sync: { ...(s.sync as Record<string, unknown>), missCount: 0, firstMissAt: null, lastMissAt: null },
        version: (s.version as number) + 1,
      });
    }
    return false;
  };
  await run(w, CHANNEL_B);
  w.fake.failReads = null;
  assert.ok(reads >= 2);
  // The write re-checks the doc it is about to change: A's feed has it again, so it stays on A.
  const s = stayDoc(w, 'airbnb_HMMOVE0001')!;
  assert.deepEqual([s.listingId, s.sync?.channelId], [LISTING, CHANNEL]);
  assert.equal(nightsOf(w.fake, '2026-10', LISTING_B)['2026-10-03'], undefined);
  assert.equal(moveNotes(w).length, 0);
});

test('a booking with income posted on its old listing is not moved: the owner is asked', async () => {
  const { w, feedB } = await movedWorld();
  // A's feed is off, so the booking would follow Airbnb to B... but it has money recorded on A.
  w.fake.seed(`${P.channels}/${CHANNEL}`, { ...channel(w), active: false });
  w.fake.seed(`${P.income}/abnb_0000000000000000000000000000000000000001`, { facilityId: FAC, stayId: 'airbnb_HMMOVE0001', status: 'posted', netCents: 41000 });
  feedB.set([KEEP_B, MOVE]);
  w.now.ms += 30 * MIN;
  await run(w, CHANNEL_B);
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.listingId, LISTING);
  assert.equal(nightsOf(w.fake, '2026-10', LISTING_B)['2026-10-03'], undefined);
  assert.equal(moveNotes(w).length, 0);
  const asked = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_NEEDS_REVIEW');
  assert.deepEqual(asked.map((n) => (n.data.metadata as { stayId: string }).stayId), ['airbnb_HMMOVE0001']);
});

test('a reservation SFC has on another listing is not moved when it is checked in, typed in by hand, or still listed there', async () => {
  const w = world();
  const feedB = secondListing(w);
  w.feed.set([MOVE, KEEP_A]);
  feedB.set([KEEP_B]);
  await run(w);
  await run(w, CHANNEL_B);
  // The guest is already checked in on listing A.
  w.fake.seed(`${P.stays}/airbnb_HMMOVE0001`, {
    ...(stayDoc(w, 'airbnb_HMMOVE0001') as unknown as Record<string, unknown>),
    arrivalState: 'checked_in',
    checkedInAt: Timestamp.fromMillis(w.now.ms),
  });
  // And a booking the owner typed in on A with its Airbnb code.
  w.fake.seed(`${P.stays}/airbnb_HMHAND0001`, makeStay(LISTING, '2026-11-01', '2026-11-03', {
    listingName: 'Airbnb 1',
    source: 'airbnb',
    origin: 'sfc',
    external: { provider: 'airbnb', uid: null, uidHistory: [], confirmationCode: 'HMHAND0001', reservationUrl: null, summary: null },
    createdAtMs: NOW - 1000,
  }) as unknown as Record<string, unknown>);
  w.feed.set([KEEP_A]);
  feedB.set([KEEP_B, MOVE, { code: 'HMHAND0001', checkIn: '2026-11-01', checkOut: '2026-11-03' }]);
  for (let i = 1; i <= 3; i++) {
    w.now.ms += 30 * MIN;
    await run(w);
    await run(w, CHANNEL_B);
  }
  assert.equal(stayDoc(w, 'airbnb_HMMOVE0001')?.listingId, LISTING);
  assert.equal(stayDoc(w, 'airbnb_HMHAND0001')?.listingId, LISTING);
  assert.equal(nightsOf(w.fake, '2026-10', LISTING_B)['2026-10-03'], undefined);
  const asked = w.fake.list(P.notifications).filter((n) => n.data.type === 'STAY_BOOKING_NEEDS_REVIEW' && /lists a booking SFC has on Airbnb 1/.test(n.data.message as string));
  assert.deepEqual(asked.map((n) => (n.data.metadata as { stayId: string }).stayId).sort(), ['airbnb_HMHAND0001', 'airbnb_HMMOVE0001']);
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
