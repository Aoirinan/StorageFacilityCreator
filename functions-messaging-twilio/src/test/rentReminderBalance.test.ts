import assert from 'node:assert/strict';
import test from 'node:test';
import { FakeFirestore, installFakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import { tenantBalance } from '../rentReminderSms';

// The rent text quotes this balance as the amount due. It summed every posted
// row, so a card-disputed amount was asked for again by text.

const LEDGERS = 'facilities/f1/ledgers';

function seed(rows: Array<[string, Record<string, unknown>]>) {
  const fake = new FakeFirestore();
  installFakeFirestore(fake);
  for (const [id, row] of rows) {
    fake.seed(`${LEDGERS}/${id}`, { tenantId: 't1', facilityId: 'f1', status: 'posted', ...row });
  }
  return fake;
}

test('the text leaves an open card dispute out of the amount it asks for', async () => {
  seed([
    ['march', { type: 'rentCharge', amount: 130 }],
    ['payment_pi_march', { type: 'payment', amount: -130 }],
    ['dispute_du_1', { type: 'dispute', amount: 130, metadata: { disputeId: 'du_1' } }],
    ['april', { type: 'rentCharge', amount: 130 }],
    ['voided', { type: 'rentCharge', amount: 999, status: 'voided' }],
    ['other_tenant', { type: 'rentCharge', amount: 50, tenantId: 't2' }],
  ]);

  assert.equal(await tenantBalance('f1', 't1'), 130);
});

test('a won dispute nets out and a lost one is still not asked for', async () => {
  seed([
    ['dispute_du_1', { type: 'dispute', amount: 130, metadata: { disputeId: 'du_1' } }],
    ['dispute_du_1_reinstated', { type: 'dispute_reversal', amount: -130, metadata: { disputeId: 'du_1' } }],
    ['dispute_du_2', { type: 'dispute', amount: 60, metadata: { disputeId: 'du_2' } }],
  ]);

  // Nothing collectible: the reminder falls back to the monthly rate.
  assert.equal(await tenantBalance('f1', 't1'), 0);
});
