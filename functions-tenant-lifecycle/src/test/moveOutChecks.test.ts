import test from 'node:test';
import assert from 'node:assert/strict';

import { contractTenantRefusal, contractUnitId, contractUnitRefusal, moveOutLedgerRows, pendingCardRefund } from '../moveOutChecks';

const held = (id: string, unitNumber: string, tenantId = 't1', status = 'occupied', area?: string) => ({
  id,
  data: { unitNumber, status, tenantId, monthlyRate: 100, ...(area ? { area } : {}) },
});

test('a contract names its unit at the top level or in its online move-in context', () => {
  assert.equal(contractUnitId({ unitId: 'u1' }), 'u1');
  assert.equal(contractUnitId({ customFields: { onlineMoveInContext: { unitId: 'u2' } } }), 'u2');
  assert.equal(contractUnitId({ tenantId: 't1' }), '');
  assert.equal(contractUnitId({ unitId: 7, customFields: { onlineMoveInContext: null } }), '');
});

test("another tenant's contract is refused; one with no tenant is not", () => {
  assert.equal(contractTenantRefusal({ tenantId: 't1' }, 't1'), null);
  assert.equal(contractTenantRefusal({}, 't1'), null);
  assert.match(contractTenantRefusal({ tenantId: 't2' }, 't1') ?? '', /belongs to another tenant, so nothing was moved out/);
});

test('a contract for another unit they still rent is refused; for the unit they leave, or one they gave up, it is not', () => {
  const linkedUnits = [held('u101', '101'), held('u102', '102')];
  const refusal = (contract: Record<string, unknown>, units = linkedUnits) =>
    contractUnitRefusal({ contract, tenantId: 't1', unitId: 'u101', unit: linkedUnits[0].data, linkedUnits: units });

  assert.equal(refusal({ unitId: 'u101' }), null);
  assert.equal(refusal({}), null, 'contracts made in the app record no unit');
  assert.equal(
    refusal({ unitId: 'u102' }),
    'This contract is for unit 102, which this tenant still rents, so ending it would end their agreement ' +
      'for unit 102. Nothing was moved out. To free unit 101 only, use Units > unit 101 > Unassign Tenant.',
  );
  // Moved to another unit since signing: the contract ends with the unit they are in.
  assert.equal(refusal({ unitId: 'u9' }), null);
  assert.equal(refusal({ unitId: 'u102' }, [held('u101', '101'), held('u102', '102', 't1', 'available')]), null);
  assert.equal(refusal({ unitId: 'u102' }, [held('u101', '101'), held('u102', '102', 't2')]), null);
});

test('the refusal names both units with their areas: two areas can each have a unit 12', () => {
  // "Units > unit 12 > Unassign Tenant" could be the other tenant's unit 12
  // in the other area, and unassigning it ends their tenancy.
  const c2 = held('c2-12', '12', 't1', 'occupied', 'Complex 2');
  const c3 = held('c3-12', '12', 't1', 'lockout', 'Complex 3');
  assert.equal(
    contractUnitRefusal({ contract: { unitId: 'c3-12' }, tenantId: 't1', unitId: 'c2-12', unit: c2.data, linkedUnits: [c2, c3] }),
    'This contract is for unit 12 (Complex 3), which this tenant still rents, so ending it would end their ' +
      'agreement for unit 12 (Complex 3). Nothing was moved out. To free unit 12 (Complex 2) only, use ' +
      'Units > unit 12 (Complex 2) > Unassign Tenant.',
  );
  // A unit with no number is named by its id, as before.
  assert.match(
    contractUnitRefusal({ contract: { unitId: 'c3-12' }, tenantId: 't1', unitId: 'u0', unit: {}, linkedUnits: [c3] }) ?? '',
    /To free unit u0 only/,
  );
});

