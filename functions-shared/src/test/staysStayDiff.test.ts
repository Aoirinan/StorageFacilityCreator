import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ExistingFeedStay,
  FeedReservation,
  MISS_SPACING_MS,
  PlanFeedSyncOptions,
  REMOVAL_MIN_AGE_MS,
  SUSPICIOUS_REQUIRED_MISSES,
  advanceMissesOnUnchanged,
  planFeedSync,
} from '../stays/stayDiff';

const CH = 'ch_a';
const TODAY = '2026-10-01';
const T0 = Date.parse('2026-10-01T18:00:00Z');
const MIN = 60_000;

function res(stayId: string, checkIn: string, checkOut: string, patch: Partial<FeedReservation> = {}): FeedReservation {
  return { stayId, uid: `${stayId}@feed`, confirmationCode: null, reservationUrl: null, summary: null, phoneLast4: null, checkIn, checkOut, ...patch };
}

function airbnb(code: string, checkIn: string, checkOut: string, uid = `${code.toLowerCase()}@airbnb.com`): FeedReservation {
  return res(`airbnb_${code}`, checkIn, checkOut, { confirmationCode: code, uid });
}

function stay(stayId: string, checkIn: string, checkOut: string, patch: Partial<ExistingFeedStay> = {}): ExistingFeedStay {
  return {
    stayId,
    status: 'confirmed',
    arrivalState: 'upcoming',
    paymentStatus: 'channel_collected',
    checkIn,
    checkOut,
    channelId: CH,
    detached: false,
    uid: `${stayId}@feed`,
    uidHistory: [],
    confirmationCode: null,
    missCount: 0,
    firstMissAtMs: null,
    lastMissAtMs: null,
    needsReview: false,
    agedOut: false,
    ...patch,
  };
}

function opts(patch: Partial<PlanFeedSyncOptions> = {}): PlanFeedSyncOptions {
  return { channelId: CH, todayYmd: TODAY, now: T0, prevFutureCount: 0, feedEventCount: 10, ...patch };
}

test('new reservations are created; old history is not', () => {
  const plan = planFeedSync([], [airbnb('HMNEW00001', '2026-10-05', '2026-10-08'), res('ical_old', '2026-05-01', '2026-05-03')], opts({ createAfterYmd: '2026-08-02' }));
  assert.deepEqual(plan.creates.map((c) => c.stayId), ['airbnb_HMNEW00001']);
  assert.equal(plan.skippedOld, 1);
  assert.equal(plan.futureReservationCount, 1);
  assert.equal(plan.suspicious, false);
});

test('an altered Airbnb booking keeps its doc: the confirmation code carries the new dates', () => {
  const existing = [stay('airbnb_HMALTER001', '2026-10-05', '2026-10-08', { confirmationCode: 'HMALTER001', uid: 'old@airbnb.com' })];
  const plan = planFeedSync(existing, [airbnb('HMALTER001', '2026-10-06', '2026-10-10', 'new@airbnb.com')], opts());
  assert.deepEqual(plan.creates, []);
  assert.deepEqual(plan.dateChanges.map((d) => [d.stayId, d.from.checkIn, d.reservation.checkIn, d.reservation.checkOut]), [
    ['airbnb_HMALTER001', '2026-10-05', '2026-10-06', '2026-10-10'],
  ]);
  assert.deepEqual(plan.uidRemaps, [{ stayId: 'airbnb_HMALTER001', fromUid: 'old@airbnb.com', toUid: 'new@airbnb.com' }]);
  assert.deepEqual(plan.missesAdvanced, []);
});

