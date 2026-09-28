import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { isDisputeLedgerRow, splitLedgerBalance } from '../ledger/disputeEntries';
import { disputeOutstanding } from '../ledger/disputePayment';

type Row = { type?: unknown; amount?: unknown; metadata?: unknown };
const parity = JSON.parse(
  readFileSync(join(__dirname, '..', '..', 'src', 'test', 'fixtures', 'disputeLedgerParity.json'), 'utf8'),
) as {
  rows: Array<{ name: string; row: Row; isDispute: boolean }>;
  balances: Array<{ name: string; rows: Row[]; total: number; disputed: number; collectible: number }>;
  outstanding: Array<{ name: string; disputeId: string; rows: Array<Row & { status?: unknown }>; outstanding: number }>;
};

for (const c of parity.rows) {
  test(`dispute row rule: ${c.name}`, () => {
    assert.equal(isDisputeLedgerRow(c.row), c.isDispute);
  });
}

for (const c of parity.balances) {
  test(`balance split: ${c.name}`, () => {
    assert.deepEqual(splitLedgerBalance(c.rows), {
      total: c.total,
      disputed: c.disputed,
      collectible: c.collectible,
    });
  });
}

for (const c of parity.outstanding) {
  test(`dispute outstanding: ${c.name}`, () => {
    assert.equal(disputeOutstanding(c.rows, c.disputeId), c.outstanding);
  });
}

test('missing rows and amounts are not disputes and count as zero', () => {
  assert.equal(isDisputeLedgerRow(null), false);
  assert.equal(isDisputeLedgerRow(undefined), false);
  assert.deepEqual(splitLedgerBalance([{ type: 'dispute' }, { amount: Number.NaN }]), {
    total: 0,
    disputed: 0,
    collectible: 0,
  });
});
