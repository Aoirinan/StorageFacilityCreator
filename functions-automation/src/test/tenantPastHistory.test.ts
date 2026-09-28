import test from 'node:test';
import assert from 'node:assert/strict';
import {
  PastHistoryInputError,
  computeHistoryOutcome,
  decidePaidThrough,
  historyPaymentDescription,
  monthsAlreadyCharged,
  parsePastHistoryRequest,
} from '../tenantPastHistory';
import {
  Caller,
  PastHistoryRefusal,
  PlannedWrite,
  planRecordPastHistory,
  planUndoPastHistory,
} from '../tenantPastHistoryPlan';
import { hasRentChargeForMonth } from '../rentChargeHelpers';

// All names and ids are made up.
const NOW = new Date('2026-09-28T15:00:00Z');
const FACILITY_ID = 'fac-demo';
const TENANT_ID = 'tenant-demo';
const OWNER: Caller = { uid: 'owner-1', email: 'owner@example.com', superAdmin: false };

/** An in-memory facility: collection -> id -> data. */
type Store = Record<string, Record<string, Record<string, unknown>>>;

function newStore(tenant: Record<string, unknown> = {}): Store {
  return {
    facility: { [FACILITY_ID]: { ownerUid: OWNER.uid, roles: { [OWNER.uid]: 'owner', 'emp-1': 'employee', 'mgr-1': 'manager' } } },
    tenants: { [TENANT_ID]: { name: 'Pat Example', unitNumber: 'A1', monthlyRate: 80, ...tenant } },
    ledgers: {},
    payments: {},
    tenantPastHistory: {},
    auditLogs: {},
  };
}

function apply(store: Store, writes: PlannedWrite[]): void {
  for (const w of writes) {
    const col = (store[w.collection] ??= {});
    if (w.kind === 'set') col[w.id] = { ...w.data };
    else {
      assert.ok(col[w.id], `update of missing ${w.collection}/${w.id}`);
      col[w.id] = { ...col[w.id], ...w.data };
    }
  }
}

let idCounter = 0;
const newId = () => `id-${++idCounter}`;

function ledgerOf(store: Store): Array<Record<string, any> & { id: string }> {
  return Object.entries(store.ledgers)
    .filter(([, e]) => e.tenantId === TENANT_ID)
    .map(([id, e]) => ({ ...e, id }));
}

function balanceOf(store: Store): number {
  const sum = ledgerOf(store)
    .filter((e) => e.status === 'posted')
    .reduce((s, e) => s + (e.amount as number), 0);
  return Math.round(sum * 100) / 100;
}

function record(store: Store, data: Record<string, unknown>, caller: Caller = OWNER) {
  const request = parsePastHistoryRequest(
    { facilityId: FACILITY_ID, tenantId: TENANT_ID, requestId: 'req-00000001', ...data },
    NOW,
  );
  const plan = planRecordPastHistory({
    request,
    caller,
    facility: store.facility[FACILITY_ID] ?? null,
    tenant: store.tenants[TENANT_ID] ?? null,
    existingLedger: ledgerOf(store),
    existingBatch: store.tenantPastHistory[request.requestId] ?? null,
    linkedPayments: Object.entries(store.payments).map(([id, data]) => ({ id, data })),
    newId,
    serverTime: NOW,
  });
  apply(store, plan.writes);
  return plan;
}

function undo(store: Store, requestId = 'req-00000001', caller: Caller = OWNER) {
  const batch = store.tenantPastHistory[requestId] ?? null;
  const ids = (batch?.ledgerEntryIds as string[]) ?? [];
  const pids = (batch?.paymentIds as string[]) ?? [];
  const plan = planUndoPastHistory({
    facilityId: FACILITY_ID,
    tenantId: TENANT_ID,
    requestId,
    caller,
    facility: store.facility[FACILITY_ID] ?? null,
    tenant: store.tenants[TENANT_ID] ?? null,
    batch,
    ledgerEntries: ids.map((id) => ({ id, data: store.ledgers[id] ?? null })),
    payments: pids.map((id) => ({ id, data: store.payments[id] ?? null })),
    replacedEntries: ((batch?.voidedExistingLedgerIds as string[]) ?? []).map((id) => ({ id, data: store.ledgers[id] ?? null })),
    replacedPayments: ((batch?.voidedExistingPayments as Array<{ id: string }>) ?? []).map((p) => ({
      id: p.id,
      data: store.payments[p.id] ?? null,
    })),
    newId,
    serverTime: NOW,
  });
  apply(store, plan.writes);
  return plan;
}

/** February (from the move-in day, the 10th) through September at $80. */
function exampleCharges(skip: number[] = []) {
  const charges = [];
  for (let month = 2; month <= 9; month += 1) {
    if (skip.includes(month)) continue;
    charges.push({ year: 2026, month, day: month === 2 ? 10 : 1, amount: 80 });
  }
  return charges;
}

