import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';

import {
  MANUAL_PAYMENT_METHODS,
  STAYS_CALLABLES,
  STAY_COLLECTIONS,
  StayDoc,
  StayFolioAirbnb,
  StayFolioDoc,
  StayIncomeDoc,
  StayManualPaymentMethod,
  StayRole,
  StaysRecordPaymentResponse,
  StaysVoidIncomeResponse,
  Ymd,
} from '@sfc/functions-shared/stays/contracts';
import { addDays, facilityToday, isValidYmd, localDateTimeToUtc } from '@sfc/functions-shared/stays/dates';
import { applyPayment, paymentStatusOf, splitProRata, splitTaxProRata } from '@sfc/functions-shared/stays/folio';
import { incomeIdManual } from '@sfc/functions-shared/stays/ids';
import { MAX_RATE_CENTS, validateText } from '@sfc/functions-shared/stays/validation';

import { confirmedTimeZone } from '../common/controls';
import { staysError, staysErrorReason } from '../common/errors';
import {
  StaysCallContext,
  StaysDeps,
  assertEmployeeSetting,
  auditStays,
  defaultStaysDeps,
  requireDocId,
  requireRequestId,
  runStaysGuards,
  staysCallable,
} from '../common/guards';
import { applyStayMutations } from '../common/stayWriter';
import { facilityCol, folioRef, incomeRef, invalid, isOtaSource, stayRef, toWire, validated } from './shared';

/**
 * Stay money recorded by hand (spec §8.2): cash, check, a card taken on her
 * own terminal, Venmo. Every row is stayIncome/man_{requestId}, created
 * once, so a double tap or a retry can never record a payment twice. The
 * folio and the stay's payment chip move in the same transaction. Nothing
 * here touches storage money (ledgers, payments, invoices).
 */

const STAFF: readonly StayRole[] = ['owner', 'manager', 'employee'];
const OWNER_OR_MANAGER: readonly StayRole[] = ['owner', 'manager'];

export interface ParsedPayment {
  method: StayManualPaymentMethod;
  amountCents: number;
  receivedDate: Ymd;
}

/** A hand-recorded payment. `allowNegative` only for a refund given back. */
export function parsePayment(value: unknown, field: string, allowNegative = false): ParsedPayment {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw invalid(field, 'The payment details are missing.');
  const p = value as Record<string, unknown>;
  if (!(MANUAL_PAYMENT_METHODS as readonly unknown[]).includes(p.method)) {
    throw invalid(`${field}.method`, 'Choose how it was paid: cash, check, card elsewhere, Venmo, bank or other.');
  }
  const amount = p.amountCents;
  if (!Number.isInteger(amount) || amount === 0 || Math.abs(amount as number) > MAX_RATE_CENTS) {
    throw invalid(`${field}.amountCents`, 'Enter an amount in whole cents, up to $100,000.');
  }
  if (!allowNegative && (amount as number) < 0) throw invalid(`${field}.amountCents`, 'A payment must be more than zero.');
  if (!isValidYmd(p.receivedDate)) {
    throw staysError('invalid-argument', 'invalid_dates', 'The payment date must be a YYYY-MM-DD date.', { field: `${field}.receivedDate` });
  }
  return { method: p.method as StayManualPaymentMethod, amountCents: amount as number, receivedDate: p.receivedDate };
}

/** A payment is recorded for a day that has happened, within the last year. */
export function assertReceivedDate(receivedDate: Ymd, today: Ymd, field: string): void {
  if (receivedDate > today) {
    throw staysError('invalid-argument', 'invalid_dates', 'A payment date cannot be in the future.', { field });
  }
  if (receivedDate < addDays(today, -366)) {
    throw staysError('invalid-argument', 'invalid_dates', 'That payment date is more than a year ago.', { field });
  }
}

/** When the money came in: now, for today; noon at the facility on an earlier day. */
export function receivedAtFor(receivedDate: Ymd, today: Ymd, tz: string, nowMs: number): Timestamp {
  return receivedDate === today ? Timestamp.fromMillis(nowMs) : Timestamp.fromDate(localDateTimeToUtc(receivedDate, '12:00', tz));
}

