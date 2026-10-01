import test from 'node:test';
import assert from 'node:assert/strict';
import {
  checkDisputeForPayment,
  checkDisputeForPaymentInTransaction,
  DISPUTE_HAND_PAYMENT_METHODS,
  disputeHandPaymentDescription,
  disputeHandPaymentDocId,
  disputeLedgerEntryId,
  disputeOverpaidNotificationId,
  notifyIfDisputeOverpaid,
  recordDisputeHandPayment,
} from '../ledger/disputePayment';
import { FakeFirestore } from '../testing/fakeFirestore';

/** Facility f1 with the webhook's row for a $100 dispute du_1 on tenant t1. */
function withDispute(row: Record<string, unknown> = {}) {
  const fake = new FakeFirestore();
  fake.seed(`facilities/f1/ledgers/${disputeLedgerEntryId('du_1')}`, {
    tenantId: 't1',
    facilityId: 'f1',
    type: 'dispute',
    amount: 100,
    status: 'posted',
    metadata: { disputeId: 'du_1', paymentIntentId: 'pi_march' },
    ...row,
  });
  return fake;
}

test('no dispute id is an ordinary payment', async () => {
  const db = withDispute().firestore();
  for (const raw of [undefined, null, '', '   ']) {
    assert.deepEqual(await checkDisputeForPayment(db, 'f1', 't1', raw, 100), { ok: true, disputeId: null });
  }
});

test('an open dispute on this tenant\'s ledger is accepted up to what it has out', async () => {
  const db = withDispute().firestore();
  assert.deepEqual(await checkDisputeForPayment(db, 'f1', 't1', ' du_1 ', 100), { ok: true, disputeId: 'du_1' });
  assert.deepEqual(await checkDisputeForPayment(db, 'f1', 't1', 'du_1', 40), { ok: true, disputeId: 'du_1' });
});

test('a dispute id that is not this tenant\'s open dispute is refused', async () => {
  const cases: Array<[string, unknown, Record<string, unknown>]> = [
    ['invalid_dispute_id', 'du/../x', {}],
    ['invalid_dispute_id', 42, {}],
    ['dispute_not_found', 'du_2', {}],
    // A payment row can carry metadata.disputeId too; only the dispute's own row counts.
    ['dispute_not_found', 'du_1', { type: 'payment' }],
    ['dispute_of_another_tenant', 'du_1', { tenantId: 't2' }],
    ['dispute_not_open', 'du_1', { status: 'voided' }],
    ['dispute_not_open', 'du_1', { metadata: { disputeId: 'du_1', settledByEntryId: 'dispute_du_1_reinstated' } }],
  ];
  for (const [reason, raw, row] of cases) {
    const result = await checkDisputeForPayment(withDispute(row).firestore(), 'f1', 't1', raw, 100);
    assert.equal(result.ok, false, `${reason} ${JSON.stringify(row)}`);
    assert.equal(!result.ok && result.reason, reason);
  }
});

test('a payment for more than the dispute still has out is refused', async () => {
  const fake = withDispute();
  // $40 already taken by hand for it; a voided hand payment does not count.
  fake.seed('facilities/f1/ledgers/hand_1', {
    tenantId: 't1',
    type: 'payment',
    amount: -40,
    status: 'posted',
    metadata: { paymentMethod: 'cash', disputeId: 'du_1' },
  });
  fake.seed('facilities/f1/ledgers/hand_void', {
    tenantId: 't1',
    type: 'payment',
    amount: -30,
    status: 'voided',
    metadata: { paymentMethod: 'cash', disputeId: 'du_1' },
  });
  const db = fake.firestore();

  // The excess would sit in `disputed` as a credit no rent is set against.
  const over = await checkDisputeForPayment(db, 'f1', 't1', 'du_1', 60.01);
  assert.equal(!over.ok && over.reason, 'amount_over_dispute');
  assert.match(!over.ok ? over.message : '', /\$60\.00 left/);
  assert.deepEqual(await checkDisputeForPayment(db, 'f1', 't1', 'du_1', 60), { ok: true, disputeId: 'du_1' });
  const zero = await checkDisputeForPayment(db, 'f1', 't1', 'du_1', 0);
  assert.equal(!zero.ok && zero.reason, 'amount_over_dispute');
});

