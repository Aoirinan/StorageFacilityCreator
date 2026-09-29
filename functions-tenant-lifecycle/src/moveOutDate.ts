/**
 * Hour (UTC) a move-out is dated at: noon, the same calendar day in every
 * time zone from UTC-12 to UTC+11, as the rent job dates its charges
 * (functions-automation rentChargeDateFor) and past history its entries.
 */
export const MOVE_OUT_HOUR_UTC = 12;

const CALENDAR_DAY = /^(\d{4})-(\d{2})-(\d{2})$/;

/**
 * A zoneless ISO date-time, as Dart's toIso8601String() writes a local
 * DateTime: no trailing Z and no ±hh:mm offset after the time.
 */
const ZONELESS_DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})T\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/;

function noonUtc(year: number, month: number, day: number): Date | null {
  if (month < 1 || month > 12 || day < 1) return null;
  const d = new Date(Date.UTC(year, month - 1, day, MOVE_OUT_HOUR_UTC));
  // Date.UTC rolls an impossible day (Feb 30) into the next month.
  if (d.getUTCFullYear() !== year || d.getUTCMonth() !== month - 1 || d.getUTCDate() !== day) return null;
  return d;
}

/**
 * The instant a move-out is dated at, from what the screen sent as
 * `moveOutDate`; null when it is not a date.
 *
 * - 'yyyy-MM-dd', the day the owner picked (the client from this change
 *   on): that day at noon UTC.
 * - A zoneless ISO date-time, local midnight from toIso8601String() (the
 *   client deployed before it): read as its calendar day, at noon UTC too.
 *   Node reads a zoneless time in the process zone, UTC on Cloud
 *   Functions, so the owner's 23 September became 2026-09-23T00:00Z, which
 *   the app shows as the evening of the 22nd everywhere in the US.
 * - An ISO instant with Z or an offset: as given.
 */
export function moveOutInstant(value: unknown): Date | null {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  const day = CALENDAR_DAY.exec(text) ?? ZONELESS_DATE_TIME.exec(text);
  if (day) return noonUtc(Number(day[1]), Number(day[2]), Number(day[3]));
  const instant = new Date(text);
  return Number.isNaN(instant.getTime()) ? null : instant;
}