/** The folio's cleaning charges, for the cleaning share a payment carries (earnings reports use it). */
function cleaningCents(folio: Pick<StayFolioDoc, 'lines'> | null): number {
  return (folio?.lines ?? []).filter((l) => l.code === 'cleaning').reduce((sum, l) => sum + l.amountCents, 0);
}

/**
 * The stayIncome row for a hand-recorded payment (or refund, when negative).
 * `folioBefore` is the folio before this payment: the pass-through tax and
 * cleaning shares are split pro rata from it (netCents = gross − tax).
 */
export function manualIncomeDoc(opts: {
  facilityId: string;
  stayId: string;
  stay: Pick<StayDoc, 'listingId' | 'guestDisplayName' | 'checkIn' | 'checkOut' | 'nights' | 'external'>;
  folioBefore: Pick<StayFolioDoc, 'taxCents' | 'totalCents' | 'paidCents' | 'lines'> | null;
  payment: ParsedPayment;
  requestId: string;
  memo: string;
  receivedAt: Timestamp;
  actor: string;
  now: Timestamp;
}): StayIncomeDoc {
  const { payment, folioBefore } = opts;
  const tax = folioBefore ? splitTaxProRata(payment.amountCents, folioBefore) : { taxCents: 0, netCents: payment.amountCents };
  const cleaning = folioBefore
    ? splitProRata(payment.amountCents, cleaningCents(folioBefore), folioBefore.totalCents, folioBefore.paidCents)
    : 0;
  return {
    facilityId: opts.facilityId,
    listingId: opts.stay.listingId,
    stayId: opts.stayId,
    guestName: opts.stay.guestDisplayName ? opts.stay.guestDisplayName.slice(0, 60) : null,
    source: 'manual',
    method: payment.method,
    kind: payment.amountCents < 0 ? 'refund_given' : 'stay_payment',
    countsAsIncome: true,
    grossCents: payment.amountCents,
    channelFeeCents: 0,
    cleaningFeeCents: cleaning,
    taxPassThroughCents: tax.taxCents,
    taxRemittedByChannelCents: 0,
    netCents: tax.netCents,
    receivedDate: payment.receivedDate,
    receivedMonth: payment.receivedDate.slice(0, 7),
    receivedAt: opts.receivedAt,
    stayStart: opts.stay.checkIn ?? null,
    stayEnd: opts.stay.checkOut ?? null,
    nights: Number.isInteger(opts.stay.nights) ? opts.stay.nights : null,
    externalRef: { confirmationCode: opts.stay.external?.confirmationCode ?? null, referenceCode: null },
    memo: opts.memo,
    importBatchId: null,
    requestId: opts.requestId,
    status: 'posted',
    voidedAt: null,
    voidedBy: null,
    voidReason: null,
    createdAt: opts.now,
    createdBy: opts.actor,
  };
}

/** Thrown inside a write to start it again from fresh reads (something moved under it). */
class RetryWrite extends Error {}
/** Thrown inside a write when this requestId's row already exists. */
class AlreadyRecorded extends Error {}

function sameMoney(a: Pick<StayFolioDoc, 'paidCents' | 'totalCents'> | null, b: Pick<StayFolioDoc, 'paidCents' | 'totalCents'> | null): boolean {
  if (!a || !b) return !a && !b;
  return a.paidCents === b.paidCents && a.totalCents === b.totalCents;
}

// ---------------------------------------------------------------------------
// staysRecordPayment
// ---------------------------------------------------------------------------

