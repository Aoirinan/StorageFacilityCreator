/**
 * What recordTenantPastHistory and undoTenantPastHistory write, worked out
 * from what they read, with no Firestore in it. The callables
 * (tenantPastHistoryCallable.ts) read inside a transaction, ask for a plan,
 * and apply its writes in the same transaction, so every rule here (who may
 * call, idempotency, refusing a month already charged, paidThrough only
 * moving later, undo restoring it) is tested without an emulator.
 */

import { isFacilityOwnerOrManager } from '@sfc/functions-shared';
import {
  HistoryOutcome,
  LedgerRow,
  PAST_HISTORY_SOURCE,
  PaidThroughChoice,
  PastHistoryRequest,
  computeHistoryOutcome,
  decidePaidThrough,
  formatDay,
  historyInstant,
  historyPayloadHash,
  historyPaymentDescription,
  historyRentDescription,
  monthLabel,
  monthsAlreadyCharged,
} from './tenantPastHistory';

/** A refusal the callable reports with this code and message. */
export class PastHistoryRefusal extends Error {
  constructor(
    readonly code: 'permission-denied' | 'not-found' | 'already-exists' | 'failed-precondition' | 'invalid-argument',
    message: string,
  ) {
    super(message);
  }
}

export interface Caller {
  uid: string;
  email: string | null;
  /** The superadmin custom claim, as the rules read it. */
  superAdmin: boolean;
}

/**
 * Owner, manager (or its legacy alias admin) or super admin: the same set
 * the rules let void ledger entries and edit payments. Employees and viewers
 * may not rewrite a tenant's history.
 */
export function mayEditTenantHistory(facility: Record<string, unknown> | null, caller: Caller): boolean {
  if (caller.superAdmin) return true;
  if (!facility) return false;
  return isFacilityOwnerOrManager(facility, caller.uid);
}

export interface PlannedWrite {
  /** Path relative to facilities/{facilityId}. */
  /** `tenantPayments` is tenants/{tenantId}/payments, the tenant's payment rows. */
  collection: 'ledgers' | 'payments' | 'tenants' | 'auditLogs' | 'tenantPastHistory' | 'tenantPayments';
  id: string;
  kind: 'set' | 'update';
  data: Record<string, unknown>;
}

export interface RecordResult {
  requestId: string;
  alreadyApplied: boolean;
  chargesPosted: number;
  paymentsPosted: number;
  totalCharges: number;
  totalPayments: number;
  balance: number;
  /** YYYY-MM-DD of the tenant's paidThrough after saving, or null. */
  paidThrough: string | null;
  paidThroughChanged: boolean;
  credit: number;
  /** Entries already on the ledger this save voided. */
  existingVoided: number;
  moveInDateSaved: boolean;
  /** paidThrough before the save (YYYY-MM-DD), for the owner to compare. */
  paidThroughBefore: string | null;
  /** Leftover credit paid ahead that buys whole months (see prepaidMonths). */
  prepaidMonths: number;
  /**
   * Invoices the voided entries were on. Left as they are: the owner voids
   * them, or they keep showing as unpaid.
   */
  invoicesToReview: Array<{ id: string; number: string | null }>;
  warnings: string[];
}

export interface RecordPlan {
  result: RecordResult;
  writes: PlannedWrite[];
}

function isoDay(d: Date | null): string | null {
  if (!d) return null;
  const mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(d.getUTCDate()).padStart(2, '0');
  return `${d.getUTCFullYear()}-${mm}-${dd}`;
}

function toDate(v: unknown): Date | null {
  if (!v) return null;
  if (v instanceof Date) return v;
  const t = v as { toDate?: () => Date };
  return typeof t.toDate === 'function' ? t.toDate() : null;
}

/**
 * The plan for recording `request`, given what the transaction read.
 *
 * `newId` hands out document ids (Firestore's in the callable, a counter in
 * tests); `serverTime` is what "now" is stored as (serverTimestamp() in the
 * callable).
 */
