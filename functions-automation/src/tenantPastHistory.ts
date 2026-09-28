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

import { createHash } from 'crypto';

/** Tag on every ledger entry and payment doc this tool writes. */
export const PAST_HISTORY_SOURCE = 'past_history';

/** Where the record of each history entry (for idempotency and undo) lives. */
export const PAST_HISTORY_COLLECTION = 'tenantPastHistory';

export const MAX_HISTORY_CHARGES = 120;
export const MAX_HISTORY_PAYMENTS = 200;
/** Entries already on the ledger that one save may void (hand-entered ones it replaces). */
export const MAX_HISTORY_VOIDS = 200;
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
  /**
   * The owner's records give only the month ("September $1000"): the date is
   * the 1st of it, and the entry says so.
   */
  monthOnly: boolean;
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
  /**
   * Ledger entries already on this tenant's ledger to void in the same
   * save: history the owner had typed in by hand (Add entry), dated the day
   * it was typed, that this entry replaces. Undo puts them back.
   */
  voidLedgerEntryIds: string[];
  /** The move-in date the owner gave; saved on the tenant if it has none. */
  moveInDate: CalendarDay | null;
  /**
   * Months the owner unticked (free rent). Not charged; one right after a
   * paid month counts as paid for paidThrough.
   */
  freeMonths: Array<{ year: number; month: number }>;
  /**
   * 'computed': set paidThrough to what the ledger works out to after the
   * save, even if earlier (the owner's choice when the save voids payments
   * that had pushed it forward). 'keepLater': only ever move it later.
   * Null: the default (computed when the save voids a payment, else
   * keepLater).
   */
  paidThroughChoice: PaidThroughChoice | null;
}

export type PaidThroughChoice = 'computed' | 'keepLater';

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
export function historyPaymentDescription(
  p: Pick<HistoryPayment, 'method' | 'reference' | 'note'> & { monthOnly?: boolean; date?: CalendarDay },
): string {
  const label = HISTORY_PAYMENT_METHODS[p.method] ?? p.method;
  const ref = p.reference ? ` #${p.reference}` : '';
  // A payment known only by its month is dated the 1st; say so on the line
  // so the statement does not claim a day nobody recorded.
  const month = p.monthOnly && p.date ? ` (${monthLabel(p.date.year, p.date.month)})` : '';
  const note = p.note ? `: ${p.note}` : '';
  return `Payment - ${label}${ref}${month}${note}`;
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
  const rawVoids = d.voidLedgerEntryIds ?? [];
  if (!Array.isArray(rawCharges) || !Array.isArray(rawPayments) || !Array.isArray(rawVoids)) {
    throw new PastHistoryInputError('charges, payments and voidLedgerEntryIds must be lists');
  }
  if (rawVoids.length > MAX_HISTORY_VOIDS) {
    throw new PastHistoryInputError(`At most ${MAX_HISTORY_VOIDS} existing entries can be voided at a time`);
  }
  const voidLedgerEntryIds: string[] = [];
  for (const v of rawVoids) {
    if (typeof v !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(v)) {
      throw new PastHistoryInputError('An entry to void is not a valid id');
    }
    if (!voidLedgerEntryIds.includes(v)) voidLedgerEntryIds.push(v);
  }
  let moveInDate: CalendarDay | null = null;
  if (d.moveInDate !== undefined && d.moveInDate !== null && d.moveInDate !== '') {
    moveInDate = parseCalendarDay(d.moveInDate, 'Move-in date');
    checkDayInRange(moveInDate, now, 'Move-in date');
  }
  if (rawCharges.length > MAX_HISTORY_CHARGES) {
    throw new PastHistoryInputError(`At most ${MAX_HISTORY_CHARGES} monthly charges at a time`);
  }
  if (rawPayments.length > MAX_HISTORY_PAYMENTS) {
    throw new PastHistoryInputError(`At most ${MAX_HISTORY_PAYMENTS} payments at a time`);
  }
  if (rawCharges.length === 0 && rawPayments.length === 0 && voidLedgerEntryIds.length === 0) {
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
    const monthOnly = p.monthOnly === true;
    const parsed = parseCalendarDay(p.date, what);
    const date = monthOnly ? { ...parsed, day: 1 } : parsed;
    checkDayInRange(date, now, what);
    const method = typeof p.method === 'string' ? p.method : '';
    if (!Object.prototype.hasOwnProperty.call(HISTORY_PAYMENT_METHODS, method)) {
      throw new PastHistoryInputError(`${what}: payment method "${method}" is not allowed`);
    }
    return {
      date,
      monthOnly,
      amount: readAmount(p.amount, what),
      method,
      reference: readOptionalString(p.reference, `${what} check # / reference`, MAX_REFERENCE_LENGTH),
      note: readOptionalString(p.note, `${what} note`, MAX_NOTE_LENGTH),
    };
  });

  const rawFree = d.freeMonths ?? [];
  if (!Array.isArray(rawFree) || rawFree.length > MAX_HISTORY_CHARGES) {
    throw new PastHistoryInputError('freeMonths must be a list of at most 120 months');
  }
  const freeMonths: Array<{ year: number; month: number }> = [];
  for (const raw of rawFree) {
    const f = (raw ?? {}) as Record<string, unknown>;
    const { year, month } = f;
    if (typeof year !== 'number' || !Number.isInteger(year) || typeof month !== 'number' || !Number.isInteger(month) || month < 1 || month > 12) {
      throw new PastHistoryInputError('A free month is not valid');
    }
    checkDayInRange({ year, month, day: 1 }, now, `Free month ${monthLabel(year, month)}`);
    if (seenMonths.has(monthKey(year, month))) {
      throw new PastHistoryInputError(`${monthLabel(year, month)} is both charged and free`);
    }
    if (!freeMonths.some((m) => m.year === year && m.month === month)) freeMonths.push({ year, month });
  }

  let paidThroughChoice: PaidThroughChoice | null = null;
  if (d.paidThroughChoice !== undefined && d.paidThroughChoice !== null) {
    if (d.paidThroughChoice !== 'computed' && d.paidThroughChoice !== 'keepLater') {
      throw new PastHistoryInputError('paidThroughChoice must be computed or keepLater');
    }
    paidThroughChoice = d.paidThroughChoice;
  }

  return {
    facilityId,
    tenantId,
    requestId,
    charges,
    payments,
    voidLedgerEntryIds,
    moveInDate,
    freeMonths,
    paidThroughChoice,
  };
}

