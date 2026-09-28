/**
 * Pure decision logic for monthly rent-charge generation.
 *
 * Extracted so the "should this tenant be charged, and have they already been
 * charged this month" rules can be tested without Firestore. Getting the
 * duplicate check wrong bills a tenant twice for the same month.
 *
 * Every server path that raises the recurring monthly rent charge
 * (rentChargeJob, the generateMonthlyRentCharges callable) takes its month,
 * date, duplicate window and move-in rent check from here, so they cannot
 * disagree.
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

// --- rent already charged at move-in ----------------------------------------
//
// A move-in posts rent of its own, and none of it is tagged as the monthly
// charge, so the duplicate check above never saw it. A move-in made in
// September and dated 1 Oct is charged all of October at move-in, and the job
// then posted "Monthly Rent - October" on the 1st; an online move-in's "Next
// Month Rent" was charged twice the same way.
//
// Which days a move-in rent row covers is the rule rentCoverage applies at
// move-out (functions-tenant-lifecycle/src/moveOutRent.ts, from 12094e8):
// - the online move-in's "Next Month Rent" (type 'rent') covers the month
//   after the move-in month;
// - the app's full month at move-in (type 'rentCharge', metadata.lineItemType
//   'rent') covers the move-in month;
// - prorated rent (type 'proratedRent' online, or 'rentCharge' with
//   lineItemType 'proratedRent' in the app) covers the move-in date to the end
//   of that month.
// A row's date is the app's metadata.moveInDate as written (its entryDate
// keeps the wizard's time of day, so an evening move-in on the 30th reads as
// the next UTC day), else its entryDate's UTC date, as the online move-in
// stores UTC midnight.
//
// PARITY: moveInRentPeriod, moveInRowDay and isMoveInRent in moveOutRent.ts.
// Change one, change the other.

/** Ledger types the job reads: its own charges and both move-ins' rent. */
export const RENT_CHARGE_LEDGER_TYPES = ['rentCharge', 'proratedRent', 'rent'] as const;

/** A calendar day as a count of days since 1970-01-01. */
type Day = number;

function dayFromParts(year: number, month: number, day: number): Day {
  return Date.UTC(year, month - 1, day) / DAY_MS;
}

