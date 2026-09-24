/**
 * The feed diff (spec §3.4 invariants 6 and 7): what one successful sync of
 * a channel changes about its stays. Pure: the caller loads the stays and
 * turns the plan into stayWriter mutations.
 *
 * Identity. A parsed reservation matches an existing stay by confirmation
 * code, then by UID (current or earlier), then — only for a stay of this
 * channel that the feed no longer lists, with the same dates and no code on
 * either side — by its dates, which is Airbnb or Google giving a booking a
 * new UID (recorded in uidHistory). A manual or CSV `airbnb_{CODE}` stay, or
 * one left behind by a removed feed, is adopted: the feed takes it over.
 *
 * Removal is deliberately slow, because a feed that hiccups must never
 * delete a real booking:
 *  - a failed fetch is never a miss (the caller only plans after a success);
 *  - a miss counts only for a stay still to come (checkOut > today) and only
 *    30 minutes or more after the previous miss;
 *  - `removed_from_feed` needs `required` misses (3, or 12 while the feed
 *    looks suspicious) and 90 minutes since the first one;
 *  - a stay that is checked in or out, has income, or is partly or fully
 *    paid is flagged for review instead, never removed;
 *  - a stay already flagged for review stops collecting misses: it waits for
 *    a person (or for the feed to list it again), and is not rewritten every
 *    run;
 *  - a past stay that drops out ages out quietly;
 *  - a removed stay that comes back is restored.
 * A feed is suspicious when it is suddenly empty, when it had 3 or more
 * future bookings and now has none, or when this run would remove half or
 * more of this channel's future bookings (two or more of them). Both
 * planners (a full diff and an unchanged feed) run the same check.
 * While suspicious 12 misses are needed. An empty or emptied feed never frees
 * nights on its own: at 12 misses its bookings are flagged for review
 * instead of removed (§12: an empty feed removes nothing), so an outage that
 * serves empty calendars for hours cannot release every night.
 */
import type { StayArrivalState, StayPaymentStatus, StayStatus, Ymd } from './contracts';
import { isActiveStatus } from './nightLocks';

export const MISS_SPACING_MS = 30 * 60_000;
export const REMOVAL_MIN_AGE_MS = 90 * 60_000;
export const REQUIRED_MISSES = 3;
export const SUSPICIOUS_REQUIRED_MISSES = 12;
/** A previous future-booking count at or above this, dropping to zero, is suspicious. */
export const SUSPICIOUS_PREVIOUS_FUTURE = 3;
/** uidHistory keeps this many earlier UIDs. */
export const UID_HISTORY_MAX = 10;

/** One reservation as the feed lists it, already given its stay id. */
export interface FeedReservation {
  /** `airbnb_{CODE}` or `ical_{hash}` (ids.ts). */
  stayId: string;
  uid: string | null;
  confirmationCode: string | null;
  reservationUrl: string | null;
  summary: string | null;
  phoneLast4: string | null;
  checkIn: Ymd;
  /** Exclusive. */
  checkOut: Ymd;
}

/** The fields of a stored stay the diff looks at. */
export interface ExistingFeedStay {
  stayId: string;
  status: StayStatus;
  arrivalState: StayArrivalState;
  paymentStatus: StayPaymentStatus;
  checkIn: Ymd;
  checkOut: Ymd;
  /** sync.channelId; null when no feed has owned it (manual or CSV). */
  channelId: string | null;
  /** sync.detached: its feed was removed. */
  detached: boolean;
  uid: string | null;
  uidHistory: string[];
  confirmationCode: string | null;
  missCount: number;
  firstMissAtMs: number | null;
  lastMissAtMs: number | null;
  needsReview: boolean;
  agedOut: boolean;
}