export function planRecordPastHistory(input: {
  request: PastHistoryRequest;
  caller: Caller;
  facility: Record<string, unknown> | null;
  tenant: Record<string, unknown> | null;
  /** The tenant's ledger, each row with its doc id. */
  existingLedger: ReadonlyArray<LedgerRow>;
  existingBatch: Record<string, unknown> | null;
  /**
   * Payment docs behind the entries being voided (their metadata.paymentId),
   * so a payment recorded through the app is voided with its ledger line.
   */
  linkedPayments?: ReadonlyArray<{ id: string; data: Record<string, unknown> | null }>;
  /**
   * The tenant's own payment rows (tenants/{id}/payments, type manual): the
   * copy Record payment writes for the billing panel, voided with its
   * payment.
   */
  tenantPaymentRows?: ReadonlyArray<{ id: string; data: Record<string, unknown> | null }>;
  /** Invoice docs named by the voided entries' metadata.invoiceId. */
  invoices?: ReadonlyArray<{ id: string; data: Record<string, unknown> | null }>;
  newId: () => string;
  serverTime: unknown;
}): RecordPlan {
  const { request, caller, facility, tenant, existingLedger, existingBatch, newId, serverTime } = input;

  if (!facility) throw new PastHistoryRefusal('not-found', 'Facility not found');
  if (!mayEditTenantHistory(facility, caller)) {
    throw new PastHistoryRefusal(
      'permission-denied',
      'Only the facility owner or a manager can enter past history',
    );
  }
  if (!tenant) throw new PastHistoryRefusal('not-found', 'Tenant not found');

  // A second press (or a retry after a dropped connection) sends the same
  // requestId: hand back what the first one saved instead of saving again.
  if (existingBatch) {
    if (existingBatch.tenantId !== request.tenantId) {
      throw new PastHistoryRefusal('already-exists', 'This history entry id was already used for another tenant');
    }
    if (existingBatch.status === 'voided') {
      throw new PastHistoryRefusal(
        'failed-precondition',
        'This history entry was undone. Start a new one to enter it again.',
      );
    }
    if (typeof existingBatch.payloadHash === 'string' && existingBatch.payloadHash !== historyPayloadHash(request)) {
      throw new PastHistoryRefusal(
        'already-exists',
        'This history entry was already saved with different details. Close Enter past history, check the Ledger, ' +
          'and use Undo this history entry there if it is wrong before entering it again.',
      );
    }
    const stored = (existingBatch.result || {}) as RecordResult;
    return { result: { ...stored, alreadyApplied: true }, writes: [] };
  }

  // Entries already on the ledger the owner chose to replace. Each must be
  // this tenant's, still posted, and not from another history entry (that
  // one has its own undo).
  const byId = new Map<string, LedgerRow>();
  for (const row of existingLedger) if (row.id) byId.set(row.id, row);
  const toVoid: LedgerRow[] = [];
  for (const id of request.voidLedgerEntryIds) {
    const row = byId.get(id);
    if (!row || row.tenantId !== request.tenantId) {
      throw new PastHistoryRefusal('invalid-argument', 'An entry to void is not on this tenant\'s ledger. Reload and try again.');
    }
    if (row.status !== 'posted') {
      throw new PastHistoryRefusal('failed-precondition', 'An entry to void is already voided. Reload and try again.');
    }
    const meta = (row.metadata || {}) as Record<string, unknown>;
    if (meta.source === PAST_HISTORY_SOURCE || (row as Record<string, unknown>).source === PAST_HISTORY_SOURCE) {
      throw new PastHistoryRefusal(
        'failed-precondition',
        'An entry to void came from another past-history entry. Use "Undo this history entry" on the Ledger for that one.',
      );
    }
    toVoid.push(row);
  }
  const voiding = new Set(request.voidLedgerEntryIds);
  const keptLedger = existingLedger.filter((row) => !(row.id && voiding.has(row.id)));

  const clash = monthsAlreadyCharged(keptLedger, request.charges);
  if (clash.length > 0) {
    throw new PastHistoryRefusal(
      'already-exists',
      `Rent is already on the ledger for ${clash.map((m) => monthLabel(m.year, m.month)).join(', ')}. ` +
        'Untick those months and save again.',
    );
  }

  const monthlyRate = typeof tenant.monthlyRate === 'number' && Number.isFinite(tenant.monthlyRate) ? tenant.monthlyRate : 0;
  const outcome: HistoryOutcome = computeHistoryOutcome({
    existing: keptLedger,
    charges: request.charges,
    payments: request.payments,
    freeMonths: request.freeMonths,
    monthlyRate,
  });
  const previousPaidThrough = toDate(tenant.paidThrough);
  // Voiding payments that had pushed paidThrough forward means the later
  // date is no longer paid for: recompute unless the owner chose to keep it.
  const voidsPayment = toVoid.some((row) => typeof row.amount === 'number' && row.amount < 0);
  const choice: PaidThroughChoice = request.paidThroughChoice ?? (voidsPayment ? 'computed' : 'keepLater');
  const decision = decidePaidThrough(previousPaidThrough, outcome.computedPaidThrough, choice);
  const warnings: string[] = [];
  if (decision.warning) warnings.push(decision.warning);
  const resultingPaidThrough = decision.value;

  const { facilityId, tenantId, requestId } = request;
  const writes: PlannedWrite[] = [];
  const ledgerEntryIds: string[] = [];
  const paymentIds: string[] = [];

  const common = {
    tenantId,
    facilityId,
    status: 'posted',
    createdAt: serverTime,
    createdBy: caller.uid,
    source: PAST_HISTORY_SOURCE,
    historyRequestId: requestId,
  };

  for (const c of request.charges) {
    const at = historyInstant({ year: c.year, month: c.month, day: c.day });
    const id = newId();
    ledgerEntryIds.push(id);
    writes.push({
      collection: 'ledgers',
      id,
      kind: 'set',
      data: {
        ...common,
        type: 'rentCharge',
        amount: c.amount,
        description: historyRentDescription(c.year, c.month),
        entryDate: at,
        dueDate: at,
        // The scheduled job's own metadata, so neither it nor the app's
        // generator raises this month again.
        metadata: {
          recurringCharge: true,
          chargeType: 'monthlyRent',
          month: c.month,
          year: c.year,
          generatedAt: serverTime,
          source: PAST_HISTORY_SOURCE,
          historyRequestId: requestId,
        },
      },
    });
  }

  const tenantName = typeof tenant.name === 'string' ? tenant.name.trim() : '';
  const unitNumber = typeof tenant.unitNumber === 'string' ? tenant.unitNumber.trim() : '';
  const contractId = typeof tenant.contractId === 'string' ? tenant.contractId : '';

  for (const p of request.payments) {
    const at = historyInstant(p.date);
    const paymentId = newId();
    const ledgerId = newId();
    paymentIds.push(paymentId);
    ledgerEntryIds.push(ledgerId);
    writes.push({
      collection: 'payments',
      id: paymentId,
      kind: 'set',
      data: {
        tenantId,
        facilityId,
        contractId,
        ...(tenantName ? { tenantName } : {}),
        ...(unitNumber ? { unitNumber } : {}),
        amount: p.amount,
        status: 'completed',
        method: p.method,
        ...(p.reference ? { reference: p.reference } : {}),
        ...(p.note ? { notes: p.note } : {}),
        ...(p.monthOnly ? { dateIsMonthOnly: true } : {}),
        paidAt: at,
        paidDate: at,
        dueDate: at,
        createdAt: serverTime,
        updatedAt: serverTime,
        createdBy: caller.uid,
        isActive: true,
        source: PAST_HISTORY_SOURCE,
        historyRequestId: requestId,
      },
    });
    writes.push({
      collection: 'ledgers',
      id: ledgerId,
      kind: 'set',
      data: {
        ...common,
        type: 'payment',
        amount: -p.amount,
        description: historyPaymentDescription(p),
        referenceId: paymentId,
        entryDate: at,
        metadata: {
          paymentMethod: p.method,
          paymentId,
          ...(p.monthOnly ? { dateIsMonthOnly: true } : {}),
          ...(p.reference ? { reference: p.reference } : {}),
          source: PAST_HISTORY_SOURCE,
          historyRequestId: requestId,
        },
      },
    });
  }

  // The hand-entered entries this history replaces, tagged so Undo can put
  // them back.
  for (const row of toVoid) {
    writes.push({
      collection: 'ledgers',
      id: row.id!,
      kind: 'update',
      data: {
        status: 'voided',
        voidedAt: serverTime,
        voidedBy: caller.uid,
        metadata: {
          ...((row.metadata as Record<string, unknown>) || {}),
          voidReason: 'Replaced by past history',
          voidedByHistoryRequestId: requestId,
        },
      },
    });
  }
  const voidedExistingPayments: Array<{ id: string; status: unknown; isActive: unknown }> = [];
  const linkedIds = new Set(
    toVoid
      .map((row) => (row.metadata as Record<string, unknown> | undefined)?.paymentId)
      .filter((v): v is string => typeof v === 'string' && v !== ''),
  );
  for (const pay of input.linkedPayments ?? []) {
    if (!linkedIds.has(pay.id) || !pay.data) continue;
    if (pay.data.tenantId !== tenantId || pay.data.status === 'voided') continue;
    voidedExistingPayments.push({ id: pay.id, status: pay.data.status ?? null, isActive: pay.data.isActive ?? null });
    writes.push({
      collection: 'payments',
      id: pay.id,
      kind: 'update',
      data: {
        status: 'voided',
        isActive: false,
        voidedAt: serverTime,
        voidedBy: caller.uid,
        voidedByHistoryRequestId: requestId,
        updatedAt: serverTime,
      },
    });
  }

  // The tenant's own copy of each voided payment (the billing panel's
  // Payment history). Linked by facilityPaymentId when Record payment wrote
  // it; older rows have no link, so an unlinked row of the same amount
  // recorded within ten minutes is taken as its copy, the closest in time
  // first, each row claimed by one payment at most.
  const voidedTenantPayments: Array<{ id: string; status: unknown }> = [];
  const rows = [...(input.tenantPaymentRows ?? [])].filter(
    (r) => r.data && r.data.type === 'manual' && r.data.status !== 'voided',
  );
  const voidedPays = (input.linkedPayments ?? []).filter(
    (pay) => pay.data && voidedExistingPayments.some((v) => v.id === pay.id),
  );
  const matched = new Map<string, string>(); // payment id -> row id
  const claimed = new Set<string>();
  for (const pay of voidedPays) {
    const row = rows.find((r) => r.data!.facilityPaymentId === pay.id);
    if (row && !claimed.has(row.id)) {
      matched.set(pay.id, row.id);
      claimed.add(row.id);
    }
  }
  const WINDOW_MS = 10 * 60 * 1000;
  const pairs: Array<{ payId: string; rowId: string; gap: number }> = [];
  for (const pay of voidedPays) {
    if (matched.has(pay.id)) continue;
    const cents = Math.round(Number(pay.data!.amount ?? 0) * 100);
    const at = toDate(pay.data!.createdAt)?.getTime() ?? null;
    if (at === null) continue;
    for (const r of rows) {
      if (claimed.has(r.id) || r.data!.facilityPaymentId || r.data!.amountCents !== cents) continue;
      const rowAt = toDate(r.data!.createdAt)?.getTime() ?? null;
      if (rowAt === null) continue;
      const gap = Math.abs(rowAt - at);
      if (gap <= WINDOW_MS) pairs.push({ payId: pay.id, rowId: r.id, gap });
    }
  }
  pairs.sort((a, b) => a.gap - b.gap);
  for (const pair of pairs) {
    if (matched.has(pair.payId) || claimed.has(pair.rowId)) continue;
    matched.set(pair.payId, pair.rowId);
    claimed.add(pair.rowId);
  }
  for (const pay of voidedPays) {
    const rowId = matched.get(pay.id);
    if (!rowId) {
      const amount = Number(pay.data!.amount ?? 0);
      const at = toDate(pay.data!.paidAt) ?? toDate(pay.data!.createdAt);
      warnings.push(
        `Couldn't find the matching Payment History row for $${amount.toFixed(2)}` +
          `${at ? ` on ${formatDay(at)}` : ''}; it may still show there.`,
      );
      continue;
    }
    const row = rows.find((r) => r.id === rowId)!;
    voidedTenantPayments.push({ id: row.id, status: row.data!.status ?? null });
    writes.push({
      collection: 'tenantPayments',
      id: row.id,
      kind: 'update',
      data: { status: 'voided', voidedAt: serverTime, voidedBy: caller.uid, voidedByHistoryRequestId: requestId, updatedAt: serverTime },
    });
  }

  // Invoices the voided entries were on, for the owner to void by hand.
  const invoiceIds = [
    ...new Set(
      toVoid
        .map((row) => (row.metadata as Record<string, unknown> | undefined)?.invoiceId)
        .filter((v): v is string => typeof v === 'string' && v !== ''),
    ),
  ];
  const invoicesToReview = invoiceIds.map((id) => {
    const doc = (input.invoices ?? []).find((i) => i.id === id)?.data;
    const number = doc && typeof doc.invoiceNumber === 'string' ? doc.invoiceNumber : null;
    return { id, number };
  });
  if (invoicesToReview.length > 0) {
    warnings.push(
      `These entries were on invoice(s) ${invoicesToReview.map((i) => i.number ?? i.id).join(', ')}; ` +
        "open Invoices and void them so they don't show as unpaid.",
    );
  }

  // The move-in date the owner gave, kept on the tenant when it has none.
  const previousMoveIn = toDate(tenant.moveInDate);
  const moveInToSet = request.moveInDate && !previousMoveIn ? historyInstant(request.moveInDate) : null;

  if (decision.change || moveInToSet) {
    writes.push({
      collection: 'tenants',
      id: tenantId,
      kind: 'update',
      data: {
        ...(decision.change ? { paidThrough: decision.value } : {}),
        ...(moveInToSet ? { moveInDate: moveInToSet } : {}),
        updatedAt: serverTime,
      },
    });
  }

  const result: RecordResult = {
    requestId,
    alreadyApplied: false,
    chargesPosted: request.charges.length,
    paymentsPosted: request.payments.length,
    totalCharges: outcome.totalCharges,
    totalPayments: outcome.totalPayments,
    balance: outcome.balance,
    paidThrough: isoDay(resultingPaidThrough),
    paidThroughChanged: decision.change,
    paidThroughBefore: isoDay(previousPaidThrough),
    prepaidMonths: outcome.prepaidMonths,
    invoicesToReview,
    credit: outcome.unappliedCredit,
    existingVoided: toVoid.length,
    moveInDateSaved: moveInToSet !== null,
    warnings,
  };

  writes.push({
    collection: 'tenantPastHistory',
    id: requestId,
    kind: 'set',
    data: {
      facilityId,
      tenantId,
      requestId,
      status: 'applied',
      ledgerEntryIds,
      paymentIds,
      payloadHash: historyPayloadHash(request),
      previousPaidThrough: previousPaidThrough ?? null,
      paidThroughChanged: decision.change,
      newPaidThrough: decision.change ? decision.value : null,
      voidedTenantPayments,
      voidedExistingLedgerIds: toVoid.map((row) => row.id!),
      voidedExistingPayments,
      moveInDateSet: moveInToSet,
      result,
      createdAt: serverTime,
      createdBy: caller.uid,
    },
  });

  writes.push({
    collection: 'auditLogs',
    id: newId(),
    kind: 'set',
    data: {
      eventType: 'tenant.pastHistory.recorded',
      actorUid: caller.uid,
      ...(caller.email ? { actorEmail: caller.email } : {}),
      facilityId,
      targetType: 'tenant',
      targetId: tenantId,
      tenantId,
      timestamp: serverTime,
      metadata: {
        requestId,
        charges: request.charges.length,
        payments: request.payments.length,
        totalCharges: outcome.totalCharges,
        totalPayments: outcome.totalPayments,
        previousPaidThrough: isoDay(previousPaidThrough),
        newPaidThrough: decision.change ? isoDay(decision.value) : isoDay(previousPaidThrough),
        paidThroughChoice: choice,
        existingVoided: toVoid.map((row) => row.id!),
        moveInDateSet: isoDay(moveInToSet),
      },
    },
  });

  return { result, writes };
}