function partsOf(day: Day): { year: number; month: number; day: number } {
  const d = new Date(day * DAY_MS);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

function firstOfMonth(day: Day): Day {
  const { year, month } = partsOf(day);
  return dayFromParts(year, month, 1);
}

function lastOfMonth(day: Day): Day {
  const { year, month } = partsOf(day);
  return dayFromParts(year, month + 1, 0);
}

/** The wall date at the start of `value` ("2026-10-01" or "2026-10-01T00:00:00.000"), read as written. */
function wallDay(value: unknown): Day | null {
  if (typeof value !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(value.trim());
  if (!m) return null;
  const [year, month, day] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const result = dayFromParts(year, month, day);
  return partsOf(result).day === day ? result : null;
}

/** The UTC calendar day of an instant (a Date, or a Timestamp's toDate()). */
function instantDay(value: unknown): Day | null {
  const date =
    value instanceof Date
      ? value
      : value && typeof (value as { toDate?: unknown }).toDate === 'function'
        ? (value as { toDate: () => Date }).toDate()
        : null;
  if (!date || Number.isNaN(date.getTime())) return null;
  return dayFromParts(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate());
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function metadataOf(row: Record<string, any>): Record<string, any> {
  const metadata = row.metadata;
  return metadata && typeof metadata === 'object' ? metadata : {};
}

function isMoveInRent(row: Record<string, any>): boolean {
  const type = text(row.type);
  const lineItemType = text(metadataOf(row).lineItemType);
  return (
    type === 'proratedRent' ||
    type === 'rent' ||
    (type === 'rentCharge' && (lineItemType === 'proratedRent' || lineItemType === 'rent'))
  );
}

/** A move-in row's date: the app's metadata.moveInDate as written, else its entryDate's UTC date. */
function moveInRowDay(row: Record<string, any>): Day | null {
  return wallDay(metadataOf(row).moveInDate) ?? instantDay(row.entryDate);
}

/** The days, first and last inclusive, that a move-in rent row dated `entry` covers. */
function moveInRentPeriod(row: Record<string, any>, entry: Day): { start: Day; end: Day } {
  const type = text(row.type);
  const lineItemType = text(metadataOf(row).lineItemType);
  if (type === 'rent') {
    // The online move-in's "Next Month Rent".
    const next = lastOfMonth(entry) + 1;
    return { start: next, end: lastOfMonth(next) };
  }
  if (type === 'rentCharge' && lineItemType === 'rent') {
    // A full month charged at move-in in the app, for the move-in month.
    return { start: firstOfMonth(entry), end: lastOfMonth(entry) };
  }
  return { start: entry, end: lastOfMonth(entry) };
}

/** Rounded to the cent. */
function cents(x: number): number {
  return Math.round(x * 100) / 100;
}

/**
 * One contract (one unit) whose move-in rent already billed the month.
 *
 * `monthlyShare` is that unit's monthly rent as the move-in charged it (the
 * row's amount for a whole month; scaled up from the days charged when the
 * move-in falls inside the month), or null when a covering row has no amount.
 * It is the gross rent: a move-in discount is a separate row and does not
 * make the month any less charged.
 */
export interface MoveInRentCover {
  contractId: string;
  monthlyShare: number | null;
  /** The covering rows' ledger ids, where the caller supplied an `id`. */
  entryIds: string[];
}

/**
 * The contracts whose posted move-in rent already covers `month`/`year`.
 *
 * A contract's month is covered when its move-in rent covers every day of the
 * month from its move-in date on. That is the whole month for a move-in on or
 * before the 1st (the full month the app charges, a prorated charge dated the
 * 1st, the online "Next Month Rent"), and the rest of the month for a move-in
 * dated later in it: the days before a tenancy starts are not rent it owes,
 * as at move-out. A mid-month move-in's prorated rent covers only its own
 * month, so the month after is not covered and the job charges it.
 *
 * Grouped by referenceId, which both move-ins set to the new contract: a
 * second unit's move-in covers that unit only.
 */
export function moveInRentCoversForMonth(
  ledgerEntries: ReadonlyArray<Record<string, any>>,
  targetMonth: number,
  targetYear: number,
): MoveInRentCover[] {
  const monthStart = dayFromParts(targetYear, targetMonth, 1);
  const monthEnd = lastOfMonth(monthStart);
  const daysInMonth = monthEnd - monthStart + 1;

  type Row = { id: string | null; start: Day; end: Day; entry: Day; amount: number | null };
  const byContract = new Map<string, Row[]>();
  for (const row of ledgerEntries) {
    if (!row || text(row.status) !== 'posted') continue;
    if (metadataOf(row).chargeType === 'monthlyRent') continue;
    if (!isMoveInRent(row)) continue;
    const entry = moveInRowDay(row);
    if (entry === null) continue;
    const { start, end } = moveInRentPeriod(row, entry);
    const amount =
      typeof row.amount === 'number' && Number.isFinite(row.amount) ? Math.max(0, row.amount) : null;
    const contractId = text(row.referenceId);
    const rows = byContract.get(contractId) ?? [];
    rows.push({ id: typeof row.id === 'string' ? row.id : null, start, end, entry, amount });
    byContract.set(contractId, rows);
  }

  const covers: MoveInRentCover[] = [];
  for (const [contractId, rows] of byContract) {
    const moveInDay = Math.min(...rows.map((r) => r.entry));
    // A tenancy starting after this month is not this month's to cover.
    if (moveInDay > monthEnd) continue;
    const from = Math.max(monthStart, moveInDay);

    // Every day owed this month must be covered. What it was charged is the
    // covering row's amount over its days (the dearest, if two cover it).
    let charged: number | null = 0;
    const covering = new Set<Row>();
    let covered = true;
    for (let day = from; day <= monthEnd; day++) {
      const over = rows.filter((r) => r.start <= day && day <= r.end);
      if (over.length === 0) {
        covered = false;
        break;
      }
      over.forEach((r) => covering.add(r));
      const perDay = over
        .filter((r) => r.amount !== null)
        .map((r) => (r.amount as number) / (r.end - r.start + 1));
      charged = charged === null || perDay.length === 0 ? null : charged + Math.max(...perDay);
    }
    if (!covered) continue;

    // Scaled up to a whole month when the move-in falls inside it.
    const daysOwed = monthEnd - from + 1;
    covers.push({
      contractId,
      monthlyShare: charged === null ? null : cents((charged / daysOwed) * daysInMonth),
      entryIds: [...covering].map((r) => r.id).filter((id): id is string => id !== null),
    });
  }
  return covers;
}

/** What the monthly rent job should do for one tenant and month. */
export type MonthlyRentChargePlan =
  /** Post the month's rent at `amount`. `lessCoveredAtMoveIn` is what move-in rent already charged, when any. */
  | { action: 'charge'; amount: number; lessCoveredAtMoveIn: number; covers: MoveInRentCover[] }
  /** Post nothing: every unit the tenant rents had this month charged at move-in. */
  | { action: 'skip'; covers: MoveInRentCover[] }
  /** Post nothing and flag for the owner: what is still owed cannot be told from the rate. */
  | { action: 'review'; reason: string; covers: MoveInRentCover[] };

/**
 * The month's charge for a tenant at `monthlyRate`, given the contracts whose
 * move-in rent already covers it (moveInRentCoversForMonth) and how many units
 * the tenant rents.
 *
 * - No move-in rent covers the month: the full rate, as always.
 * - It covers every unit they rent (one unit, or all of them): nothing.
 * - They rent more units than it covers: the rate is the total for all of
 *   them, and only the covered units' month is paid, so the charge is the
 *   rate less those units' rent. When that leaves nothing, or a covering
 *   row has no amount, the split cannot be trusted: nothing is posted and the
 *   tenant is flagged rather than billed a guess.
 *
 * `heldUnitCount` is how many units the tenant rents (units whose tenantId is
 * theirs). A count of 0, a tenant whose unit is not linked, is one unit.
 * `movedOutContractIds` are contracts already moved out: a unit the tenant
 * has left is not in their rate, so its move-in rent says nothing about the
 * units they still rent.
 */
export function planMonthlyRentCharge(input: {
  monthlyRate: number;
  covers: ReadonlyArray<MoveInRentCover>;
  heldUnitCount: number;
  movedOutContractIds?: ReadonlySet<string>;
}): MonthlyRentChargePlan {
  const covers = input.covers.filter((c) => !input.movedOutContractIds?.has(c.contractId));
  if (covers.length === 0) {
    return { action: 'charge', amount: input.monthlyRate, lessCoveredAtMoveIn: 0, covers };
  }
  if (Math.max(1, input.heldUnitCount) <= covers.length) {
    return { action: 'skip', covers };
  }
  if (covers.some((c) => c.monthlyShare === null)) {
    return {
      action: 'review',
      reason: 'A move-in rent charge covering this month has no amount, so the other units\' rent cannot be worked out.',
      covers,
    };
  }
  const covered = cents(covers.reduce((sum, c) => sum + (c.monthlyShare as number), 0));
  const amount = cents(input.monthlyRate - covered);
  if (amount <= 0) {
    return {
      action: 'review',
      reason:
        `Rent charged at move-in ($${covered.toFixed(2)}) is at least the monthly rate ` +
        `($${input.monthlyRate.toFixed(2)}) though the tenant rents ${input.heldUnitCount} units.`,
      covers,
    };
  }
  return { action: 'charge', amount, lessCoveredAtMoveIn: covered, covers };
}

/**
 * The description for a charge the plan reduced, e.g. "Monthly Rent - October
 * 2026 (less $100.00 charged at move-in)", so the owner and tenant can see why
 * it is under the rate.
 */
export function buildReducedRentChargeDescription(
  year: number,
  month: number,
  lessCoveredAtMoveIn: number,
): string {
  return `${buildRentChargeDescription(year, month)} (less $${lessCoveredAtMoveIn.toFixed(2)} charged at move-in)`;
}

/**
 * Half-open [start, end) range of entry dates the job reads for `year`/`month`:
 * the month before and the month itself, with a day either side.
 *
 * Wider than rentChargeDuplicateWindow because the online "Next Month Rent"
 * that covers this month is dated at the move-in, in the month before. The
 * extra day either side catches the app's move-in rows, whose entryDate is a
 * local time and can fall on the neighbouring UTC day.
 */
export function rentChargeLedgerWindow(year: number, month: number): { start: Date; end: Date } {
  const start = new Date(Date.UTC(year, month - 2, 1) - DAY_MS);
  const end = new Date(Date.UTC(year, month, 1) + DAY_MS);
  return { start, end };
}
