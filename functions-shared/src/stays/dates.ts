/**
 * Dates for Stays (spec §3.1, §6.2).
 *
 * Nights are 'YYYY-MM-DD' strings in the facility's confirmed zone and are
 * handled with plain UTC calendar math, never through a zone. Only the
 * facility-clock helpers (facilityToday, facilityLocalHour, …) consult a
 * zone, through Intl, and they throw on an invalid one: there is no fallback
 * zone anywhere, and the platform's America/Chicago default is never used.
 */
import type { HourMinute, LocalDateTime, Ymd, YearMonth } from './contracts';

const YMD_RE = /^(\d{4})-(\d{2})-(\d{2})$/;
const MONTH_RE = /^(\d{4})-(\d{2})$/;
const HM_RE = /^([01]\d|2[0-3]):([0-5]\d)$/;
const DAY_MS = 86_400_000;

function ymdToUtcMs(ymd: Ymd): number {
  const m = YMD_RE.exec(ymd);
  if (!m) throw new Error(`Not a YYYY-MM-DD date: ${ymd}`);
  return Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
}

function utcMsToYmd(ms: number): Ymd {
  return new Date(ms).toISOString().slice(0, 10);
}

/** A real calendar date written as 'YYYY-MM-DD' (years 1900–2999). */
export function isValidYmd(value: unknown): value is Ymd {
  if (typeof value !== 'string') return false;
  const m = YMD_RE.exec(value);
  if (!m) return false;
  const year = Number(m[1]);
  if (year < 1900 || year > 2999) return false;
  const ms = Date.UTC(year, Number(m[2]) - 1, Number(m[3]));
  return utcMsToYmd(ms) === value;
}

export function isValidMonth(value: unknown): value is YearMonth {
  if (typeof value !== 'string') return false;
  const m = MONTH_RE.exec(value);
  return !!m && Number(m[2]) >= 1 && Number(m[2]) <= 12 && isValidYmd(`${value}-01`);
}

export function isValidHourMinute(value: unknown): value is HourMinute {
  return typeof value === 'string' && HM_RE.test(value);
}

export function addDays(ymd: Ymd, days: number): Ymd {
  return utcMsToYmd(ymdToUtcMs(ymd) + days * DAY_MS);
}

/** Days from `from` to `to` (negative when `to` is earlier). */
export function diffDays(from: Ymd, to: Ymd): number {
  return Math.round((ymdToUtcMs(to) - ymdToUtcMs(from)) / DAY_MS);
}

/** The nights of a stay: checkIn up to, but not including, checkOut. */
export function enumerateNights(checkIn: Ymd, checkOut: Ymd): Ymd[] {
  const count = diffDays(checkIn, checkOut);
  const nights: Ymd[] = [];
  for (let i = 0; i < count; i++) nights.push(addDays(checkIn, i));
  return nights;
}

export function monthOf(ymd: Ymd): YearMonth {
  if (!YMD_RE.test(ymd)) throw new Error(`Not a YYYY-MM-DD date: ${ymd}`);
  return ymd.slice(0, 7);
}

/** 'YYYY-MM-01'. */
export function monthStart(month: YearMonth): Ymd {
  if (!isValidMonth(month)) throw new Error(`Not a YYYY-MM month: ${month}`);
  return `${month}-01`;
}

/** The first day of the next month: an exclusive end, like checkOut. */
export function monthEnd(month: YearMonth): Ymd {
  return monthStart(nextMonth(month));
}

export function nextMonth(month: YearMonth): YearMonth {
  const m = MONTH_RE.exec(month);
  if (!m) throw new Error(`Not a YYYY-MM month: ${month}`);
  const year = Number(m[1]);
  const mon = Number(m[2]);
  return mon === 12 ? `${year + 1}-01` : `${m[1]}-${String(mon + 1).padStart(2, '0')}`;
}

/** Months holding any of the nights [from, toExclusive), in order. Empty when there are none. */
export function monthsSpanned(from: Ymd, toExclusive: Ymd): YearMonth[] {
  if (diffDays(from, toExclusive) <= 0) return [];
  const last = monthOf(addDays(toExclusive, -1));
  const months: YearMonth[] = [];
  for (let m = monthOf(from); m <= last; m = nextMonth(m)) months.push(m);
  return months;
}

/** 0 = Sunday … 6 = Saturday, by calendar date alone (no zone). */
export function weekdayOfYmd(ymd: Ymd): number {
  return new Date(ymdToUtcMs(ymd)).getUTCDay();
}

// ---------------------------------------------------------------------------
// Facility clock: the only place a zone is consulted.
// ---------------------------------------------------------------------------

const ZONE_SHAPE_RE = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+){0,2}$/;
const formatters = new Map<string, Intl.DateTimeFormat>();

function formatterFor(tz: string): Intl.DateTimeFormat {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-CA', {
      timeZone: tz,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    });
    formatters.set(tz, f);
  }
  return f;
}

