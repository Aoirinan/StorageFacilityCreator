/**
 * A card payment disputed as `fraudulent` switches the tenant's autopay off.
 *
 * The cardholder has told their bank they never made the charge. Autopay
 * kept charging next month's rent to the saved card: a second charge on a
 * card that may be stolen, disputed in turn. Now autopay is disarmed once
 * per dispute, staff are told how to turn it back on, and the tenant cannot
 * turn it back on from the portal until staff do.
 *
 * Runs the deployed webhook dispatch and setTenantAutopay against an
 * in-memory Firestore. Made-up ids only: this repo is public.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { getStripeClient } from '@sfc/functions-shared';
import { dispatchStripeWebhookEvent } from '../stripeWebhook';
import { fraudDisputeAutopayNotificationId, LEGACY_SUBSCRIPTION_NOT_CANCELLED_NOTE } from '../disputeFraudAutopayPause';
import { portalAutopayPausedForDispute } from '../stripeFacilityTenantPortalAutopay';
import { setTenantAutopay } from '../stripeFacilityAutopaySet';
import { ACCOUNT, event, linkPaymentIntent, setup } from './support/webhookFakes';

const OWNER = 'owner_uid';
const CARD = 'facilities/f1/tenants/t1/paymentMethods/card_1';
const TENANT = 'facilities/f1/tenants/t1';
const NOTICE = `facilities/f1/Notifications/${fraudDisputeAutopayNotificationId('du_1')}`;

function dispute(overrides: Record<string, unknown> = {}): Stripe.Dispute {
  return {
    id: 'du_1',
    object: 'dispute',
    amount: 4200,
    charge: 'ch_1',
    payment_intent: 'pi_1',
    reason: 'fraudulent',
    status: 'needs_response',
    balance_transactions: [],
    ...overrides,
  } as unknown as Stripe.Dispute;
}

/** Tenant t1 with autopay armed on card_1, and a $42 payment pi_1 on the facility's account. */
function armedTenant(options: { disputeLedger?: boolean } = {}) {
  const ctx = setup({}, options);
  ctx.fake.seed('facilities/f1', { ...ctx.fake.read('facilities/f1')!, ownerUid: OWNER });
  ctx.fake.seed(TENANT, {
    name: 'Pat Tenant',
    monthlyRate: 42,
    stripe: { defaultPaymentMethodId: 'pm_card_1' },
    autopay: { requested: true, enabled: true, status: 'ON' },
  });
  ctx.fake.seed(CARD, {
    tenantId: 't1',
    facilityId: 'f1',
    stripePaymentMethodId: 'pm_card_1',
    isActive: true,
    isDefault: true,
    autopayEnabled: true,
    autopaySchedule: { frequency: 'monthly', dayOfMonth: 1 },
  });
  ctx.fake.seed(`${TENANT}/billing/default`, { autopayEnabled: true });
  ctx.stripe.put(ACCOUNT, 'pi_1', linkPaymentIntent('pi_1'));
  return ctx;
}

/** What the nightly autopay job selects (functions-automation autopayScheduled.ts). */
async function cardsAutopayWouldCharge(fake: ReturnType<typeof setup>['fake']) {
  const snap = await fake
    .firestore()
    .collectionGroup('paymentMethods')
    .where('facilityId', '==', 'f1')
    .where('autopayEnabled', '==', true)
    .where('isActive', '==', true)
    .get();
  return snap.docs.map((d) => d.ref.path);
}

test('a fraudulent dispute switches autopay off, and tells staff how to turn it back on', async () => {
  const { fake } = armedTenant();
  assert.deepEqual(await cardsAutopayWouldCharge(fake), [CARD]);

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));

  // Before: next month's rent went on the card the cardholder says is not theirs.
  assert.deepEqual(await cardsAutopayWouldCharge(fake), []);
  const card = fake.read(CARD)!;
  assert.equal(card.autopayEnabled, false);
  assert.equal(card.autopayPausedForDisputeId, 'du_1');
  assert.match(String(card.autopayDisabledReason), /did not make a \$42\.00 charge/);
  assert.equal(fake.read(`${TENANT}/billing/default`)!.autopayEnabled, false);
  const autopay = fake.read(TENANT)!.autopay as Record<string, unknown>;
  assert.equal(autopay.enabled, false);
  assert.equal(autopay.status, 'OFF');
  assert.equal(autopay.pausedForDisputeId, 'du_1');
  assert.equal(autopay.updatedBy, 'SYSTEM');
  const notice = fake.read(NOTICE)!;
  assert.equal(notice.type, 'STRIPE_ACTION_REQUIRED');
  assert.equal(notice.tenantId, 't1');
  assert.match(String(notice.message), /Autopay was turned off for Pat Tenant/);
  assert.match(String(notice.message), /Autopay switch on the tenant's page/);
  assert.equal(fake.read('facilities/f1/AutopayEvents/fraudDispute_du_1')!.action, 'DISABLED');
  assert.equal(portalAutopayPausedForDispute(fake.read(TENANT)), true);
});

