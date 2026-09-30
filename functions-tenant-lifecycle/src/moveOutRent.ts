/**
 * The rent line of a move-out: what the tenant still owes for days they used
 * that no rent charge covers, and what comes back to them for days after the
 * move-out that rent already posted covers.
 *
 * The screen used to count days 1 to the move-out date of the move-out month
 * as used, and charge them unless the scheduled job had posted that month.
 * A tenant whose tenancy starts 1 Oct, moved out on 24 Sep, was charged
 * "Prorated Rent (24 days) $0.80" for September days before their tenancy,
 * and October, which they had paid for at move-in, stayed charged. A
 * mid-month move-in moved out the same month was charged from the 1st for
 * days the move-in's prorated rent had already billed.
 *
 * Decided rule:
 * - Used days are those from the move-in date (or the 1st, when it is later
 *   or unknown) to the move-out date, in the move-out month only. Those no
 *   posted rent covers are charged at the month's daily rate.
 * - Days after the move-out date that posted rent covers are unused prepaid
 *   rent: they come back as a credit on the ledger, each day once however
 *   many charges cover it, at the month's daily rate but never more than
 *   the charge covering it cost per day (its amount over its days; this
 *   contract's move-in discounts come off its move-in rent). Crediting at
 *   the rate alone gave back rent never paid: $200 for a free-month coupon
 *   left on the 10th, or a rent rise's difference. Whether that credit is
 *   paid out is the owner's separate refund choice: processMoveOut records
 *   a cash, check or ACH refund positive against it, and a card refund
 *   when Stripe confirms it.
 * - Posted rent: the monthly rent charge (metadata.chargeType 'monthlyRent',
 *   with its month) covers its month; this contract's move-in rent covers
 *   the move-in date to the end of that month (prorated), the whole move-in
 *   month (a full month charged at move-in in the app), or the month after
 *   (the online move-in's "Next Month Rent"). Another contract's move-in
 *   rent is another unit's.
 * - The move-in date is this contract's move-in rent's date, else the
 *   vacated unit's moveInDate.
 *
 * Dates are calendar days. The app's move-in rows record the date picked
 * as metadata.moveInDate (a wall date, read as written): their entryDate
 * keeps the time of day the wizard defaults to, so an evening move-in on
 * the 30th fell on the next UTC day, and its one prorated day read as the
 * whole of the next month. Otherwise a stored instant (a Timestamp) is read
 * as its UTC date, as the online move-in stores UTC midnight. A move-out
 * date is the wall date the owner picked (its leading YYYY-MM-DD).
 *
 * PARITY: MoveOutRent in lib/services/move_out_rent.dart. Both test suites
 * run src/test/fixtures/moveOutRent.json.
 *
 * PARITY: the rent job decides which months a move-in already charged from
 * a copy of moveInRentPeriod, moveInRowDay and isMoveInRent
 * (moveInRentCoversForMonth in functions-automation/src/rentChargeHelpers.ts).
 * Change which days a move-in row covers here and change it there too, or
 * the job charges a month this credits back at move-out (or skips one).
 */

type DocData = Record<string, unknown>;

/** A calendar day as a count of days since 1970-01-01. */
export type Day = number;

/**
 * Days a posted rent charge covers, first and last inclusive, and what it
 * cost ([amount], after this contract's move-in discounts; null when the
 * entry has no amount).
 */
export type RentPeriod = { start: Day; end: Day; amount: number | null };

/** A ledger entry as the rent line reads it. */
export type RentLedgerRow = {
  type?: unknown;
  status?: unknown;
  referenceId?: unknown;
  /** When it was dated: a Date (a Timestamp's toDate()). */
  entryDate?: unknown;
  amount?: unknown;
  metadata?: unknown;
};

export type MoveOutRentLine = {
  /** Used days no posted rent covers, and their rent. */
  chargeDays: number;
  chargeAmount: number;
  /** Unused days after the move-out that posted rent covers, and their rent. */
  creditDays: number;
  creditAmount: number;
  /** The tenancy's first day, when known, as YYYY-MM-DD. */
  moveInDate: string | null;
};

const MS_PER_DAY = 86_400_000;