export interface PlanFeedSyncOptions {
  channelId: string;
  todayYmd: Ymd;
  /** The miss clock (ms). */
  now: number;
  /** channel.sync.futureReservationCount before this run. */
  prevFutureCount: number;
  /** Stays with posted income: never removed automatically. */
  withIncome?: ReadonlySet<string>;
  /** Every VEVENT the feed had, blocks included (0: the feed is empty). Defaults to the reservations given. */
  feedEventCount?: number;
  /** Reservations ending on or before this are not created (old history). Defaults to never skipping. */
  createAfterYmd?: Ymd;
}

export interface FeedMatch {
  stayId: string;
  reservation: FeedReservation;
  /** The stored dates. */
  from: { checkIn: Ymd; checkOut: Ymd };
}

export interface MissUpdate {
  stayId: string;
  missCount: number;
  firstMissAtMs: number;
  lastMissAtMs: number;
}

export type SuspiciousReason = 'empty_feed' | 'future_dropped' | 'mass_removal';

/**
 * Why a stay is flagged for review instead of removed: it is protected
 * (checked in, paid, income), or it has been missing for 12 runs from a feed
 * that looks empty.
 */
export type ReviewReason = 'protected' | 'feed_suspicious';

export interface FeedSyncPlan {
  /** New stays. */
  creates: FeedReservation[];
  /** Seen again with different dates (an altered booking): same doc, new dates. */
  dateChanges: FeedMatch[];
  /** Seen again with the same dates. */
  touches: FeedMatch[];
  /** Was removed_from_feed; back in the feed. */
  restores: FeedMatch[];
  /** Missing this run, and the miss counted. */
  missesAdvanced: MissUpdate[];
  /** To become removed_from_feed. */
  removals: string[];
  /** Newly flagged sync.needsReview (would be removed, but is protected or its feed looks empty). */
  reviews: string[];
  /** Why each stay in `reviews` is flagged. */
  reviewReasons: Record<string, ReviewReason>;
  /** Past stays that left the feed. */
  agedOut: string[];
  uidRemaps: { stayId: string; fromUid: string | null; toUid: string }[];
  /** Matched stays this channel did not own before. */
  adopted: string[];
  /** Parsed reservations dropped as repeats of an earlier one with the same id. */
  duplicates: string[];
  /** Parsed reservations too old to create. */
  skippedOld: number;
  suspicious: boolean;
  suspiciousReason: SuspiciousReason | null;
  requiredMisses: number;
  /** Parsed reservations with checkOut > today. */
  futureReservationCount: number;
  /** Miss state after this run, for every stay listed in missesAdvanced. */
  missState: Record<string, MissUpdate>;
}

function emptyPlan(): FeedSyncPlan {
  return {
    creates: [],
    dateChanges: [],
    touches: [],
    restores: [],
    missesAdvanced: [],
    removals: [],
    reviews: [],
    reviewReasons: {},
    agedOut: [],
    uidRemaps: [],
    adopted: [],
    duplicates: [],
    skippedOld: 0,
    suspicious: false,
    suspiciousReason: null,
    requiredMisses: REQUIRED_MISSES,
    futureReservationCount: 0,
    missState: {},
  };
}

function codeOf(e: ExistingFeedStay): string | null {
  if (e.confirmationCode) return e.confirmationCode;
  return e.stayId.startsWith('airbnb_') ? e.stayId.slice('airbnb_'.length) : null;
}

/**
 * Checked in or out (the guest came), or partly or fully paid: never removed
 * automatically. Exported so the writer re-checks it on the stored doc at
 * commit time (a check-in does not bump `version`).
 */
export function isProtectedState(arrivalState: StayArrivalState | undefined, paymentStatus: StayPaymentStatus | undefined): boolean {
  return arrivalState === 'checked_in' || arrivalState === 'checked_out' || paymentStatus === 'partial' || paymentStatus === 'paid';
}

/** Protected, or has posted income: a person must look. */
function isProtected(e: ExistingFeedStay, withIncome: ReadonlySet<string>): boolean {
  return isProtectedState(e.arrivalState, e.paymentStatus) || withIncome.has(e.stayId);
}