const venmo = (date: string, amount: number, reference?: string) => ({ date, amount, method: 'venmo', reference });

/** The owner's paper ledger: $80 on 2/10, 3/20, 4/19, 5/31, then $160 on 6/1. */
const examplePayments = [
  venmo('2026-02-10', 80),
  venmo('2026-03-20', 80),
  venmo('2026-04-19', 80),
  venmo('2026-05-31', 80),
  venmo('2026-06-01', 160),
];

test('the owner example: $640 of rent, $480 paid, $160 owed, paid through July 31', () => {
  const store = newStore();
  const { result } = record(store, { charges: exampleCharges(), payments: examplePayments });

  assert.equal(result.totalCharges, 640);
  assert.equal(result.totalPayments, 480);
  assert.equal(result.balance, 160);
  assert.equal(result.paidThrough, '2026-07-31');
  assert.equal(result.paidThroughChanged, true);
  assert.equal(result.credit, 0);
  assert.deepEqual(result.warnings, []);

  // What the Ledger screen will show: the sum of posted entries.
  assert.equal(balanceOf(store), 160);
  const paidThrough = store.tenants[TENANT_ID].paidThrough as Date;
  assert.equal(paidThrough.toISOString(), '2026-07-31T12:00:00.000Z');

  // Dated when they happened, not today.
  const feb = ledgerOf(store).find((e) => e.type === 'rentCharge' && (e.metadata as any).month === 2)!;
  assert.equal((feb.entryDate as Date).toISOString(), '2026-02-10T12:00:00.000Z');
  const mar = ledgerOf(store).find((e) => e.type === 'rentCharge' && (e.metadata as any).month === 3)!;
  assert.equal((mar.entryDate as Date).toISOString(), '2026-03-01T12:00:00.000Z');
  const payments = Object.values(store.payments);
  assert.equal(payments.length, 5);
  assert.ok(payments.every((p) => p.status === 'completed' && p.method === 'venmo' && p.source === 'past_history'));
  assert.equal(
    (payments.find((p) => p.amount === 160)!.paidDate as Date).toISOString(),
    '2026-06-01T12:00:00.000Z',
  );
  // No late fee, no delinquency change: only the rent, the payments and paidThrough.
  assert.ok(ledgerOf(store).every((e) => e.type === 'rentCharge' || e.type === 'payment'));
  assert.deepEqual(Object.keys(store.tenants[TENANT_ID]).filter((k) => !['name', 'unitNumber', 'monthlyRate'].includes(k)).sort(), [
    'paidThrough',
    'updatedAt',
  ]);
});

test('history rent charges carry the rent job metadata, so October 1 does not bill September again', () => {
  const store = newStore();
  record(store, { charges: exampleCharges(), payments: examplePayments });
  const entries = ledgerOf(store).map((e) => ({
    ...e,
    entryDate: { toDate: () => e.entryDate as Date },
  }));
  for (let month = 2; month <= 9; month += 1) {
    assert.equal(hasRentChargeForMonth(entries, month, 2026), true, `month ${month}`);
  }
  assert.equal(hasRentChargeForMonth(entries, 10, 2026), false);
});

test('an overpayment leaves a credit and pays through the last charged month', () => {
  const store = newStore();
  const { result } = record(store, {
    charges: exampleCharges().filter((c) => c.month <= 4), // Feb-Apr, $240
    payments: [venmo('2026-02-10', 300)],
  });
  assert.equal(result.balance, -60);
  assert.equal(result.credit, 60);
  assert.equal(result.paidThrough, '2026-04-30');
});

test('a partial payment is shown as credit toward the next month, not a paid month', () => {
  const outcome = computeHistoryOutcome({
    existing: [],
    charges: exampleCharges().filter((c) => c.month <= 3),
    payments: parsePastHistoryRequest(
      { facilityId: 'f', tenantId: 't', requestId: 'req-00000009', payments: [venmo('2026-02-10', 120)] },
      NOW,
    ).payments,
  });
  assert.equal(outcome.computedPaidThrough?.toISOString(), '2026-02-28T12:00:00.000Z');
  assert.equal(outcome.unappliedCredit, 40);
  assert.deepEqual(outcome.firstUnpaidMonth, { year: 2026, month: 3 });
});

test('an unticked (free) month is skipped: not charged, and does not hold paidThrough back', () => {
  const store = newStore();
  const { result } = record(store, {
    charges: exampleCharges([3]), // March free
    payments: examplePayments,
  });
  assert.equal(result.totalCharges, 560);
  assert.equal(result.balance, 80);
  // $480 covers Feb, Apr, May, Jun, Jul, Aug.
  assert.equal(result.paidThrough, '2026-08-31');
  assert.equal(
    ledgerOf(store).some((e) => e.type === 'rentCharge' && (e.metadata as any).month === 3),
    false,
  );
});