test('autopay is switched off even while the dispute ledger switch is off', async () => {
  const { fake } = armedTenant({ disputeLedger: false });

  const outcome = await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));

  assert.deepEqual(outcome, { held: true });
  assert.deepEqual(await cardsAutopayWouldCharge(fake), []);
  assert.ok(fake.read(NOTICE));
});

test('later events for the same dispute do not switch autopay off again once staff turned it back on', async () => {
  const { fake } = armedTenant();
  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));
  // Staff spoke to the tenant and re-armed the card.
  fake.seed(CARD, { ...fake.read(CARD)!, autopayEnabled: true });

  await dispatchStripeWebhookEvent(event('charge.dispute.updated', dispute({ status: 'under_review' }), ACCOUNT));
  await dispatchStripeWebhookEvent(event('charge.dispute.closed', dispute({ status: 'lost', balance_transactions: [{ amount: -4200 }] }), ACCOUNT));

  assert.deepEqual(await cardsAutopayWouldCharge(fake), [CARD]);
  assert.equal(fake.writesTo(NOTICE).length, 1);
});

test('a dispute for any other reason leaves autopay alone', async () => {
  const { fake } = armedTenant();

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute({ reason: 'product_not_received' }), ACCOUNT));

  assert.deepEqual(await cardsAutopayWouldCharge(fake), [CARD]);
  assert.equal(fake.read(NOTICE), undefined);
});

test('staff turning autopay back on from the tenant page clears the pause', async () => {
  const { fake } = armedTenant();
  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.accounts.retrieve = async () => ({ id: ACCOUNT, charges_enabled: true });
  const run = (setTenantAutopay as unknown as {
    run: (data: unknown, context: unknown) => Promise<Record<string, unknown>>;
  }).run;

  const result = await run(
    { facilityId: 'f1', tenantId: 't1', enabled: true, source: 'FACILITY' },
    { auth: { uid: OWNER }, app: { appId: 'test' } },
  );

  assert.equal(result.enabled, true);
  assert.deepEqual(await cardsAutopayWouldCharge(fake), [CARD]);
  assert.equal((fake.read(TENANT)!.autopay as Record<string, unknown>).pausedForDisputeId, null);
  assert.equal(portalAutopayPausedForDispute(fake.read(TENANT)), false);
});

test('the portal pause reads only a dispute id', () => {
  assert.equal(portalAutopayPausedForDispute(undefined), false);
  assert.equal(portalAutopayPausedForDispute({ autopay: { pausedForDisputeId: null } }), false);
  assert.equal(portalAutopayPausedForDispute({ autopay: { pausedForDisputeId: '' } }), false);
  assert.equal(portalAutopayPausedForDispute({ autopay: { pausedForDisputeId: 'du_1' } }), true);
});

// The tenant's legacy AutoPay subscription on the platform account.

const BILLING = `${TENANT}/billing/default`;

/**
 * Stripe's subscription calls on the platform client: cancel answers as
 * [cancel] says, and retrieve finds what FakeStripeObjects holds.
 */
function legacyStripe(cancel: (id: string) => Promise<unknown>) {
  const calls: string[] = [];
  const client = getStripeClient() as unknown as Record<string, Record<string, unknown>>;
  client.subscriptions.cancel = async (id: string) => {
    calls.push(id);
    return cancel(id);
  };
  return calls;
}

test('a fraudulent dispute also cancels the legacy AutoPay subscription that would charge the card, and drops its id', async () => {
  const { fake } = armedTenant();
  fake.seed(BILLING, { autopayEnabled: true, stripeSubscriptionId: 'sub_legacy' });
  const cancelled = legacyStripe(async (id) => ({ id, status: 'canceled' }));

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));

  // Before: the cards were disarmed and the subscription kept charging the reported card.
  assert.deepEqual(cancelled, ['sub_legacy']);
  const billing = fake.read(BILLING)!;
  assert.equal(billing.stripeSubscriptionId, undefined);
  assert.equal(billing.autopayEnabled, false);
  const notice = fake.read(NOTICE)!;
  assert.equal((notice.metadata as Record<string, unknown>).legacySubscriptionId, 'sub_legacy');
  assert.equal((notice.metadata as Record<string, unknown>).legacySubscriptionCancelled, true);
  assert.doesNotMatch(String(notice.message), /could not be cancelled/);
});