/**
 * A fingerprint of what a request asks for, stored with its requestId. A
 * repeat of the same requestId with a different fingerprint is a different
 * save under an old id (an edit after a timed-out save), refused rather than
 * answered with the first save's result.
 */
export function historyPayloadHash(r: PastHistoryRequest): string {
  const day = (d: CalendarDay | null) => (d ? `${d.year}-${d.month}-${d.day}` : null);
  const byMonth = (a: { year: number; month: number }, b: { year: number; month: number }) =>
    monthKey(a.year, a.month) - monthKey(b.year, b.month);
  const normal = {
    facilityId: r.facilityId,
    tenantId: r.tenantId,
    charges: [...r.charges].sort(byMonth).map((c) => [c.year, c.month, c.day, c.amount]),
    payments: r.payments.map((p) => [day(p.date), p.monthOnly, p.amount, p.method, p.reference, p.note]),
    voids: [...r.voidLedgerEntryIds].sort(),
    moveIn: day(r.moveInDate),
    free: [...r.freeMonths].sort(byMonth).map((m) => [m.year, m.month]),
    choice: r.paidThroughChoice,
  };
  return createHash('sha256').update(JSON.stringify(normal)).digest('hex');
}

/** A ledger row as stored, the fields these rules read. */
export interface LedgerRow {
  id?: string;
  tenantId?: unknown;
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

export interface HistoryOutcome {
  /** This entry's charges and payments. */
  totalCharges: number;
  totalPayments: number;
  /** Sum of every posted entry after saving (the Ledger screen's Current Balance). */
  balance: number;
  /** End of the last rent month paid, or null when none is. */
  computedPaidThrough: Date | null;
  /**
   * Money paid beyond the rent months it covers: part of the next month's
   * rent, or less than a month ahead when nothing is owed.
   */
  unappliedCredit: number;
  /** The first rent month not fully paid, when there is one. */
  firstUnpaidMonth: { year: number; month: number } | null;
  /** Whole months past the last charged month that a credit pays for. */
  prepaidMonths: number;
}

/**
 * Balance and paidThrough for a tenant's ledger as it will stand after the
 * save: `existing` (the posted rows kept, without any being voided), plus
 * `charges` and `payments`.
 *
 * Only rent decides paidThrough. All money paid is applied to the rent
 * months in month order; fees (late, admin, move-in, insurance) count in the
 * balance but do not hold paidThrough back. A free month right after a paid
 * month counts as paid. Months past the last charged month are bought only
 * with real credit (the whole balance below zero, fees and deposits
 * included), in whole months at `monthlyRate`; less than a month is a
 * credit.
 */
export function computeHistoryOutcome(params: {
  existing: ReadonlyArray<LedgerRow>;
  charges: ReadonlyArray<HistoryCharge>;
  payments: ReadonlyArray<HistoryPayment>;
  freeMonths?: ReadonlyArray<{ year: number; month: number }>;
  monthlyRate?: number;
}): HistoryOutcome {
  const { existing, charges, payments } = params;
  const rentByMonth = new Map<number, number>();
  let pool = 0;
  let balance = 0;

  for (const row of existing) {
    if (row.status !== 'posted') continue;
    const amount = typeof row.amount === 'number' && Number.isFinite(row.amount) ? row.amount : 0;
    if (amount === 0) continue;
    balance += amount;
    if (amount < 0) {
      pool += -amount;
      continue;
    }
    const m = rentChargeMonthOf(row);
    if (m) {
      const key = monthKey(m.year, m.month);
      rentByMonth.set(key, (rentByMonth.get(key) ?? 0) + amount);
    }
  }

  let totalCharges = 0;
  for (const c of charges) {
    totalCharges += c.amount;
    balance += c.amount;
    const key = monthKey(c.year, c.month);
    rentByMonth.set(key, (rentByMonth.get(key) ?? 0) + c.amount);
  }

  let totalPayments = 0;
  for (const p of payments) {
    totalPayments += p.amount;
    balance -= p.amount;
    pool += p.amount;
  }

  pool = roundCents(pool);
  const months = [...rentByMonth.keys()].sort((a, b) => a - b);
  let lastCovered: number | null = null;
  let firstUnpaid: number | null = null;
  for (const key of months) {
    const need = roundCents(rentByMonth.get(key)!);
    if (pool + 0.005 >= need) {
      pool = roundCents(pool - need);
      lastCovered = key;
      continue;
    }
    firstUnpaid = key;
    break;
  }

  const free = new Set((params.freeMonths ?? []).map((m) => monthKey(m.year, m.month)));
  const extendThroughFree = () => {
    while (
      lastCovered !== null &&
      free.has(lastCovered + 1) &&
      !rentByMonth.has(lastCovered + 1) &&
      (firstUnpaid === null || lastCovered + 1 < firstUnpaid)
    ) {
      lastCovered += 1;
    }
  };
  extendThroughFree();

  // Months past the last charged one are bought only with real credit: the
  // whole balance below zero, fees and deposits included. Money that paid a
  // deposit or a fee must not buy future rent just because rent was applied
  // first on the charged months.
  let prepaidMonths = 0;
  const rate = params.monthlyRate ?? 0;
  if (firstUnpaid === null) {
    const credit = Math.max(0, roundCents(-balance));
    if (lastCovered !== null && rate > 0) {
      prepaidMonths = Math.floor((credit + 0.005) / rate);
      lastCovered += prepaidMonths;
    }
    pool = roundCents(credit - prepaidMonths * rate);
  }

  const monthOf = (key: number) => ({ year: Math.floor(key / 12), month: (key % 12) + 1 });
  return {
    totalCharges: roundCents(totalCharges),
    totalPayments: roundCents(totalPayments),
    balance: roundCents(balance),
    computedPaidThrough:
      lastCovered === null ? null : endOfMonthInstant(monthOf(lastCovered).year, monthOf(lastCovered).month),
    unappliedCredit: roundCents(pool),
    firstUnpaidMonth: firstUnpaid === null ? null : monthOf(firstUnpaid),
    prepaidMonths,
  };
}

function sameDay(a: Date | null, b: Date | null): boolean {
  if (!a || !b) return a === b;
  // The app stores local midnight, this stores noon UTC: within a day either
  // way is the same date.
  const da = Date.UTC(a.getUTCFullYear(), a.getUTCMonth(), a.getUTCDate());
  const db = Date.UTC(b.getUTCFullYear(), b.getUTCMonth(), b.getUTCDate());
  return Math.abs(da - db) <= DAY_MS;
}

/**
 * What to do with the tenant's paidThrough.
 *
 * `computed` sets it to what the ledger works out to after the save, even
 * when that is earlier: the owner's choice when payments that had pushed it
 * forward are being voided. `keepLater` only moves it later and keeps a
 * later date with a warning. With no choice, the default is `computed` when
 * the save voids a payment and `keepLater` otherwise.
 */
export function decidePaidThrough(
  existing: Date | null,
  computed: Date | null,
  choice: PaidThroughChoice,
): { change: boolean; value: Date | null; warning: string | null } {
  if (sameDay(existing, computed)) return { change: false, value: existing, warning: null };
  if (choice === 'computed') return { change: true, value: computed, warning: null };
  if (!computed) return { change: false, value: existing, warning: null };
  if (!existing || computed.getTime() > existing.getTime()) return { change: true, value: computed, warning: null };
  return {
    change: false,
    value: existing,
    warning:
      `Paid through was left at ${formatDay(existing)}, which is later than the ` +
      `${formatDay(computed)} this history works out to. Check it on the tenant's page.`,
  };
}

export function formatDay(d: Date): string {
  return `${d.getUTCMonth() + 1}/${d.getUTCDate()}/${d.getUTCFullYear()}`;
}