test('a month that already has a rent charge is refused, and nothing is written', () => {
  const store = newStore();
  store.ledgers['job-sept'] = {
    tenantId: TENANT_ID,
    type: 'rentCharge',
    status: 'posted',
    amount: 80,
    entryDate: new Date('2026-09-01T12:00:00Z'),
    metadata: { recurringCharge: true, chargeType: 'monthlyRent', month: 9, year: 2026 },
  };
  assert.throws(
    () => record(store, { charges: exampleCharges(), payments: examplePayments }),
    (e: unknown) => e instanceof PastHistoryRefusal && e.code === 'already-exists' && /September 2026/.test(e.message),
  );
  assert.equal(Object.keys(store.payments).length, 0);
  assert.equal(ledgerOf(store).length, 1);

  // Through August it goes in, and the September charge already there counts.
  const { result } = record(store, {
    charges: exampleCharges().filter((c) => c.month <= 8),
    payments: examplePayments,
  });
  assert.equal(result.balance, 160);
  assert.equal(result.paidThrough, '2026-07-31');
});

test('a voided rent charge does not block its month', () => {
  const existing = [
    { type: 'rentCharge', status: 'voided', amount: 80, entryDate: new Date('2026-03-01T12:00:00Z'), metadata: { recurringCharge: true, chargeType: 'monthlyRent', month: 3, year: 2026 } },
  ];
  assert.deepEqual(monthsAlreadyCharged(existing, [{ year: 2026, month: 3 }]), []);
});

test('a hand-entered rent charge without metadata still blocks its month', () => {
  const existing = [{ type: 'rentCharge', status: 'posted', amount: 80, entryDate: new Date('2026-04-01T05:00:00Z') }];
  assert.deepEqual(monthsAlreadyCharged(existing, [{ year: 2026, month: 4 }, { year: 2026, month: 5 }]), [
    { year: 2026, month: 4 },
  ]);
});

test('a double press with the same requestId saves once and returns the first result', () => {
  const store = newStore();
  const first = record(store, { charges: exampleCharges(), payments: examplePayments });
  const ledgerCount = ledgerOf(store).length;
  const second = record(store, { charges: exampleCharges(), payments: examplePayments });
  assert.equal(second.writes.length, 0);
  assert.equal(second.result.alreadyApplied, true);
  assert.equal(second.result.balance, first.result.balance);
  assert.equal(ledgerOf(store).length, ledgerCount);
  assert.equal(Object.keys(store.payments).length, 5);
});

test('employees, outsiders and viewers are refused; managers and super admins may', () => {
  for (const uid of ['emp-1', 'stranger']) {
    const store = newStore();
    assert.throws(
      () => record(store, { charges: exampleCharges() }, { uid, email: null, superAdmin: false }),
      (e: unknown) => e instanceof PastHistoryRefusal && e.code === 'permission-denied',
    );
    assert.equal(ledgerOf(store).length, 0);
  }
  const mgrStore = newStore();
  record(mgrStore, { charges: exampleCharges() }, { uid: 'mgr-1', email: null, superAdmin: false });
  assert.equal(ledgerOf(mgrStore).length, 8);
  const adminStore = newStore();
  record(adminStore, { charges: exampleCharges() }, { uid: 'support', email: null, superAdmin: true });
  assert.equal(ledgerOf(adminStore).length, 8);
});

test('undo voids every entry and payment and restores the previous paidThrough', () => {
  const previous = new Date('2026-03-31T05:00:00Z');
  const store = newStore({ paidThrough: previous });
  record(store, { charges: exampleCharges(), payments: examplePayments });
  assert.equal(balanceOf(store), 160);

  const { result } = undo(store);
  assert.equal(result.entriesVoided, 13);
  assert.equal(result.paymentsVoided, 5);
  assert.equal(result.paidThroughRestored, true);
  assert.equal(balanceOf(store), 0);
  assert.ok(ledgerOf(store).every((e) => e.status === 'voided'));
  assert.ok(Object.values(store.payments).every((p) => p.status === 'voided' && p.isActive === false));
  assert.equal((store.tenants[TENANT_ID].paidThrough as Date).getTime(), previous.getTime());

  // Undoing twice changes nothing; re-sending the undone request is refused.
  assert.equal(undo(store).writes.length, 0);
  assert.throws(
    () => record(store, { charges: exampleCharges(), payments: examplePayments }),
    (e: unknown) => e instanceof PastHistoryRefusal && e.code === 'failed-precondition',
  );
});