function dayFromParts(year: number, month: number, day: number): Day {
  return Date.UTC(year, month - 1, day) / MS_PER_DAY;
}

function partsOf(day: Day): { year: number; month: number; day: number } {
  const d = new Date(day * MS_PER_DAY);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

function daysInMonthOf(day: Day): number {
  const { year, month } = partsOf(day);
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

function firstOfMonth(day: Day): Day {
  const { year, month } = partsOf(day);
  return dayFromParts(year, month, 1);
}

function lastOfMonth(day: Day): Day {
  const { year, month } = partsOf(day);
  return dayFromParts(year, month + 1, 0);
}

/** YYYY-MM-DD. */
export function isoDay(day: Day): string {
  const { year, month, day: d } = partsOf(day);
  return `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

/**
 * The wall date at the start of [value] ("2026-09-24", or the app's
 * "2026-09-24T00:00:00.000"), or null. Read as written, never as an instant:
 * a date-time with no offset is otherwise parsed in the server's zone.
 */
export function wallDay(value: unknown): Day | null {
  if (typeof value !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(value.trim());
  if (!m) return null;
  const [year, month, day] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  const result = dayFromParts(year, month, day);
  return partsOf(result).day === day ? result : null;
}

/** The UTC calendar day of an instant (a Date, or a Timestamp's toDate()), or null. */
export function instantDay(value: unknown): Day | null {
  const date =
    value instanceof Date
      ? value
      : value && typeof (value as { toDate?: unknown }).toDate === 'function'
        ? (value as { toDate: () => Date }).toDate()
        : null;
  if (!date || Number.isNaN(date.getTime())) return null;
  return dayFromParts(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate());
}

/** [x] rounded to the cent, as MoveOutRent.cents in the app. */
function cents(x: number): number {
  return Math.round(x * 100) / 100;
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function metadataOf(row: RentLedgerRow): DocData {
  const metadata = row.metadata;
  return metadata && typeof metadata === 'object' ? (metadata as DocData) : {};
}

/** The row's amount, when it has one; a negative one as 0. */
function amountOf(row: RentLedgerRow): number | null {
  const amount = row.amount;
  return typeof amount === 'number' && Number.isFinite(amount) ? Math.max(0, amount) : null;
}

/** The days this contract's move-in rent [row], dated [entry], covers. */
function moveInRentPeriod(row: RentLedgerRow, entry: Day): RentPeriod {
  const type = text(row.type);
  const lineItemType = text(metadataOf(row).lineItemType);
  const amount = amountOf(row);
  if (type === 'rent') {
    // The online move-in's "Next Month Rent".
    const next = lastOfMonth(entry) + 1;
    return { start: next, end: lastOfMonth(next), amount };
  }
  if (type === 'rentCharge' && lineItemType === 'rent') {
    // A full month charged at move-in in the app, for the move-in month.
    return { start: firstOfMonth(entry), end: lastOfMonth(entry), amount };
  }
  return { start: entry, end: lastOfMonth(entry), amount };
}

/** A move-in row's date: the app's metadata.moveInDate as written, else its entryDate's UTC date. */
function moveInRowDay(row: RentLedgerRow): Day | null {
  return wallDay(metadataOf(row).moveInDate) ?? instantDay(row.entryDate);
}

/** A discount posted at the app's move-in (a negative line, lineItemType 'discount'). */
function isMoveInDiscount(row: RentLedgerRow): boolean {
  return text(metadataOf(row).lineItemType) === 'discount' || text(row.type) === 'discount';
}

function isMoveInRent(row: RentLedgerRow): boolean {
  const type = text(row.type);
  const lineItemType = text(metadataOf(row).lineItemType);
  return (
    type === 'proratedRent' ||
    type === 'rent' ||
    (type === 'rentCharge' && (lineItemType === 'proratedRent' || lineItemType === 'rent'))
  );
}

/**
 * The days rent posted to this tenant covers, and what it cost, for
 * [contractId]'s move-out, and the tenancy's first day from its move-in
 * rent. Only posted entries. This contract's move-in discounts come off its
 * move-in rent, earliest first.
 */
export function rentCoverage(
  rows: ReadonlyArray<RentLedgerRow>,
  contractId: string,
): { periods: RentPeriod[]; moveInDay: Day | null } {
  const periods: RentPeriod[] = [];
  const moveInPeriods: RentPeriod[] = [];
  let discount = 0;
  let moveInDay: Day | null = null;
  for (const row of rows) {
    if (text(row.status) !== 'posted') continue;
    const metadata = metadataOf(row);
    if (metadata.chargeType === 'monthlyRent') {
      const month = metadata.month;
      const year = metadata.year;
      if (Number.isInteger(month) && Number.isInteger(year) && (month as number) >= 1 && (month as number) <= 12) {
        const start = dayFromParts(year as number, month as number, 1);
        periods.push({ start, end: lastOfMonth(start), amount: amountOf(row) });
      }
      continue;
    }
    if (!contractId || text(row.referenceId) !== contractId) continue;
    if (isMoveInDiscount(row)) {
      const amount = row.amount;
      if (typeof amount === 'number' && Number.isFinite(amount) && amount < 0) discount -= amount;
      continue;
    }
    if (!isMoveInRent(row)) continue;
    const entry = moveInRowDay(row);
    if (entry === null) continue;
    moveInPeriods.push(moveInRentPeriod(row, entry));
    if (moveInDay === null || entry < moveInDay) moveInDay = entry;
  }
  moveInPeriods.sort((a, b) => a.start - b.start);
  for (const p of moveInPeriods) {
    if (discount > 0 && p.amount !== null) {
      const off = Math.min(p.amount, discount);
      discount -= off;
      p.amount -= off;
    }
    periods.push(p);
  }
  return { periods, moveInDay };
}

/**
 * The rent line for a move-out on [moveOutDay] at [monthlyRate] a month,
 * given the days posted rent covers ([periods]) and the tenancy's first day
 * ([moveInDay], null when unknown).
 */
export function moveOutRent(input: {
  monthlyRate: number;
  moveOutDay: Day;
  moveInDay: Day | null;
  periods: ReadonlyArray<RentPeriod>;
}): Omit<MoveOutRentLine, 'moveInDate'> {
  const rate = Number.isFinite(input.monthlyRate) && input.monthlyRate > 0 ? input.monthlyRate : 0;
  const covered = (day: Day) => input.periods.some((p) => p.start <= day && day <= p.end);

  // Used and not billed: the move-out month, from the move-in date.
  const monthStart = firstOfMonth(input.moveOutDay);
  const from = input.moveInDay !== null && input.moveInDay > monthStart ? input.moveInDay : monthStart;
  let chargeDays = 0;
  for (let day = from; day <= input.moveOutDay; day++) {
    if (!covered(day)) chargeDays++;
  }

  // Billed and not used: every covered day after the move-out, once, at
  // the month's daily rate or what the charge covering it cost per day,
  // whichever is less (the dearest charge, when several cover it).
  const perDay = new Map<Day, number>();
  for (const p of input.periods) {
    for (let day = Math.max(p.start, input.moveOutDay + 1); day <= p.end; day++) {
      const daily = rate / daysInMonthOf(day);
      const paid = p.amount === null ? daily : p.amount / (p.end - p.start + 1);
      const price = Math.min(daily, paid);
      perDay.set(day, Math.max(perDay.get(day) ?? 0, price));
    }
  }
  let credit = 0;
  for (const day of [...perDay.keys()].sort((a, b) => a - b)) {
    credit += perDay.get(day) as number;
  }

  return {
    chargeDays,
    chargeAmount: cents((chargeDays * rate) / daysInMonthOf(input.moveOutDay)),
    creditDays: perDay.size,
    creditAmount: cents(credit),
  };
}

/**
 * [moveOutRent] from the tenant's ledger: [rows] are their ledger entries
 * (any status; only posted ones count), [unitMoveInDate] the vacated unit's
 * moveInDate, used when this contract has no move-in rent to date it.
 */
export function moveOutRentLine(input: {
  monthlyRate: number;
  moveOutDay: Day;
  contractId: string;
  rows: ReadonlyArray<RentLedgerRow>;
  unitMoveInDate?: unknown;
}): MoveOutRentLine {
  const coverage = rentCoverage(input.rows, input.contractId);
  const moveInDay = coverage.moveInDay ?? instantDay(input.unitMoveInDate);
  return {
    ...moveOutRent({
      monthlyRate: input.monthlyRate,
      moveOutDay: input.moveOutDay,
      moveInDay,
      periods: coverage.periods,
    }),
    moveInDate: moveInDay === null ? null : isoDay(moveInDay),
  };
}

/** A ledger row processMoveOut posts for the move-out's own lines. */
export type MoveOutLine = {
  type: 'moveOutFee' | 'credit';
  amount: number;
  description: string;
  line: 'proratedRent' | 'proratedRentCredit' | 'fees';
  days: number | null;
};

/** A finite amount of at least 0, to the cent. */
function feeOf(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? cents(value) : 0;
}

/**
 * The move-out's own ledger rows, each on its own line as the screen lists
 * them (MoveOutService.buildCalculation): rent for used days no rent covers
 * (positive), the credit for unused days rent covers (negative), and the
 * fees. [net] is their sum, as the screen's "New Charges".
 */
export function moveOutLines(input: { rent: MoveOutRentLine | null; moveOutFees: unknown }): {
  rows: MoveOutLine[];
  net: number;
} {
  const rows: MoveOutLine[] = [];
  let rentNet = 0;
  const rent = input.rent;
  if (rent && rent.chargeAmount > 0) {
    rows.push({
      type: 'moveOutFee',
      amount: rent.chargeAmount,
      description: `Prorated rent (${rent.chargeDays} days)`,
      line: 'proratedRent',
      days: rent.chargeDays,
    });
    rentNet += rent.chargeAmount;
  }
  if (rent && rent.creditAmount > 0) {
    rows.push({
      type: 'credit',
      amount: -rent.creditAmount,
      description: `Prorated rent credit (${rent.creditDays} unused days)`,
      line: 'proratedRentCredit',
      days: rent.creditDays,
    });
    rentNet -= rent.creditAmount;
  }
  const fees = feeOf(input.moveOutFees);
  if (fees > 0) {
    rows.push({ type: 'moveOutFee', amount: fees, description: 'Move-out fees', line: 'fees', days: null });
  }
  return { rows, net: cents(rentNet + fees) };
}

/** The tenant's balance: the plain sum of their posted entries' amounts, as LedgerService.getLedgerBalance. */
export function postedBalance(rows: ReadonlyArray<{ status?: unknown; amount?: unknown }>): number {
  let total = 0;
  for (const row of rows) {
    if (text(row.status) !== 'posted') continue;
    if (typeof row.amount === 'number' && Number.isFinite(row.amount)) total += row.amount;
  }
  return cents(total);
}

function money(amount: number): string {
  return amount < 0 ? `a $${(-amount).toFixed(2)} credit` : `$${amount.toFixed(2)}`;
}

/**
 * Why processMoveOut must not post what it worked out: the owner was shown
 * something else. [shownNet] is the screen's "New Charges" and [refund] the
 * refund it offered; [net] and [balance] are the callable's own. A rent
 * charge posted, or a payment taken, since the screen calculated (or a
 * screen that disagrees with this rule) would otherwise post amounts nobody
 * reviewed, and a refund paid out in cash could exceed what the tenant is
 * owed.
 */
export function moveOutPreviewRefusal(input: {
  net: number;
  shownNet: unknown;
  balance: number;
  refund: unknown;
  processRefund: unknown;
}): string | null {
  const shown = typeof input.shownNet === 'number' && Number.isFinite(input.shownNet) ? cents(input.shownNet) : 0;
  const again = 'Nothing was moved out. Calculate charges again and check them.';
  if (Math.abs(input.net - shown) >= 0.005) {
    return `The move-out charges have changed since they were calculated: they now come to ${money(input.net)}, not ${money(shown)}. ${again}`;
  }
  const refund = feeOf(input.refund);
  if (input.processRefund === true && refund > 0) {
    const owed = Math.max(0, -cents(input.balance + input.net));
    if (refund - owed >= 0.005) {
      return `The $${refund.toFixed(2)} refund is more than the $${owed.toFixed(2)} this tenant is owed after the move-out. ${again}`;
    }
  }
  return null;
}
