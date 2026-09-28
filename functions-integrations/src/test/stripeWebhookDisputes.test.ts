import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import type { FakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import {
  ACCOUNT,
  event,
  LEDGERS,
  linkPaymentIntent,
  PAYMENTS,
  setup,
  writesOutsideRefusals,
} from './support/webhookFakes';

/** The balance transactions Stripe books on a dispute: money out, then back. */
const WITHDRAWAL = { id: 'txn_out', object: 'balance_transaction', amount: -4200, reporting_category: 'dispute' };
const REINSTATEMENT = { id: 'txn_back', object: 'balance_transaction', amount: 4200, reporting_category: 'dispute_reversal' };

function dispute(overrides: Record<string, unknown> = {}): Stripe.Dispute {
  return {
    id: 'du_1',
    object: 'dispute',
    amount: 4200,
    charge: 'ch_1',
    payment_intent: 'pi_1',
    reason: 'fraudulent',
    status: 'needs_response',
    balance_transactions: [WITHDRAWAL],
    ...overrides,
  } as unknown as Stripe.Dispute;
}

const inquiry = (status: string) => dispute({ status, balance_transactions: [] });
const won = (overrides: Record<string, unknown> = {}) =>
  dispute({ status: 'won', balance_transactions: [WITHDRAWAL, REINSTATEMENT], ...overrides });

function send(type: string, object: Stripe.Dispute, created?: number, account: string = ACCOUNT, id?: string) {
  const e = event(type, object, account, id);
  return dispatchStripeWebhookEvent(created === undefined ? e : ({ ...e, created } as Stripe.Event));
}

/** A tenant who paid $42 through the facility's account, and so owes nothing. */
async function paidTenant() {
  const ctx = setup();
  ctx.stripe.put(ACCOUNT, 'pi_1', linkPaymentIntent('pi_1'));
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_1'), ACCOUNT));
  return ctx;
}

/** What the delinquency job and autopay see: every posted ledger row, summed. */
function owed(fake: FakeFirestore): number {
  return fake
    .list(LEDGERS)
    .map((id) => fake.read(`${LEDGERS}/${id}`)!)
    .filter((row) => row.tenantId === 't1' && row.status === 'posted')
    .reduce((sum, row) => sum + (row.amount as number), 0);
}

const disputeRows = (fake: FakeFirestore) => fake.list(LEDGERS).filter((id) => id.startsWith('dispute_'));

test('an inquiry never touches the ledger, however it ends', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.created', inquiry('warning_needs_response'));
  await send('charge.dispute.updated', inquiry('warning_under_review'));
  // Even a snapshot that lists a balance transaction: an inquiry is never charged.
  await send('charge.dispute.updated', dispute({ status: 'warning_under_review' }));
  await send('charge.dispute.closed', inquiry('warning_closed'));

  assert.deepEqual(disputeRows(fake), []);
  assert.equal(owed(fake), -42);
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.disputeStatus, 'warning_closed');
});

test('a dispute is charged only once Stripe has withdrawn the funds, not when it opens', async () => {
  const { fake } = await paidTenant();

  // Open, but nothing booked against the balance yet.
  await send('charge.dispute.created', dispute({ balance_transactions: [] }));
  assert.deepEqual(disputeRows(fake), []);
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'disputed');

  await send('charge.dispute.funds_withdrawn', dispute());
  assert.deepEqual(disputeRows(fake), ['dispute_du_1']);
});