test('undo leaves paidThrough alone if it moved since, and says so', () => {
  const store = newStore();
  record(store, { charges: exampleCharges(), payments: examplePayments });
  store.tenants[TENANT_ID].paidThrough = new Date('2026-09-30T05:00:00Z');
  const { result } = undo(store);
  assert.equal(result.paidThroughRestored, false);
  assert.equal(result.warnings.length, 1);
  assert.equal((store.tenants[TENANT_ID].paidThrough as Date).toISOString(), '2026-09-30T05:00:00.000Z');
});

test('undo is owner/manager/super admin only', () => {
  const store = newStore();
  record(store, { charges: exampleCharges() });
  assert.throws(
    () => undo(store, 'req-00000001', { uid: 'emp-1', email: null, superAdmin: false }),
    (e: unknown) => e instanceof PastHistoryRefusal && e.code === 'permission-denied',
  );
});

test('a later paidThrough already on the tenant is kept, with a warning', () => {
  const store = newStore({ paidThrough: new Date('2026-12-31T06:00:00Z') });
  const { result } = record(store, { charges: exampleCharges(), payments: examplePayments });
  assert.equal(result.paidThroughChanged, false);
  assert.equal(result.paidThrough, '2026-12-31');
  assert.equal(result.warnings.length, 1);
  assert.equal((store.tenants[TENANT_ID].paidThrough as Date).toISOString(), '2026-12-31T06:00:00.000Z');
});

test('decidePaidThrough treats the same day stored at local midnight as the same', () => {
  const computed = new Date('2026-07-31T12:00:00Z');
  const sameDay = new Date('2026-07-31T05:00:00Z');
  for (const choice of ['computed', 'keepLater'] as const) {
    assert.equal(decidePaidThrough(sameDay, computed, choice).change, false);
    assert.equal(decidePaidThrough(new Date('2026-06-30T05:00:00Z'), computed, choice).value, computed);
    assert.equal(decidePaidThrough(null, null, choice).change, false);
  }
  // Earlier: only the recomputed choice moves it back.
  const later = new Date('2027-01-31T06:00:00Z');
  assert.deepEqual(decidePaidThrough(later, computed, 'computed'), { change: true, value: computed, warning: null });
  const kept = decidePaidThrough(later, computed, 'keepLater');
  assert.equal(kept.change, false);
  assert.match(kept.warning!, /1\/31\/2027/);
});

test('payment reference goes into the payment and the ledger line', () => {
  const store = newStore();
  record(store, {
    payments: [{ date: '2026-03-02', amount: 80, method: 'check', reference: '1234', note: 'mailed' }],
  });
  const payment = Object.values(store.payments)[0];
  assert.equal(payment.reference, '1234');
  assert.equal(payment.notes, 'mailed');
  const line = ledgerOf(store).find((e) => e.type === 'payment')!;
  assert.equal(line.description, 'Payment - Check #1234: mailed');
  assert.equal(line.amount, -80);
  assert.equal(historyPaymentDescription({ method: 'zelle', reference: null, note: null }), 'Payment - Zelle');
});

test('request validation', () => {
  const base = { facilityId: 'f', tenantId: 't', requestId: 'req-00000002' };
  const bad = (extra: Record<string, unknown>, pattern: RegExp) =>
    assert.throws(
      () => parsePastHistoryRequest({ ...base, ...extra }, NOW),
      (e: unknown) => e instanceof PastHistoryInputError && pattern.test(e.message),
    );
  bad({ payments: [venmo('2026-10-15', 80)] }, /future/);
  bad({ payments: [venmo('1999-12-31', 80)] }, /before 2000/);
  bad({ payments: [venmo('2026-02-30', 80)] }, /not a real date/);
  bad({ payments: [venmo('2026-02-10', 0)] }, /more than \$0/);
  bad({ payments: [venmo('2026-02-10', -5)] }, /more than \$0/);
  bad({ payments: [venmo('2026-02-10', 1e7)] }, /not allowed/);
  bad({ payments: [{ date: '2026-02-10', amount: 80, method: 'bitcoin' }] }, /not allowed/);
  bad({ charges: [{ year: 2026, month: 10, day: 1, amount: 80 }] }, /future/);
  bad({ charges: [{ year: 2026, month: 2, day: 30, amount: 80 }] }, /day is not valid/);
  bad({ charges: [{ year: 2026, month: 3, day: 1, amount: 80 }, { year: 2026, month: 3, day: 1, amount: 80 }] }, /twice/);
  bad({ charges: Array.from({ length: 121 }, (_, i) => ({ year: 2010 + Math.floor(i / 12), month: (i % 12) + 1, day: 1, amount: 1 })) }, /At most 120/);
  bad({ payments: Array.from({ length: 201 }, () => venmo('2026-02-10', 1)) }, /At most 200/);
  bad({}, /Nothing to save/);
  bad({ requestId: 'x', payments: [venmo('2026-02-10', 80)] }, /requestId/);
  // Today is fine, and so is tomorrow in UTC while it is still today somewhere west.
  parsePastHistoryRequest({ ...base, payments: [venmo('2026-09-28', 80)] }, NOW);
});

