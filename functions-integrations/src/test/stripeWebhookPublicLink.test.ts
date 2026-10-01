import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { FakeFirestore, installFakeFirestore } from '@sfc/functions-shared/testing/fakeFirestore';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import {
  ACCOUNT,
  event,
  LEDGERS,
  LINK_PATH,
  linkPaymentIntent,
  linkSession,
  PAYMENTS,
  setup,
} from './support/webhookFakes';

test('checkout.session.completed for a link marks it paid using the event account', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('checkout.session.completed', linkSession('cs_1', 'pi_1'), ACCOUNT));

  const link = fake.read(LINK_PATH)!;
  assert.equal(link.status, 'paid');
  assert.equal(link.paymentIntentId, 'pi_1');
  assert.equal(link.paidVia, 'webhook');
  // The session event never writes money; payment_intent.succeeded does.
  assert.deepEqual(fake.writesTo(LEDGERS), []);
  assert.deepEqual(fake.writesTo(PAYMENTS), []);
});

test('a link session event without the connected account does not mark the link paid', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('checkout.session.completed', linkSession('cs_1', 'pi_1')));
  await dispatchStripeWebhookEvent(event('checkout.session.completed', linkSession('cs_1', 'pi_1'), 'acct_other'));

  assert.equal(fake.read(LINK_PATH)!.status, 'pending');
  // Only the refusal record for the other account's session.
  assert.deepEqual(fake.writes.map((w) => w.path), ['stripeWebhookRefusals/acct_other__cs_1']);
  assert.equal(fake.read('stripeWebhookRefusals/acct_other__cs_1')!.reason, 'unknown_account');
});

test('a Firestore failure on the link branch fails the webhook so Stripe retries', async () => {
  const { fake } = setup();
  fake.beforeCommit = () => {
    throw new Error('UNAVAILABLE: try again');
  };

  await assert.rejects(
    dispatchStripeWebhookEvent(event('checkout.session.completed', linkSession('cs_1', 'pi_1'), ACCOUNT)),
    /UNAVAILABLE/,
  );
  assert.equal(fake.read(LINK_PATH)!.status, 'pending');
});

test('a link payment is recorded once: one payment record and one ledger credit, whatever arrives how often', async () => {
  const { fake } = setup();
  const pi = linkPaymentIntent('pi_1');
  const session = linkSession('cs_1', 'pi_1');

  // Stripe sends both events; either can be redelivered or arrive together.
  await Promise.all([
    dispatchStripeWebhookEvent(event('payment_intent.succeeded', pi, ACCOUNT, 'evt_pi')),
    dispatchStripeWebhookEvent(event('payment_intent.succeeded', pi, ACCOUNT, 'evt_pi')),
    dispatchStripeWebhookEvent(event('checkout.session.completed', session, ACCOUNT, 'evt_cs')),
    dispatchStripeWebhookEvent(event('checkout.session.completed', session, ACCOUNT, 'evt_cs')),
  ]);
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', pi, ACCOUNT, 'evt_pi'));

  assert.deepEqual(fake.list(PAYMENTS), ['stripe_pi_1']);
  const payment = fake.read(`${PAYMENTS}/stripe_pi_1`)!;
  assert.equal(payment.amount, 42);
  assert.equal(payment.tenantId, 't1');
  assert.equal(payment.status, 'completed');
  assert.equal(payment.externalPaymentId, 'pi_1');

  assert.deepEqual(fake.list(LEDGERS), ['payment_pi_1']);
  const credit = fake.read(`${LEDGERS}/payment_pi_1`)!;
  assert.equal(credit.amount, -42);
  assert.equal(credit.tenantId, 't1');
  assert.equal(credit.status, 'posted');
  assert.equal(credit.referenceId, 'stripe_pi_1');

  assert.equal(fake.read(LINK_PATH)!.status, 'paid');
  assert.deepEqual(fake.list('publicPaymentLinkExceptions'), []);
});

test('a second real payment on a paid link is credited (money was taken) and raised as one exception', async () => {
  const { fake } = setup();
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_1'), ACCOUNT));
  await dispatchStripeWebhookEvent(event('checkout.session.completed', linkSession('cs_1', 'pi_1'), ACCOUNT));

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_2'), ACCOUNT));
  await dispatchStripeWebhookEvent(event('checkout.session.completed', linkSession('cs_2', 'pi_2'), ACCOUNT));
  await dispatchStripeWebhookEvent(event('checkout.session.completed', linkSession('cs_2', 'pi_2'), ACCOUNT));

  assert.deepEqual(fake.list(LEDGERS), ['payment_pi_1', 'payment_pi_2']);
  assert.equal(fake.read(LINK_PATH)!.paymentIntentId, 'pi_1');
  assert.deepEqual(fake.list('publicPaymentLinkExceptions'), ['cs_2']);
  assert.equal(fake.read('publicPaymentLinkExceptions/cs_2')!.reason, 'duplicate_payment');
  assert.equal(fake.list('facilities/f1/Notifications').length, 1);
});

test('a Firestore failure recording a link payment fails the webhook; other payments keep the old behaviour', async () => {
  const { fake } = setup();
  const working = fake.firestore();
  const broken = new FakeFirestore();
  broken.firestore = () => ({
    ...working,
    collection: () => {
      throw new Error('UNAVAILABLE: firestore down');
    },
  }) as never;
  installFakeFirestore(broken);

  await assert.rejects(
    dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_1'), ACCOUNT)),
    /UNAVAILABLE/,
  );
  const portalPayment = {
    ...linkPaymentIntent('pi_other'),
    metadata: { facilityId: 'f1', tenantId: 't1', type: 'tenant_portal_payment' },
  } as Stripe.PaymentIntent;
  // Unchanged for everything else: logged and swallowed.
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPayment, ACCOUNT));
});
