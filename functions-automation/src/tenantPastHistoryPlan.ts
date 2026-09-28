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
  PastHistoryRequest,
  computeHistoryOutcome,
  decidePaidThrough,
  formatDay,
  historyInstant,
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
  collection: 'ledgers' | 'payments' | 'tenants' | 'auditLogs' | 'tenantPastHistory';
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
  existingLedger: ReadonlyArray<LedgerRow>;
  existingBatch: Record<string, unknown> | null;
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
    const stored = (existingBatch.result || {}) as RecordResult;
    return { result: { ...stored, alreadyApplied: true }, writes: [] };
  }

  const clash = monthsAlreadyCharged(existingLedger, request.charges);
  if (clash.length > 0) {
    throw new PastHistoryRefusal(
      'already-exists',
      `Rent is already on the ledger for ${clash.map((m) => monthLabel(m.year, m.month)).join(', ')}. ` +
        'Untick those months and save again.',
    );
  }

  const outcome: HistoryOutcome = computeHistoryOutcome({
    existing: existingLedger,
    charges: request.charges,
    payments: request.payments,
  });
  const previousPaidThrough = toDate(tenant.paidThrough);
  const decision = decidePaidThrough(previousPaidThrough, outcome.computedPaidThrough);
  const warnings: string[] = [];
  if (decision.warning) warnings.push(decision.warning);
  const resultingPaidThrough = decision.write ?? previousPaidThrough;

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
          ...(p.reference ? { reference: p.reference } : {}),
          source: PAST_HISTORY_SOURCE,
          historyRequestId: requestId,
        },
      },
    });
  }

  if (decision.write) {
    writes.push({
      collection: 'tenants',
      id: tenantId,
      kind: 'update',
      data: { paidThrough: decision.write, updatedAt: serverTime },
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
    paidThroughChanged: decision.write !== null,
    credit: outcome.unappliedCredit,
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
      previousPaidThrough: previousPaidThrough ?? null,
      newPaidThrough: decision.write ?? null,
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
        newPaidThrough: isoDay(decision.write),
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

  const warnings: string[] = [];
  const setTo = toDate(batch.newPaidThrough);
  const before = toDate(batch.previousPaidThrough);
  const current = toDate(tenant.paidThrough);
  let paidThroughRestored = false;
  let resulting = current;
  if (setTo) {
    if (current && current.getTime() === setTo.getTime()) {
      writes.push({
        collection: 'tenants',
        id: tenantId,
        kind: 'update',
        data: { paidThrough: before ?? null, updatedAt: serverTime },
      });
      paidThroughRestored = true;
      resulting = before;
    } else {
      warnings.push(
        `Paid through has changed since this history was entered (now ${current ? formatDay(current) : 'not set'}), ` +
          'so it was left as it is. Check it on the tenant\'s page.',
      );
    }
  }

  const result: UndoResult = {
    requestId,
    alreadyUndone: false,
    entriesVoided,
    paymentsVoided,
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
      metadata: { requestId, entriesVoided, paymentsVoided, paidThroughRestored },
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