test('a new UID with the same dates on one of our missing stays is a remap, not a new booking', () => {
  const existing = [stay('ical_aaa', '2026-10-05', '2026-10-08', { uid: 'uid-1' })];
  const plan = planFeedSync(existing, [res('ical_bbb', '2026-10-05', '2026-10-08', { uid: 'uid-2' })], opts());
  assert.deepEqual(plan.creates, []);
  assert.deepEqual(plan.touches.map((t) => t.stayId), ['ical_aaa']);
  assert.deepEqual(plan.uidRemaps, [{ stayId: 'ical_aaa', fromUid: 'uid-1', toUid: 'uid-2' }]);

  // Seen again later under the new UID: matched through it.
  const later = planFeedSync([stay('ical_aaa', '2026-10-05', '2026-10-08', { uid: 'uid-2', uidHistory: ['uid-1'] })], [res('ical_bbb', '2026-10-05', '2026-10-08', { uid: 'uid-2' })], opts());
  assert.deepEqual(later.touches.map((t) => t.stayId), ['ical_aaa']);
  assert.deepEqual(later.uidRemaps, []);

  // Two of our stays with those dates: cannot tell which, so it is created instead.
  const ambiguous = planFeedSync(
    [stay('ical_x', '2026-10-05', '2026-10-08', { uid: 'x' }), stay('ical_y', '2026-10-05', '2026-10-08', { uid: 'y' })],
    [res('ical_z', '2026-10-05', '2026-10-08', { uid: 'z' })],
    opts(),
  );
  assert.deepEqual(ambiguous.creates.map((c) => c.stayId), ['ical_z']);
});

test('a manual or CSV airbnb_ stay, or one a removed feed left behind, is adopted', () => {
  const manual = stay('airbnb_HMMANUAL01', '2026-10-05', '2026-10-08', { channelId: null, uid: null, confirmationCode: 'HMMANUAL01', paymentStatus: 'none' });
  const csv = stay('airbnb_HMCSV00001', '2026-11-05', '2026-11-08', { channelId: null, uid: null, confirmationCode: null });
  const detached = stay('ical_old', '2026-12-01', '2026-12-03', { channelId: 'ch_removed', detached: true, uid: 'old-uid' });
  const plan = planFeedSync(
    [manual, csv, detached],
    [airbnb('HMMANUAL01', '2026-10-05', '2026-10-08'), airbnb('HMCSV00001', '2026-11-05', '2026-11-08'), res('ical_old', '2026-12-01', '2026-12-03', { uid: 'old-uid' })],
    opts(),
  );
  assert.deepEqual(plan.creates, []);
  assert.deepEqual(plan.adopted.sort(), ['airbnb_HMCSV00001', 'airbnb_HMMANUAL01', 'ical_old']);
  assert.deepEqual(plan.touches.map((t) => t.stayId).sort(), ['airbnb_HMCSV00001', 'airbnb_HMMANUAL01', 'ical_old']);
  // Adopted stays that are not this feed's yet never collect misses here.
  const unmatched = planFeedSync([manual], [], opts({ feedEventCount: 3 }));
  assert.deepEqual(unmatched.missesAdvanced, []);
});

test('a cancelled stay is never revived or re-owned by the feed', () => {
  const plan = planFeedSync([stay('airbnb_HMGONE0001', '2026-10-05', '2026-10-08', { status: 'cancelled', confirmationCode: 'HMGONE0001' })], [], opts());
  assert.deepEqual(plan.missesAdvanced, []);
  assert.deepEqual(plan.removals, []);
});

/** Runs the plan for a stay missing from the feed at `now`, carrying its miss state forward. */
function missRun(s: ExistingFeedStay, now: number, patch: Partial<PlanFeedSyncOptions> = {}) {
  const plan = planFeedSync([s, stay('ical_keep1', '2026-10-20', '2026-10-22'), stay('ical_keep2', '2026-10-24', '2026-10-26')], [res('ical_keep1', '2026-10-20', '2026-10-22'), res('ical_keep2', '2026-10-24', '2026-10-26')], opts({ now, prevFutureCount: 3, ...patch }));
  const m = plan.missState[s.stayId];
  const next: ExistingFeedStay = m ? { ...s, missCount: m.missCount, firstMissAtMs: m.firstMissAtMs, lastMissAtMs: m.lastMissAtMs } : s;
  return { plan, next };
}

