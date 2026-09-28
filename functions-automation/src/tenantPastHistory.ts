/**
 * Pure rules for entering a tenant's past rent history (paper ledger ->
 * app): parsing and validating the request, spotting months that already
 * have a rent charge, and working out the balance and paidThrough that
 * result. No Firestore here; tenantPastHistoryCallable.ts does the reads and
 * the one transaction that writes.
 *
 * Why a server path at all: every client path that records a payment dates
 * it now (the rules pin paidAt to request.time) and advances paidThrough
 * from where it stands, so six old payments entered today would push
 * paidThrough months into the future. History has to be written with the
 * dates it happened on, and paidThrough worked out from the whole picture.
 */

/** Tag on every ledger entry and payment doc this tool writes. */
export const PAST_HISTORY_SOURCE = 'past_history';

/** Where the record of each history entry (for idempotency and undo) lives. */
export const PAST_HISTORY_COLLECTION = 'tenantPastHistory';

export const MAX_HISTORY_CHARGES = 120;
export const MAX_HISTORY_PAYMENTS = 200;
/** No single rent charge or payment on a paper ledger is this big. */
export const MAX_HISTORY_AMOUNT = 100000;
export const MIN_HISTORY_YEAR = 2000;
export const MAX_REFERENCE_LENGTH = 100;
export const MAX_NOTE_LENGTH = 500;

/**
 * Methods an owner can record for money received outside the card flow.
 * Kept in step with PaymentMethod in lib/models/payment_model.dart and the
 * method regex in firestore-rules-src/01-shared-functions.rules.
 */
export const HISTORY_PAYMENT_METHODS: Readonly<Record<string, string>> = {
  cash: 'Cash',
  check: 'Check',
  venmo: 'Venmo',
  zelle: 'Zelle',
  bankTransfer: 'Bank Transfer',
  creditCard: 'Credit Card',
  debitCard: 'Debit Card',
  other: 'Other',
};

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

/** A calendar day as the owner typed it, no time zone attached. */
export interface CalendarDay {
  year: number;
  month: number; // 1-based
  day: number;
}

export interface HistoryCharge {
  year: number;
  month: number; // 1-based billing month
  day: number; // day of that month the charge is dated (move-in day or 1st)
  amount: number;
}

export interface HistoryPayment {
  date: CalendarDay;
  amount: number;
  method: string;
  reference: string | null;
  note: string | null;
}

export interface PastHistoryRequest {
  facilityId: string;
  tenantId: string;
  requestId: string;
  charges: HistoryCharge[];
  payments: HistoryPayment[];
}

/** A request problem, reported to the app as invalid-argument. */
export class PastHistoryInputError extends Error {}

const DAY_MS = 24 * 60 * 60 * 1000;

/** Hour (UTC) history entries are dated at: the same day in every US zone. */
export const HISTORY_ENTRY_HOUR_UTC = 12;

export function historyInstant(d: CalendarDay): Date {
  return new Date(Date.UTC(d.year, d.month - 1, d.day, HISTORY_ENTRY_HOUR_UTC));
}

/** The last day of `year`/`month` (1-based), at noon UTC. */
export function endOfMonthInstant(year: number, month: number): Date {
  return new Date(Date.UTC(year, month, 0, HISTORY_ENTRY_HOUR_UTC));
}

export function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

export function monthKey(year: number, month: number): number {
  return year * 12 + (month - 1);
}

export function monthLabel(year: number, month: number): string {
  return `${MONTH_NAMES[month - 1]} ${year}`;
}

/** "Monthly Rent - February 2026", the scheduled job's wording. */
export function historyRentDescription(year: number, month: number): string {
  return `Monthly Rent - ${monthLabel(year, month)}`;
}

/**
 * "Payment - Check #1234", "Payment - Venmo: paid late". The Record payment
 * dialog in the app builds the same line.
 */
export function historyPaymentDescription(p: Pick<HistoryPayment, 'method' | 'reference' | 'note'>): string {
  const label = HISTORY_PAYMENT_METHODS[p.method] ?? p.method;
  const ref = p.reference ? ` #${p.reference}` : '';
  const note = p.note ? `: ${p.note}` : '';
  return `Payment - ${label}${ref}${note}`;
}

function roundCents(n: number): number {
  return Math.round(n * 100) / 100;
}

function readString(value: unknown, field: string, max = 200): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new PastHistoryInputError(`${field} is required`);
  }
  const s = value.trim();
  if (s.length > max) throw new PastHistoryInputError(`${field} is too long`);
  return s;
}