/**
 * An IANA zone name Intl knows, e.g. 'America/Denver' or 'UTC'. Offsets
 * ('+05:00'), abbreviations ('MST') and anything Intl rejects are refused.
 */
export function isValidIanaZone(value: unknown): value is string {
  if (typeof value !== 'string' || value.length > 64 || !ZONE_SHAPE_RE.test(value)) return false;
  if (!value.includes('/') && value !== 'UTC') return false;
  try {
    formatterFor(value);
    return true;
  } catch {
    return false;
  }
}

/**
 * The zone as Intl names it (resolvedOptions().timeZone), or null when it is
 * not a valid zone: 'america/denver' and 'US/Mountain' both become
 * 'America/Denver'. Stays stores and compares this form, so one zone spelled
 * two ways never reads as a mismatch.
 */
export function canonicalIanaZone(value: unknown): string | null {
  if (!isValidIanaZone(value)) return null;
  return formatterFor(value).resolvedOptions().timeZone;
}

/** Whether two zone names are the same zone (both valid, same canonical name). */
export function sameTimeZone(a: unknown, b: unknown): boolean {
  const ca = canonicalIanaZone(a);
  return ca !== null && ca === canonicalIanaZone(b);
}

function assertZone(tz: string): void {
  if (!isValidIanaZone(tz)) {
    throw new Error(`Not a valid IANA time zone: ${String(tz)}`);
  }
}

type InstantLike = Date | number | { toMillis(): number };

function toMs(at: InstantLike): number {
  if (typeof at === 'number') return at;
  if (at instanceof Date) return at.getTime();
  return at.toMillis();
}

interface WallClock {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;
}

function wallClock(tz: string, ms: number): WallClock {
  assertZone(tz);
  const parts = formatterFor(tz).formatToParts(new Date(ms));
  const get = (type: string): number => {
    const part = parts.find((p) => p.type === type);
    if (!part) throw new Error(`Intl gave no ${type} for ${tz}`);
    return Number(part.value);
  };
  return {
    year: get('year'),
    month: get('month'),
    day: get('day'),
    // Some engines still print midnight as 24 even with h23.
    hour: get('hour') % 24,
    minute: get('minute'),
    second: get('second'),
  };
}

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

function wallYmd(w: WallClock): Ymd {
  return `${w.year}-${pad2(w.month)}-${pad2(w.day)}`;
}

/** Today's date at the facility. Throws on an invalid zone; never guesses one. */
export function facilityToday(tz: string, now: InstantLike): Ymd {
  return wallYmd(wallClock(tz, toMs(now)));
}

export function facilityLocalHour(tz: string, now: InstantLike): number {
  return wallClock(tz, toMs(now)).hour;
}

export function facilityLocalMinute(tz: string, now: InstantLike): number {
  return wallClock(tz, toMs(now)).minute;
}

/** The zone's offset from UTC at `ms`, in milliseconds (local − UTC). */
function offsetAt(tz: string, ms: number): number {
  const w = wallClock(tz, ms);
  const asUtc = Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute, w.second);
  return asUtc - Math.floor(ms / 1000) * 1000;
}

/**
 * The instant a facility-local date and time names. Around a DST change it
 * behaves like Temporal's 'compatible' choice: a time that happens twice
 * (fall back) is the earlier one, and a time that never happens (spring
 * forward) moves later by the gap, e.g. 02:30 on the spring-forward day in
 * Denver is 03:30 MDT.
 */
export function localDateTimeToUtc(ymd: Ymd, hhmm: HourMinute, tz: string): Date {
  assertZone(tz);
  if (!isValidYmd(ymd) || !isValidHourMinute(hhmm)) {
    throw new Error(`Bad local date/time: ${ymd} ${hhmm}`);
  }
  const [h, mi] = hhmm.split(':').map(Number);
  const localMs = ymdToUtcMs(ymd) + (h * 60 + mi) * 60_000;
  const before = offsetAt(tz, localMs - DAY_MS);
  const after = offsetAt(tz, localMs + DAY_MS);
  const candidates = [...new Set([before, after])]
    .map((offset) => localMs - offset)
    .filter((t) => offsetAt(tz, t) === localMs - t)
    .sort((a, b) => a - b);
  if (candidates.length > 0) return new Date(candidates[0]);
  // In the gap: read the wall time with the offset in force before it.
  return new Date(localMs - before);
}

/** 'YYYY-MM-DD HH:mm' at the facility, for the server-written `*Local` display strings. */
export function utcToLocalString(at: InstantLike, tz: string): LocalDateTime {
  const w = wallClock(tz, toMs(at));
  return `${wallYmd(w)} ${pad2(w.hour)}:${pad2(w.minute)}`;
}

/** The sync slot for `now`: UTC, floored to 30 minutes, 'YYYY-MM-DDTHH:mm'. */
export function slotKey(now: InstantLike): string {
  const ms = toMs(now);
  const floored = Math.floor(ms / (30 * 60_000)) * 30 * 60_000;
  return new Date(floored).toISOString().slice(0, 16);
}