test('removal takes 3 misses at least 30 minutes apart and 90 minutes after the first', () => {
  let s = stay('ical_gone', '2026-10-05', '2026-10-08');
  let r = missRun(s, T0);
  assert.equal(r.next.missCount, 1);
  assert.deepEqual(r.plan.removals, []);
  s = r.next;
  // Ten minutes later (a Sync now): not spaced out, so it does not count.
  r = missRun(s, T0 + 10 * MIN);
  assert.equal(r.next.missCount, 1);
  assert.deepEqual(r.plan.missesAdvanced, []);
  r = missRun(s, T0 + MISS_SPACING_MS);
  assert.equal(r.next.missCount, 2);
  s = r.next;
  r = missRun(s, T0 + 2 * MISS_SPACING_MS);
  assert.equal(r.next.missCount, 3);
  // Three misses, but only 60 minutes since the first.
  assert.deepEqual(r.plan.removals, []);
  s = r.next;
  r = missRun(s, T0 + REMOVAL_MIN_AGE_MS);
  assert.deepEqual(r.plan.removals, ['ical_gone']);
  assert.equal(r.plan.suspicious, false);
});

test('a missing stay that is checked in, paid or has income goes to review instead of removal', () => {
  const missing = { missCount: 3, firstMissAtMs: T0 - 2 * REMOVAL_MIN_AGE_MS, lastMissAtMs: T0 - MISS_SPACING_MS };
  const checkedIn = stay('ical_in', '2026-09-30', '2026-10-04', { arrivalState: 'checked_in', ...missing });
  const paid = stay('ical_paid', '2026-10-05', '2026-10-08', { paymentStatus: 'paid', ...missing });
  const partial = stay('ical_part', '2026-10-09', '2026-10-11', { paymentStatus: 'partial', ...missing });
  const income = stay('ical_inc', '2026-10-12', '2026-10-14', { ...missing });
  const flagged = stay('ical_flagged', '2026-10-15', '2026-10-17', { arrivalState: 'checked_in', needsReview: true, ...missing });
  const keep = Array.from({ length: 8 }, (_, i) => stay(`ical_k${i}`, '2026-11-01', '2026-11-03'));
  const plan = planFeedSync(
    [checkedIn, paid, partial, income, flagged, ...keep],
    keep.map((k) => res(k.stayId, k.checkIn, k.checkOut)),
    opts({ withIncome: new Set(['ical_inc']) }),
  );
  assert.deepEqual(plan.removals, []);
  // Already flagged: not flagged (or notified) again.
  assert.deepEqual(plan.reviews.sort(), ['ical_in', 'ical_inc', 'ical_paid', 'ical_part']);
  assert.deepEqual(Object.values(plan.reviewReasons), ['protected', 'protected', 'protected', 'protected']);
  // ...and its misses stop counting, so its doc is not rewritten every run until checkout.
  assert.equal(plan.missesAdvanced.some((m) => m.stayId === 'ical_flagged'), false);
  assert.equal(plan.missState.ical_flagged, undefined);
});

test('a stay waiting for review collects no more misses, on a full diff or an unchanged feed', () => {
  const flagged = stay('ical_flagged', '2026-10-15', '2026-10-17', { needsReview: true, missCount: 4, firstMissAtMs: T0 - 3 * MISS_SPACING_MS, lastMissAtMs: T0 - MISS_SPACING_MS });
  const keep = stay('ical_keep', '2026-11-01', '2026-11-03');
  const full = planFeedSync([flagged, keep], [res('ical_keep', '2026-11-01', '2026-11-03')], opts());
  assert.deepEqual([full.missesAdvanced, full.removals, full.reviews], [[], [], []]);
  const unchanged = advanceMissesOnUnchanged([flagged, keep], T0, { channelId: CH, todayYmd: TODAY, suspicious: false });
  assert.deepEqual([unchanged.missesAdvanced, unchanged.removals, unchanged.reviews], [[], [], []]);
});