function readOptionalString(value: unknown, field: string, max: number): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string') throw new PastHistoryInputError(`${field} must be text`);
  const s = value.trim();
  if (s === '') return null;
  if (s.length > max) throw new PastHistoryInputError(`${field} is too long (max ${max} characters)`);
  return s;
}

function readAmount(value: unknown, what: string): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new PastHistoryInputError(`${what}: amount must be a number`);
  }
  const cents = roundCents(value);
  if (cents <= 0) throw new PastHistoryInputError(`${what}: amount must be more than $0`);
  if (cents > MAX_HISTORY_AMOUNT) {
    throw new PastHistoryInputError(`${what}: amount over $${MAX_HISTORY_AMOUNT} is not allowed`);
  }
  return cents;
}

/** Today's calendar day at `now` in the latest time zone (UTC+14). */
function latestToday(now: Date): CalendarDay {
  const t = new Date(now.getTime() + 14 * 60 * 60 * 1000);
  return { year: t.getUTCFullYear(), month: t.getUTCMonth() + 1, day: t.getUTCDate() };
}

function compareDays(a: CalendarDay, b: CalendarDay): number {
  return Date.UTC(a.year, a.month - 1, a.day) - Date.UTC(b.year, b.month - 1, b.day);
}

/** Parses "YYYY-MM-DD" (a date picker's day, no zone). */
export function parseCalendarDay(value: unknown, what: string): CalendarDay {
  if (typeof value !== 'string') throw new PastHistoryInputError(`${what}: date is required`);
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value.trim());
  if (!m) throw new PastHistoryInputError(`${what}: date must be YYYY-MM-DD`);
  const day = { year: Number(m[1]), month: Number(m[2]), day: Number(m[3]) };
  if (day.month < 1 || day.month > 12 || day.day < 1 || day.day > daysInMonth(day.year, day.month)) {
    throw new PastHistoryInputError(`${what}: ${value} is not a real date`);
  }
  return day;
}

function checkDayInRange(day: CalendarDay, now: Date, what: string): void {
  if (day.year < MIN_HISTORY_YEAR) {
    throw new PastHistoryInputError(`${what}: dates before ${MIN_HISTORY_YEAR} are not allowed`);
  }
  if (compareDays(day, latestToday(now)) > 0) {
    throw new PastHistoryInputError(`${what}: the date is in the future`);
  }
}

/**
 * Reads and validates the callable's data. Throws PastHistoryInputError with
 * a message the owner can act on.
 */
export function parsePastHistoryRequest(data: unknown, now: Date): PastHistoryRequest {
  const d = (data ?? {}) as Record<string, unknown>;
  const facilityId = readString(d.facilityId, 'facilityId');
  const tenantId = readString(d.tenantId, 'tenantId');
  const requestId = readString(d.requestId, 'requestId', 64);
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(requestId)) {
    throw new PastHistoryInputError('requestId must be 8-64 letters, digits, - or _');
  }

  const rawCharges = d.charges ?? [];
  const rawPayments = d.payments ?? [];
  if (!Array.isArray(rawCharges) || !Array.isArray(rawPayments)) {
    throw new PastHistoryInputError('charges and payments must be lists');
  }
  if (rawCharges.length > MAX_HISTORY_CHARGES) {
    throw new PastHistoryInputError(`At most ${MAX_HISTORY_CHARGES} monthly charges at a time`);
  }
  if (rawPayments.length > MAX_HISTORY_PAYMENTS) {
    throw new PastHistoryInputError(`At most ${MAX_HISTORY_PAYMENTS} payments at a time`);
  }
  if (rawCharges.length === 0 && rawPayments.length === 0) {
    throw new PastHistoryInputError('Nothing to save: add a charge or a payment');
  }

  const seenMonths = new Set<number>();
  const charges: HistoryCharge[] = rawCharges.map((raw, i) => {
    const c = (raw ?? {}) as Record<string, unknown>;
    const what = `Charge ${i + 1}`;
    const year = c.year;
    const month = c.month;
    if (typeof year !== 'number' || !Number.isInteger(year) || typeof month !== 'number' || !Number.isInteger(month) || month < 1 || month > 12) {
      throw new PastHistoryInputError(`${what}: month is not valid`);
    }
    const dayRaw = c.day ?? 1;
    if (typeof dayRaw !== 'number' || !Number.isInteger(dayRaw) || dayRaw < 1 || dayRaw > daysInMonth(year, month)) {
      throw new PastHistoryInputError(`${what}: day is not valid for ${monthLabel(year, month)}`);
    }
    checkDayInRange({ year, month, day: dayRaw }, now, `${what} (${monthLabel(year, month)})`);
    const key = monthKey(year, month);
    if (seenMonths.has(key)) {
      throw new PastHistoryInputError(`${monthLabel(year, month)} is listed twice`);
    }
    seenMonths.add(key);
    return { year, month, day: dayRaw, amount: readAmount(c.amount, `${what} (${monthLabel(year, month)})`) };
  });

  const payments: HistoryPayment[] = rawPayments.map((raw, i) => {
    const p = (raw ?? {}) as Record<string, unknown>;
    const what = `Payment ${i + 1}`;
    const date = parseCalendarDay(p.date, what);
    checkDayInRange(date, now, what);
    const method = typeof p.method === 'string' ? p.method : '';
    if (!Object.prototype.hasOwnProperty.call(HISTORY_PAYMENT_METHODS, method)) {
      throw new PastHistoryInputError(`${what}: payment method "${method}" is not allowed`);
    }
    return {
      date,
      amount: readAmount(p.amount, what),
      method,
      reference: readOptionalString(p.reference, `${what} check # / reference`, MAX_REFERENCE_LENGTH),
      note: readOptionalString(p.note, `${what} note`, MAX_NOTE_LENGTH),
    };
  });

  return { facilityId, tenantId, requestId, charges, payments };
}