export async function handleRecordPayment(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysRecordPaymentResponse> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.recordPayment,
      roles: STAFF,
      validate: (d) => {
        requireRequestId(d);
        requireDocId(d, 'stayId');
      },
      rateLimit: { key: 'stays_payment', windowSeconds: 60, perFacility: 60, perUser: 20 },
    },
    deps,
  );
  const requestId = requireRequestId(ctx.data);
  const stayId = requireDocId(ctx.data, 'stayId');
  const payment = parsePayment(
    { method: ctx.data.method, amountCents: ctx.data.amountCents, receivedDate: ctx.data.receivedDate },
    'payment',
    true,
  );
  const memo = validated(() => validateText(ctx.data.memo ?? '', 'memo', { max: 500 }));
  if (ctx.role === 'employee') {
    assertEmployeeSetting(ctx, 'employeesCanRecordCash');
    if (payment.amountCents < 0) {
      throw staysError('permission-denied', 'role_not_allowed', 'Only an owner or manager can record a refund.', { role: ctx.role });
    }
  }
  const tz = confirmedTimeZone(ctx.controls);
  const today = facilityToday(tz, ctx.nowMs);
  assertReceivedDate(payment.receivedDate, today, 'receivedDate');
  const entryId = incomeIdManual(requestId);

  const result = await recordWithRetry(ctx, async () => {
    const [staySnap, folioSnap, incomeSnap] = await ctx.db.getAll(
      stayRef(ctx.db, ctx.facilityId, stayId),
      folioRef(ctx.db, ctx.facilityId, stayId),
      incomeRef(ctx.db, ctx.facilityId, entryId),
    );
    if (!staySnap.exists) throw staysError('not-found', 'not_found', 'That booking was not found.', { stayId });
    const stay = staySnap.data() as StayDoc;
    const folio = folioSnap.exists ? (folioSnap.data() as StayFolioDoc) : null;
    if (incomeSnap.exists) {
      return { created: false, paymentStatus: stay.paymentStatus, folio };
    }
    if (stay.kind !== 'reservation') throw invalid('stayId', 'Blocks have no payments.');
    if (payment.amountCents < 0 && (!folio || -payment.amountCents > folio.paidCents)) {
      throw invalid('amountCents', 'A refund cannot be more than has been paid on this booking.');
    }
    const now = Timestamp.fromMillis(ctx.nowMs);
    const income = manualIncomeDoc({
      facilityId: ctx.facilityId,
      stayId,
      stay,
      folioBefore: folio,
      payment,
      requestId,
      memo,
      receivedAt: receivedAtFor(payment.receivedDate, today, tz, ctx.nowMs),
      actor: ctx.uid,
      now,
    });
    const nextFolio = folio ? { ...applyPayment(folio, payment.amountCents), updatedAt: now } : null;
    const refunded = payment.amountCents < 0 && !!nextFolio && nextFolio.paidCents <= 0;
    const paymentStatus = isOtaSource(stay.source) ? stay.paymentStatus : paymentStatusOf(nextFolio, stay, { refunded });
    const version = Number.isInteger(stay.version) ? stay.version : 0;
    await applyStayMutations({
      db: ctx.db,
      facilityId: ctx.facilityId,
      controls: ctx.controls,
      nowMs: ctx.nowMs,
      actor: ctx.uid,
      mutations: [
        {
          stayId,
          // A payment bumps the version, so an edit opened before it is re-read, not saved over it.
          next: { ...stay, paymentStatus, version: version + 1, updatedAt: now, updatedBy: ctx.uid },
          expectedVersion: version,
          mode: 'sfc',
        },
      ],
      extraReads: [incomeRef(ctx.db, ctx.facilityId, entryId), folioRef(ctx.db, ctx.facilityId, stayId)],
      extraWrites: (tx, snaps) => {
        if (snaps[0].exists) throw new AlreadyRecorded();
        const current = snaps[1].exists ? (snaps[1].data() as StayFolioDoc) : null;
        if (!sameMoney(current, folio)) throw new RetryWrite();
        tx.create(incomeRef(ctx.db, ctx.facilityId, entryId), income);
        if (nextFolio) tx.set(folioRef(ctx.db, ctx.facilityId, stayId), nextFolio);
      },
    });
    return { created: true, paymentStatus, folio: nextFolio, income };
  });

  if (result.created) {
    await auditStays(ctx, {
      eventType: 'stays.income.created',
      targetType: 'stayIncome',
      targetId: entryId,
      metadata: {
        stayId,
        kind: payment.amountCents < 0 ? 'refund_given' : 'stay_payment',
        method: payment.method,
        amountCents: payment.amountCents,
      },
    });
  }
  return {
    entryId,
    created: result.created,
    paymentStatus: result.paymentStatus,
    folio: result.folio ? toWire(result.folio) : null,
  };
}