test('a lost dispute charges the tenant the disputed amount once', async () => {
  const { fake, stripe } = await paidTenant();

  await send('charge.dispute.created', dispute());
  await send('charge.dispute.funds_withdrawn', dispute());
  await send('charge.dispute.created', dispute()); // redelivery
  await send('charge.dispute.updated', dispute({ status: 'under_review' }));
  await send('charge.dispute.closed', dispute({ status: 'lost' }));
  await send('charge.dispute.closed', dispute({ status: 'lost' })); // redelivery

  assert.deepEqual(disputeRows(fake), ['dispute_du_1']);
  assert.equal(fake.writesTo(`${LEDGERS}/dispute_du_1`).length, 1);
  const entry = fake.read(`${LEDGERS}/dispute_du_1`)!;
  assert.equal(entry.amount, 42);
  assert.equal(entry.type, 'dispute');
  assert.equal(entry.tenantId, 't1');
  assert.equal(entry.referenceId, 'stripe_pi_1');
  assert.equal((entry.metadata as Record<string, unknown>).connectedAccountId, ACCOUNT);
  // The money is gone again, so the tenant owes it again.
  assert.equal(owed(fake), 0);

  const payment = fake.read(`${PAYMENTS}/stripe_pi_1`)!;
  assert.equal(payment.status, 'disputed');
  assert.equal(payment.disputeStatus, 'lost');
  // Every lookup went to the facility's account, never the platform.
  assert.ok(stripe.calls.length > 0);
  assert.ok(stripe.calls.every((c) => c.stripeAccount === ACCOUNT));
});

test('a won dispute is reversed once, leaving the tenant owing nothing', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.created', dispute());
  await send('charge.dispute.funds_withdrawn', dispute());
  await send('charge.dispute.updated', dispute({ status: 'under_review' }));
  await send('charge.dispute.closed', won());
  await send('charge.dispute.funds_reinstated', won());
  await send('charge.dispute.closed', won()); // redelivery

  assert.deepEqual(disputeRows(fake), ['dispute_du_1', 'dispute_du_1_reinstated']);
  // Created once; the one later write only marks it settled by the reversal.
  assert.deepEqual(fake.writesTo(`${LEDGERS}/dispute_du_1`).map((w) => w.op), ['create', 'update']);
  assert.equal(fake.writesTo(`${LEDGERS}/dispute_du_1_reinstated`).length, 1);
  const reversal = fake.read(`${LEDGERS}/dispute_du_1_reinstated`)!;
  assert.equal(reversal.amount, -42);
  assert.equal(reversal.type, 'dispute_reversal');
  assert.equal(reversal.status, 'posted');
  assert.equal(owed(fake), -42);
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.disputeStatus, 'won');
});

test('funds_reinstated reverses the charge even before the dispute reads won', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.funds_withdrawn', dispute());
  await send('charge.dispute.funds_reinstated', dispute({ status: 'under_review' }));

  assert.deepEqual(disputeRows(fake), ['dispute_du_1', 'dispute_du_1_reinstated']);
  assert.equal(owed(fake), -42);
});

test('a dispute closed as won reverses the charge even before its object lists the return', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.funds_withdrawn', dispute());
  await send('charge.dispute.closed', dispute({ status: 'won' }));

  assert.deepEqual(disputeRows(fake), ['dispute_du_1', 'dispute_du_1_reinstated']);
  assert.equal(owed(fake), -42);
});

test('the reversal undoes exactly what was charged', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.funds_withdrawn', dispute());
  // Stripe's later object carries a different amount (a currency or partial change).
  await send('charge.dispute.closed', won({ amount: 5000 }));

  assert.equal(fake.read(`${LEDGERS}/dispute_du_1`)!.amount, 42);
  assert.equal(fake.read(`${LEDGERS}/dispute_du_1_reinstated`)!.amount, -42);
  assert.equal(owed(fake), -42);
});

test('a return delivered before its withdrawal nets to zero, and the late withdrawal adds nothing', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.closed', won());
  await send('charge.dispute.created', dispute());
  await send('charge.dispute.funds_withdrawn', dispute());

  assert.deepEqual(disputeRows(fake), ['dispute_du_1', 'dispute_du_1_reinstated']);
  assert.equal(fake.writesTo(`${LEDGERS}/dispute_du_1`).length, 1);
  assert.equal(owed(fake), -42);
});

test('a return reported before any withdrawal was booked still nets to zero', async () => {
  const { fake } = await paidTenant();

  // Its object does not list the balance transactions yet.
  await send('charge.dispute.funds_reinstated', dispute({ status: 'under_review', balance_transactions: [] }));
  await send('charge.dispute.funds_withdrawn', dispute());

  assert.deepEqual(disputeRows(fake), ['dispute_du_1', 'dispute_du_1_reinstated']);
  assert.equal(owed(fake), -42);
});