export interface UndoResult {
  requestId: string;
  alreadyUndone: boolean;
  entriesVoided: number;
  paymentsVoided: number;
  /** Hand-entered entries the history had replaced, posted again. */
  entriesRestored: number;
  paidThrough: string | null;
  paidThroughRestored: boolean;
  warnings: string[];
}

/**
 * The plan for undoing history entry `requestId`: every ledger entry it
 * posted voided, every payment doc marked voided, and paidThrough put back
 * to what it was before, unless something moved it since (a payment taken
 * after the history was entered), in which case it is left and the owner
 * told.
 */
export function planUndoPastHistory(input: {
  facilityId: string;
  tenantId: string;
  requestId: string;
  caller: Caller;
  facility: Record<string, unknown> | null;
  tenant: Record<string, unknown> | null;
  batch: Record<string, unknown> | null;
  ledgerEntries: ReadonlyArray<{ id: string; data: Record<string, unknown> | null }>;
  payments: ReadonlyArray<{ id: string; data: Record<string, unknown> | null }>;
  /** The entries (and their payment docs) the history voided, to restore. */
  replacedEntries?: ReadonlyArray<{ id: string; data: Record<string, unknown> | null }>;
  replacedPayments?: ReadonlyArray<{ id: string; data: Record<string, unknown> | null }>;
  replacedTenantPayments?: ReadonlyArray<{ id: string; data: Record<string, unknown> | null }>;
  newId: () => string;
  serverTime: unknown;
}): { result: UndoResult; writes: PlannedWrite[] } {
  const { facilityId, tenantId, requestId, caller, facility, tenant, batch, newId, serverTime } = input;
  if (!facility) throw new PastHistoryRefusal('not-found', 'Facility not found');
  if (!mayEditTenantHistory(facility, caller)) {
    throw new PastHistoryRefusal('permission-denied', 'Only the facility owner or a manager can undo past history');
  }
  if (!batch || batch.tenantId !== tenantId) {
    throw new PastHistoryRefusal('not-found', 'That history entry was not found for this tenant');
  }
  if (!tenant) throw new PastHistoryRefusal('not-found', 'Tenant not found');

  if (batch.status === 'voided') {
    const stored = (batch.undoResult || {}) as UndoResult;
    return { result: { ...stored, alreadyUndone: true }, writes: [] };
  }

  const writes: PlannedWrite[] = [];
  let entriesVoided = 0;
  for (const e of input.ledgerEntries) {
    if (!e.data || e.data.status === 'voided') continue;
    const metadata = { ...((e.data.metadata as Record<string, unknown>) || {}), voidReason: 'Past history undone' };
    writes.push({
      collection: 'ledgers',
      id: e.id,
      kind: 'update',
      data: { status: 'voided', voidedAt: serverTime, voidedBy: caller.uid, metadata },
    });
    entriesVoided += 1;
  }
  let paymentsVoided = 0;
  for (const p of input.payments) {
    if (!p.data || p.data.status === 'voided') continue;
    writes.push({
      collection: 'payments',
      id: p.id,
      kind: 'update',
      // isActive false takes it off the Payments list and out of reports,
      // as archiving does.
      data: { status: 'voided', isActive: false, voidedAt: serverTime, voidedBy: caller.uid, updatedAt: serverTime },
    });
    paymentsVoided += 1;
  }

  // Put back what the history replaced, if it is still voided by it.
  let entriesRestored = 0;
  for (const e of input.replacedEntries ?? []) {
    const meta = { ...((e.data?.metadata as Record<string, unknown>) || {}) };
    if (!e.data || e.data.status !== 'voided' || meta.voidedByHistoryRequestId !== requestId) continue;
    delete meta.voidReason;
    delete meta.voidedByHistoryRequestId;
    writes.push({
      collection: 'ledgers',
      id: e.id,
      kind: 'update',
      data: { status: 'posted', voidedAt: null, voidedBy: null, metadata: meta },
    });
    entriesRestored += 1;
  }
  const previousPayments = new Map<string, { status: unknown; isActive: unknown }>();
  for (const p of (batch.voidedExistingPayments as Array<{ id: string; status: unknown; isActive: unknown }>) || []) {
    previousPayments.set(p.id, p);
  }
  for (const p of input.replacedPayments ?? []) {
    const before = previousPayments.get(p.id);
    if (!before || !p.data || p.data.status !== 'voided' || p.data.voidedByHistoryRequestId !== requestId) continue;
    writes.push({
      collection: 'payments',
      id: p.id,
      kind: 'update',
      data: {
        status: before.status ?? 'completed',
        isActive: before.isActive ?? true,
        voidedAt: null,
        voidedBy: null,
        voidedByHistoryRequestId: null,
        updatedAt: serverTime,
      },
    });
  }

  const previousTenantRows = new Map<string, unknown>();
  for (const r of (batch.voidedTenantPayments as Array<{ id: string; status: unknown }>) || []) {
    previousTenantRows.set(r.id, r.status);
  }
  for (const r of input.replacedTenantPayments ?? []) {
    if (!previousTenantRows.has(r.id) || !r.data || r.data.status !== 'voided') continue;
    if (r.data.voidedByHistoryRequestId !== requestId) continue;
    writes.push({
      collection: 'tenantPayments',
      id: r.id,
      kind: 'update',
      data: {
        status: previousTenantRows.get(r.id) ?? 'succeeded',
        voidedAt: null,
        voidedBy: null,
        voidedByHistoryRequestId: null,
        updatedAt: serverTime,
      },
    });
  }

  const warnings: string[] = [];
  // Older batches (none in production) stored only a non-null newPaidThrough.
  const changed = batch.paidThroughChanged === true || (batch.paidThroughChanged === undefined && !!batch.newPaidThrough);
  const setTo = toDate(batch.newPaidThrough);
  const before = toDate(batch.previousPaidThrough);
  const current = toDate(tenant.paidThrough);
  let paidThroughRestored = false;
  let resulting = current;
  const tenantUpdate: Record<string, unknown> = {};
  // The move-in date it filled in comes off again, unless changed since.
  const moveInSet = toDate(batch.moveInDateSet);
  const moveInNow = toDate(tenant.moveInDate);
  if (moveInSet && moveInNow && moveInNow.getTime() === moveInSet.getTime()) {
    tenantUpdate.moveInDate = null;
  }
  if (changed) {
    // Exact match only: anything that moved paidThrough since is kept.
    const unchanged = setTo === null ? current === null : current !== null && current.getTime() === setTo.getTime();
    if (unchanged) {
      tenantUpdate.paidThrough = before ?? null;
      paidThroughRestored = true;
      resulting = before;
    } else {
      warnings.push(
        `Paid through has changed since this history was entered (now ${current ? formatDay(current) : 'not set'}), ` +
          'so it was left as it is. Check it on the tenant\'s page.',
      );
    }
  }

  if (Object.keys(tenantUpdate).length > 0) {
    writes.push({
      collection: 'tenants',
      id: tenantId,
      kind: 'update',
      data: { ...tenantUpdate, updatedAt: serverTime },
    });
  }

  const result: UndoResult = {
    requestId,
    alreadyUndone: false,
    entriesVoided,
    paymentsVoided,
    entriesRestored,
    paidThrough: isoDay(resulting),
    paidThroughRestored,
    warnings,
  };

  writes.push({
    collection: 'tenantPastHistory',
    id: requestId,
    kind: 'update',
    data: { status: 'voided', voidedAt: serverTime, voidedBy: caller.uid, undoResult: result },
  });
  writes.push({
    collection: 'auditLogs',
    id: newId(),
    kind: 'set',
    data: {
      eventType: 'tenant.pastHistory.undone',
      actorUid: caller.uid,
      ...(caller.email ? { actorEmail: caller.email } : {}),
      facilityId,
      targetType: 'tenant',
      targetId: tenantId,
      tenantId,
      timestamp: serverTime,
      metadata: { requestId, entriesVoided, paymentsVoided, entriesRestored, paidThroughRestored },
    },
  });

  return { result, writes };
}

/** For the callable's argument check on undo. */
export function parseUndoRequest(data: unknown): { facilityId: string; tenantId: string; requestId: string } {
  const d = (data ?? {}) as Record<string, unknown>;
  const read = (v: unknown, f: string) => {
    if (typeof v !== 'string' || v.trim() === '' || v.length > 200) {
      throw new PastHistoryRefusal('invalid-argument', `${f} is required`);
    }
    return v.trim();
  };
  const requestId = read(d.requestId, 'requestId');
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(requestId)) {
    throw new PastHistoryRefusal('invalid-argument', 'requestId is not valid');
  }
  return { facilityId: read(d.facilityId, 'facilityId'), tenantId: read(d.tenantId, 'tenantId'), requestId };
}
