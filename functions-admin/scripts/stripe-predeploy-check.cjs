#!/usr/bin/env node
'use strict';

/**
 * Read-only checks to run against production before deploying the Stripe
 * webhook's connected-account and dispute changes. It only reads: every call
 * is a get, so it is safe to point at the live project.
 *
 *   node scripts/stripe-predeploy-check.cjs --project=<firebase-project-id> [--after-deploy]
 *
 * 1. Dispute rows already on tenant ledgers. The webhook now writes one
 *    `dispute_{disputeId}` row per dispute and its `dispute_{disputeId}_reinstated`
 *    reversal. The old handler wrote random-id `dispute` rows whenever its
 *    lookups worked; one opened before the deploy and won after it would get
 *    the new pair on top, and the old row would stay. Expected: none.
 * 2. Money events that will be refused after the deploy. Payments, refunds,
 *    disputes and link checkouts from a connected account are accepted only
 *    from the account the facility is connected to now. Past events show
 *    which accounts send them; any that is not a facility's current account
 *    would have its next event refused, logged and recorded in
 *    stripeWebhookRefusals instead of posted. Expected: none.
 * 3. Refusals already recorded (for a re-run after the deploy), including
 *    disputes held while the dispute ledger switch was off (reason
 *    `dispute_ledger_off`).
 * 4. The dispute ledger switch, `appConfig/payments.disputeLedgerEnabled`.
 *    It must stay off until every step of [REQUIRED_DEPLOY_ORDER] is done:
 *    before, the webhook posts no dispute rows and marks no payment
 *    disputed, so code still on the old version cannot charge a disputed
 *    amount back to the card, add late fees for it, or ask the tenant to
 *    pay it again. On before the deploy needs attention; run with
 *    `--after-deploy` once it has been turned on on purpose.
 *
 * Prints the required deploy order (stderr) and a JSON report (stdout);
 * exits 1 when anything needs a person to look.
 */

const admin = require('firebase-admin');

/** Connected-account events that move tenant money, as stripeWebhookEvents records them. */
const MONEY_EVENT_TYPES = [
  'payment_intent.succeeded',
  'charge.refunded',
  'charge.dispute.created',
  'charge.dispute.updated',
  'charge.dispute.closed',
  'charge.dispute.funds_withdrawn',
  'charge.dispute.funds_reinstated',
  'checkout.session.completed',
];

const DISPUTE_TYPES = ['dispute', 'dispute_reversal'];

/**
 * The order the payment-links-and-disputes change must deploy in. Each step
 * after the first reads or writes what the ones before it changed.
 */
const REQUIRED_DEPLOY_ORDER = [
  '1. firebase deploy --only functions:automation,functions:tenant-lifecycle,functions:messaging-twilio' +
    ' -- FIRST: autopay, the delinquency job, the reminders, the portal balance and the rent reminder text' +
    ' leave card disputes and failed attempts out of what they collect.',
  '2. firebase deploy --only functions:integrations -- the Stripe webhook and payment callables.' +
    ' appConfig/payments.disputeLedgerEnabled stays OFF. Then, in the Stripe Dashboard, add' +
    ' payment_intent.payment_failed to the Connect webhook destination.',
  '3. firebase deploy --only functions:public-website -- payment links (confirmPublicPaymentCheckout is new).',
  '4. firebase deploy --only functions:admin -- facility and account delete, platform purge.',
  "5. Hosting (the Flutter app) LAST: the old server ignores the app's disputeId and has no confirmPublicPaymentCheckout.",
  '6. Only after 1-5: set appConfig/payments.disputeLedgerEnabled = true in the Firebase console, then re-run' +
    ' this check with --after-deploy. Held disputes post on their next Stripe event, or resend one of their' +
    ' eventIds from the Stripe Dashboard.',
];

function parseArgs(argv) {
  const values = new Map();
  for (const arg of argv.slice(2)) {
    if (!arg.startsWith('--')) continue;
    const [key, ...rest] = arg.slice(2).split('=');
    values.set(key, rest.length > 0 ? rest.join('=') : true);
  }
  return values;
}

/** Whether a ledger row id is one the new webhook writes. */
function isWebhookDisputeRowId(id, row) {
  const disputeId = row && row.metadata && row.metadata.disputeId;
  if (typeof disputeId !== 'string' || !disputeId) return false;
  return id === `dispute_${disputeId}` || id === `dispute_${disputeId}_reinstated`;
}

/** The same rule as connectedAccountGuard.ts refusalReasonFor. */
function refusalReason(facility, account) {
  if (!facility) return 'facility_missing';
  if (facility.stripeConnectAccountId === account) return null;
  if (facility.stripeConnectPreviousAccountId === account) return 'previous_account';
  return facility.stripeConnectAccountId ? 'unknown_account' : 'facility_has_no_account';
}

