/**
 * The dispute ledger switch (appConfig/payments.disputeLedgerEnabled).
 *
 * Production's old dispute handler never wrote a connected-account dispute,
 * so this webhook writes the first real dispute rows and `disputed`
 * payments. Autopay, the delinquency job, the portal and the app read them,
 * and each deploys on its own; any of them still on old code would treat a
 * dispute as rent owed (charge it back to the card, add late fees, ask the
 * tenant to pay it again). Until a super admin turns the switch on, nothing
 * is posted, whatever order the codebases deploy in.
 *
 * Runs the deployed webhook dispatch against an in-memory Firestore.
 * Made-up ids only: this repo is public.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { DISPUTE_LEDGER_OFF_REASON, heldDisputeDocId } from '../disputeLedgerGate';
import { ACCOUNT, event, LEDGERS, linkPaymentIntent, PAYMENTS, setup } from './support/webhookFakes';

const WITHDRAWAL = { id: 'txn_out', object: 'balance_transaction', amount: -4200 };

function dispute(overrides: Record<string, unknown> = {}): Stripe.Dispute {
  return {
    id: 'du_1',
    object: 'dispute',
    amount: 4200,
    charge: 'ch_1',
    payment_intent: 'pi_1',
    reason: 'product_not_received',
    status: 'needs_response',
    balance_transactions: [WITHDRAWAL],
    ...overrides,
  } as unknown as Stripe.Dispute;
}

const HELD = `stripeWebhookRefusals/${heldDisputeDocId(ACCOUNT, 'du_1')}`;

/** A tenant who paid $42 through the facility's account; the switch as given. */
async function paidTenant(disputeLedger: boolean) {
  const ctx = setup({}, { disputeLedger });
  ctx.stripe.put(ACCOUNT, 'pi_1', linkPaymentIntent('pi_1'));
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_1'), ACCOUNT));
  return ctx;
}

test('with the switch off, a dispute posts nothing and is held for a super admin', async () => {
  const { fake } = await paidTenant(false);

  const outcome = await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute(), ACCOUNT, 'evt_w'));

  assert.deepEqual(outcome, { held: true });
  assert.deepEqual(fake.list(LEDGERS).filter((id) => id.startsWith('dispute_')), []);
  // The payment is not marked disputed either: the old portal counts that as owed.
  const payment = fake.read(`${PAYMENTS}/stripe_pi_1`)!;
  assert.equal(payment.status, 'completed');
  assert.equal(payment.disputeStatus, undefined);
  const held = fake.read(HELD)!;
  assert.equal(held.reason, DISPUTE_LEDGER_OFF_REASON);
  assert.equal(held.resolved, false);
  assert.equal(held.facilityId, 'f1');
  assert.equal(held.tenantId, 't1');
  assert.equal(held.amount, 42);
  assert.equal(held.paymentIntentId, 'pi_1');
  assert.deepEqual(held.eventIds, ['evt_w']);
  assert.match(String(held.action), /disputeLedgerEnabled/);
});

test('with no config document at all, the switch reads as off', async () => {
  const { fake } = await paidTenant(false);
  assert.equal(fake.read('appConfig/payments'), undefined);

  assert.deepEqual(await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute({ status: 'lost' }), ACCOUNT)), {
    held: true,
  });
  assert.equal(fake.read(`${LEDGERS}/dispute_du_1`), undefined);

  // Set to anything but true: still off.
  fake.seed('appConfig/payments', { disputeLedgerEnabled: 'true' });
  assert.deepEqual(await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute({ status: 'lost' }), ACCOUNT)), {
    held: true,
  });
  assert.equal(fake.read(`${LEDGERS}/dispute_du_1`), undefined);
});

