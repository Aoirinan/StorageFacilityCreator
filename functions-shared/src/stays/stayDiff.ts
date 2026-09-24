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
 *  - a past stay that drops out ages out quietly;
 *  - a removed stay that comes back is restored.
 * A feed is suspicious when it is suddenly empty, when it had 3 or more
 * future bookings and now has none, or when this run would remove half or
 * more of this channel's future bookings (two or more of them).
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
  /** Newly flagged sync.needsReview (would be removed but is checked in, has income or is paid). */
  reviews: string[];
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

/** Checked in or out (the guest came), income, or money taken: a person must look. */
function isProtected(e: ExistingFeedStay, withIncome: ReadonlySet<string>): boolean {
  return (
    e.arrivalState === 'checked_in' ||
    e.arrivalState === 'checked_out' ||
    withIncome.has(e.stayId) ||
    e.paymentStatus === 'partial' ||
    e.paymentStatus === 'paid'
  );
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
}

/** Advances misses for the given stays and decides removals and reviews at `required`. */
function applyMisses(missing: ExistingFeedStay[], now: number, required: number, withIncome: ReadonlySet<string>): MissOutcome {
  const out: MissOutcome = { missesAdvanced: [], missState: {}, removals: [], reviews: [] };
  for (const e of missing) {
    const { update, advanced } = nextMiss(e, now);
    out.missState[e.stayId] = update;
    if (advanced) out.missesAdvanced.push(update);
    if (!isActiveStatus(e.status) || !meetsRemoval(update, required, now)) continue;
    if (isProtected(e, withIncome)) {
      if (!e.needsReview) out.reviews.push(e.stayId);
    } else {
      out.removals.push(e.stayId);
    }
  }
  return out;
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
  const activeFutureOwn = usable.filter((e) => own(e) && isActiveStatus(e.status) && e.checkOut > today);
  const eventCount = opts.feedEventCount ?? feed.length;
  const tentative = applyMisses(missing, opts.now, REQUIRED_MISSES, withIncome);
  // Reviews remove nothing, so only real removals count towards "half of them".
  const wouldRemove = tentative.removals.length;
  if (missingActive.length > 0 && eventCount === 0) {
    plan.suspiciousReason = 'empty_feed';
  } else if (missingActive.length > 0 && opts.prevFutureCount >= SUSPICIOUS_PREVIOUS_FUTURE && plan.futureReservationCount === 0) {
    plan.suspiciousReason = 'future_dropped';
  } else if (wouldRemove >= 2 && wouldRemove * 2 >= activeFutureOwn.length) {
    plan.suspiciousReason = 'mass_removal';
  }
  plan.suspicious = plan.suspiciousReason !== null;
  plan.requiredMisses = plan.suspicious ? SUSPICIOUS_REQUIRED_MISSES : REQUIRED_MISSES;

  const misses = plan.suspicious ? applyMisses(missing, opts.now, plan.requiredMisses, withIncome) : tentative;
  plan.missesAdvanced = misses.missesAdvanced;
  plan.missState = misses.missState;
  plan.removals = misses.removals;
  plan.reviews = misses.reviews;
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
}

/**
 * A 304, or a body identical to the last one: nothing to diff, but the stays
 * already missing from it are still missing, so their misses keep counting
 * (and may reach removal or review). Past ones age out.
 */
export function advanceMissesOnUnchanged(existing: readonly ExistingFeedStay[], now: number, opts: Omit<UnchangedFeedOptions, 'now'>): FeedSyncPlan {
  const plan = emptyPlan();
  plan.suspicious = opts.suspicious;
  plan.suspiciousReason = null;
  plan.requiredMisses = opts.suspicious ? SUSPICIOUS_REQUIRED_MISSES : REQUIRED_MISSES;
  const missing: ExistingFeedStay[] = [];
  for (const e of existing) {
    if (e.channelId !== opts.channelId || e.detached) continue;
    if (!(e.missCount > 0) || !isActiveStatus(e.status)) continue;
    if (e.checkOut <= opts.todayYmd) {
      if (!e.agedOut) plan.agedOut.push(e.stayId);
      continue;
    }
    missing.push(e);
  }
  const misses = applyMisses(missing, now, plan.requiredMisses, opts.withIncome ?? new Set());
  plan.missesAdvanced = misses.missesAdvanced;
  plan.missState = misses.missState;
  plan.removals = misses.removals;
  plan.reviews = misses.reviews;
  return plan;
}
