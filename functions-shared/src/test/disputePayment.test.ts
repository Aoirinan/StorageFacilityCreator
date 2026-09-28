import test from 'node:test';
import assert from 'node:assert/strict';
import { checkDisputeForPayment, disputeLedgerEntryId } from '../ledger/disputePayment';
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