test('a dispute already paid in full by hand has nothing left to collect', async () => {
  const fake = withDispute();
  fake.seed('facilities/f1/ledgers/hand_1', {
    tenantId: 't1',
    type: 'payment',
    amount: -100,
    status: 'posted',
    metadata: { paymentMethod: 'cash', disputeId: 'du_1' },
  });

  const result = await checkDisputeForPayment(fake.firestore(), 'f1', 't1', 'du_1', 100);

  assert.equal(!result.ok && result.reason, 'dispute_not_open');
});

test('a fraudulent dispute is never charged to the card on file, but can be taken another way', async () => {
  const db = withDispute({ metadata: { disputeId: 'du_1', reason: 'fraudulent' } }).firestore();

  const card = await checkDisputeForPayment(db, 'f1', 't1', 'du_1', 100, { cardOnFile: true });
  assert.equal(!card.ok && card.reason, 'fraud_dispute_card_charge');
  assert.deepEqual(await checkDisputeForPayment(db, 'f1', 't1', 'du_1', 100), { ok: true, disputeId: 'du_1' });

  // Any other reason may go on the card, with the tenant's consent (the app asks).
  const other = withDispute({ metadata: { disputeId: 'du_1', reason: 'product_not_received' } }).firestore();
  assert.deepEqual(
    await checkDisputeForPayment(other, 'f1', 't1', 'du_1', 100, { cardOnFile: true }),
    { ok: true, disputeId: 'du_1' },
  );
});

/** $100 dispute du_1 collected by hand; [won] adds the webhook's reversal. */
function paidByHand(won: boolean) {
  const fake = withDispute();
  fake.seed('facilities/f1/tenants/t1', { name: ' Pat Tenant ' });
  fake.seed('facilities/f1/ledgers/hand_1', {
    tenantId: 't1',
    type: 'payment',
    amount: -100,
    status: 'posted',
    metadata: { paymentMethod: 'cash', disputeId: 'du_1' },
  });
  if (won) {
    fake.seed('facilities/f1/ledgers/dispute_du_1_reinstated', {
      tenantId: 't1',
      type: 'dispute_reversal',
      amount: -100,
      status: 'posted',
      metadata: { disputeId: 'du_1' },
    });
  }
  return fake;
}

const NOTIFICATION = `facilities/f1/Notifications/${disputeOverpaidNotificationId('du_1')}`;

test('a dispute paid by hand and then won tells staff to refund it, once per amount', async () => {
  const fake = paidByHand(true);
  const db = fake.firestore();
  const notify = () => notifyIfDisputeOverpaid({ db, facilityId: 'f1', tenantId: 't1', disputeId: 'du_1', createdBy: 'system@stripe-webhook' });

  assert.equal(await notify(), 100);
  const row = fake.read(NOTIFICATION)!;
  assert.equal(row.type, 'STRIPE_ACTION_REQUIRED');
  assert.equal(row.tenantId, 't1');
  assert.equal(row.tenantName, 'Pat Tenant');
  assert.equal(row.readAt, null);
  assert.match(String(row.message), /paid \$100\.00 more towards card dispute du_1/);
  assert.match(String(row.message), /Refund \$100\.00/);
  assert.deepEqual(row.metadata, { reason: 'dispute_paid_twice', disputeId: 'du_1', creditCents: 10000 });

  // Staff read it; a redelivered event does not bring it back.
  fake.seed(NOTIFICATION, { ...row, readAt: row.createdAt });
  const writes = fake.writesTo(NOTIFICATION).length;
  assert.equal(await notify(), 100);
  assert.equal(fake.writesTo(NOTIFICATION).length, writes);
  assert.notEqual(fake.read(NOTIFICATION)!.readAt, null);

  // A second payment on top changes the amount: told again.
  fake.seed('facilities/f1/ledgers/hand_2', {
    tenantId: 't1',
    type: 'payment',
    amount: -20,
    status: 'posted',
    metadata: { paymentMethod: 'cash', disputeId: 'du_1' },
  });
  assert.equal(await notify(), 120);
  assert.equal(fake.read(NOTIFICATION)!.readAt, null);
  assert.equal((fake.read(NOTIFICATION)!.metadata as Record<string, unknown>).creditCents, 12000);
});