test('a legacy subscription alone counts as autopay being on', async () => {
  const { fake } = armedTenant();
  fake.seed(CARD, { ...fake.read(CARD)!, autopayEnabled: false });
  fake.seed(BILLING, { autopayEnabled: false, stripeSubscriptionId: 'sub_legacy' });
  const cancelled = legacyStripe(async (id) => ({ id, status: 'canceled' }));

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));

  assert.deepEqual(cancelled, ['sub_legacy']);
  const notice = fake.read(NOTICE)!;
  // Before: "Autopay was not on", while the subscription charged the card monthly.
  assert.equal((notice.metadata as Record<string, unknown>).autopayWasOn, true);
  assert.match(String(notice.message), /Autopay was turned off for Pat Tenant/);
});

test('a legacy subscription Stripe already ended counts as cancelled', async () => {
  const { fake } = armedTenant();
  fake.seed(BILLING, { autopayEnabled: true, stripeSubscriptionId: 'sub_gone' });
  legacyStripe(async () => {
    throw Object.assign(new Error("No such subscription: 'sub_gone'"), { code: 'resource_missing' });
  });

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));

  assert.equal(fake.read(BILLING)!.stripeSubscriptionId, undefined);
  assert.equal((fake.read(NOTICE)!.metadata as Record<string, unknown>).legacySubscriptionCancelled, true);
});

test('a legacy subscription that could not be cancelled keeps its id, staff are told, and the dispute still posts', async () => {
  const { fake, stripe } = armedTenant();
  fake.seed(BILLING, { autopayEnabled: true, stripeSubscriptionId: 'sub_live' });
  stripe.put(null, 'sub_live', { id: 'sub_live', status: 'active' });
  const cancelled = legacyStripe(async () => {
    throw Object.assign(new Error('Rate limit exceeded'), { type: 'StripeRateLimitError' });
  });

  const outcome = await dispatchStripeWebhookEvent(
    event('charge.dispute.funds_withdrawn', dispute({ balance_transactions: [{ amount: -4200 }] }), ACCOUNT),
  );

  assert.deepEqual(cancelled, ['sub_live']);
  // The id stays where the facility delete refusal and Disable autopay look for it.
  assert.equal(fake.read(BILLING)!.stripeSubscriptionId, 'sub_live');
  const notice = fake.read(NOTICE)!;
  assert.match(String(notice.message), /Autopay was turned off for Pat Tenant/);
  assert.ok(String(notice.message).endsWith(LEGACY_SUBSCRIPTION_NOT_CANCELLED_NOTE));
  assert.equal((notice.metadata as Record<string, unknown>).legacySubscriptionCancelled, false);
  // The cards are still disarmed, and a failed cancel does not hold the dispute back.
  assert.deepEqual(await cardsAutopayWouldCharge(fake), []);
  assert.deepEqual(outcome, { held: false });
  assert.ok(fake.read('facilities/f1/ledgers/dispute_du_1'));
});

test('the legacy subscription is cancelled once per dispute, like the pause', async () => {
  const { fake } = armedTenant();
  fake.seed(BILLING, { autopayEnabled: true, stripeSubscriptionId: 'sub_legacy' });
  const cancelled = legacyStripe(async (id) => ({ id, status: 'canceled' }));

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));
  // Somehow written again: a later event for the same dispute leaves it to staff.
  fake.seed(BILLING, { ...fake.read(BILLING)!, stripeSubscriptionId: 'sub_other' });
  await dispatchStripeWebhookEvent(event('charge.dispute.updated', dispute({ status: 'under_review' }), ACCOUNT));

  assert.deepEqual(cancelled, ['sub_legacy']);
  assert.equal(fake.read(BILLING)!.stripeSubscriptionId, 'sub_other');
});

test('a tenant with no legacy subscription makes no Stripe subscription call', async () => {
  armedTenant();
  const cancelled = legacyStripe(async () => assert.fail('nothing to cancel'));

  await dispatchStripeWebhookEvent(event('charge.dispute.created', dispute(), ACCOUNT));

  assert.deepEqual(cancelled, []);
});
