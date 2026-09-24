/**
 * Night locks (spec §3.4 invariant 1): who holds each night of a listing.
 *
 * A lock bucket (stayNightLocks/{listingId}_{YYYY-MM}) is only a cache. It
 * is rebuilt from the active stays and the channel block ranges inside every
 * stayWriter transaction, so a bucket that drifted heals on the next write,
 * and when a conflict's winner goes away the loser gets its nights back in
 * the same commit.
 *
 * Precedence: hard claimants (active stays of any kind) sorted by
 * (createdAtMs asc, stayId asc); the first writer wins each night and keeps
 * every night it wins. A stay that loses any night is a conflict. Soft
 * channel blocks only fill nights no hard claimant holds and never cause a
 * conflict.
 */
import type { ChannelBlockRange, NightClaim, StayKind, StayStatus, Ymd, YearMonth } from './contracts';
import { ACTIVE_STAY_STATUSES, STAYS_LIMITS } from './contracts';
import { addDays, diffDays, monthOf, monthsSpanned } from './dates';
import { sha256Hex } from './ids';

/** The fields of a stay the locks depend on. */
export interface LockStayInput {
  stayId: string;
  status: StayStatus;
  kind: StayKind;
  source: string;
  checkIn: Ymd;
  checkOut: Ymd;
  createdAtMs: number;
}

/** One feed's soft-block ranges (stayChannelBlocks/{channelId}). */
export interface LockBlockInput {
  channelId: string;
  provider: string;
  ranges: ChannelBlockRange[];
}

export interface RebuildBucketsInput {
  /** The months to rebuild; nights outside them are not looked at. */
  months: YearMonth[];
  stays: LockStayInput[];
  blocks: LockBlockInput[];
  /** Inclusive start of the lock horizon. */
  clampFrom: Ymd;
  /** Exclusive end of the lock horizon. */
  clampTo: Ymd;
}

export interface BuiltBucket {
  month: YearMonth;
  nights: Record<Ymd, NightClaim>;
  digest: string;
}

export interface StayLockOutcome {
  status: 'confirmed' | 'conflict';
  /** The stays holding the nights this one lost (sorted). */
  conflictStayIds: string[];
  /** The nights this one lost (sorted). */
  conflictNights: Ymd[];
}

export interface EchoRange {
  channelId: string;
  checkIn: Ymd;
  checkOut: Ymd;
}

export interface RebuildBucketsResult {
  /** One per requested month, empty months included. */
  buckets: Record<YearMonth, BuiltBucket>;
  /**
   * For every active stay with a night in the rebuilt months: whether it won
   * all of those nights. Only the nights inside the months count, so the
   * caller must rebuild every month of a stay before trusting its outcome.
   */
  outcomes: Record<string, StayLockOutcome>;
  /** Channel block ranges marked as echoes, within the rebuilt months. */
  echoRanges: EchoRange[];
}

export interface RequestedCheck {
  hardConflicts: { date: Ymd; stayId: string }[];
  softNights: Ymd[];
}

/** The lock horizon for `todayYmd`: today−60 days (inclusive) to today+540 days (exclusive). */
export function lockHorizon(todayYmd: Ymd): { clampFrom: Ymd; clampTo: Ymd } {
  return {
    clampFrom: addDays(todayYmd, -STAYS_LIMITS.lockHorizonPastDays),
    clampTo: addDays(todayYmd, STAYS_LIMITS.lockHorizonFutureDays),
  };
}

function maxYmd(a: Ymd, b: Ymd): Ymd {
  return a > b ? a : b;
}

function minYmd(a: Ymd, b: Ymd): Ymd {
  return a < b ? a : b;
}

/** The nights of [checkIn, checkOut) inside [clampFrom, clampTo). */
export function clampedNights(checkIn: Ymd, checkOut: Ymd, clampFrom: Ymd, clampTo: Ymd): Ymd[] {
  const from = maxYmd(checkIn, clampFrom);
  const to = minYmd(checkOut, clampTo);
  const count = diffDays(from, to);
  const nights: Ymd[] = [];
  for (let i = 0; i < count; i++) nights.push(addDays(from, i));
  return nights;
}

/** The months a stay's nights touch inside the horizon. */
export function lockMonthsFor(checkIn: Ymd, checkOut: Ymd, clampFrom: Ymd, clampTo: Ymd): YearMonth[] {
  const from = maxYmd(checkIn, clampFrom);
  const to = minYmd(checkOut, clampTo);
  return monthsSpanned(from, to);
}

export function isActiveStatus(status: string): boolean {
  return (ACTIVE_STAY_STATUSES as readonly string[]).includes(status);
}