test('a feed that suddenly drops every future booking is suspicious and needs 12 misses', () => {
  const missing = { missCount: 3, firstMissAtMs: T0 - 2 * REMOVAL_MIN_AGE_MS, lastMissAtMs: T0 - MISS_SPACING_MS };
  const ours = [stay('ical_1', '2026-10-05', '2026-10-08', missing), stay('ical_2', '2026-10-10', '2026-10-12', missing), stay('ical_3', '2026-10-15', '2026-10-18', missing)];
  const dropped = planFeedSync(ours, [], opts({ prevFutureCount: 3, feedEventCount: 4 }));
  assert.equal(dropped.suspicious, true);
  assert.equal(dropped.suspiciousReason, 'future_dropped');
  assert.equal(dropped.requiredMisses, SUSPICIOUS_REQUIRED_MISSES);
  assert.deepEqual(dropped.removals, []);
  assert.equal(dropped.missesAdvanced.length, 3);

  // An empty feed (no events at all) is suspicious whatever it had before.
  const empty = planFeedSync([ours[0]], [], opts({ prevFutureCount: 1, feedEventCount: 0 }));
  assert.equal(empty.suspiciousReason, 'empty_feed');
  assert.deepEqual(empty.removals, []);

  // Removing half or more of the channel's future bookings at once is suspicious too.
  const keep = [stay('ical_k', '2026-11-01', '2026-11-03')];
  const mass = planFeedSync([ours[0], ours[1], ...keep], keep.map((k) => res(k.stayId, k.checkIn, k.checkOut)), opts({ prevFutureCount: 3 }));
  assert.equal(mass.suspiciousReason, 'mass_removal');
  assert.deepEqual(mass.removals, []);

  // After 12 spaced misses a feed that lost half its bookings does remove them...
  const late = { missCount: 11, firstMissAtMs: T0 - 12 * MISS_SPACING_MS, lastMissAtMs: T0 - MISS_SPACING_MS };
  const massLate = planFeedSync([{ ...ours[0], ...late }, { ...ours[1], ...late }, ...keep], keep.map((k) => res(k.stayId, k.checkIn, k.checkOut)), opts({ prevFutureCount: 3 }));
  assert.equal(massLate.suspiciousReason, 'mass_removal');
  assert.deepEqual(massLate.removals.sort(), ['ical_1', 'ical_2']);
  assert.deepEqual(massLate.reviews, []);

  // ...but an empty or emptied feed never frees nights by itself: at 12 misses a person is asked instead.
  const finally_ = planFeedSync(ours.map((s) => ({ ...s, ...late })), [], opts({ prevFutureCount: 3, feedEventCount: 4 }));
  assert.equal(finally_.suspiciousReason, 'future_dropped');
  assert.deepEqual(finally_.removals, []);
  assert.deepEqual(finally_.reviews.sort(), ['ical_1', 'ical_2', 'ical_3']);
  assert.deepEqual(finally_.reviewReasons, { ical_1: 'feed_suspicious', ical_2: 'feed_suspicious', ical_3: 'feed_suspicious' });
  const emptyLate = planFeedSync(ours.map((s) => ({ ...s, ...late })), [], opts({ prevFutureCount: 1, feedEventCount: 0 }));
  assert.equal(emptyLate.suspiciousReason, 'empty_feed');
  assert.deepEqual(emptyLate.removals, []);
  assert.deepEqual(emptyLate.reviews.sort(), ['ical_1', 'ical_2', 'ical_3']);
  // Before the 12th miss nothing is flagged yet.
  const early = { missCount: 10, firstMissAtMs: T0 - 11 * MISS_SPACING_MS, lastMissAtMs: T0 - MISS_SPACING_MS };
  assert.deepEqual(planFeedSync(ours.map((s) => ({ ...s, ...early })), [], opts({ prevFutureCount: 1, feedEventCount: 0 })).reviews, []);

  // A single cancellation among others is ordinary.
  const one = planFeedSync([ours[0], ...Array.from({ length: 3 }, (_, i) => stay(`ical_o${i}`, '2026-11-05', '2026-11-07'))], Array.from({ length: 3 }, (_, i) => res(`ical_o${i}`, '2026-11-05', '2026-11-07')), opts({ prevFutureCount: 4 }));
  assert.equal(one.suspicious, false);
  assert.deepEqual(one.removals, ['ical_1']);
});