// --- History typed in by hand before this tool existed ----------------------

/**
 * What the owner typed through Ledger -> Add entry and then invoiced: eight
 * $80 rent charges and four payments, all dated the day she typed them, with
 * the invoice's metadata rather than the rent job's, plus one she voided.
 */
function seedHandEntered(store: Store): string[] {
  const today = new Date('2026-09-28T02:00:00Z');
  const ids: string[] = [];
  for (let i = 0; i < 8; i += 1) {
    const id = `hand-charge-${i}`;
    store.ledgers[id] = {
      tenantId: TENANT_ID,
      type: 'rentCharge',
      status: 'posted',
      amount: 80,
      entryDate: today,
      metadata: { invoiceId: 'inv-demo-1' },
    };
    ids.push(id);
  }
  [-160, -80, -80, -80].forEach((amount, i) => {
    const id = `hand-payment-${i}`;
    store.ledgers[id] = { tenantId: TENANT_ID, type: 'payment', status: 'posted', amount, entryDate: today };
    ids.push(id);
  });
  store.ledgers['hand-voided'] = { tenantId: TENANT_ID, type: 'rentCharge', status: 'voided', amount: 80, entryDate: today };
  return ids;
}

const throughAugust = () => exampleCharges().filter((c) => c.month <= 8);

test('hand-entered rent dated today blocks this month, and left alone it doubles the balance', () => {
  const store = newStore();
  seedHandEntered(store);
  assert.equal(balanceOf(store), 240);
  // Dated September 28, so September counts as charged.
  assert.throws(
    () => record(store, { charges: exampleCharges(), payments: examplePayments }),
    (e: unknown) => e instanceof PastHistoryRefusal && /September 2026/.test(e.message),
  );
  const { result } = record(store, { charges: throughAugust(), payments: examplePayments });
  assert.equal(result.balance, 320); // 240 already there + 80 from the history
  assert.equal(result.existingVoided, 0);
});

test('voiding the hand-entered entries in the same save gives the real balance, and undo puts them back', () => {
  const store = newStore();
  const handIds = seedHandEntered(store);
  const { result } = record(store, { charges: exampleCharges(), payments: examplePayments, voidLedgerEntryIds: handIds });
  assert.equal(result.existingVoided, 12);
  assert.equal(result.balance, 160);
  assert.equal(result.paidThrough, '2026-07-31');
  assert.equal(balanceOf(store), 160);
  for (const id of handIds) {
    assert.equal(store.ledgers[id].status, 'voided');
    assert.equal((store.ledgers[id].metadata as any).voidedByHistoryRequestId, 'req-00000001');
  }
  // The one she had voided herself is untouched.
  assert.equal((store.ledgers['hand-voided'].metadata as any)?.voidedByHistoryRequestId, undefined);

  const undone = undo(store);
  assert.equal(undone.result.entriesRestored, 12);
  assert.equal(balanceOf(store), 240);
  for (const id of handIds) {
    assert.equal(store.ledgers[id].status, 'posted');
    assert.equal(store.ledgers[id].voidedAt, null);
    assert.equal((store.ledgers[id].metadata as any).voidedByHistoryRequestId, undefined);
  }
  assert.equal((store.ledgers['hand-charge-0'].metadata as any).invoiceId, 'inv-demo-1');
  assert.equal(store.ledgers['hand-voided'].status, 'voided');
});

test('a payment recorded in the app is voided with its ledger line, and restored on undo', () => {
  const store = newStore();
  store.payments['pay-app'] = { tenantId: TENANT_ID, amount: 80, status: 'completed', isActive: true, method: 'cash' };
  store.ledgers['led-app'] = {
    tenantId: TENANT_ID,
    type: 'payment',
    status: 'posted',
    amount: -80,
    entryDate: new Date('2026-09-20T15:00:00Z'),
    metadata: { paymentId: 'pay-app', paymentMethod: 'cash' },
  };
  record(store, { charges: exampleCharges(), payments: examplePayments, voidLedgerEntryIds: ['led-app'] });
  assert.equal(store.payments['pay-app'].status, 'voided');
  assert.equal(store.payments['pay-app'].isActive, false);
  undo(store);
  assert.equal(store.payments['pay-app'].status, 'completed');
  assert.equal(store.payments['pay-app'].isActive, true);
  assert.equal(store.ledgers['led-app'].status, 'posted');
});