/** A ledger row as stored, the fields these rules read. */
export interface LedgerRow {
  type?: unknown;
  status?: unknown;
  amount?: unknown;
  entryDate?: { toDate?: () => Date } | Date | null;
  metadata?: Record<string, unknown> | null;
}

function rowDate(row: LedgerRow): Date | null {
  const v = row.entryDate as any;
  if (!v) return null;
  if (v instanceof Date) return v;
  if (typeof v.toDate === 'function') return v.toDate();
  return null;
}

/**
 * The billing month a posted rent charge is for, or null when `row` is not
 * one. The recurring metadata decides when present (the job, the app and
 * this tool all stamp it); a rent charge added by hand with no metadata
 * counts for the UTC month of its date, pulled a day either way by the same
 * window the job uses, so a hand-entered charge dated at a local midnight is
 * not missed.
 */
export function rentChargeMonthOf(row: LedgerRow): { year: number; month: number } | null {
  if (row.status !== 'posted' || row.type !== 'rentCharge') return null;
  const meta = row.metadata || {};
  if (
    meta.chargeType === 'monthlyRent' &&
    typeof meta.month === 'number' &&
    typeof meta.year === 'number'
  ) {
    return { year: meta.year, month: meta.month };
  }
  const at = rowDate(row);
  if (!at) return null;
  // Middle of the stored instant's day in UTC: a local-midnight date east
  // of Greenwich reads as the day before, which the +12h brings back.
  const shifted = new Date(at.getTime() + 12 * 60 * 60 * 1000);
  return { year: shifted.getUTCFullYear(), month: shifted.getUTCMonth() + 1 };
}

/** The months in `charges` that `existing` already has a posted rent charge for. */
export function monthsAlreadyCharged(
  existing: ReadonlyArray<LedgerRow>,
  charges: ReadonlyArray<Pick<HistoryCharge, 'year' | 'month'>>,
): Array<{ year: number; month: number }> {
  const charged = new Set<number>();
  for (const row of existing) {
    const m = rentChargeMonthOf(row);
    if (m) charged.add(monthKey(m.year, m.month));
  }
  return charges
    .filter((c) => charged.has(monthKey(c.year, c.month)))
    .map((c) => ({ year: c.year, month: c.month }));
}

/** A charge or payment in the order-of-events walk. */
interface Movement {
  at: number;
  amount: number; // + charge, - payment/credit
  rentMonth: { year: number; month: number } | null;
}

export interface HistoryOutcome {
  /** This entry's charges and payments. */
  totalCharges: number;
  totalPayments: number;
  /** Sum of every posted entry after saving (the Ledger screen's Current Balance). */
  balance: number;
  /** End of the last rent month fully paid, or null when none is. */
  computedPaidThrough: Date | null;
  /**
   * Money paid beyond the fully covered charges: part of the next charge,
   * or a credit when every charge is covered.
   */
  unappliedCredit: number;
  /** The first charge not fully paid, when there is one. */
  firstUnpaidMonth: { year: number; month: number } | null;
}