async function runPredeployChecks(db, options = {}) {
  const afterDeploy = options.afterDeploy === true;
  const report = {
    requiredDeployOrder: REQUIRED_DEPLOY_ORDER,
    disputeLedgerEnabled: false,
    disputeLedgerRows: [],
    refusedAfterDeploy: [],
    accountsWithNoFacility: [],
    recordedRefusals: [],
  };

  const facilities = await db.collection('facilities').get();
  const facilityById = new Map(facilities.docs.map((doc) => [doc.id, doc.data() || {}]));

  // 1. Per facility, not a collection-group query: the ledgers `type` field
  // has no collection-group index, and a collection-scope one always exists.
  for (const facility of facilities.docs) {
    const rows = await facility.ref.collection('ledgers').where('type', 'in', DISPUTE_TYPES).get();
    for (const row of rows.docs) {
      const data = row.data() || {};
      report.disputeLedgerRows.push({
        path: row.ref.path,
        type: data.type,
        amount: data.amount ?? null,
        tenantId: data.tenantId ?? null,
        status: data.status ?? null,
        writtenByNewWebhook: isWebhookDisputeRowId(row.id, data),
      });
    }
  }

  // 2. Every past money event from a connected account.
  const events = await db.collection('stripeWebhookEvents').where('eventType', 'in', MONEY_EVENT_TYPES).get();
  const byFacilityAndAccount = new Map();
  const accountsWithoutFacilityId = new Map();
  for (const doc of events.docs) {
    const e = doc.data() || {};
    if (!e.account) continue;
    if (e.facilityId) {
      const key = `${e.facilityId}|${e.account}`;
      const seen = byFacilityAndAccount.get(key) || { facilityId: e.facilityId, account: e.account, eventTypes: new Set(), events: 0 };
      seen.eventTypes.add(e.eventType);
      seen.events += 1;
      byFacilityAndAccount.set(key, seen);
    } else {
      // Charges and disputes carry no facility metadata; match the account.
      const seen = accountsWithoutFacilityId.get(e.account) || { account: e.account, eventTypes: new Set(), events: 0 };
      seen.eventTypes.add(e.eventType);
      seen.events += 1;
      accountsWithoutFacilityId.set(e.account, seen);
    }
  }
  for (const seen of byFacilityAndAccount.values()) {
    const reason = refusalReason(facilityById.get(seen.facilityId), seen.account);
    if (!reason) continue;
    report.refusedAfterDeploy.push({
      facilityId: seen.facilityId,
      account: seen.account,
      facilityAccount: (facilityById.get(seen.facilityId) || {}).stripeConnectAccountId || null,
      reason,
      eventTypes: [...seen.eventTypes].sort(),
      events: seen.events,
    });
  }
  for (const seen of accountsWithoutFacilityId.values()) {
    const current = [...facilityById.entries()].filter(([, f]) => f.stripeConnectAccountId === seen.account);
    if (current.length > 0) continue;
    const previous = [...facilityById.entries()]
      .filter(([, f]) => f.stripeConnectPreviousAccountId === seen.account)
      .map(([id]) => id);
    report.accountsWithNoFacility.push({
      account: seen.account,
      previouslyConnectedTo: previous,
      eventTypes: [...seen.eventTypes].sort(),
      events: seen.events,
    });
  }

  // 3. Refusals the new webhook has recorded and nobody has closed.
  const refusals = await db.collection('stripeWebhookRefusals').where('resolved', '==', false).get();
  for (const doc of refusals.docs) {
    const r = doc.data() || {};
    report.recordedRefusals.push({
      id: doc.id,
      reason: r.reason ?? null,
      facilityId: r.facilityId ?? null,
      tenantId: r.tenantId ?? null,
      eventTypes: r.eventTypes ?? [],
      amount: r.amount ?? null,
      action: r.action ?? null,
    });
  }

  // 4. The dispute ledger switch.
  const paymentsConfig = await db.collection('appConfig').doc('payments').get();
  report.disputeLedgerEnabled = paymentsConfig.exists && paymentsConfig.get('disputeLedgerEnabled') === true;

  report.needsAttention =
    (report.disputeLedgerEnabled && !afterDeploy) ||
    report.disputeLedgerRows.length > 0 ||
    report.refusedAfterDeploy.length > 0 ||
    report.accountsWithNoFacility.length > 0 ||
    report.recordedRefusals.length > 0;
  return report;
}

async function main() {
  const args = parseArgs(process.argv);
  const projectId = String(args.get('project') || '').trim();
  if (!projectId) throw new Error('Pass --project=<firebase-project-id>.');
  const afterDeploy = args.get('after-deploy') === true;
  console.error(['REQUIRED DEPLOY ORDER (payment links and card disputes):', ...REQUIRED_DEPLOY_ORDER].join('\n'));
  admin.initializeApp({ projectId });
  const report = await runPredeployChecks(admin.firestore(), { afterDeploy });
  if (report.disputeLedgerEnabled && !afterDeploy) {
    console.error(
      'appConfig/payments.disputeLedgerEnabled is ON. It must stay off until steps 1-5 are deployed.',
    );
  }
  console.log(JSON.stringify({ projectId, generatedAt: new Date().toISOString(), ...report }, null, 2));
  if (report.needsAttention) process.exitCode = 1;
}

// Run only as a script; tests load it for runPredeployChecks.
if (require.main === module) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.stack : error);
    process.exitCode = 1;
  });
}

module.exports = { MONEY_EVENT_TYPES, REQUIRED_DEPLOY_ORDER, runPredeployChecks };