test('nothing is said while the dispute is open, lost and paid once, or when only a stranded reversal is left', async () => {
  for (const fake of [paidByHand(false), withDispute()]) {
    const credit = await notifyIfDisputeOverpaid({ db: fake.firestore(), facilityId: 'f1', tenantId: 't1', disputeId: 'du_1', createdBy: 'x' });
    assert.equal(credit, 0);
    assert.deepEqual(fake.list('facilities/f1/Notifications'), []);
  }
  // Staff voided the dispute row after the win: the reversal is not money the tenant paid.
  const stranded = withDispute({ status: 'voided' });
  stranded.seed('facilities/f1/ledgers/dispute_du_1_reinstated', {
    tenantId: 't1',
    type: 'dispute_reversal',
    amount: -100,
    status: 'posted',
    metadata: { disputeId: 'du_1' },
  });
  assert.equal(
    await notifyIfDisputeOverpaid({ db: stranded.firestore(), facilityId: 'f1', tenantId: 't1', disputeId: 'du_1', createdBy: 'x' }),
    0,
  );
  assert.deepEqual(stranded.list('facilities/f1/Notifications'), []);
});

function handPayment(fake: FakeFirestore, overrides: Record<string, unknown> = {}) {
  return recordDisputeHandPayment({
    db: fake.firestore(),
    facilityId: 'f1',
    tenantId: 't1',
    disputeId: 'du_1',
    amount: 100,
    method: 'cash',
    reference: ' 0042 ',
    requestId: 'req_00000001',
    actorUid: 'staff_1',
    ...overrides,
  });
}

function withTenant(row: Record<string, unknown> = {}) {
  const fake = withDispute(row);
  fake.seed('facilities/f1/tenants/t1', { name: 'Pat Tenant', unitNumber: 'A1', contractId: 'c1' });
  return fake;
}

test('money taken by hand for a dispute is written by the server, booked against the dispute', async () => {
  const fake = withTenant();

  const result = await handPayment(fake, { notes: 'at the counter' });

  const id = disputeHandPaymentDocId('req_00000001');
  assert.deepEqual(result, { outcome: 'recorded', paymentId: id, ledgerEntryId: id });
  const ledger = fake.read(`facilities/f1/ledgers/${id}`)!;
  assert.equal(ledger.amount, -100);
  assert.equal(ledger.type, 'payment');
  assert.equal(ledger.status, 'posted');
  assert.equal(ledger.createdBy, 'staff_1');
  assert.equal(ledger.referenceId, id);
  assert.equal(ledger.description, 'Card dispute payment - Cash #0042: at the counter');
  assert.deepEqual(ledger.metadata, { paymentMethod: 'cash', paymentId: id, reference: '0042', disputeId: 'du_1' });
  const payment = fake.read(`facilities/f1/payments/${id}`)!;
  assert.equal(payment.status, 'completed');
  assert.equal(payment.amount, 100);
  assert.equal(payment.disputeId, 'du_1');
  assert.equal(payment.tenantName, 'Pat Tenant');
  const history = fake.read(`facilities/f1/tenants/t1/payments/${id}`)!;
  assert.equal(history.amountCents, 10000);
  assert.equal(history.chargeType, 'manual_cash');
  assert.equal(history.facilityPaymentId, id);
  // Paid-through is not moved by a dispute payment.
  assert.equal(fake.read('facilities/f1/tenants/t1')!.paidThrough, undefined);
});

