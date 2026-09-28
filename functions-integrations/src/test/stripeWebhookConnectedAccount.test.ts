import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { STRIPE_WEBHOOK_REFUSALS_COLLECTION } from '../connectedAccountGuard';
import {
  ACCOUNT,
  captureLogs,
  event,
  LEDGERS,
  linkPaymentIntent,
  PAYMENTS,
  setup,
  writesOutsideRefusals,
} from './support/webhookFakes';

// A Standard account's owner can create a PaymentIntent, SetupIntent or
// account with any metadata, including another facility's id. Only events
// from the facility's own connected account may write to that facility.

function portalPaymentIntent(id: string): Stripe.PaymentIntent {
  return {
    ...linkPaymentIntent(id),
    metadata: { facilityId: 'f1', tenantId: 't1', type: 'tenant_portal_payment' },
  } as Stripe.PaymentIntent;
}

function refundedCharge(id: string, paymentIntent: string): Stripe.Charge {
  return {
    id,
    object: 'charge',
    amount: 4200,
    amount_refunded: 4200,
    payment_intent: paymentIntent,
    refunds: { data: [{ id: `re_${id}`, amount: 4200, status: 'succeeded' }] },
  } as unknown as Stripe.Charge;
}

function savedCard(id: string): Stripe.SetupIntent {
  return {
    id,
    object: 'setup_intent',
    status: 'succeeded',
    customer: 'cus_attacker',
    payment_method: 'pm_attacker',
    metadata: { facilityId: 'f1', tenantId: 't1' },
  } as unknown as Stripe.SetupIntent;
}

function failedPayment(id: string): Stripe.PaymentIntent {
  return {
    ...portalPaymentIntent(id),
    status: 'requires_payment_method',
    last_payment_error: { code: 'card_declined', message: 'Your card was declined.' },
  } as unknown as Stripe.PaymentIntent;
}

const refusal = (fake: ReturnType<typeof setup>['fake'], account: string, objectId: string) =>
  fake.read(`${STRIPE_WEBHOOK_REFUSALS_COLLECTION}/${account}__${objectId}`);

test('a payment made on another account naming this facility credits nothing, and is recorded for a super admin', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', linkPaymentIntent('pi_forged'), 'acct_other', 'evt_1'));
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_forged2'), 'acct_other'));

  assert.deepEqual(writesOutsideRefusals(fake), []);
  assert.deepEqual(fake.list(LEDGERS), []);
  assert.deepEqual(fake.list(PAYMENTS), []);
  const row = refusal(fake, 'acct_other', 'pi_forged')!;
  assert.equal(row.reason, 'unknown_account');
  assert.equal(row.facilityId, 'f1');
  assert.equal(row.tenantId, 't1');
  assert.equal(row.amount, 42);
  assert.equal(row.facilityAccount, ACCOUNT);
  assert.deepEqual(row.eventIds, ['evt_1']);
  assert.equal(row.resolved, false);
  assert.match(String(row.action), /Nothing to post/);
});

test('a connected-account payment for a facility with no connected account is refused', async () => {
  const { fake } = setup();
  fake.seed('facilities/f1', { name: 'Test Storage', stripeConnectAccountId: null });

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_1'), ACCOUNT));

  assert.deepEqual(writesOutsideRefusals(fake), []);
  assert.equal(refusal(fake, ACCOUNT, 'pi_1')!.reason, 'facility_has_no_account');
});

test('a refund on the facility\'s previous account is refused, with what to do about it', async () => {
  const { fake, stripe } = setup();
  fake.seed('facilities/f1', {
    name: 'Test Storage',
    stripeConnectAccountId: 'acct_new',
    stripeConnectPreviousAccountId: ACCOUNT,
  });
  stripe.put(ACCOUNT, 'pi_1', portalPaymentIntent('pi_1'));

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('ch_1', 'pi_1'), ACCOUNT, 'evt_refund'));

  assert.deepEqual(writesOutsideRefusals(fake), []);
  const row = refusal(fake, ACCOUNT, 'ch_1')!;
  assert.equal(row.reason, 'previous_account');
  assert.equal(row.eventType, 'charge.refunded');
  assert.equal(row.amount, 42);
  assert.match(String(row.action), /post it on the tenant ledger by hand/);
});

test('payments on the facility\'s own account, and platform payments, are still credited', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_own'), ACCOUNT));
  // No event.account: the platform's own PaymentIntent, which only this server creates.
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_platform')));

  assert.deepEqual(fake.list(LEDGERS), ['payment_pi_own', 'payment_pi_platform']);
  assert.equal(fake.read(`${LEDGERS}/payment_pi_own`)!.amount, -42);
  assert.deepEqual(fake.list(STRIPE_WEBHOOK_REFUSALS_COLLECTION), []);
});