test("entries to void must be this tenant's, still posted, and not from another history entry", () => {
  const store = newStore();
  store.ledgers['other-tenant'] = { tenantId: 'someone-else', type: 'rentCharge', status: 'posted', amount: 80, entryDate: NOW };
  store.ledgers['already-void'] = { tenantId: TENANT_ID, type: 'rentCharge', status: 'voided', amount: 80, entryDate: NOW };
  assert.throws(
    () => record(store, { charges: throughAugust(), voidLedgerEntryIds: ['other-tenant'] }),
    (e: unknown) => e instanceof PastHistoryRefusal && e.code === 'invalid-argument',
  );
  assert.throws(
    () => record(store, { charges: throughAugust(), voidLedgerEntryIds: ['already-void'] }),
    (e: unknown) => e instanceof PastHistoryRefusal && e.code === 'failed-precondition',
  );
  record(store, { charges: throughAugust() });
  const fromHistory = ledgerOf(store).find((e) => e.metadata?.source === 'past_history')!;
  assert.throws(
    () => record(store, { requestId: 'req-00000002', payments: examplePayments, voidLedgerEntryIds: [fromHistory.id] }),
    (e: unknown) => e instanceof PastHistoryRefusal && /Undo this history entry/.test(e.message),
  );
});

test("rent comes from the tenant's monthly rate, which covers all their units", () => {
  // Four $20 outdoor spaces billed as one $80 rate: the history is $80 a month.
  const store = newStore({ monthlyRate: 80, unitNumber: 'OUT-1' });
  const { result } = record(store, { charges: exampleCharges(), payments: examplePayments });
  assert.equal(result.totalCharges, 640);
  assert.equal(ledgerOf(store).filter((e) => e.type === 'rentCharge').length, 8);
});

test('the move-in date is saved on a tenant without one, never over one, and taken off by undo', () => {
  const store = newStore();
  record(store, { charges: exampleCharges(), moveInDate: '2026-02-10' });
  assert.equal((store.tenants[TENANT_ID].moveInDate as Date).toISOString(), '2026-02-10T12:00:00.000Z');
  undo(store);
  assert.equal(store.tenants[TENANT_ID].moveInDate, null);

  const kept = new Date('2026-01-05T06:00:00Z');
  const store2 = newStore({ moveInDate: kept });
  const { result } = record(store2, { charges: exampleCharges(), moveInDate: '2026-02-10' });
  assert.equal(result.moveInDateSaved, false);
  assert.equal(store2.tenants[TENANT_ID].moveInDate, kept);
});

test('a payment known only by its month is dated the 1st and says so', () => {
  // A house: moved in 8/17, August prorated to $475, September $1000.
  const store = newStore({ monthlyRate: 1000 });
  const { result } = record(store, {
    moveInDate: '2026-08-17',
    charges: [
      { year: 2026, month: 8, day: 17, amount: 475 },
      { year: 2026, month: 9, day: 1, amount: 1000 },
    ],
    payments: [
      { date: '2026-08-17', amount: 475, method: 'zelle' },
      { date: '2026-09-15', monthOnly: true, amount: 1000, method: 'check', reference: '2201' },
    ],
  });
  assert.equal(result.balance, 0);
  assert.equal(result.paidThrough, '2026-09-30');
  const sept = ledgerOf(store).find((e) => e.type === 'payment' && e.amount === -1000)!;
  assert.equal((sept.entryDate as Date).toISOString(), '2026-09-01T12:00:00.000Z');
  assert.equal(sept.description, 'Payment - Check #2201 (September 2026)');
  assert.equal((sept.metadata as any).dateIsMonthOnly, true);
});

// --- Review round: paidThrough from the whole ledger ------------------------

/**
 * The same hand history, but the payments went through Record payment:
 * each has a facility payment doc, the tenant's own copy, and a ledger line
 * linked by paymentId. Each advanced paidThrough, which now reads 1/31/2027.
 */
function seedRecordedByHand(store: Store): string[] {
  const typed = new Date('2026-09-28T02:00:00Z');
  const ids: string[] = [];
  for (let i = 0; i < 8; i += 1) {
    const id = `hand-charge-${i}`;
    store.ledgers[id] = {
      tenantId: TENANT_ID,
      type: 'rentCharge',
      status: 'posted',
      amount: 80,
      entryDate: typed,
      metadata: { invoiceId: 'inv-demo-1' },
    };
    ids.push(id);
  }
  [160, 80, 80, 80].forEach((amount, i) => {
    const at = new Date(typed.getTime() + i * 60_000);
    store.payments[`pay-${i}`] = { tenantId: TENANT_ID, amount, status: 'completed', isActive: true, method: 'venmo', createdAt: at };
    store.tenantPayments[`row-${i}`] = { type: 'manual', status: 'succeeded', amountCents: amount * 100, createdAt: new Date(at.getTime() + 500) };
    store.ledgers[`hand-payment-${i}`] = {
      tenantId: TENANT_ID,
      type: 'payment',
      status: 'posted',
      amount: -amount,
      entryDate: at,
      metadata: { paymentId: `pay-${i}`, paymentMethod: 'venmo' },
    };
    ids.push(`hand-payment-${i}`);
  });
  store.invoices['inv-demo-1'] = { invoiceNumber: 'INV-0042' };
  store.tenants[TENANT_ID].paidThrough = new Date('2027-01-31T06:00:00Z');
  return ids;
}