test('the server refuses a by-hand dispute payment over what the dispute has out', async () => {
  const fake = withTenant();
  fake.seed('facilities/f1/ledgers/hand_1', {
    tenantId: 't1',
    type: 'payment',
    amount: -60,
    status: 'posted',
    metadata: { paymentMethod: 'cash', disputeId: 'du_1' },
  });

  const result = await handPayment(fake, { amount: 40.01 });

  assert.equal(result.outcome, 'refused');
  assert.equal(result.outcome === 'refused' && result.reason, 'amount_over_dispute');
  assert.deepEqual(fake.writes, []);
  assert.equal((await handPayment(fake, { amount: 40 })).outcome, 'recorded');
});

test('two staff recording the same dispute by hand at once cannot both take its full amount', async () => {
  const fake = withTenant();

  const results = await Promise.all([
    handPayment(fake, { requestId: 'req_first_01' }),
    handPayment(fake, { requestId: 'req_second_1' }),
  ]);

  assert.deepEqual(results.map((r) => r.outcome).sort(), ['recorded', 'refused']);
  const refused = results.find((r) => r.outcome === 'refused');
  assert.equal(refused?.outcome === 'refused' && refused.reason, 'dispute_not_open');
  const handRows = fake.list('facilities/f1/ledgers').filter((id) => id.startsWith('disputehand_'));
  assert.equal(handRows.length, 1);
});

test('a retried or double-pressed by-hand dispute payment is recorded once', async () => {
  const fake = withTenant();

  const first = await handPayment(fake);
  const again = await handPayment(fake);

  assert.equal(first.outcome, 'recorded');
  assert.equal(again.outcome, 'already_recorded');
  assert.equal(fake.writesTo(`facilities/f1/ledgers/${disputeHandPaymentDocId('req_00000001')}`).length, 1);
});

test('a by-hand dispute payment needs a known method, an amount, a dispute and a request id', async () => {
  const cases: Array<Record<string, unknown>> = [
    { method: 'stripe' },
    { method: 'creditCard' },
    { amount: 0 },
    { amount: '100' },
    { disputeId: '' },
    { requestId: 'x' },
    { requestId: undefined },
    { reference: 'r'.repeat(101) },
  ];
  for (const overrides of cases) {
    const fake = withTenant();
    const result = await handPayment(fake, overrides);
    assert.equal(result.outcome, 'refused', JSON.stringify(overrides));
    assert.deepEqual(fake.writes, [], JSON.stringify(overrides));
  }
  // Voided, or another tenant's: refused by the same check the card uses.
  for (const row of [{ status: 'voided' }, { tenantId: 't2' }]) {
    const fake = withTenant(row);
    assert.equal((await handPayment(fake)).outcome, 'refused');
    assert.deepEqual(fake.writes, []);
  }
});

test("the by-hand line reads like the app's", () => {
  assert.equal(disputeHandPaymentDescription('bankTransfer', '', ''), 'Card dispute payment - Bank Transfer');
  assert.equal(disputeHandPaymentDescription('check', ' 12 ', ' late '), 'Card dispute payment - Check #12: late');
  assert.deepEqual(Object.keys(DISPUTE_HAND_PAYMENT_METHODS), ['cash', 'check', 'venmo', 'zelle', 'bankTransfer', 'other']);
});

test('checking a dispute inside a transaction reads the same as outside it', async () => {
  const fake = withTenant();
  const db = fake.firestore();
  const inside = await db.runTransaction((tx) => checkDisputeForPaymentInTransaction(tx, db, 'f1', 't1', 'du_1', 100.01));
  assert.equal(!inside.ok && inside.reason, 'amount_over_dispute');
  assert.deepEqual(
    await db.runTransaction((tx) => checkDisputeForPaymentInTransaction(tx, db, 'f1', 't1', 'du_1', 100)),
    { ok: true, disputeId: 'du_1' },
  );
});