test('ledger rows: charges positive, a credit negative, a refund made in cash positive', () => {
  // Paid September's $100 on the 1st, leaving on the 10th: $66.67 of unused
  // days back, less a $30 cleaning fee, is a net credit of $36.67, refunded.
  const rows = moveOutLedgerRows({ moveOutCharges: -36.67, moveOutRefund: 36.67, processRefund: true, refundMethod: 'cash' });
  assert.deepEqual(rows.charges, {
    type: 'credit',
    amount: -36.67,
    description: 'Move-out credit (unused prorated rent, less any fees)',
  });
  assert.deepEqual(rows.refund, { amount: 36.67, method: 'cash' });
  assert.equal(rows.cardRefund, null);
  assert.equal(rows.refundWarning, null);
  // The balance they leave with is 0: the credit, then the money paid back.
  assert.equal(rows.charges!.amount + rows.refund!.amount, 0);

  assert.deepEqual(moveOutLedgerRows({ moveOutCharges: 40, moveOutRefund: 0, processRefund: false }).charges, {
    type: 'moveOutFee',
    amount: 40,
    description: 'Move-out charges',
  });
  assert.equal(moveOutLedgerRows({ moveOutCharges: 0, moveOutRefund: 0 }).charges, null);
  assert.equal(moveOutLedgerRows({ moveOutCharges: 'x', moveOutRefund: Infinity, processRefund: true }).refund, null);
});

test('no refund row unless the owner made one outside Stripe', () => {
  // Not ticked: the tenant still holds the credit.
  assert.equal(moveOutLedgerRows({ moveOutCharges: -50, moveOutRefund: 50, processRefund: false, refundMethod: 'cash' }).refund, null);
  // A card refund is not made or posted here: its amount goes back to the
  // screen, which refunds it through processRefund. The webhook alone does
  // not post it for every payment (an online move-in's PaymentIntent has no
  // tenantId), so the warning no longer says the ledger will record it. For
  // a payment that names its tenant it does, so "refund in Stripe, then Add
  // entry" counted it twice: the owner looks for that row first.
  const card = moveOutLedgerRows({ moveOutCharges: -50, moveOutRefund: 50, processRefund: true, refundMethod: 'creditCard' });
  assert.equal(card.refund, null);
  assert.equal(card.cardRefund, 50);
  assert.equal(
    card.refundWarning,
    'The $50.00 card refund was not made by the move-out, and it stays on their ledger as a credit. ' +
      'Refund it to their card in your Stripe dashboard. Wait a minute, then look at their ledger: Stripe ' +
      'records some card refunds there itself, as a "Refund for charge …" row. Only if none has appeared ' +
      'for it, record it on their ledger (Add entry, type Refund).',
  );
  assert.doesNotMatch(card.refundWarning ?? '', /when Stripe confirms/);
  // Not ticked, or nothing to refund: no card refund either.
  assert.equal(moveOutLedgerRows({ moveOutCharges: -50, moveOutRefund: 50, processRefund: false, refundMethod: 'creditCard' }).cardRefund, null);
  assert.equal(moveOutLedgerRows({ moveOutCharges: 10, moveOutRefund: 0, processRefund: true, refundMethod: 'creditCard' }).cardRefund, null);
  assert.deepEqual(
    moveOutLedgerRows({ moveOutCharges: 0, moveOutRefund: 12.5, processRefund: true }).refund,
    { amount: 12.5, method: 'manual' },
  );
});

test('a card refund a finished move-out left pending is sent back on a retry; none otherwise', () => {
  const at = { toDate: () => new Date('2026-09-23T15:04:05.000Z') };
  assert.deepEqual(pendingCardRefund({ moveOutCardRefund: { status: 'pending', requested: 36.67, refunded: 0, at } }), {
    requested: 36.67,
    since: '2026-09-23T15:04:05.000Z',
  });
  // A record from before [at] still says the refund is owed, with no time.
  assert.deepEqual(pendingCardRefund({ moveOutCardRefund: { status: 'pending', requested: 20 } }), {
    requested: 20,
    since: null,
  });
  // The screen reported back (made, partly made or not made), or the owner
  // chose to refund it in Stripe themselves: nothing pending.
  for (const status of ['refunded', 'partial', 'notMade', 'manual']) {
    assert.equal(pendingCardRefund({ moveOutCardRefund: { status, requested: 36.67, at } }), null, status);
  }
  assert.equal(pendingCardRefund({}), null);
  assert.equal(pendingCardRefund({ moveOutCardRefund: { status: 'pending', requested: 0, at } }), null);
  assert.equal(pendingCardRefund({ moveOutCardRefund: { status: 'pending', requested: 'x', at } }), null);
});
