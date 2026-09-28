import test from 'node:test';
import assert from 'node:assert/strict';
import { collectibleLedgerBalance } from '../autopayScheduledHelpers';

/**
 * Guards the balance arithmetic the delinquency job depends on.
 *
 * That job computed its own balance and subtracted the amount for payments and
 * credits, which are stored negative, so every payment increased the debt. A
 * paid-up tenant was given a late fee, emailed delinquency notices, moved to
 * lien status, and had gate access disabled where auto-lockout is on — daily.
 *
 * These cases encode the convention (charges positive, payments negative) so the
 * same inversion cannot come back through either reader.
 */

const posted = (amount: number) => ({ amount });

test('a tenant who paid in full owes nothing', () => {
  // The exact case that was reported as $300 owing.
  assert.equal(collectibleLedgerBalance([posted(150), posted(-150)]), 0);
});

test('a partial payment leaves only the remainder', () => {
  assert.equal(collectibleLedgerBalance([posted(150), posted(-50)]), 100);
});

test('a credit reduces the balance rather than raising it', () => {
  assert.equal(collectibleLedgerBalance([posted(150), posted(-25)]), 125);
});

test('an overpayment leaves a negative balance, not a debt', () => {
  const balance = collectibleLedgerBalance([posted(150), posted(-200)]);
  assert.equal(balance, -50);
  assert.ok(balance <= 0, 'an overpaid tenant must not look delinquent');
});

test('several months of charges and payments net correctly', () => {
  const entries = [posted(150), posted(-150), posted(150), posted(-150), posted(150)];
  assert.equal(collectibleLedgerBalance(entries), 150);
});

test('a late fee adds to the balance like any other charge', () => {
  assert.equal(collectibleLedgerBalance([posted(150), posted(-150), posted(25)]), 25);
});

test('missing or non-numeric amounts count as zero', () => {
  assert.equal(collectibleLedgerBalance([posted(150), { amount: undefined }, { amount: 'x' }]), 150);
  assert.equal(collectibleLedgerBalance([posted(100), { amount: Number.NaN }]), 100);
});

test('an empty ledger is not a debt', () => {
  assert.equal(collectibleLedgerBalance([]), 0);
});