test('a dispute that ends without moving money posts no reversal', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.created', dispute({ balance_transactions: [] }));
  await send('charge.dispute.closed', dispute({ status: 'prevented', balance_transactions: [] }));

  assert.deepEqual(disputeRows(fake), []);
  assert.equal(owed(fake), -42);
});

test('concurrent deliveries post each entry once', async () => {
  const { fake } = await paidTenant();

  await Promise.all([
    send('charge.dispute.created', dispute(), undefined, ACCOUNT, 'evt_created'),
    send('charge.dispute.funds_withdrawn', dispute(), undefined, ACCOUNT, 'evt_out'),
    send('charge.dispute.funds_withdrawn', dispute(), undefined, ACCOUNT, 'evt_out'),
  ]);
  assert.deepEqual(disputeRows(fake), ['dispute_du_1']);

  await Promise.all([
    send('charge.dispute.closed', won(), undefined, ACCOUNT, 'evt_closed'),
    send('charge.dispute.funds_reinstated', won(), undefined, ACCOUNT, 'evt_back'),
    send('charge.dispute.funds_reinstated', won(), undefined, ACCOUNT, 'evt_back'),
  ]);

  assert.deepEqual(disputeRows(fake), ['dispute_du_1', 'dispute_du_1_reinstated']);
  assert.deepEqual(fake.writesTo(`${LEDGERS}/dispute_du_1`).map((w) => w.op), ['create', 'update']);
  assert.equal(fake.writesTo(`${LEDGERS}/dispute_du_1_reinstated`).length, 1);
  assert.equal(owed(fake), -42);
});

test('concurrent won and withdrawn deliveries with nothing posted yet still net to zero', async () => {
  const { fake } = await paidTenant();

  await Promise.all([
    send('charge.dispute.funds_withdrawn', dispute()),
    send('charge.dispute.closed', won()),
    send('charge.dispute.funds_reinstated', won()),
  ]);

  assert.deepEqual(disputeRows(fake), ['dispute_du_1', 'dispute_du_1_reinstated']);
  assert.equal(owed(fake), -42);
});

test('the payment shows the status from the newest event, whatever order they arrive in', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.closed', won(), 300);
  await send('charge.dispute.updated', dispute({ status: 'under_review' }), 200); // late redelivery
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.disputeStatus, 'won');

  await send('charge.dispute.updated', won(), 400);
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.disputeStatus, 'won');
});

test('a dispute from an account that is not the facility\'s posts nothing', async () => {
  const { fake, stripe } = await paidTenant();
  // Another facility's owner makes a PaymentIntent naming this facility and tenant.
  stripe.put('acct_other', 'pi_forged', linkPaymentIntent('pi_forged'));
  const writesBefore = writesOutsideRefusals(fake).length;

  await send('charge.dispute.funds_withdrawn', dispute({ id: 'du_forged', payment_intent: 'pi_forged' }), undefined, 'acct_other');

  assert.equal(writesOutsideRefusals(fake).length, writesBefore);
  assert.deepEqual(disputeRows(fake), []);
  // Recorded, since a genuine one would need posting by hand.
  const row = fake.read('stripeWebhookRefusals/acct_other__du_forged')!;
  assert.equal(row.reason, 'unknown_account');
  assert.equal(row.amount, 42);
});

test('a dispute without payment_intent falls back to the charge, on the connected account', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'ch_1', { id: 'ch_1', payment_intent: 'pi_1' });
  stripe.put(ACCOUNT, 'pi_1', linkPaymentIntent('pi_1'));

  await send('charge.dispute.funds_withdrawn', dispute({ payment_intent: null }));

  assert.deepEqual(fake.list(LEDGERS), ['dispute_du_1']);
  assert.deepEqual(stripe.calls.map((c) => [c.resource, c.stripeAccount]), [
    ['charge', ACCOUNT],
    ['payment_intent', ACCOUNT],
  ]);
});

test('a dispute lookup failure fails the webhook instead of being marked processed', async () => {
  setup();
  // PaymentIntent not on the account: Stripe says "No such payment_intent".
  await assert.rejects(send('charge.dispute.created', dispute()), /No such payment_intent/);
});