/** The miss state after one more (spaced) miss. */
function nextMiss(e: ExistingFeedStay, now: number): { update: MissUpdate; advanced: boolean } {
  const due = e.lastMissAtMs === null || now - e.lastMissAtMs >= MISS_SPACING_MS;
  const missCount = (Number.isInteger(e.missCount) && e.missCount > 0 ? e.missCount : 0) + (due ? 1 : 0);
  const firstMissAtMs = e.firstMissAtMs ?? now;
  const lastMissAtMs = due ? now : (e.lastMissAtMs as number);
  return { update: { stayId: e.stayId, missCount, firstMissAtMs, lastMissAtMs }, advanced: due };
}

function meetsRemoval(state: MissUpdate | null, required: number, now: number): boolean {
  return !!state && state.missCount >= required && now - state.firstMissAtMs >= REMOVAL_MIN_AGE_MS;
}

interface MissOutcome {
  missesAdvanced: MissUpdate[];
  missState: Record<string, MissUpdate>;
  removals: string[];
  reviews: string[];
  reviewReasons: Record<string, ReviewReason>;
}

/**
 * Advances misses for the given stays and decides removals and reviews at
 * `required`. With `holdRemovals` (an empty or emptied feed) a stay that
 * would be removed is flagged for review instead.
 */
function applyMisses(
  missing: ExistingFeedStay[],
  now: number,
  required: number,
  withIncome: ReadonlySet<string>,
  holdRemovals: boolean,
): MissOutcome {
  const out: MissOutcome = { missesAdvanced: [], missState: {}, removals: [], reviews: [], reviewReasons: {} };
  for (const e of missing) {
    // Already waiting on a person: counting on would only rewrite the doc (and fire its triggers) every run.
    if (e.needsReview) continue;
    const { update, advanced } = nextMiss(e, now);
    out.missState[e.stayId] = update;
    if (advanced) out.missesAdvanced.push(update);
    if (!isActiveStatus(e.status) || !meetsRemoval(update, required, now)) continue;
    if (isProtected(e, withIncome)) {
      out.reviews.push(e.stayId);
      out.reviewReasons[e.stayId] = 'protected';
    } else if (holdRemovals) {
      out.reviews.push(e.stayId);
      out.reviewReasons[e.stayId] = 'feed_suspicious';
    } else {
      out.removals.push(e.stayId);
    }
  }
  return out;
}

/** Removing this many of a channel's active future bookings at once looks like a broken feed. */
function isMassRemoval(removals: number, activeFutureOwn: number): boolean {
  return removals >= 2 && removals * 2 >= activeFutureOwn;
}

interface MissDecision {
  reason: SuspiciousReason | null;
  required: number;
  misses: MissOutcome;
}

/**
 * The misses of a run, with the suspicion check both planners share: a
 * full diff and an unchanged feed (304 or the same bytes) must reach the
 * same verdict, or a byte-stable feed could remove half its bookings at once.
 * `feedReason` is what the feed itself shows (empty, or its future bookings
 * gone); `alreadySuspicious` carries a flag from an earlier run.
 */
function decideMisses(
  missing: ExistingFeedStay[],
  activeFutureOwn: number,
  now: number,
  withIncome: ReadonlySet<string>,
  feedReason: SuspiciousReason | null,
  alreadySuspicious = false,
): MissDecision {
  const tentative = applyMisses(missing, now, REQUIRED_MISSES, withIncome, false);
  // Reviews remove nothing, so only real removals count towards "half of them".
  const reason = feedReason ?? (isMassRemoval(tentative.removals.length, activeFutureOwn) ? 'mass_removal' : null);
  if (!reason && !alreadySuspicious) return { reason: null, required: REQUIRED_MISSES, misses: tentative };
  const hold = reason === 'empty_feed' || reason === 'future_dropped';
  return {
    reason,
    required: SUSPICIOUS_REQUIRED_MISSES,
    misses: applyMisses(missing, now, SUSPICIOUS_REQUIRED_MISSES, withIncome, hold),
  };
}