/**
 * Runs a money write, starting again from fresh reads when the stay or its
 * folio moved in between (another payment, an edit), up to three times. A
 * row that already exists is not an error: that request was recorded.
 */
async function recordWithRetry<T>(ctx: StaysCallContext, attempt: () => Promise<T>): Promise<T> {
  for (let i = 0; ; i++) {
    try {
      return await attempt();
    } catch (error) {
      const retryable = error instanceof RetryWrite || error instanceof AlreadyRecorded || staysErrorReason(error) === 'version_mismatch';
      if (!retryable || i >= 2) {
        if (error instanceof RetryWrite || error instanceof AlreadyRecorded) {
          throw staysError('aborted', 'contention', 'This booking is being changed right now. Try again.');
        }
        throw error;
      }
      functions.logger.info('stays: money write re-read after a concurrent change', { facilityId: ctx.facilityId });
    }
  }
}

export const staysRecordPayment = staysCallable(STAYS_CALLABLES.recordPayment, (data, context) => handleRecordPayment(data, context));

// ---------------------------------------------------------------------------
// staysVoidIncome
// ---------------------------------------------------------------------------

/**
 * What folio.airbnb is made of: the stay's posted Airbnb CSV rows that count
 * as income, summed. Voiding one recomputes it from the rows left; with none
 * left it is cleared (or kept, when it only holds the Reservations CSV's
 * expected figure).
 */
export function airbnbFolioFrom(rows: StayIncomeDoc[], existing: StayFolioAirbnb | null): StayFolioAirbnb | null {
  const counted = rows.filter((r) => r.source === 'airbnb_csv' && r.status === 'posted' && r.countsAsIncome === true);
  if (counted.length === 0) return existing?.expectedOnly === true ? existing : null;
  const sum = (pick: (r: StayIncomeDoc) => number) => counted.reduce((total, r) => total + (Number.isInteger(pick(r)) ? pick(r) : 0), 0);
  return {
    grossCents: sum((r) => r.grossCents),
    hostFeeCents: sum((r) => r.channelFeeCents),
    cleaningFeeCents: sum((r) => r.cleaningFeeCents),
    taxRemittedCents: sum((r) => r.taxRemittedByChannelCents),
    netCents: sum((r) => r.netCents),
    rowCount: counted.length,
  };
}

