/**
 * Autopay and the delinquency job never collect a card-disputed amount.
 *
 * The Stripe webhook posts `dispute` (+amount) when a dispute takes the money
 * back and `dispute_reversal` (-amount) when the facility wins it. Autopay
 * summed every posted row and charged the total, so in the month a dispute
 * was open it charged the disputed amount straight back to the card being
 * disputed; when the facility then won, the tenant had paid it twice. These
 * run the deployed trigger (processFacilityAutopayJob) against an in-memory
 * Firestore and a recording Stripe client.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import { getStripeClient, registerStripeKeysProvider } from '@sfc/functions-shared';
import { FakeFirestore, installFakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import { processFacilityAutopayJob } from '../autopayScheduled';
import { processDelinquencyForFacility } from '../delinquencyAutomation';
import { reminderBalance } from '../paymentRemindersScheduled';

registerStripeKeysProvider({
  getSecretKey: () => 'sk_test_fake_for_unit_tests',
  getPublishableKey: () => 'pk_test_fake_for_unit_tests',
});

const LEDGERS = 'facilities/f1/ledgers';
const METHOD = 'facilities/f1/tenants/t1/paymentMethods/pm1';

type Row = { type: string; amount: number; metadata?: Record<string, unknown> };

const rent = (amount = 100): Row => ({ type: 'rentCharge', amount });
const paid = (amount = 100): Row => ({ type: 'payment', amount: -amount });
/** What stripeWebhookDisputeCreated.ts posts when the money is taken back. */
const disputeRow = (amount = 100): Row => ({
  type: 'dispute',
  amount,
  metadata: { disputeId: 'du_1', paymentIntentId: 'pi_march' },
});
/** And when it comes back: on a win, or on funds_reinstated before the win. */
const reversalRow = (amount = 100): Row => ({
  type: 'dispute_reversal',
  amount: -amount,
  metadata: { disputeId: 'du_1', reversesEntryId: 'dispute_du_1' },
});

/** Every PaymentIntent autopay asked Stripe for, in dollars. */
let charged: number[] = [];

function setup(rows: Array<[id: string, row: Row]>) {
  const fake = new FakeFirestore();
  installFakeFirestore(fake);
  fake.seed('facilities/f1', {
    name: 'Test Storage',
    active: true,
    stripeConnectAccountId: 'acct_f1',
    stripeStatus: { chargesEnabled: true },
  });
  fake.seed('facilities/f1/tenants/t1', { name: 'Pat Tenant', isActive: true });
  fake.seed(METHOD, {
    facilityId: 'f1',
    tenantId: 't1',
    autopayEnabled: true,
    isActive: true,
    stripePaymentMethodId: 'pm_card',
    stripeCustomerId: 'cus_1',
    autopaySchedule: {
      frequency: 'monthly',
      dayOfMonth: 1,
      autopayNextRun: admin.firestore.Timestamp.fromDate(new Date(Date.now() - 60 * 60 * 1000)),
    },
  });
  for (const [id, row] of rows) {
    fake.seed(`${LEDGERS}/${id}`, { tenantId: 't1', facilityId: 'f1', status: 'posted', ...row });
  }

  charged = [];
  let n = 0;
  const client = getStripeClient() as unknown as { paymentIntents: Record<string, unknown> };
  client.paymentIntents.create = async (params: { amount: number }) => {
    charged.push(params.amount / 100);
    return { id: `pi_autopay_${++n}`, status: 'succeeded' };
  };
  return fake;
}

/** One nightly run for facility f1, through the deployed trigger. */
async function runAutopay(fake: FakeFirestore, jobId = `f1_${Math.random().toString(36).slice(2)}`) {
  fake.seed(`autopayJobs/${jobId}`, { facilityId: 'f1', status: 'pending' });
  const snapshot = await admin.firestore().collection('autopayJobs').doc(jobId).get();
  const run = (processFacilityAutopayJob as unknown as { run: (s: unknown, c: unknown) => Promise<unknown> }).run;
  await run(snapshot, { params: { jobId } });
  assert.equal(fake.read(`autopayJobs/${jobId}`)!.status, 'completed');
}

/** Everything on the tenant's books, as staff see it. */
function ledgerTotal(fake: FakeFirestore): number {
  const total = fake
    .list(LEDGERS)
    .map((id) => fake.read(`${LEDGERS}/${id}`)!)
    .filter((row) => row.status === 'posted')
    .reduce((sum, row) => sum + (row.amount as number), 0);
  return Math.round(total * 100) / 100;
}

/** Makes the schedule due again, as next month would. */
function nextMonth(fake: FakeFirestore) {
  const method = fake.read(METHOD)!;
  fake.seed(METHOD, {
    ...method,
    autopaySchedule: {
      ...(method.autopaySchedule as Record<string, unknown>),
      autopayNextRun: admin.firestore.Timestamp.fromDate(new Date(Date.now() - 60 * 1000)),
    },
  });
}

test('an open dispute is not charged: autopay takes only next month\'s rent', async () => {
  // March paid, March disputed and the money withdrawn, April rent due.
  const fake = setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', disputeRow()],
    ['april', rent()],
  ]);

  await runAutopay(fake);

  // It charged $200 before: the disputed $100 went back onto the disputed card.
  assert.deepEqual(charged, [100]);
  // The disputed $100 stays on the ledger for staff.
  assert.equal(ledgerTotal(fake), 100);
  const audit = fake.list('facilities/f1/auditLogs').map((id) => fake.read(`facilities/f1/auditLogs/${id}`)!);
  assert.equal((audit[0].details as Record<string, unknown>).disputedExcluded, 100);
});