test('a refund made on another account naming this facility charges the tenant nothing', async () => {
  const { fake, stripe } = setup();
  stripe.put('acct_other', 'pi_forged', portalPaymentIntent('pi_forged'));

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('ch_forged', 'pi_forged'), 'acct_other'));

  assert.deepEqual(writesOutsideRefusals(fake), []);
  assert.equal(refusal(fake, 'acct_other', 'ch_forged')!.reason, 'unknown_account');
});

test('a refund on the facility\'s own account is posted', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'pi_1', portalPaymentIntent('pi_1'));

  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('ch_1', 'pi_1'), ACCOUNT));

  assert.deepEqual(fake.list(LEDGERS), ['refund_re_ch_1']);
  assert.equal(fake.read(`${LEDGERS}/refund_re_ch_1`)!.amount, 42);
});

test('a card saved on another account cannot replace the tenant\'s billing or default card', async () => {
  const { fake, stripe } = setup();
  fake.seed('facilities/f1/tenants/t1/paymentMethods/real', {
    tenantId: 't1',
    facilityId: 'f1',
    stripePaymentMethodId: 'pm_real',
    isDefault: true,
    isActive: true,
    autopayEnabled: true,
  });
  stripe.put('acct_other', 'cus_attacker', { id: 'cus_attacker' });
  stripe.put('acct_other', 'pm_attacker', { id: 'pm_attacker', card: { brand: 'visa', last4: '6666' } });
  const writesBefore = fake.writes.length;

  await dispatchStripeWebhookEvent(event('setup_intent.succeeded', savedCard('seti_forged'), 'acct_other'));

  // Before: billing/default and the tenant's stripe ids pointed at the attacker's
  // customer and card, and the real card lost isDefault.
  assert.equal(fake.writes.length, writesBefore);
  assert.equal(fake.read('facilities/f1/tenants/t1/billing/default'), undefined);
  assert.equal(fake.read('facilities/f1/tenants/t1/paymentMethods/real')!.isDefault, true);
  assert.deepEqual(stripe.calls, []);
  // Nothing to post by hand, so no refusal row either.
  assert.deepEqual(fake.list(STRIPE_WEBHOOK_REFUSALS_COLLECTION), []);
});

test('a card saved on the facility\'s own account is recorded as before', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'cus_attacker', { id: 'cus_attacker' });
  stripe.put(ACCOUNT, 'pm_attacker', { id: 'pm_attacker', card: { brand: 'visa', last4: '4242' } });

  await dispatchStripeWebhookEvent(event('setup_intent.succeeded', savedCard('seti_1'), ACCOUNT));

  assert.equal(fake.read('facilities/f1/tenants/t1/billing/default')!.defaultPaymentMethodId, 'pm_attacker');
  const cards = fake.list('facilities/f1/tenants/t1/paymentMethods');
  assert.equal(cards.length, 1);
  assert.equal(fake.read(`facilities/f1/tenants/t1/paymentMethods/${cards[0]}`)!.last4, '4242');
});

test('a failed payment on another account adds nothing to the facility', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('payment_intent.payment_failed', failedPayment('pi_forged'), 'acct_other'));

  // Before: a 'failed' payment record for tenant t1 appeared in facility f1.
  assert.deepEqual(fake.writes, []);
  assert.deepEqual(fake.list(PAYMENTS), []);
});

test('a failed payment on the facility\'s own account is recorded as before', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('payment_intent.payment_failed', failedPayment('pi_1'), ACCOUNT));

  const records = fake.list(PAYMENTS).map((id) => fake.read(`${PAYMENTS}/${id}`)!);
  assert.deepEqual(records.map((r) => r.status), ['failed']);
});

test('an update from an account the facility no longer uses does not change its Stripe status', async () => {
  const { fake } = setup();
  // Disconnected: the old account still exists and still names the facility.
  fake.seed('facilities/f1', { name: 'Test Storage', stripeConnectAccountId: null, stripeConnectPreviousAccountId: 'acct_old' });
  const oldAccount = {
    id: 'acct_old',
    object: 'account',
    charges_enabled: true,
    payouts_enabled: true,
    details_submitted: true,
    requirements: { currently_due: [], past_due: [] },
    metadata: { facilityId: 'f1' },
  };

  await dispatchStripeWebhookEvent(event('account.updated', oldAccount, 'acct_old'));

  // Before: stripeStatus ENABLED and onboarding complete on a disconnected facility.
  assert.deepEqual(fake.writes, []);

  // Connected to ACCOUNT now: an event from acct_old carrying ACCOUNT's
  // object is still acct_old's, and must not pass as ACCOUNT's.
  fake.seed('facilities/f1', { name: 'Test Storage', stripeConnectAccountId: ACCOUNT });
  await dispatchStripeWebhookEvent(event('account.updated', { ...oldAccount, id: ACCOUNT }, 'acct_old'));
  assert.deepEqual(fake.writes, []);

  fake.seed('facilities/f1', { name: 'Test Storage', stripeConnectAccountId: 'acct_old' });
  await dispatchStripeWebhookEvent(event('account.updated', oldAccount, 'acct_old'));
  assert.equal((fake.read('facilities/f1')!.stripeStatus as Record<string, unknown>).state, 'ENABLED');
});