test('nothing to protect, nothing suspicious: an empty feed with no future bookings of ours is just empty', () => {
  const plan = planFeedSync([stay('ical_past', '2026-09-01', '2026-09-05')], [], opts({ prevFutureCount: 5, feedEventCount: 0 }));
  assert.equal(plan.suspicious, false);
  assert.deepEqual(plan.agedOut, ['ical_past']);
  assert.deepEqual(plan.removals, []);
});

test('a past stay that leaves the feed ages out quietly, once', () => {
  const plan = planFeedSync([stay('ical_past', '2026-09-20', '2026-10-01'), stay('ical_aged', '2026-09-01', '2026-09-03', { agedOut: true })], [], opts({ feedEventCount: 2 }));
  assert.deepEqual(plan.agedOut, ['ical_past']);
  assert.deepEqual(plan.missesAdvanced, []);
  assert.deepEqual(plan.removals, []);
});

test('a removed stay that comes back is restored', () => {
  const plan = planFeedSync([stay('airbnb_HMBACK0001', '2026-10-05', '2026-10-08', { status: 'removed_from_feed', confirmationCode: 'HMBACK0001', missCount: 3 })], [airbnb('HMBACK0001', '2026-10-05', '2026-10-09')], opts());
  assert.deepEqual(plan.restores.map((r) => [r.stayId, r.reservation.checkOut]), [['airbnb_HMBACK0001', '2026-10-09']]);
  assert.deepEqual(plan.dateChanges, []);
  // A removed stay still missing is left alone (no more misses).
  const still = planFeedSync([stay('ical_r', '2026-10-05', '2026-10-08', { status: 'removed_from_feed', missCount: 3 })], [], opts());
  assert.deepEqual(still.missesAdvanced, []);
});

test('a code listed twice in one feed is used once', () => {
  const plan = planFeedSync([], [airbnb('HMTWICE001', '2026-10-05', '2026-10-08'), airbnb('HMTWICE001', '2026-10-05', '2026-10-08')], opts());
  assert.equal(plan.creates.length, 1);
  assert.deepEqual(plan.duplicates, ['airbnb_HMTWICE001']);
});

test('on an unchanged feed, misses keep advancing for stays already missing (and can reach removal)', () => {
  const missing = stay('ical_m', '2026-10-05', '2026-10-08', { missCount: 2, firstMissAtMs: T0 - REMOVAL_MIN_AGE_MS, lastMissAtMs: T0 - MISS_SPACING_MS });
  const seen = stay('ical_seen', '2026-10-10', '2026-10-12');
  const pastMissing = stay('ical_pm', '2026-09-25', '2026-10-01', { missCount: 1, firstMissAtMs: T0 - MIN, lastMissAtMs: T0 - MIN });
  const plan = advanceMissesOnUnchanged([missing, seen, pastMissing], T0, { channelId: CH, todayYmd: TODAY, suspicious: false });
  assert.deepEqual(plan.missesAdvanced.map((m) => [m.stayId, m.missCount]), [['ical_m', 3]]);
  assert.deepEqual(plan.removals, ['ical_m']);
  assert.deepEqual(plan.agedOut, ['ical_pm']);
  // While the feed is suspicious, 12 are needed.
  const held = advanceMissesOnUnchanged([missing], T0, { channelId: CH, todayYmd: TODAY, suspicious: true });
  assert.deepEqual(held.removals, []);
  assert.equal(held.missesAdvanced.length, 1);
  // Another channel's stays are not this feed's business.
  const other = advanceMissesOnUnchanged([{ ...missing, channelId: 'ch_b' }], T0, { channelId: CH, todayYmd: TODAY, suspicious: false });
  assert.deepEqual(other.missesAdvanced, []);
});