function applyDecision(plan: FeedSyncPlan, d: MissDecision, alreadySuspicious = false): void {
  plan.suspiciousReason = d.reason;
  plan.suspicious = d.reason !== null || alreadySuspicious;
  plan.requiredMisses = d.required;
  plan.missesAdvanced = d.misses.missesAdvanced;
  plan.missState = d.misses.missState;
  plan.removals = d.misses.removals;
  plan.reviews = d.misses.reviews;
  plan.reviewReasons = d.misses.reviewReasons;
}

export function planFeedSync(existing: readonly ExistingFeedStay[], parsed: readonly FeedReservation[], opts: PlanFeedSyncOptions): FeedSyncPlan {
  const plan = emptyPlan();
  const withIncome = opts.withIncome ?? new Set<string>();
  const today = opts.todayYmd;
  const own = (e: ExistingFeedStay) => e.channelId === opts.channelId && !e.detached;
  // A cancelled stay is the owner's decision; the feed never revives or re-owns it.
  const usable = existing.filter((e) => e.status !== 'cancelled');

  // Repeats of one id in a feed (a code listed twice): the first wins.
  const feed: FeedReservation[] = [];
  const seenIds = new Set<string>();
  for (const p of parsed) {
    if (seenIds.has(p.stayId)) {
      plan.duplicates.push(p.stayId);
      continue;
    }
    seenIds.add(p.stayId);
    feed.push(p);
  }

  const matched = new Map<string, FeedReservation>();
  const take = (e: ExistingFeedStay | undefined, p: FeedReservation): boolean => {
    if (!e || matched.has(e.stayId)) return false;
    matched.set(e.stayId, p);
    return true;
  };

  // 1. Confirmation code.
  const byCode = new Map<string, ExistingFeedStay>();
  for (const e of usable) {
    const code = codeOf(e);
    if (code && !byCode.has(code)) byCode.set(code, e);
  }
  let pending: FeedReservation[] = [];
  for (const p of feed) {
    if (!(p.confirmationCode && take(byCode.get(p.confirmationCode), p))) pending.push(p);
  }

  // 2. UID (current, then earlier ones), or the same deterministic id.
  const byUid = new Map<string, ExistingFeedStay>();
  for (const e of usable) if (e.uid && !byUid.has(e.uid)) byUid.set(e.uid, e);
  for (const e of usable) for (const h of e.uidHistory ?? []) if (h && !byUid.has(h)) byUid.set(h, e);
  const byId = new Map(usable.map((e) => [e.stayId, e]));
  const codesAgree = (e: ExistingFeedStay, p: FeedReservation) => {
    const code = codeOf(e);
    return !code || !p.confirmationCode || code === p.confirmationCode;
  };
  let next: FeedReservation[] = [];
  for (const p of pending) {
    const byU = p.uid ? byUid.get(p.uid) : undefined;
    if (byU && codesAgree(byU, p) && take(byU, p)) continue;
    const same = byId.get(p.stayId);
    if (same && codesAgree(same, p) && take(same, p)) continue;
    next.push(p);
  }
  pending = next;

  // 3. Same dates on one of this channel's missing stays: a new UID for the same booking.
  next = [];
  for (const p of pending) {
    if (p.confirmationCode) {
      next.push(p);
      continue;
    }
    const candidates = usable.filter(
      (e) => own(e) && !matched.has(e.stayId) && !codeOf(e) && e.checkIn === p.checkIn && e.checkOut === p.checkOut,
    );
    // Two stays with the same dates cannot be told apart: create instead of guessing.
    if (candidates.length === 1 && p.uid && take(candidates[0], p)) {
      plan.uidRemaps.push({ stayId: candidates[0].stayId, fromUid: candidates[0].uid, toUid: p.uid });
      continue;
    }
    next.push(p);
  }

  for (const p of next) {
    if (opts.createAfterYmd && p.checkOut <= opts.createAfterYmd) {
      plan.skippedOld++;
      continue;
    }
    plan.creates.push(p);
  }

  for (const e of usable) {
    const p = matched.get(e.stayId);
    if (!p) continue;
    const match: FeedMatch = { stayId: e.stayId, reservation: p, from: { checkIn: e.checkIn, checkOut: e.checkOut } };
    if (!own(e)) plan.adopted.push(e.stayId);
    if (p.uid && e.uid !== p.uid && !plan.uidRemaps.some((r) => r.stayId === e.stayId)) {
      plan.uidRemaps.push({ stayId: e.stayId, fromUid: e.uid, toUid: p.uid });
    }
    if (e.status === 'removed_from_feed') plan.restores.push(match);
    else if (e.checkIn !== p.checkIn || e.checkOut !== p.checkOut) plan.dateChanges.push(match);
    else plan.touches.push(match);
  }

  // Stays of this channel the feed no longer lists.
  const missing: ExistingFeedStay[] = [];
  for (const e of usable) {
    if (!own(e) || matched.has(e.stayId) || e.status === 'removed_from_feed') continue;
    if (e.checkOut <= today) {
      if (!e.agedOut) plan.agedOut.push(e.stayId);
      continue;
    }
    missing.push(e);
  }

  // Is this feed suspicious?
  plan.futureReservationCount = feed.filter((p) => p.checkOut > today).length;
  const missingActive = missing.filter((e) => isActiveStatus(e.status));
  const activeFutureOwn = usable.filter((e) => own(e) && isActiveStatus(e.status) && e.checkOut > today).length;
  const eventCount = opts.feedEventCount ?? feed.length;
  let feedReason: SuspiciousReason | null = null;
  if (missingActive.length > 0 && eventCount === 0) {
    feedReason = 'empty_feed';
  } else if (missingActive.length > 0 && opts.prevFutureCount >= SUSPICIOUS_PREVIOUS_FUTURE && plan.futureReservationCount === 0) {
    feedReason = 'future_dropped';
  }
  applyDecision(plan, decideMisses(missing, activeFutureOwn, opts.now, withIncome, feedReason));
  return plan;
}