test('a platform-only event from a connected account reaches no handler', async () => {
  const { fake } = setup();
  const subscription = {
    id: 'sub_forged',
    object: 'subscription',
    status: 'active',
    metadata: { facilityId: 'f1', tenantId: 't1' },
    items: { data: [] },
  };

  await dispatchStripeWebhookEvent(event('customer.subscription.updated', subscription, 'acct_other'));

  // Before: billing/default for tenant t1 was written from the object as sent.
  assert.deepEqual(fake.writes, []);
});

test('a subscription checkout from a connected account adds no facility to any owner account', async () => {
  const { fake } = setup();
  fake.seed('facilityCreatorAccounts/acc_attacker', { facilityIds: [] });
  const session = {
    id: 'cs_sub',
    object: 'checkout.session',
    mode: 'subscription',
    subscription: 'sub_1',
    metadata: { accountId: 'acc_attacker', facilityId: 'f1' },
  };

  await dispatchStripeWebhookEvent(event('checkout.session.completed', session, 'acct_other'));

  assert.deepEqual(fake.writes, []);
  assert.deepEqual(fake.read('facilityCreatorAccounts/acc_attacker')!.facilityIds, []);
});

test('a connected account\'s test-mode event is refused in production, whatever it is', async () => {
  const { fake, stripe } = setup();
  stripe.put(ACCOUNT, 'pi_1', portalPaymentIntent('pi_1'));

  // From the facility's own account: its test key makes these for free.
  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_test'), ACCOUNT, undefined, false));
  await dispatchStripeWebhookEvent(event('charge.refunded', refundedCharge('ch_test', 'pi_1'), ACCOUNT, undefined, false));
  await dispatchStripeWebhookEvent(event('setup_intent.succeeded', savedCard('seti_test'), ACCOUNT, undefined, false));

  // Before: ledgers/payment_pi_test credited the tenant on the live books.
  assert.deepEqual(fake.writes, []);
  assert.deepEqual(stripe.calls, []);
});

test('test-mode connected events are accepted where the deployment says so, and in the emulator', async () => {
  for (const [name, value] of [
    ['STRIPE_ACCEPT_TEST_MODE_EVENTS', 'true'],
    ['FUNCTIONS_EMULATOR', 'true'],
  ] as const) {
    const before = process.env[name];
    process.env[name] = value;
    try {
      const { fake } = setup();
      await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_test'), ACCOUNT, undefined, false));
      assert.deepEqual(fake.list(LEDGERS), ['payment_pi_test'], name);
    } finally {
      if (before === undefined) delete process.env[name];
      else process.env[name] = before;
    }
  }
});

test('the platform\'s own test-mode objects are not refused as connected-account events', async () => {
  const { fake } = setup();

  await dispatchStripeWebhookEvent(event('payment_intent.succeeded', portalPaymentIntent('pi_platform'), undefined, undefined, false));

  assert.deepEqual(fake.list(LEDGERS), ['payment_pi_platform']);
});

test('a tenant checkout completing on the facility\'s account is not logged as an error', async () => {
  setup();
  // Portal payments, online move-ins and tenant payment checkouts complete on
  // the facility's account and are recorded from payment_intent.succeeded.
  const portal = {
    id: 'cs_portal',
    object: 'checkout.session',
    mode: 'payment',
    metadata: { facilityId: 'f1', tenantId: 't1', type: 'tenant_portal_payment' },
  };
  const subscription = {
    id: 'cs_sub',
    object: 'checkout.session',
    mode: 'subscription',
    metadata: { accountId: 'acc_1', facilityId: 'f1' },
  };

  const portalLogs = await captureLogs(() =>
    dispatchStripeWebhookEvent(event('checkout.session.completed', portal, ACCOUNT)),
  );
  const subscriptionLogs = await captureLogs(() =>
    dispatchStripeWebhookEvent(event('checkout.session.completed', subscription, ACCOUNT)),
  );

  // Before: every portal payment, move-in and tenant checkout raised an ERROR.
  assert.deepEqual(portalLogs.filter((l) => l.severity === 'ERROR'), []);
  assert.ok(portalLogs.some((l) => l.message.includes('left to its own handler')));
  assert.ok(
    subscriptionLogs.some(
      (l) => l.severity === 'ERROR' && l.message.includes('Subscription checkout from a connected account ignored'),
    ),
  );
});