/** Hard claimants in precedence order: (createdAtMs asc, stayId asc). */
export function sortByPrecedence<T extends { createdAtMs: number; stayId: string }>(stays: T[]): T[] {
  return [...stays].sort((a, b) => {
    const byTime = (a.createdAtMs || 0) - (b.createdAtMs || 0);
    if (byTime !== 0) return byTime;
    return a.stayId < b.stayId ? -1 : a.stayId > b.stayId ? 1 : 0;
  });
}

/**
 * A stable digest of one bucket's nights: sorted dates, fixed field order.
 * The writer compares it to the stored digest and skips unchanged buckets.
 */
export function bucketDigest(nights: Record<Ymd, NightClaim>): string {
  const canonical = Object.keys(nights)
    .sort()
    .map((date) => {
      const c = nights[date];
      return [date, c.s, c.h ? 1 : 0, c.src, c.k, c.e ? 1 : 0];
    });
  return sha256Hex(JSON.stringify(canonical)).slice(0, 32);
}

export function rebuildBuckets(input: RebuildBucketsInput): RebuildBucketsResult {
  const months = [...new Set(input.months)].sort();
  const inMonths = new Set(months);
  const { clampFrom, clampTo } = input;
  const claims = new Map<Ymd, NightClaim>();
  const outcomes: Record<string, StayLockOutcome> = {};

  const hard = sortByPrecedence(input.stays.filter((s) => isActiveStatus(s.status)));
  for (const stay of hard) {
    const nights = clampedNights(stay.checkIn, stay.checkOut, clampFrom, clampTo).filter((n) =>
      inMonths.has(monthOf(n)),
    );
    if (nights.length === 0) continue;
    const lostTo = new Set<string>();
    const lostNights: Ymd[] = [];
    for (const night of nights) {
      const holder = claims.get(night);
      if (holder) {
        lostTo.add(holder.s);
        lostNights.push(night);
      } else {
        claims.set(night, { s: stay.stayId, h: true, src: stay.source, k: stay.kind });
      }
    }
    outcomes[stay.stayId] = {
      status: lostNights.length > 0 ? 'conflict' : 'confirmed',
      conflictStayIds: [...lostTo].sort(),
      conflictNights: lostNights.sort(),
    };
  }

  const echoRanges: EchoRange[] = [];
  const blocks = [...input.blocks].sort((a, b) => (a.channelId < b.channelId ? -1 : a.channelId > b.channelId ? 1 : 0));
  for (const block of blocks) {
    const ranges = [...block.ranges].sort((a, b) => (a.checkIn < b.checkIn ? -1 : a.checkIn > b.checkIn ? 1 : 0));
    for (const range of ranges) {
      const nights = clampedNights(range.checkIn, range.checkOut, clampFrom, clampTo).filter((n) =>
        inMonths.has(monthOf(n)),
      );
      if (nights.length === 0) continue;
      if (range.echo === true) {
        echoRanges.push({ channelId: block.channelId, checkIn: range.checkIn, checkOut: range.checkOut });
      }
      for (const night of nights) {
        // Soft: only a free night, and never a conflict.
        if (claims.has(night)) continue;
        const claim: NightClaim = { s: `blk:${block.channelId}`, h: false, src: block.provider, k: 'channel_block' };
        if (range.echo === true) claim.e = true;
        claims.set(night, claim);
      }
    }
  }

  const buckets: Record<YearMonth, BuiltBucket> = {};
  for (const month of months) {
    buckets[month] = { month, nights: {}, digest: '' };
  }
  for (const night of [...claims.keys()].sort()) {
    buckets[monthOf(night)].nights[night] = claims.get(night)!;
  }
  for (const month of months) {
    buckets[month].digest = bucketDigest(buckets[month].nights);
  }
  return { buckets, outcomes, echoRanges };
}

/**
 * Whether `stayId` may take `nights` given `buckets`: nights another stay
 * holds hard, and nights only a channel block holds. Nights in months not in
 * `buckets` are not checked.
 */
export function checkRequested(
  buckets: Record<YearMonth, { nights: Record<Ymd, NightClaim> }>,
  stayId: string,
  nights: Ymd[],
): RequestedCheck {
  const hardConflicts: { date: Ymd; stayId: string }[] = [];
  const softNights: Ymd[] = [];
  for (const night of [...nights].sort()) {
    const bucket = buckets[monthOf(night)];
    const claim = bucket?.nights[night];
    if (!claim || claim.s === stayId) continue;
    if (claim.h) hardConflicts.push({ date: night, stayId: claim.s });
    else softNights.push(night);
  }
  return { hardConflicts, softNights };
}