test('two events from the same second: the later stage wins, whichever arrives last', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.closed', dispute({ status: 'lost' }), 300);
  await send('charge.dispute.updated', dispute({ status: 'under_review' }), 300);
  // Before: under_review, an open dispute on a payment whose dispute had ended.
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.disputeStatus, 'lost');

  await send('charge.dispute.updated', dispute({ status: 'needs_response' }), 400);
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.disputeStatus, 'needs_response');
});

test('a lost dispute charges the tenant even when no withdrawal was ever reported', async () => {
  const { fake } = await paidTenant();

  // No funds_withdrawn event and no balance transactions on the object.
  await send('charge.dispute.created', dispute({ balance_transactions: [] }));
  await send('charge.dispute.closed', dispute({ status: 'lost', balance_transactions: [] }));

  // Before: nothing posted, and the tenant owed nothing for money that was gone.
  assert.deepEqual(disputeRows(fake), ['dispute_du_1']);
  assert.equal(owed(fake), 0);
});

test('a won dispute puts the payment back as it was and marks the charge settled', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.created', dispute());
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'disputed');
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.statusBeforeDispute, 'completed');
  await send('charge.dispute.funds_withdrawn', dispute());
  await send('charge.dispute.closed', won());

  // Before: it stayed 'disputed' for good, and the portal counted it as owed.
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'completed');
  const original = fake.read(`${LEDGERS}/dispute_du_1`)!;
  assert.equal((original.metadata as Record<string, unknown>).allocatedAmount, 42);
  assert.equal((original.metadata as Record<string, unknown>).settledByEntryId, 'dispute_du_1_reinstated');

  // A late redelivery of `created` does not mark it disputed again.
  await send('charge.dispute.created', dispute());
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'completed');
});

test('an inquiry that closes puts the payment back as it was', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.created', inquiry('warning_needs_response'));
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'disputed');
  await send('charge.dispute.closed', inquiry('warning_closed'));

  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'completed');
});

test('a lost dispute leaves the payment disputed', async () => {
  const { fake } = await paidTenant();

  await send('charge.dispute.created', dispute());
  await send('charge.dispute.closed', dispute({ status: 'lost' }));

  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'disputed');
});

test('an unpaid invoice staff made from the dispute is voided when the facility wins; a paid one is left', async () => {
  const { fake } = await paidTenant();
  await send('charge.dispute.funds_withdrawn', dispute());
  // Staff billed the disputed amount by hand, once alone and once with rent.
  fake.seed('facilities/f1/invoices/inv_open', {
    tenantId: 't1',
    invoiceNumber: 'INV-1',
    status: 'sent',
    isActive: true,
    ledgerEntryIds: ['dispute_du_1', 'rent_oct'],
  });
  fake.seed('facilities/f1/invoices/inv_paid', {
    tenantId: 't1',
    invoiceNumber: 'INV-2',
    status: 'paid',
    isActive: true,
    ledgerEntryIds: ['dispute_du_1'],
  });
  fake.seed('facilities/f1/invoices/inv_other', {
    tenantId: 't1',
    invoiceNumber: 'INV-3',
    status: 'sent',
    isActive: true,
    ledgerEntryIds: ['rent_nov'],
  });

  await send('charge.dispute.closed', won());
  await send('charge.dispute.funds_reinstated', won()); // redelivery-safe

  // Before: INV-1 stayed open, asking the tenant for money the facility had back.
  const open = fake.read('facilities/f1/invoices/inv_open')!;
  assert.equal(open.status, 'voided');
  assert.equal(open.isActive, false);
  assert.match(String(open.voidReason), /dispute on this invoice was won/);
  assert.match(String(open.voidReason), /other charges can go on a new invoice/);
  assert.equal(fake.read('facilities/f1/invoices/inv_paid')!.status, 'paid');
  assert.equal(fake.read('facilities/f1/invoices/inv_other')!.status, 'sent');
  const audit = fake
    .list('facilities/f1/auditLogs')
    .map((id) => fake.read(`facilities/f1/auditLogs/${id}`)!)
    .filter((row) => row.action === 'invoice.voided');
  assert.deepEqual(audit.map((row) => row.targetId), ['inv_open']);
});
