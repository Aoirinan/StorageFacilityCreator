import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as path from 'node:path';
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

/** The `firebase deploy --only ...` targets in [text], in the order they appear. */
function deployTargets(text: string): string[] {
  return [...text.matchAll(/firebase deploy --only ([a-z:,-]+)/g)].map((m) => m[1]);
}

test('the report carries the required deploy order for the whole train, and each step comes after what it needs', async () => {
  const report = (await check.runPredeployChecks(new FakeFirestore().firestore())) as unknown as {
    requiredDeployOrder: string[];
  };
  const order = report.requiredDeployOrder;
  assert.deepEqual(check.REQUIRED_DEPLOY_ORDER, order);
  const step = (text: string) => {
    const at = order.findIndex((line) => line.includes(text));
    assert.ok(at >= 0, `no step mentions ${text}`);
    return at;
  };

  // The read-only checks and the app build come before anything is deployed.
  assert.equal(step('predeploy-online-move-in-checks.mjs'), 0);
  assert.equal(step('flutter build web'), 0);
  // #55: the move-in refund sweep and the alerts banner need the indexes.
  assert.equal(step('--only firestore:indexes'), 1);
  assert.ok(step('--only firestore:indexes') < step('--only functions:public-website'));
  // This PR: autopay, the delinquency job and the reminders before the webhook.
  assert.ok(step('functions:automation,functions:messaging-twilio') < step('--only functions:integrations'));
  // #55: the webhook holds units for paid move-ins only the public-website sweep settles.
  assert.equal(step('--only functions:integrations'), step('--only functions:public-website') + 1);
  // #56: integrations and tenant-lifecycle, then hosting straight after; never hosting first.
  assert.equal(step('--only functions:tenant-lifecycle'), step('--only functions:integrations') + 1);
  assert.equal(step('--only hosting'), step('--only functions:tenant-lifecycle') + 1);
  // This PR: the Connect destination sends failures only once the portal and the webhook handle them.
  assert.ok(step('payment_intent.payment_failed') > step('--only functions:tenant-lifecycle'));
  assert.ok(step('payment_intent.payment_failed') > step('--only functions:integrations'));
  // #58: hosting, then the team-access audit, then the rules.
  assert.ok(step('--only firestore:rules') > step('--only hosting'));
  assert.equal(step('audit-team-access.mjs'), step('--only firestore:rules'));
  // This PR: the dispute ledger switch after everything else.
  assert.equal(step('disputeLedgerEnabled = true'), order.length - 1);
  // Every codebase the train changes, deployed exactly once.
  assert.deepEqual(
    deployTargets(order.join('\n')).flatMap((t) => t.split(',')).sort(),
    [
      'firestore:indexes',
      'firestore:rules',
      'functions:admin',
      'functions:automation',
      'functions:integrations',
      'functions:messaging-twilio',
      'functions:public-website',
      'functions:tenant-lifecycle',
      'hosting',
    ],
  );
});

test('docs/payments_architecture.md lists the same deploy steps in the same order', () => {
  // lib/test/ -> functions-admin/ -> repo root.
  const doc = fs.readFileSync(path.join(__dirname, '..', '..', '..', 'docs', 'payments_architecture.md'), 'utf8');
  const start = doc.indexOf('### Dispute ledger switch and deploy order');
  assert.ok(start >= 0);
  const end = doc.indexOf('\n### ', start + 1);
  const section = doc.slice(start, end < 0 ? undefined : end);

  assert.deepEqual(deployTargets(section), deployTargets(check.REQUIRED_DEPLOY_ORDER.join('\n')));
  assert.match(section, /payment_intent\.payment_failed/);
  assert.match(section, /audit-team-access\.mjs/);
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