/**
 * Balance and paidThrough once `charges` and `payments` join `existing`.
 *
 * Payments are applied oldest charge first, as a pool: a tenant who paid
 * $160 in June for June and July has both months covered. paidThrough is
 * the end of the last rent month in the run of charges fully covered from
 * the start; any money left over is a credit (toward the next charge, or
 * ahead of the account when nothing is owed). A month with no charge (a
 * free month the owner unticked) is simply not in the walk.
 */
export function computeHistoryOutcome(params: {
  existing: ReadonlyArray<LedgerRow>;
  charges: ReadonlyArray<HistoryCharge>;
  payments: ReadonlyArray<HistoryPayment>;
}): HistoryOutcome {
  const { existing, charges, payments } = params;
  const movements: Movement[] = [];
  let balance = 0;

  for (const row of existing) {
    if (row.status !== 'posted') continue;
    const amount = typeof row.amount === 'number' && Number.isFinite(row.amount) ? row.amount : 0;
    if (amount === 0) continue;
    balance += amount;
    const at = rowDate(row);
    movements.push({
      at: at ? at.getTime() : 0,
      amount,
      rentMonth: amount > 0 ? rentChargeMonthOf(row) : null,
    });
  }

  let totalCharges = 0;
  for (const c of charges) {
    totalCharges += c.amount;
    balance += c.amount;
    movements.push({
      at: historyInstant({ year: c.year, month: c.month, day: c.day }).getTime(),
      amount: c.amount,
      rentMonth: { year: c.year, month: c.month },
    });
  }

  let totalPayments = 0;
  for (const p of payments) {
    totalPayments += p.amount;
    balance -= p.amount;
    movements.push({ at: historyInstant(p.date).getTime(), amount: -p.amount, rentMonth: null });
  }

  // Oldest charge first; the pool of money paid is applied down that list.
  const chargeList = movements.filter((m) => m.amount > 0).sort((a, b) => a.at - b.at);
  let pool = roundCents(movements.filter((m) => m.amount < 0).reduce((s, m) => s - m.amount, 0));

  let lastCovered: { year: number; month: number } | null = null;
  let firstUnpaidMonth: { year: number; month: number } | null = null;
  for (const charge of chargeList) {
    if (pool + 0.005 >= charge.amount) {
      pool = roundCents(pool - charge.amount);
      if (charge.rentMonth) {
        if (!lastCovered || monthKey(charge.rentMonth.year, charge.rentMonth.month) > monthKey(lastCovered.year, lastCovered.month)) {
          lastCovered = charge.rentMonth;
        }
      }
      continue;
    }
    firstUnpaidMonth = charge.rentMonth ?? monthOfInstant(charge.at);
    break;
  }

  return {
    totalCharges: roundCents(totalCharges),
    totalPayments: roundCents(totalPayments),
    balance: roundCents(balance),
    computedPaidThrough: lastCovered ? endOfMonthInstant(lastCovered.year, lastCovered.month) : null,
    unappliedCredit: roundCents(pool),
    firstUnpaidMonth,
  };
}

function monthOfInstant(ms: number): { year: number; month: number } {
  const d = new Date(ms);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1 };
}

/**
 * What to do with the tenant's paidThrough. Only ever moves it later: an
 * existing paidThrough past the computed one (set by hand, or by payments
 * already recorded) is kept, with a warning for the owner to check.
 */
export function decidePaidThrough(
  existing: Date | null,
  computed: Date | null,
): { write: Date | null; warning: string | null } {
  if (!computed) return { write: null, warning: null };
  if (!existing) return { write: computed, warning: null };
  // Compare calendar days: the app stores local midnight, this stores noon UTC.
  const existingDay = Date.UTC(existing.getUTCFullYear(), existing.getUTCMonth(), existing.getUTCDate());
  const computedDay = Date.UTC(computed.getUTCFullYear(), computed.getUTCMonth(), computed.getUTCDate());
  if (computedDay > existingDay + DAY_MS) return { write: computed, warning: null };
  if (computedDay >= existingDay - DAY_MS) return { write: null, warning: null };
  return {
    write: null,
    warning:
      `Paid through was left at ${formatDay(existing)}, which is later than the ` +
      `${formatDay(computed)} this history works out to. Check it on the tenant's page.`,
  };
}

export function formatDay(d: Date): string {
  return `${d.getUTCMonth() + 1}/${d.getUTCDate()}/${d.getUTCFullYear()}`;
}
