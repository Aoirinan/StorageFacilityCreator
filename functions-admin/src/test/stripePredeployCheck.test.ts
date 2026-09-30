import test from 'node:test';
import assert from 'node:assert/strict';
import type * as admin from 'firebase-admin';
import { FakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';

// Plain CommonJS outside src/, run by hand against production before deploying.
// eslint-disable-next-line @typescript-eslint/no-var-requires
const check = require('../../scripts/stripe-predeploy-check.cjs') as {
  REQUIRED_DEPLOY_ORDER: string[];
  runPredeployChecks: (db: admin.firestore.Firestore, options?: { afterDeploy?: boolean }) => Promise<{
    disputeLedgerRows: Array<Record<string, unknown>>;
    refusedAfterDeploy: Array<Record<string, unknown>>;
    accountsWithNoFacility: Array<Record<string, unknown>>;
    recordedRefusals: Array<Record<string, unknown>>;
    needsAttention: boolean;
  }>;
};

test('the pre-deploy check only reads, and finds nothing on clean data', async () => {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_1' });
  fake.seed('facilities/f1/ledgers/r1', { type: 'rentCharge', amount: 100 });
  fake.seed('stripeWebhookEvents/evt_1', { eventType: 'payment_intent.succeeded', account: 'acct_1', facilityId: 'f1' });
  fake.seed('stripeWebhookEvents/evt_2', { eventType: 'charge.refunded', account: 'acct_1', facilityId: null });
  // A platform event (no account) is never refused.
  fake.seed('stripeWebhookEvents/evt_3', { eventType: 'payment_intent.succeeded', account: null, facilityId: 'f9' });

  const report = await check.runPredeployChecks(fake.firestore());

  assert.deepEqual(fake.writes, []);
  assert.equal(report.needsAttention, false);
});

test('the pre-deploy check reports old dispute rows and accounts whose next money event will be refused', async () => {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_new', stripeConnectPreviousAccountId: 'acct_old' });
  fake.seed('facilities/f2', { stripeConnectAccountId: null });
  // main's handler: a random-id row. The new webhook's own pair is marked as such.
  fake.seed('facilities/f1/ledgers/Xy12random', { type: 'dispute', amount: 50, tenantId: 't1', status: 'posted' });
  fake.seed('facilities/f1/ledgers/dispute_du_1', { type: 'dispute', amount: 42, metadata: { disputeId: 'du_1' } });
  fake.seed('stripeWebhookEvents/evt_1', { eventType: 'payment_intent.succeeded', account: 'acct_old', facilityId: 'f1' });
  fake.seed('stripeWebhookEvents/evt_2', { eventType: 'payment_intent.succeeded', account: 'acct_x', facilityId: 'f2' });
  // Refunds and disputes carry no facility metadata: matched by account.
  fake.seed('stripeWebhookEvents/evt_3', { eventType: 'charge.dispute.created', account: 'acct_old', facilityId: null });
  fake.seed('stripeWebhookRefusals/acct_old__du_2', {
    reason: 'previous_account',
    facilityId: 'f1',
    resolved: false,
    action: 'post it by hand',
  });

  const report = await check.runPredeployChecks(fake.firestore());

  assert.deepEqual(fake.writes, []);
  assert.equal(report.needsAttention, true);
  assert.deepEqual(
    report.disputeLedgerRows.map((r) => [r.path, r.writtenByNewWebhook]),
    [
      ['facilities/f1/ledgers/Xy12random', false],
      ['facilities/f1/ledgers/dispute_du_1', true],
    ],
  );
  assert.deepEqual(
    report.refusedAfterDeploy.map((r) => [r.facilityId, r.account, r.reason]),
    [
      ['f1', 'acct_old', 'previous_account'],
      ['f2', 'acct_x', 'facility_has_no_account'],
    ],
  );
  assert.deepEqual(report.accountsWithNoFacility, [
    { account: 'acct_old', previouslyConnectedTo: ['f1'], eventTypes: ['charge.dispute.created'], events: 1 },
  ]);
  assert.deepEqual(report.recordedRefusals.map((r) => r.id), ['acct_old__du_2']);
});

test('a refund from an account no facility is connected to is reported', async () => {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_new', stripeConnectPreviousAccountId: 'acct_old' });
  // Refunds carry no facility metadata; this one is from the old account.
  fake.seed('stripeWebhookEvents/evt_1', { eventType: 'charge.refunded', account: 'acct_old', facilityId: null });

  const report = await check.runPredeployChecks(fake.firestore());

  assert.equal(report.needsAttention, true);
  assert.deepEqual(report.accountsWithNoFacility, [
    { account: 'acct_old', previouslyConnectedTo: ['f1'], eventTypes: ['charge.refunded'], events: 1 },
  ]);
});

test('an unresolved refusal alone needs a person; a resolved one does not', async () => {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_1' });
  fake.seed('stripeWebhookRefusals/acct_x__pi_1', { reason: 'unknown_account', facilityId: 'f1', resolved: true });

  assert.equal((await check.runPredeployChecks(fake.firestore())).needsAttention, false);

  fake.seed('stripeWebhookRefusals/acct_x__pi_2', { reason: 'unknown_account', facilityId: 'f1', resolved: false });
  const report = await check.runPredeployChecks(fake.firestore());

  assert.deepEqual(report.recordedRefusals.map((r) => r.id), ['acct_x__pi_2']);
  assert.equal(report.needsAttention, true);
});

test('the report carries the required deploy order: consumers first, hosting last, the dispute switch after all', async () => {
  const report = (await check.runPredeployChecks(new FakeFirestore().firestore())) as unknown as {
    requiredDeployOrder: string[];
  };
  const order = report.requiredDeployOrder;
  const step = (text: string) => order.findIndex((line) => line.includes(text));

  assert.ok(step('functions:automation,functions:tenant-lifecycle,functions:messaging-twilio') === 0);
  assert.ok(step('functions:integrations') > step('functions:automation'));
  assert.ok(step('payment_intent.payment_failed') === step('functions:integrations'));
  assert.ok(step('functions:public-website') > step('functions:integrations'));
  assert.ok(step('functions:admin') > step('functions:public-website'));
  assert.ok(step('Hosting') > step('functions:admin'));
  assert.ok(step('disputeLedgerEnabled = true') > step('Hosting'));
  assert.deepEqual(check.REQUIRED_DEPLOY_ORDER, order);
});

test('the dispute ledger switch on before the deploy needs a person; after it, it is expected', async () => {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_1' });

  let report = await check.runPredeployChecks(fake.firestore());
  assert.equal((report as unknown as { disputeLedgerEnabled: boolean }).disputeLedgerEnabled, false);
  assert.equal(report.needsAttention, false);

  fake.seed('appConfig/payments', { disputeLedgerEnabled: true });
  report = await check.runPredeployChecks(fake.firestore());
  assert.equal((report as unknown as { disputeLedgerEnabled: boolean }).disputeLedgerEnabled, true);
  assert.equal(report.needsAttention, true);
  assert.equal((await check.runPredeployChecks(fake.firestore(), { afterDeploy: true })).needsAttention, false);
  assert.deepEqual(fake.writes, []);
});

test('a dispute held while the switch was off is listed until it posts', async () => {
  const fake = new FakeFirestore();
  fake.seed('facilities/f1', { stripeConnectAccountId: 'acct_1' });
  fake.seed('stripeWebhookRefusals/acct_1__du_1', { reason: 'dispute_ledger_off', facilityId: 'f1', tenantId: 't1', resolved: false });

  const report = await check.runPredeployChecks(fake.firestore(), { afterDeploy: true });

  assert.deepEqual(report.recordedRefusals.map((r) => [r.id, r.reason]), [['acct_1__du_1', 'dispute_ledger_off']]);
  assert.equal(report.needsAttention, true);
});