test('a dispute the facility wins leaves the tenant having paid once, not twice', async () => {
  const fake = setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', disputeRow()],
    ['april', rent()],
  ]);
  await runAutopay(fake);

  // Won in May: the webhook posts the reversal. May rent is charged.
  fake.seed(`${LEDGERS}/dispute_du_1_reinstated`, { tenantId: 't1', facilityId: 'f1', status: 'posted', ...reversalRow() });
  fake.seed(`${LEDGERS}/may`, { tenantId: 't1', facilityId: 'f1', status: 'posted', ...rent() });
  nextMonth(fake);
  await runAutopay(fake);

  assert.deepEqual(charged, [100, 100]);
  // Before: $200 in April, then the reversal left a $100 credit nobody refunds.
  assert.equal(ledgerTotal(fake), 0);
});

test('funds reinstated before the win: the same, nothing disputed is charged', async () => {
  const fake = setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', disputeRow()],
    ['dispute_du_1_reinstated', reversalRow()],
    ['april', rent()],
  ]);

  await runAutopay(fake);

  assert.deepEqual(charged, [100]);
  assert.equal(ledgerTotal(fake), 0);
});

test('a lost dispute is still not charged to the card: staff collect it by hand', async () => {
  const fake = setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', disputeRow()],
    ['april', rent()],
  ]);
  await runAutopay(fake);
  // Lost: the webhook posts nothing more; the money is gone for good.
  fake.seed(`${LEDGERS}/may`, { tenantId: 't1', facilityId: 'f1', status: 'posted', ...rent() });
  nextMonth(fake);
  await runAutopay(fake);

  assert.deepEqual(charged, [100, 100]);
  // Owed, and visible to staff, but never re-billed without fresh consent.
  assert.equal(ledgerTotal(fake), 100);
});

test('when only a disputed amount is owed, autopay charges nothing and leaves the schedule due', async () => {
  const fake = setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', disputeRow()],
  ]);

  await runAutopay(fake);

  assert.deepEqual(charged, []);
  assert.equal(fake.list(LEDGERS).includes('payment_pi_autopay_1'), false);
  assert.equal(fake.read(METHOD)!.autopayLastResult, undefined);
});

test('a row re-labelled by the app but still carrying its dispute id is not charged either', async () => {
  // The app reads unknown types as otherCharge and writes that back on save.
  const fake = setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', { ...disputeRow(), type: 'otherCharge' }],
    ['april', rent()],
  ]);

  await runAutopay(fake);

  assert.deepEqual(charged, [100]);
});

test('the delinquency job sets a percentage late fee on what is collectible, not on a disputed amount', async () => {
  const fake = setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', disputeRow()],
    ['april', rent()],
  ]);
  fake.seed('facilities/f1', {
    ...fake.read('facilities/f1')!,
    // Late fees are opt-in (main #20): switched on here so the fee's basis is what is tested.
    billingSettings: { enableAutoLateFees: true, lateFeeType: 'percentage', lateFeeAmount: 10, enableAutoNotices: false },
  });
  // Paid through February: late for April by any grace period.
  fake.seed('facilities/f1/tenants/t1', {
    ...fake.read('facilities/f1/tenants/t1')!,
    paidThrough: admin.firestore.Timestamp.fromDate(new Date(Date.now() - 90 * 24 * 3600 * 1000)),
  });

  const result = await processDelinquencyForFacility('f1', false);

  assert.equal(result.success, true);
  const fees = fake
    .list(LEDGERS)
    .map((id) => fake.read(`${LEDGERS}/${id}`)!)
    .filter((row) => row.type === 'lateFee');
  // 10% of the $100 April rent. It was $20: 10% of the rent plus the dispute.
  assert.deepEqual(fees.map((row) => row.amount), [10]);
});

test('the delinquency job leaves alone a tenant who owes only a disputed amount', async () => {
  const fake = setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', disputeRow()],
  ]);
  fake.seed('facilities/f1', {
    ...fake.read('facilities/f1')!,
    billingSettings: { enableAutoNotices: false },
  });
  fake.seed('facilities/f1/tenants/t1', {
    ...fake.read('facilities/f1/tenants/t1')!,
    paidThrough: admin.firestore.Timestamp.fromDate(new Date(Date.now() - 90 * 24 * 3600 * 1000)),
  });

  const result = await processDelinquencyForFacility('f1', false);

  assert.equal(result.success, true);
  assert.equal(fake.list(LEDGERS).some((id) => fake.read(`${LEDGERS}/${id}`)!.type === 'lateFee'), false);
  assert.equal(fake.read('facilities/f1/tenants/t1')!.delinquencyStatus, undefined);
});

test('the payment reminder email quotes the balance without the disputed amount', async () => {
  setup([
    ['march', rent()],
    ['payment_pi_march', paid()],
    ['dispute_du_1', disputeRow()],
    ['april', rent()],
  ]);

  assert.equal(await reminderBalance('f1', 't1'), 100);
});