test('once the switch is on, the next event for a held dispute posts it and closes the held row', async () => {
  const { fake } = await paidTenant(false);
  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT, 'evt_c'));
  await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute(), ACCOUNT, 'evt_w'));
  assert.deepEqual(fake.read(HELD)!.eventIds, ['evt_c', 'evt_w']);

  fake.seed('appConfig/payments', { disputeLedgerEnabled: true });
  const outcome = await dispatchStripeWebhookEvent(event('charge.dispute.updated', dispute({ status: 'under_review' }), ACCOUNT));

  assert.deepEqual(outcome, { held: false });
  const row = fake.read(`${LEDGERS}/dispute_du_1`)!;
  assert.equal(row.amount, 42);
  assert.equal(row.tenantId, 't1');
  assert.equal(fake.read(HELD)!.resolved, true);
  assert.equal(fake.read(HELD)!.resolvedBy, 'system@stripe-webhook');
});

test('a dispute whose `created` was held is marked disputed by the first event that posts its withdrawal', async () => {
  for (const [label, next] of [
    ['closed as lost', event('charge.dispute.closed', dispute({ status: 'lost', balance_transactions: [] }), ACCOUNT)],
    ['funds withdrawn', event('charge.dispute.funds_withdrawn', dispute(), ACCOUNT)],
    ['updated, money out', event('charge.dispute.updated', dispute({ status: 'under_review' }), ACCOUNT)],
  ] as const) {
    const { fake } = await paidTenant(false);
    await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute({ balance_transactions: [] }), ACCOUNT));
    assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'completed', label);

    // `created` is not sent again once the switch is on.
    fake.seed('appConfig/payments', { disputeLedgerEnabled: true });
    assert.deepEqual(await dispatchStripeWebhookEvent(next), { held: false }, label);

    assert.equal(fake.read(`${LEDGERS}/dispute_du_1`)!.amount, 42, label);
    const payment = fake.read(`${PAYMENTS}/stripe_pi_1`)!;
    // Before: still `completed`, with the money gone.
    assert.equal(payment.status, 'disputed', label);
    assert.equal(payment.statusBeforeDispute, 'completed', label);
    assert.equal(payment.disputeId, 'du_1', label);
  }
});

test('an event that posts no withdrawal, or one for a dispute the facility won, does not mark the payment disputed', async () => {
  const { fake } = await paidTenant(false);
  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute({ balance_transactions: [] }), ACCOUNT));
  fake.seed('appConfig/payments', { disputeLedgerEnabled: true });

  // An update before any money has moved: nothing to post, nothing to mark.
  await dispatchStripeWebhookEvent(
    event('charge.dispute.updated', dispute({ status: 'under_review', balance_transactions: [] }), ACCOUNT),
  );
  assert.equal(fake.read(`${LEDGERS}/dispute_du_1`), undefined);
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'completed');

  // Won: withdrawn and returned at once, and the payment stands.
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute({ status: 'won' }), ACCOUNT));
  assert.ok(fake.read(`${LEDGERS}/dispute_du_1_reinstated`));
  assert.equal(fake.read(`${PAYMENTS}/stripe_pi_1`)!.status, 'completed');
});

test('with the switch on, dispatch reports nothing held and writes no held row', async () => {
  const { fake } = await paidTenant(true);

  assert.deepEqual(await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute(), ACCOUNT)), {
    held: false,
  });

  assert.ok(fake.read(`${LEDGERS}/dispute_du_1`));
  assert.equal(fake.read(HELD), undefined);
  assert.deepEqual(await dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_2'), ACCOUNT)), {
    held: false,
  });
});

test('a dispute from another account is refused, not held, whatever the switch says', async () => {
  const { fake, stripe } = await paidTenant(false);
  stripe.put('acct_elsewhere', 'pi_1', linkPaymentIntent('pi_1'));

  const outcome = await dispatchStripeWebhookEvent(event('charge.dispute.funds_withdrawn', dispute(), 'acct_elsewhere'));

  assert.deepEqual(outcome, { held: false });
  const refusal = fake.read(`stripeWebhookRefusals/${heldDisputeDocId('acct_elsewhere', 'du_1')}`)!;
  assert.equal(refusal.reason, 'unknown_account');
  assert.equal(fake.read(`${LEDGERS}/dispute_du_1`), undefined);
});