export interface UnchangedFeedOptions {
  channelId: string;
  todayYmd: Ymd;
  /** The miss clock (ms). */
  now: number;
  /** channel.sync.suspiciousSince is set: 12 misses are needed. */
  suspicious: boolean;
  withIncome?: ReadonlySet<string>;
  /**
   * Events in the unchanged body (channel.sync.eventCount from its last full
   * diff). 0 is an empty feed, held as a full diff holds it; unknown when
   * omitted.
   */
  feedEventCount?: number;
}

/**
 * A 304, or a body identical to the last one: nothing to diff, but the stays
 * already missing from it are still missing, so their misses keep counting
 * (and may reach removal or review). Past ones age out. The suspicion checks
 * run here too: a feed that dropped half its bookings and then went
 * byte-stable must turn suspicious, not remove them three runs later, and
 * an empty body that never changes must not free nights at the 12th miss.
 */
export function advanceMissesOnUnchanged(existing: readonly ExistingFeedStay[], now: number, opts: Omit<UnchangedFeedOptions, 'now'>): FeedSyncPlan {
  const plan = emptyPlan();
  const missing: ExistingFeedStay[] = [];
  let activeFutureOwn = 0;
  for (const e of existing) {
    if (e.channelId !== opts.channelId || e.detached || !isActiveStatus(e.status)) continue;
    if (e.checkOut > opts.todayYmd) activeFutureOwn++;
    if (!(e.missCount > 0)) continue;
    if (e.checkOut <= opts.todayYmd) {
      if (!e.agedOut) plan.agedOut.push(e.stayId);
      continue;
    }
    missing.push(e);
  }
  const feedReason: SuspiciousReason | null = missing.length > 0 && opts.feedEventCount === 0 ? 'empty_feed' : null;
  applyDecision(plan, decideMisses(missing, activeFutureOwn, now, opts.withIncome ?? new Set(), feedReason, opts.suspicious), opts.suspicious);
  return plan;
}
