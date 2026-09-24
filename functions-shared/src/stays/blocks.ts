/**
 * Imported channel blocks (spec §3.4 invariants 4 and 5).
 *
 * A feed's "Not available" events are soft blocks, kept per feed as one set
 * of merged ranges (stayChannelBlocks/{channelId}.ranges) that each
 * successful sync replaces whole. There are no per-block docs, UIDs or miss
 * counts, so the churn of block UIDs between exports cannot remove or
 * duplicate anything.
 */
import type { ChannelBlockRange, Ymd } from './contracts';
import { addDays, diffDays } from './dates';

/** At most this many ranges are kept per feed (spec §3.3). */
export const MAX_BLOCK_RANGES = 500;

/** Nights trimmed at each end of a block before the echo test: Airbnb pads blocks with preparation time. */
export const ECHO_PREP_NIGHTS = 3;

export interface BlockEventLike {
  checkIn: Ymd;
  checkOut: Ymd;
}

export interface BlockClamp {
  /** Inclusive. */
  clampFrom: Ymd;
  /** Exclusive. */
  clampTo: Ymd;
}

export interface NormalizedBlocks {
  ranges: ChannelBlockRange[];
  /** Ranges dropped past MAX_BLOCK_RANGES (the latest ones). */
  dropped: number;
}

/**
 * Clamps the block events to the lock horizon, then sorts and merges ranges
 * that overlap or touch, so the set is small and the same blocks always give
 * the same ranges. Every range starts with echo:false (markEchoes sets it).
 */
export function normalizeBlockRanges(events: readonly BlockEventLike[], clamp: BlockClamp): NormalizedBlocks {
  const clamped: { checkIn: Ymd; checkOut: Ymd }[] = [];
  for (const e of events) {
    const checkIn = e.checkIn > clamp.clampFrom ? e.checkIn : clamp.clampFrom;
    const checkOut = e.checkOut < clamp.clampTo ? e.checkOut : clamp.clampTo;
    if (checkIn < checkOut) clamped.push({ checkIn, checkOut });
  }
  clamped.sort((a, b) => (a.checkIn < b.checkIn ? -1 : a.checkIn > b.checkIn ? 1 : a.checkOut < b.checkOut ? -1 : 1));
  const merged: ChannelBlockRange[] = [];
  for (const r of clamped) {
    const last = merged[merged.length - 1];
    if (last && r.checkIn <= last.checkOut) {
      if (r.checkOut > last.checkOut) last.checkOut = r.checkOut;
    } else {
      merged.push({ checkIn: r.checkIn, checkOut: r.checkOut, echo: false });
    }
  }
  const dropped = Math.max(0, merged.length - MAX_BLOCK_RANGES);
  return { ranges: merged.slice(0, MAX_BLOCK_RANGES), dropped };
}

/**
 * Marks as echoes the ranges that are our own exported stays coming back
 * (Airbnb re-exports what it imports from us as "Not available"): a range is
 * an echo when, after trimming up to ECHO_PREP_NIGHTS at each end, every
 * remaining night is covered by one of `exportedStays` (the hard stays the
 * export link to that channel sends). Cosmetic only: soft blocks never
 * conflict, so this just fades them on the tape chart.
 */
export function markEchoes(ranges: readonly ChannelBlockRange[], exportedStays: readonly BlockEventLike[]): ChannelBlockRange[] {
  if (exportedStays.length === 0) return ranges.map((r) => ({ checkIn: r.checkIn, checkOut: r.checkOut, echo: false }));
  const covered = new Set<Ymd>();
  for (const s of exportedStays) {
    const n = diffDays(s.checkIn, s.checkOut);
    for (let i = 0; i < n; i++) covered.add(addDays(s.checkIn, i));
  }
  return ranges.map((r) => {
    const n = diffDays(r.checkIn, r.checkOut);
    let first = -1;
    let last = -1;
    for (let i = 0; i < n; i++) {
      if (covered.has(addDays(r.checkIn, i))) {
        if (first < 0) first = i;
        last = i;
      }
    }
    let echo = first >= 0 && first <= ECHO_PREP_NIGHTS && n - 1 - last <= ECHO_PREP_NIGHTS;
    for (let i = first; echo && i <= last; i++) {
      if (!covered.has(addDays(r.checkIn, i))) echo = false;
    }
    return { checkIn: r.checkIn, checkOut: r.checkOut, echo };
  });
}

/** Whether two range sets are the same, echo marks included. */
export function sameBlockRanges(a: readonly ChannelBlockRange[], b: readonly ChannelBlockRange[]): boolean {
  return (
    a.length === b.length &&
    a.every((r, i) => r.checkIn === b[i].checkIn && r.checkOut === b[i].checkOut && (r.echo === true) === (b[i].echo === true))
  );
}