function recordFull(store: Store, data: Record<string, unknown>, requestId = 'req-00000001') {
  const request = parsePastHistoryRequest({ facilityId: FACILITY_ID, tenantId: TENANT_ID, requestId, ...data }, NOW);
  const plan = planRecordPastHistory({
    request,
    caller: OWNER,
    facility: store.facility[FACILITY_ID],
    tenant: store.tenants[TENANT_ID],
    existingLedger: ledgerOf(store),
    existingBatch: store.tenantPastHistory[requestId] ?? null,
    linkedPayments: Object.entries(store.payments).map(([id, d]) => ({ id, data: d })),
    tenantPaymentRows: Object.entries(store.tenantPayments).map(([id, d]) => ({ id, data: d })),
    invoices: Object.entries(store.invoices).map(([id, d]) => ({ id, data: d })),
    newId,
    serverTime: NOW,
  });
  apply(store, plan.writes);
  return plan;
}

function undoFull(store: Store, requestId = 'req-00000001') {
  const batch = store.tenantPastHistory[requestId];
  const read = (col: string, ids: string[]) => ids.map((id) => ({ id, data: store[col][id] ?? null }));
  const plan = planUndoPastHistory({
    facilityId: FACILITY_ID,
    tenantId: TENANT_ID,
    requestId,
    caller: OWNER,
    facility: store.facility[FACILITY_ID],
    tenant: store.tenants[TENANT_ID],
    batch,
    ledgerEntries: read('ledgers', batch.ledgerEntryIds as string[]),
    payments: read('payments', batch.paymentIds as string[]),
    replacedEntries: read('ledgers', batch.voidedExistingLedgerIds as string[]),
    replacedPayments: read('payments', (batch.voidedExistingPayments as Array<{ id: string }>).map((p) => p.id)),
    replacedTenantPayments: read('tenantPayments', (batch.voidedTenantPayments as Array<{ id: string }>).map((p) => p.id)),
    newId,
    serverTime: NOW,
  });
  apply(store, plan.writes);
  return plan;
}

function fullStore(tenant: Record<string, unknown> = {}): Store {
  return { ...newStore(tenant), tenantPayments: {}, invoices: {} };
}

test('owner example over hand payments that pushed paidThrough to 1/31/2027: voiding them brings it back to 7/31', () => {
  const store = fullStore();
  const handIds = seedRecordedByHand(store);
  const { result } = recordFull(store, { charges: exampleCharges(), payments: examplePayments, voidLedgerEntryIds: handIds });
  assert.equal(result.balance, 160);
  assert.equal(result.paidThroughBefore, '2027-01-31');
  assert.equal(result.paidThrough, '2026-07-31');
  assert.equal(result.paidThroughChanged, true);
  assert.equal((store.tenants[TENANT_ID].paidThrough as Date).toISOString(), '2026-07-31T12:00:00.000Z');
  // The tenant's own payment rows go with them, and the invoice is named.
  for (let i = 0; i < 4; i += 1) {
    assert.equal(store.tenantPayments[`row-${i}`].status, 'voided');
    assert.equal(store.payments[`pay-${i}`].status, 'voided');
  }
  assert.deepEqual(result.invoicesToReview, [{ id: 'inv-demo-1', number: 'INV-0042' }]);
  assert.ok(result.warnings.some((w) => /INV-0042/.test(w) && /open Invoices and void them/.test(w)));

  const undone = undoFull(store);
  assert.equal(undone.result.paidThroughRestored, true);
  assert.equal((store.tenants[TENANT_ID].paidThrough as Date).toISOString(), '2027-01-31T06:00:00.000Z');
  for (let i = 0; i < 4; i += 1) {
    assert.equal(store.tenantPayments[`row-${i}`].status, 'succeeded');
    assert.equal(store.tenantPayments[`row-${i}`].voidedByHistoryRequestId, null);
    assert.equal(store.payments[`pay-${i}`].status, 'completed');
  }
});

test('the owner can choose to keep the later paidThrough even while voiding payments', () => {
  const store = fullStore();
  const handIds = seedRecordedByHand(store);
  const { result } = recordFull(store, {
    charges: exampleCharges(),
    payments: examplePayments,
    voidLedgerEntryIds: handIds,
    paidThroughChoice: 'keepLater',
  });
  assert.equal(result.paidThrough, '2027-01-31');
  assert.equal(result.paidThroughChanged, false);
  assert.equal(result.warnings.filter((w) => /later than/.test(w)).length, 1);
});