test('an unchanged feed runs the same mass-removal check as a full diff', () => {
  // 2 of 4 future bookings missed twice already; this run would remove both.
  const due = { missCount: 2, firstMissAtMs: T0 - REMOVAL_MIN_AGE_MS, lastMissAtMs: T0 - MISS_SPACING_MS };
  const four = [
    stay('ical_1', '2026-10-05', '2026-10-08', due),
    stay('ical_2', '2026-10-10', '2026-10-12', due),
    stay('ical_3', '2026-10-15', '2026-10-18'),
    stay('ical_4', '2026-10-20', '2026-10-22'),
  ];
  const plan = advanceMissesOnUnchanged(four, T0, { channelId: CH, todayYmd: TODAY, suspicious: false });
  assert.equal(plan.suspicious, true);
  assert.equal(plan.suspiciousReason, 'mass_removal');
  assert.equal(plan.requiredMisses, SUSPICIOUS_REQUIRED_MISSES);
  assert.deepEqual(plan.removals, []);
  assert.deepEqual(plan.missesAdvanced.map((m) => [m.stayId, m.missCount]), [
    ['ical_1', 3],
    ['ical_2', 3],
  ]);
  // The full diff of the same situation reaches the same verdict.
  const full = planFeedSync(four, [res('ical_3', '2026-10-15', '2026-10-18'), res('ical_4', '2026-10-20', '2026-10-22')], opts({ prevFutureCount: 4 }));
  assert.equal(full.suspiciousReason, 'mass_removal');
  assert.deepEqual(full.removals, []);
  // One of four is ordinary, unchanged feed or not.
  const one = advanceMissesOnUnchanged([four[0], ...four.slice(2), stay('ical_5', '2026-11-01', '2026-11-03')], T0, { channelId: CH, todayYmd: TODAY, suspicious: false });
  assert.equal(one.suspicious, false);
  assert.deepEqual(one.removals, ['ical_1']);
});

test('an empty body that never changes asks at the 12th miss instead of freeing the nights', () => {
  const late = { missCount: 11, firstMissAtMs: T0 - 12 * MISS_SPACING_MS, lastMissAtMs: T0 - MISS_SPACING_MS };
  const two = [stay('ical_1', '2026-10-05', '2026-10-08', late), stay('ical_2', '2026-10-10', '2026-10-12', late)];
  const empty = advanceMissesOnUnchanged(two, T0, { channelId: CH, todayYmd: TODAY, suspicious: true, feedEventCount: 0 });
  assert.equal(empty.suspiciousReason, 'empty_feed');
  assert.deepEqual(empty.removals, []);
  assert.deepEqual(empty.reviews.sort(), ['ical_1', 'ical_2']);
  assert.deepEqual(empty.reviewReasons, { ical_1: 'feed_suspicious', ical_2: 'feed_suspicious' });
  // A body with events in it is not empty: a feed suspicious for another reason still removes at 12.
  const listed = advanceMissesOnUnchanged(two, T0, { channelId: CH, todayYmd: TODAY, suspicious: true, feedEventCount: 3 });
  assert.deepEqual(listed.removals.sort(), ['ical_1', 'ical_2']);
  // Unknown (never recorded) is not taken as empty.
  assert.deepEqual(advanceMissesOnUnchanged(two, T0, { channelId: CH, todayYmd: TODAY, suspicious: true }).removals.sort(), ['ical_1', 'ical_2']);
});
