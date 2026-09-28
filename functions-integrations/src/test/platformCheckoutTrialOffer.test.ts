/**
 * One trial and one free month per owner, ever. Drives the real checkout logic
 * (`executeCreateSubscriptionCheckout`, `executeCreateFacilitySubscriptionCheckout`)
 * and the subscription webhook writers against a fake Firestore and a fake Stripe
 * client. No network, no real keys; all data is fake.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import type * as functions from 'firebase-functions/v1';
import type Stripe from 'stripe';
import { FIRST_MONTH_FREE_COUPON_ID } from '@sfc/functions-shared';
import { executeCreateSubscriptionCheckout } from '../stripePlatformAccountSubscriptionCheckoutLogic';
import { executeCreateFacilitySubscriptionCheckout } from '../stripePlatformFacilitySubscriptionCheckoutLogic';
import {
  recordPlatformOfferUsage,
  updateAccountFromSubscription,
  updateFacilityFromPlatformSubscription,
} from '../stripeWebhookSubscriptionInternal';
import { platformOfferUsageFromCheckoutSession } from '../stripeWebhookCheckoutCompleted';
import { FakeFirestore } from './support/fakeFirestore';

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const NOW = Date.parse('2026-10-01T12:00:00Z');
const UID = 'uid_fake_owner';
const ACCOUNT = 'acct_fake_1';
const context = { auth: { uid: UID } } as unknown as functions.https.CallableContext;
const ts = (ms: number) => admin.firestore.Timestamp.fromMillis(ms);

delete process.env.STRIPE_BASE_PRICE_ID;
delete process.env.STRIPE_ADDON_PRICE_ID;

type FakeStripe = {
  stripe: Stripe;
  sessions: Stripe.Checkout.SessionCreateParams[];
  subscriptions: Map<string, Partial<Stripe.Subscription>>;
};

function fakeStripe(): FakeStripe {
  const sessions: Stripe.Checkout.SessionCreateParams[] = [];
  const subscriptions = new Map<string, Partial<Stripe.Subscription>>();
  const stripe = {
    customers: { create: async () => ({ id: 'cus_fake_new' }) },
    prices: {
      list: async (p: { lookup_keys: string[] }) => ({
        data: [{ id: `price_fake_${p.lookup_keys[0]}`, active: true }],
      }),
    },
    coupons: {
      retrieve: async (id: string) => ({ id, valid: true, percent_off: 100, duration: 'once' }),
      create: async () => {
        throw new Error('fake stripe: coupon should already exist');
      },
    },
    checkout: {
      sessions: {
        create: async (params: Stripe.Checkout.SessionCreateParams) => {
          sessions.push(params);
          return { id: `cs_fake_${sessions.length}`, url: `https://checkout.example.test/${sessions.length}` };
        },
      },
    },
    subscriptions: {
      list: async () => ({ data: [] }),
      retrieve: async (id: string) => {
        const sub = subscriptions.get(id);
        if (!sub) throw Object.assign(new Error('No such subscription'), { code: 'resource_missing' });
        return sub;
      },
    },
  } as unknown as Stripe;
  return { stripe, sessions, subscriptions };
}

const noAudit = async () => {};

function world(account: Record<string, unknown>, facilities: Record<string, Record<string, unknown>> = { fac_fake_1: {} }) {
  const seed: Record<string, Record<string, unknown>> = {
    [`facilityCreatorAccounts/${ACCOUNT}`]: { ownerUid: UID, facilityIds: Object.keys(facilities), ...account },
  };
  for (const [id, data] of Object.entries(facilities)) {
    seed[`facilities/${id}`] = { ownerUid: UID, facilityCreatorAccountId: ACCOUNT, name: `Fake ${id}`, ...data };
  }
  const db = new FakeFirestore(seed);
  const s = fakeStripe();
  const deps = { db: db.asFirestore(), stripe: s.stripe, auditLog: noAudit, nowMs: () => NOW };
  return { db, ...s, deps };
}

async function accountCheckout(w: ReturnType<typeof world>) {
  await executeCreateSubscriptionCheckout({ accountId: ACCOUNT, customerEmail: 'owner@example.test' }, context, w.deps);
  return w.sessions[w.sessions.length - 1];
}

async function facilityCheckout(w: ReturnType<typeof world>, facilityId = 'fac_fake_1') {
  await executeCreateFacilitySubscriptionCheckout(
    { accountId: ACCOUNT, facilityId, customerEmail: 'owner@example.test' },
    context,
    w.deps,
  );
  return w.sessions[w.sessions.length - 1];
}

function offerOf(params: Stripe.Checkout.SessionCreateParams) {
  const sd = params.subscription_data ?? {};
  return {
    trial_end: sd.trial_end,
    trial_period_days: sd.trial_period_days,
    coupon: (params.discounts ?? []).map((d) => d.coupon),
  };
}

const COUPON = [FIRST_MONTH_FREE_COUPON_ID];
const runningAppTrial = (end = NOW + 20 * DAY) => ({
  subscriptionStatus: 'trialing',
  subscriptionTrialEnd: ts(end),
  platformTrialUsedAt: ts(end - 30 * DAY),
});

// --- Account checkout ------------------------------------------------------------------

test('account: app trial running -> trial_end = app trial end + coupon', async () => {
  const end = NOW + 20 * DAY;
  const params = await accountCheckout(world(runningAppTrial(end)));
  assert.deepEqual(offerOf(params), { trial_end: Math.floor(end / 1000), trial_period_days: undefined, coupon: COUPON });
  assert.equal(params.subscription_data?.metadata?.firstMonthFreeCoupon, 'true');
});

test('account: app trial ended (swept to cancelled) -> no trial + coupon', async () => {
  const params = await accountCheckout(
    world({
      subscriptionStatus: 'cancelled',
      subscriptionTrialEnd: ts(NOW - 5 * DAY),
      trialExpiredAt: ts(NOW - 5 * DAY),
      stripeCustomerId: 'cus_fake_abandoned',
    }),
  );
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: undefined, coupon: COUPON });
});

test('account: brand-new card-at-signup owner -> 30 days + coupon', async () => {
  const params = await accountCheckout(world({ subscriptionStatus: 'pendingApproval' }));
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: 30, coupon: COUPON });
});

test('account: pastDue with an old trial end -> no fresh trial, no coupon', async () => {
  const params = await accountCheckout(
    world({
      subscriptionStatus: 'pastDue',
      subscriptionTrialEnd: ts(NOW - 40 * DAY),
      stripeCustomerId: 'cus_fake_1',
      stripeSubscriptionId: 'sub_fake_pastdue',
    }),
  );
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: undefined, coupon: [] });
  assert.equal(params.discounts, undefined);
  assert.equal(params.subscription_data?.metadata?.firstMonthFreeCoupon, 'false');
});

test('account: subscribe, cancel, resubscribe -> the second checkout has no trial and no coupon', async () => {
  const w = world({ subscriptionStatus: 'pendingApproval' });

  // 1. First checkout: the full offer.
  const first = await accountCheckout(w);
  assert.deepEqual(offerOf(first), { trial_end: undefined, trial_period_days: 30, coupon: COUPON });

  // 2. Stripe creates the subscription; the webhook mirrors it and sets the markers.
  const trialEndSec = Math.floor((NOW + 30 * DAY) / 1000);
  w.subscriptions.set('sub_fake_first', {
    id: 'sub_fake_first',
    status: 'trialing',
    trial_end: trialEndSec,
    cancel_at_period_end: false,
    canceled_at: null,
    metadata: { ...(first.subscription_data?.metadata as Record<string, string>) },
    discounts: ['di_fake_1'],
  });
  await updateAccountFromSubscription(ACCOUNT, 'sub_fake_first', { db: w.deps.db, stripe: w.stripe });
  const afterSubscribe = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.ok(afterSubscribe.platformTrialUsedAt, 'trial marker set');
  assert.ok(afterSubscribe.platformFirstMonthFreeUsedAt, 'coupon marker set');

  // 3. Cancelled: what the deleted webhook plus reconcile write.
  await w.deps.db.collection('facilityCreatorAccounts').doc(ACCOUNT).update({
    subscriptionStatus: 'cancelled',
    subscriptionCanceledAt: ts(NOW),
    stripeSubscriptionId: null,
    stripeSubscriptionIdClearedFrom: 'sub_fake_first',
  });

  // 4. Resubscribe.
  const second = await accountCheckout(w);
  assert.deepEqual(offerOf(second), { trial_end: undefined, trial_period_days: undefined, coupon: [] });
});

// --- Facility checkout -----------------------------------------------------------------

test('facility: app trial running -> trial_end = app trial end + coupon', async () => {
  const end = NOW + 12 * DAY;
  const params = await facilityCheckout(world(runningAppTrial(end)));
  assert.deepEqual(offerOf(params), { trial_end: Math.floor(end / 1000), trial_period_days: undefined, coupon: COUPON });
});

test('facility: app trial with under 48h left -> no trial + coupon', async () => {
  const params = await facilityCheckout(world(runningAppTrial(NOW + 30 * HOUR)));
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: undefined, coupon: COUPON });
});

test('facility: app trial ended -> no trial + coupon', async () => {
  const params = await facilityCheckout(world({ subscriptionStatus: 'cancelled', subscriptionTrialEnd: ts(NOW - DAY) }));
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: undefined, coupon: COUPON });
});

test('facility: brand-new card-at-signup owner -> 30 days + coupon', async () => {
  const params = await facilityCheckout(world({ subscriptionStatus: 'pendingApproval' }));
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: 30, coupon: COUPON });
});

test('facility: referred brand-new owner -> referral trial days + coupon', async () => {
  const params = await facilityCheckout(
    world({ subscriptionStatus: 'pendingApproval' }, { fac_fake_1: { platformReferralReferredByAccountId: 'acct_fake_referrer' } }),
  );
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: 30, coupon: COUPON });
});

test('facility: referred owner inside a running app trial -> app trial end, not referral days', async () => {
  const end = NOW + 20 * DAY;
  const params = await facilityCheckout(
    world(runningAppTrial(end), { fac_fake_1: { platformReferralReferredByAccountId: 'acct_fake_referrer' } }),
  );
  assert.deepEqual(offerOf(params), { trial_end: Math.floor(end / 1000), trial_period_days: undefined, coupon: COUPON });
});

test("facility: the facility's own old trial record blocks a new trial and the coupon", async () => {
  const params = await facilityCheckout(
    world(
      { subscriptionStatus: 'cancelled' },
      { fac_fake_1: { platformSubscriptionStatus: 'cancelled', platformSubscriptionTrialEnd: ts(NOW - 60 * DAY) } },
    ),
  );
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: undefined, coupon: [] });
});

test('facility: pastDue account with an existing trial end -> no fresh trial, no coupon', async () => {
  const params = await facilityCheckout(
    world({ subscriptionStatus: 'pastDue', subscriptionTrialEnd: ts(NOW - 40 * DAY), stripeCustomerId: 'cus_fake_1' }),
  );
  assert.deepEqual(offerOf(params), { trial_end: undefined, trial_period_days: undefined, coupon: [] });
});

test('facility: subscribe, cancel, resubscribe -> no trial and no coupon the second time', async () => {
  const w = world({ subscriptionStatus: 'pendingApproval' });
  const first = await facilityCheckout(w);
  assert.deepEqual(offerOf(first), { trial_end: undefined, trial_period_days: 30, coupon: COUPON });

  w.subscriptions.set('sub_fake_fac', {
    id: 'sub_fake_fac',
    status: 'trialing',
    trial_end: Math.floor((NOW + 30 * DAY) / 1000),
    cancel_at_period_end: false,
    metadata: { ...(first.subscription_data?.metadata as Record<string, string>) },
    discounts: [],
  });
  await updateFacilityFromPlatformSubscription('fac_fake_1', 'sub_fake_fac', { db: w.deps.db, stripe: w.stripe });
  const account = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.ok(account.platformTrialUsedAt && account.platformFirstMonthFreeUsedAt, 'both markers set from the facility subscription');

  // Cancelled: what the deleted webhook writes on the facility.
  await w.deps.db.collection('facilities').doc('fac_fake_1').update({
    platformSubscriptionStatus: 'cancelled',
    platformSubscriptionCancelledAt: ts(NOW),
    stripePlatformSubscriptionId: admin.firestore.FieldValue.delete(),
  });
  const second = await facilityCheckout(w);
  assert.deepEqual(offerOf(second), { trial_end: undefined, trial_period_days: undefined, coupon: [] });
});

// --- Webhook writers ---------------------------------------------------------------------

test('webhook: a subscription with no trial never nulls an existing subscriptionTrialEnd', async () => {
  const oldTrialEnd = ts(NOW - 10 * DAY);
  const w = world({ subscriptionStatus: 'cancelled', subscriptionTrialEnd: oldTrialEnd });
  w.subscriptions.set('sub_fake_notrial', {
    id: 'sub_fake_notrial',
    status: 'active',
    trial_end: null,
    cancel_at_period_end: false,
    canceled_at: null,
    metadata: { accountId: ACCOUNT, firstMonthFreeCoupon: 'true' },
    discounts: [],
  });
  await updateAccountFromSubscription(ACCOUNT, 'sub_fake_notrial', { db: w.deps.db, stripe: w.stripe });
  const account = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.equal(account.subscriptionStatus, 'active');
  assert.equal(account.stripeSubscriptionId, 'sub_fake_notrial');
  assert.equal((account.subscriptionTrialEnd as admin.firestore.Timestamp).toMillis(), oldTrialEnd.toMillis());
  assert.ok(account.platformFirstMonthFreeUsedAt, 'coupon marker set from subscription metadata');
  assert.equal(account.platformTrialUsedAt, undefined, 'no trial on this subscription');
});

test('webhook: a trial subscription writes its trial end and the trial marker; existing markers are kept', async () => {
  const firstUse = ts(NOW - 100 * DAY);
  const w = world({ platformFirstMonthFreeUsedAt: firstUse });
  const trialEndSec = Math.floor((NOW + 5 * DAY) / 1000);
  w.subscriptions.set('sub_fake_trial', {
    id: 'sub_fake_trial',
    status: 'trialing',
    trial_end: trialEndSec,
    cancel_at_period_end: false,
    metadata: { accountId: ACCOUNT, firstMonthFreeCoupon: 'true' },
    discounts: [],
  });
  await updateAccountFromSubscription(ACCOUNT, 'sub_fake_trial', { db: w.deps.db, stripe: w.stripe });
  const account = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.equal((account.subscriptionTrialEnd as admin.firestore.Timestamp).toMillis(), trialEndSec * 1000);
  assert.ok(account.platformTrialUsedAt);
  assert.equal((account.platformFirstMonthFreeUsedAt as admin.firestore.Timestamp).toMillis(), firstUse.toMillis());
});

test('webhook: a facility subscription with no trial keeps the facility trial end', async () => {
  const oldTrialEnd = ts(NOW - 50 * DAY);
  const w = world({}, { fac_fake_1: { platformSubscriptionTrialEnd: oldTrialEnd } });
  w.subscriptions.set('sub_fake_fac2', {
    id: 'sub_fake_fac2',
    status: 'active',
    trial_end: null,
    cancel_at_period_end: false,
    metadata: { accountId: ACCOUNT, facilityId: 'fac_fake_1', firstMonthFreeCoupon: 'false' },
    discounts: [],
  });
  await updateFacilityFromPlatformSubscription('fac_fake_1', 'sub_fake_fac2', { db: w.deps.db, stripe: w.stripe });
  const facility = w.db.read('facilities/fac_fake_1')!;
  assert.equal(facility.platformSubscriptionStatus, 'active');
  assert.equal((facility.platformSubscriptionTrialEnd as admin.firestore.Timestamp).toMillis(), oldTrialEnd.toMillis());
  const account = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.equal(account.platformFirstMonthFreeUsedAt, undefined);
  assert.equal(account.platformTrialUsedAt, undefined);
});

test('webhook: a completed checkout with the coupon sets the free-month marker once', async () => {
  const session = {
    metadata: { accountId: ACCOUNT },
    discounts: [{ coupon: FIRST_MONTH_FREE_COUPON_ID, promotion_code: null }],
  } as unknown as Stripe.Checkout.Session;
  assert.deepEqual(platformOfferUsageFromCheckoutSession(session), { trialUsed: false, firstMonthFreeUsed: true });
  assert.deepEqual(
    platformOfferUsageFromCheckoutSession({ metadata: { firstMonthFreeCoupon: 'false' }, discounts: [] } as unknown as Stripe.Checkout.Session),
    { trialUsed: false, firstMonthFreeUsed: false },
  );

  const w = world({});
  await recordPlatformOfferUsage(w.deps.db, ACCOUNT, platformOfferUsageFromCheckoutSession(session));
  const first = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!.platformFirstMonthFreeUsedAt;
  assert.ok(first);
  await w.deps.db.collection('facilityCreatorAccounts').doc(ACCOUNT).update({ platformFirstMonthFreeUsedAt: ts(1) });
  await recordPlatformOfferUsage(w.deps.db, ACCOUNT, platformOfferUsageFromCheckoutSession(session));
  assert.equal(
    (w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!.platformFirstMonthFreeUsedAt as admin.firestore.Timestamp).toMillis(),
    1,
    'an existing marker is never overwritten',
  );
});