test('a tenant row linked by facilityPaymentId is matched by the link, not the amount', () => {
  const store = fullStore();
  store.payments['pay-x'] = { tenantId: TENANT_ID, amount: 80, status: 'completed', isActive: true, createdAt: new Date('2026-09-01T12:00:00Z') };
  store.tenantPayments['row-other'] = { type: 'manual', status: 'succeeded', amountCents: 8000, createdAt: new Date('2026-09-01T12:00:01Z') };
  store.tenantPayments['row-linked'] = { type: 'manual', status: 'succeeded', amountCents: 8000, facilityPaymentId: 'pay-x', createdAt: new Date('2026-09-01T12:00:02Z') };
  store.ledgers['led-x'] = { tenantId: TENANT_ID, type: 'payment', status: 'posted', amount: -80, entryDate: new Date('2026-09-01T12:00:00Z'), metadata: { paymentId: 'pay-x' } };
  recordFull(store, { charges: throughAugust(), voidLedgerEntryIds: ['led-x'] });
  assert.equal(store.tenantPayments['row-linked'].status, 'voided');
  assert.equal(store.tenantPayments['row-other'].status, 'succeeded');
});

test('a $15 fee counts in the balance but does not hold paidThrough back', () => {
  const store = fullStore();
  store.ledgers['fee-1'] = { tenantId: TENANT_ID, type: 'lateFee', status: 'posted', amount: 15, entryDate: new Date('2026-03-06T12:00:00Z') };
  const { result } = recordFull(store, { charges: exampleCharges(), payments: examplePayments });
  assert.equal(result.balance, 175);
  assert.equal(result.paidThrough, '2026-07-31');
});

test('credit left after the charged months buys whole months, and less than a month shows as credit', () => {
  const charges = [
    { year: 2026, month: 8, day: 1, amount: 80 },
    { year: 2026, month: 9, day: 1, amount: 80 },
  ];
  const store = fullStore();
  const { result } = recordFull(store, { charges, payments: [venmo('2026-08-01', 240)] });
  assert.equal(result.paidThrough, '2026-10-31');
  assert.equal(result.prepaidMonths, 1);
  assert.equal(result.credit, 0);

  const store2 = fullStore();
  const r2 = recordFull(store2, { charges, payments: [venmo('2026-08-01', 270)] }).result;
  assert.equal(r2.paidThrough, '2026-10-31');
  assert.equal(r2.credit, 30);
});

test('a free month right after a paid month counts as paid', () => {
  const store = fullStore();
  const { result } = recordFull(store, {
    charges: [
      { year: 2026, month: 7, day: 1, amount: 80 },
      { year: 2026, month: 8, day: 1, amount: 80 },
    ],
    freeMonths: [{ year: 2026, month: 9 }],
    payments: [venmo('2026-07-01', 80), venmo('2026-08-01', 80)],
  });
  assert.equal(result.paidThrough, '2026-09-30');
  // Unpaid rent before it stops it there.
  const store2 = fullStore();
  const r2 = recordFull(store2, {
    charges: [
      { year: 2026, month: 7, day: 1, amount: 80 },
      { year: 2026, month: 8, day: 1, amount: 80 },
    ],
    freeMonths: [{ year: 2026, month: 9 }],
    payments: [venmo('2026-07-01', 80)],
  }).result;
  assert.equal(r2.paidThrough, '2026-07-31');
});

test('the same requestId with different details is refused, not answered with the first result', () => {
  const store = fullStore();
  recordFull(store, { charges: exampleCharges(), payments: examplePayments });
  assert.equal(recordFull(store, { charges: exampleCharges(), payments: examplePayments }).result.alreadyApplied, true);
  assert.throws(
    () => recordFull(store, { charges: exampleCharges(), payments: [...examplePayments, venmo('2026-09-02', 80)] }),
    (e: unknown) => e instanceof PastHistoryRefusal && e.code === 'already-exists' && /different details/.test(e.message),
  );
});

test('free months are validated', () => {
  const base = { facilityId: 'f', tenantId: 't', requestId: 'req-00000003' };
  assert.throws(
    () => parsePastHistoryRequest({ ...base, charges: [{ year: 2026, month: 3, day: 1, amount: 80 }], freeMonths: [{ year: 2026, month: 3 }] }, NOW),
    (e: unknown) => e instanceof PastHistoryInputError && /both charged and free/.test(e.message),
  );
  assert.throws(
    () => parsePastHistoryRequest({ ...base, charges: [{ year: 2026, month: 3, day: 1, amount: 80 }], freeMonths: [{ year: 2026, month: 11 }] }, NOW),
    (e: unknown) => e instanceof PastHistoryInputError && /future/.test(e.message),
  );
  assert.throws(
    () => parsePastHistoryRequest({ ...base, charges: [{ year: 2026, month: 3, day: 1, amount: 80 }], paidThroughChoice: 'always' }, NOW),
    (e: unknown) => e instanceof PastHistoryInputError,
  );
});