export async function handleVoidIncome(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysVoidIncomeResponse> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.voidIncome,
      roles: OWNER_OR_MANAGER,
      validate: (d) => void requireDocId(d, 'entryId'),
      rateLimit: { key: 'stays_void', windowSeconds: 60, perFacility: 30 },
    },
    deps,
  );
  const entryId = requireDocId(ctx.data, 'entryId');
  const reason = validated(() => validateText(ctx.data.reason, 'reason', { min: 1, max: 500 }));
  const ref = incomeRef(ctx.db, ctx.facilityId, entryId);

  const result = await recordWithRetry(ctx, async () => {
    const incomeSnap = await ref.get();
    if (!incomeSnap.exists) throw staysError('not-found', 'not_found', 'That payment was not found.', { entryId });
    const income = incomeSnap.data() as StayIncomeDoc;
    if (income.status !== 'posted') throw invalid('entryId', 'That payment is already voided.');
    if (income.source !== 'manual' && income.source !== 'airbnb_csv') {
      throw invalid('entryId', 'Only payments recorded by hand or imported from Airbnb can be voided here.');
    }
    const now = Timestamp.fromMillis(ctx.nowMs);
    const voided = { status: 'voided', voidedAt: now, voidedBy: ctx.uid, voidReason: reason };
    const stayId = income.stayId;

    // A hand-recorded payment moves the folio and the stay's payment chip.
    if (income.source === 'manual' && stayId) {
      const [staySnap, folioSnap] = await ctx.db.getAll(stayRef(ctx.db, ctx.facilityId, stayId), folioRef(ctx.db, ctx.facilityId, stayId));
      const folio = folioSnap.exists ? (folioSnap.data() as StayFolioDoc) : null;
      if (!staySnap.exists) {
        await ctx.db.runTransaction(async (tx) => {
          const again = await tx.get(ref);
          if (again.get('status') !== 'posted') throw invalid('entryId', 'That payment is already voided.');
          tx.update(ref, voided);
        });
        return { stayId, folio: null };
      }
      const stay = staySnap.data() as StayDoc;
      const nextFolio = folio ? { ...applyPayment(folio, -income.grossCents), updatedAt: now } : null;
      const refunded = stay.paymentStatus === 'refunded' && !!nextFolio && nextFolio.paidCents <= 0;
      const paymentStatus = isOtaSource(stay.source) ? stay.paymentStatus : paymentStatusOf(nextFolio, stay, { refunded });
      const version = Number.isInteger(stay.version) ? stay.version : 0;
      await applyStayMutations({
        db: ctx.db,
        facilityId: ctx.facilityId,
        controls: ctx.controls,
        nowMs: ctx.nowMs,
        actor: ctx.uid,
        mutations: [
          {
            stayId,
            next: { ...stay, paymentStatus, version: version + 1, updatedAt: now, updatedBy: ctx.uid },
            expectedVersion: version,
            mode: 'sfc',
          },
        ],
        extraReads: [ref, folioRef(ctx.db, ctx.facilityId, stayId)],
        extraWrites: (tx, snaps) => {
          if (snaps[0].get('status') !== 'posted') throw invalid('entryId', 'That payment is already voided.');
          const current = snaps[1].exists ? (snaps[1].data() as StayFolioDoc) : null;
          if (!sameMoney(current, folio)) throw new RetryWrite();
          tx.update(ref, voided);
          if (nextFolio) tx.set(folioRef(ctx.db, ctx.facilityId, stayId), nextFolio);
        },
      });
      return { stayId, folio: nextFolio };
    }

    // An Airbnb CSV row: the stay stays channel-collected; folio.airbnb is recomputed from the rows left.
    const folio = await ctx.db.runTransaction(async (tx) => {
      const again = await tx.get(ref);
      if (again.get('status') !== 'posted') throw invalid('entryId', 'That payment is already voided.');
      let nextFolio: StayFolioDoc | null = null;
      if (stayId) {
        const fRef = folioRef(ctx.db, ctx.facilityId, stayId);
        const [folioSnap, rows] = await Promise.all([
          tx.get(fRef),
          tx.get(facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.income).where('stayId', '==', stayId).where('status', '==', 'posted')),
        ]);
        if (folioSnap.exists) {
          const current = folioSnap.data() as StayFolioDoc;
          const remaining = rows.docs.filter((d) => d.id !== entryId).map((d) => d.data() as StayIncomeDoc);
          nextFolio = { ...current, airbnb: airbnbFolioFrom(remaining, current.airbnb ?? null), updatedAt: now };
        }
        tx.update(ref, voided);
        if (nextFolio) tx.set(fRef, nextFolio);
      } else {
        tx.update(ref, voided);
      }
      return nextFolio;
    });
    return { stayId, folio };
  });

  await auditStays(ctx, {
    eventType: 'stays.income.voided',
    targetType: 'stayIncome',
    targetId: entryId,
    metadata: { stayId: result.stayId ?? null },
  });
  return { entryId, status: 'voided', folio: result.folio ? toWire(result.folio) : null };
}

export const staysVoidIncome = staysCallable(STAYS_CALLABLES.voidIncome, (data, context) => handleVoidIncome(data, context));
