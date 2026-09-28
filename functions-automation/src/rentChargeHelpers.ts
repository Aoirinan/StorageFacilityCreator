/**
 * Pure decision logic for monthly rent-charge generation.
 *
 * Extracted so the "should this tenant be charged, and have they already been
 * charged this month" rules can be tested without Firestore. Getting the
 * duplicate check wrong bills a tenant twice for the same month.
 *
 * Every server path that raises the recurring monthly rent charge
 * (rentChargeJob, the generateMonthlyRentCharges callable) takes its month,
 * date and duplicate window from here, so they cannot disagree.
 */

const MONTH_NAMES = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/**
 * Whether a tenant should have rent raised.
 *
 * Requires an assigned unit and a positive rate. A blank unit number means the
 * tenant record is not actually occupying anything, and a zero or missing rate
 * means there is nothing to bill — charging either would invent revenue.
 */
export function shouldChargeTenant(tenantData: Record<string, any> | undefined | null): boolean {
  if (!tenantData) return false;

  const unitNumber = tenantData.unitNumber;
  if (typeof unitNumber !== 'string' || unitNumber.trim() === '') return false;

  const monthlyRate = tenantData.monthlyRate;
  return typeof monthlyRate === 'number' && Number.isFinite(monthlyRate) && monthlyRate > 0;
}

/** A billing month. `month` is 1-based (1 = January), as stored in charge metadata. */
export interface RentChargeMonth {
  year: number;
  month: number;
}

/** Hour of day, in UTC, that a recurring rent charge is dated at. */
export const RENT_CHARGE_HOUR_UTC = 12;

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * The instant a recurring rent charge for `year`/`month` is dated at: the 1st
 * of the month at 12:00 UTC. `month` is 1-based.
 *
 * Charges used to be dated at the moment the scheduler ran, 00:00 UTC on the
 * 1st. The app renders dates in the viewer's local time, and 00:00 UTC is still
 * the previous evening everywhere in the Americas, so "Monthly Rent - October"
 * showed on ledgers and statements dated September 30. Noon UTC is the 1st in
 * every time zone from UTC-12 to UTC+11, which covers all US zones (Hawaii is
 * UTC-10) and Europe.
 */
export function rentChargeDateFor(year: number, month: number): Date {
  return new Date(Date.UTC(year, month - 1, 1, RENT_CHARGE_HOUR_UTC));
}

/**
 * The billing month a run at `now` is for, read in UTC so the answer does not
 * depend on the process time zone. The scheduler fires at 00:00 UTC on the 1st,
 * so a run seconds after midnight bills the month that just started.
 */
export function rentChargeMonthAt(now: Date): RentChargeMonth {
  return { year: now.getUTCFullYear(), month: now.getUTCMonth() + 1 };
}

/**
 * The billing month named by a caller-supplied date, or null when it cannot be
 * read.
 *
 * Takes the calendar year and month as written when the value starts with
 * `YYYY-MM`. The app sends a local `DateTime.toIso8601String()` with no offset,
 * so the leading digits are the month the operator picked; converting through
 * an instant first could move the 1st of a month into the previous one.
 * Anything else falls back to the instant's UTC month.
 */
export function rentChargeMonthFromInput(value: unknown): RentChargeMonth | null {
  if (typeof value === 'string') {
    const match = /^(\d{4})-(\d{2})/.exec(value.trim());
    if (match) {
      const year = Number(match[1]);
      const month = Number(match[2]);
      if (month >= 1 && month <= 12) return { year, month };
      return null;
    }
  }
  if (typeof value === 'string' || typeof value === 'number' || value instanceof Date) {
    const parsed = new Date(value);
    if (!Number.isNaN(parsed.getTime())) return rentChargeMonthAt(parsed);
  }
  return null;
}

/**
 * Half-open [start, end) range of entry dates searched for an existing charge
 * for `year`/`month`.
 *
 * The whole month in UTC, widened by a day on each side. Charges already on the
 * books are not all at noon UTC: the scheduled job used to post at 00:00 UTC,
 * and the app posts at the operator's local midnight, which is the previous day
 * in UTC for anyone east of Greenwich. Missing one of those would bill the
 * month twice. The metadata month and year decide the match, so the extra days
 * cannot pull in a neighbouring month's charge.
 */
export function rentChargeDuplicateWindow(year: number, month: number): { start: Date; end: Date } {
  const start = new Date(Date.UTC(year, month - 1, 1) - DAY_MS);
  const end = new Date(Date.UTC(year, month, 1) + DAY_MS);
  return { start, end };
}

/**
 * Whether one ledger entry is the recurring rent charge for `targetMonth`/`targetYear`.
 *
 * Matches on the charge metadata rather than the entry date alone: a manually
 * dated adjustment in the same month must not be mistaken for the recurring
 * charge, or the tenant would silently go un-billed. The entry date only has to
 * fall in the duplicate window, compared as an instant so the process time zone
 * does not matter.
 */
export function isRentChargeForMonth(
  entry: Record<string, any> | undefined | null,
  targetMonth: number,
  targetYear: number,
): boolean {
  const entryDate: Date | undefined = entry?.entryDate?.toDate?.();
  if (!entryDate) return false;

  const { start, end } = rentChargeDuplicateWindow(targetYear, targetMonth);
  const at = entryDate.getTime();
  if (at < start.getTime() || at >= end.getTime()) return false;

  const metadata = entry?.metadata || {};
  return (
    metadata.recurringCharge === true &&
    metadata.chargeType === 'monthlyRent' &&
    metadata.month === targetMonth &&
    metadata.year === targetYear
  );
}

/** Whether this month's rent charge already exists for a tenant. */
export function hasRentChargeForMonth(
  ledgerEntries: ReadonlyArray<Record<string, any>>,
  targetMonth: number,
  targetYear: number,
): boolean {
  return ledgerEntries.some((entry) => isRentChargeForMonth(entry, targetMonth, targetYear));
}

/** Human-readable description, e.g. "Monthly Rent - March 2026". `month` is 1-based. */
export function buildRentChargeDescription(year: number, month: number): string {
  return `Monthly Rent - ${MONTH_NAMES[month - 1]} ${year}`;
}
