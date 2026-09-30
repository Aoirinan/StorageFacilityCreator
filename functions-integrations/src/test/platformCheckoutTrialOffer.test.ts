/**
 * One trial and one free month per owner, ever, with the free month delivered as trial
 * time (never a coupon). Drives the real checkout logic (`executeCreateSubscriptionCheckout`,
 * `executeCreateFacilitySubscriptionCheckout`) and the subscription webhook writers
 * against a fake Firestore and a fake Stripe client. No network, no real keys; all data
 * is fake.
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
const FREE_MONTH = 30 * DAY;
const NOW = Date.parse('2026-10-01T12:00:00Z');
const UID = 'uid_fake_owner';
const ACCOUNT = 'acct_fake_1';
const context = { auth: { uid: UID } } as unknown as functions.https.CallableContext;
const ts = (ms: number) => admin.firestore.Timestamp.fromMillis(ms);
const sec = (ms: number) => Math.floor(ms / 1000);

/** The worked example: app trial ends 2026-10-21T03:30Z; subscribing on 2026-10-01 is free until 2026-11-20T03:30Z. */
const EXAMPLE_APP_TRIAL_END = Date.parse('2026-10-21T03:30:00Z');
const EXAMPLE_FREE_MONTH_END = Date.parse('2026-11-20T03:30:00Z');

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
  const noCoupons = async () => {
    throw new Error('fake stripe: checkout must not touch coupons any more');
  };
  const stripe = {
    customers: { create: async () => ({ id: 'cus_fake_new' }) },
    prices: {
      list: async (p: { lookup_keys: string[] }) => ({
        data: [{ id: `price_fake_${p.lookup_keys[0]}`, active: true }],
      }),
    },
    coupons: { retrieve: noCoupons, create: noCoupons },
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

/** What the session offers: the trial fields and any discounts (there must never be any). */
function offerOf(params: Stripe.Checkout.SessionCreateParams) {
  const sd = params.subscription_data ?? {};
  return {
    trial_end: sd.trial_end,
    trial_period_days: sd.trial_period_days,
    discounts: params.discounts,
    firstMonthFree: sd.metadata?.firstMonthFree,
  };
}

/** The session carries the free month: trial_end = `freeMonthStartMs` + 30 days, flagged in metadata, no discounts. */
function assertFreeMonthSession(params: Stripe.Checkout.SessionCreateParams, freeMonthStartMs: number) {
  const trialEnd = sec(freeMonthStartMs + FREE_MONTH);
  assert.deepEqual(offerOf(params), { trial_end: trialEnd, trial_period_days: undefined, discounts: undefined, firstMonthFree: 'true' });
  assert.equal(params.subscription_data?.metadata?.trialDecision, 'free_month');
  assert.equal(params.subscription_data?.metadata?.freeMonthStart, new Date(sec(freeMonthStartMs) * 1000).toISOString());
  assert.equal(params.subscription_data?.metadata?.freeMonthTrialEnd, new Date(trialEnd * 1000).toISOString());
  assert.equal(params.metadata?.firstMonthFree, 'true', 'session metadata flags it for checkout.session.completed');
}

const NOTHING = { trial_end: undefined, trial_period_days: undefined, discounts: undefined, firstMonthFree: 'false' };

const runningAppTrial = (end = NOW + 20 * DAY) => ({
  subscriptionStatus: 'trialing',
  subscriptionTrialEnd: ts(end),
  platformTrialUsedAt: ts(end - 30 * DAY),
});

/** The subscription Stripe would create from these Checkout params. */
function subscriptionFrom(
  id: string,
  params: Stripe.Checkout.SessionCreateParams,
  extra: Partial<Stripe.Subscription> = {},
): Partial<Stripe.Subscription> {
  const trialEnd = params.subscription_data?.trial_end ?? null;
  return {
    id,
    status: trialEnd ? 'trialing' : 'active',
    trial_end: trialEnd,
    trial_start: trialEnd ? sec(NOW) : null,
    cancel_at_period_end: false,
    canceled_at: null,
    metadata: { ...(params.subscription_data?.metadata as Record<string, string>) },
    discounts: [],
    ...extra,
  };
}

// --- Account checkout ------------------------------------------------------------------

test('account: worked example, app trial ends 2026-10-21T03:30Z -> trial_end 2026-11-20T03:30Z, no discounts', async () => {
  const params = await accountCheckout(world(runningAppTrial(EXAMPLE_APP_TRIAL_END)));
  assert.equal(params.subscription_data?.trial_end, sec(EXAMPLE_FREE_MONTH_END));
  assertFreeMonthSession(params, EXAMPLE_APP_TRIAL_END);
  assert.equal(params.subscription_data?.metadata?.freeMonthTrialEnd, '2026-11-20T03:30:00.000Z');
});

test('account: app trial with under 48h left -> app trial end + 30 days', async () => {
  const end = NOW + 30 * HOUR;
  assertFreeMonthSession(await accountCheckout(world(runningAppTrial(end))), end);
});

test('account: app trial ended (swept to cancelled), free month unused -> now + 30 days', async () => {
  const params = await accountCheckout(
    world({
      subscriptionStatus: 'cancelled',
      subscriptionTrialEnd: ts(NOW - 5 * DAY),
      trialExpiredAt: ts(NOW - 5 * DAY),
      stripeCustomerId: 'cus_fake_abandoned',
    }),
  );
  assertFreeMonthSession(params, NOW);
});

test('account: brand-new card-at-signup owner -> 30-day trial then the free month: now + 60 days', async () => {
  assertFreeMonthSession(await accountCheckout(world({ subscriptionStatus: 'pendingApproval' })), NOW + 30 * DAY);
});

test('account: pastDue with an old trial end -> no trial, no free month, no discounts', async () => {
  const params = await accountCheckout(
    world({
      subscriptionStatus: 'pastDue',
      subscriptionTrialEnd: ts(NOW - 40 * DAY),
      stripeCustomerId: 'cus_fake_1',
      stripeSubscriptionId: 'sub_fake_pastdue',
    }),
  );
  assert.deepEqual(offerOf(params), NOTHING);
  assert.equal(params.subscription_data?.metadata?.freeMonthTrialEnd, undefined);
});

test('account: resubscribe after the free month was used, app trial still running -> app trial end only', async () => {
  const end = NOW + 10 * DAY;
  const params = await accountCheckout(world({ ...runningAppTrial(end), platformFirstMonthFreeUsedAt: ts(NOW - DAY) }));
  assert.deepEqual(offerOf(params), { trial_end: sec(end), trial_period_days: undefined, discounts: undefined, firstMonthFree: 'false' });
  assert.equal(params.subscription_data?.metadata?.trialDecision, 'align_to_app_trial');
});

test('account: subscribe, webhook, cancel, resubscribe -> free month marked from metadata; second checkout gets nothing', async () => {
  const w = world(runningAppTrial(EXAMPLE_APP_TRIAL_END));

  // 1. First checkout: the free month as trial time.
  const first = await accountCheckout(w);
  assertFreeMonthSession(first, EXAMPLE_APP_TRIAL_END);

  // 2. Stripe creates the subscription (no discounts); the webhook mirrors it and sets the markers.
  w.subscriptions.set('sub_fake_first', subscriptionFrom('sub_fake_first', first));
  await updateAccountFromSubscription(ACCOUNT, 'sub_fake_first', { db: w.deps.db, stripe: w.stripe });
  const afterSubscribe = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.ok(afterSubscribe.platformTrialUsedAt, 'trial marker kept');
  assert.ok(afterSubscribe.platformFirstMonthFreeUsedAt, 'free-month marker set from subscription metadata');
  assert.equal(afterSubscribe.subscriptionStatus, 'trialing');
  assert.equal(
    (afterSubscribe.subscriptionTrialEnd as admin.firestore.Timestamp).toMillis(),
    EXAMPLE_FREE_MONTH_END,
    'account trial end moves to the end of the free month, so the app keeps access through it',
  );

  // 3. Cancelled: what the deleted webhook plus reconcile write.
  await w.deps.db.collection('facilityCreatorAccounts').doc(ACCOUNT).update({
    subscriptionStatus: 'cancelled',
    subscriptionCanceledAt: ts(NOW),
    stripeSubscriptionId: null,
    stripeSubscriptionIdClearedFrom: 'sub_fake_first',
  });

  // 4. Resubscribe: no fresh trial, no second free month.
  const second = await accountCheckout(w);
  assert.deepEqual(offerOf(second), NOTHING);
});

// --- Facility checkout -----------------------------------------------------------------

test('facility: worked example, app trial ends 2026-10-21T03:30Z -> trial_end 2026-11-20T03:30Z, no discounts', async () => {
  const params = await facilityCheckout(world(runningAppTrial(EXAMPLE_APP_TRIAL_END)));
  assert.equal(params.subscription_data?.trial_end, sec(EXAMPLE_FREE_MONTH_END));
  assertFreeMonthSession(params, EXAMPLE_APP_TRIAL_END);
  assert.equal(params.subscription_data?.metadata?.facilityId, 'fac_fake_1');
});

test('facility: app trial with under 48h left -> app trial end + 30 days', async () => {
  const end = NOW + 30 * HOUR;
  assertFreeMonthSession(await facilityCheckout(world(runningAppTrial(end))), end);
});

test('facility: app trial ended, free month unused -> now + 30 days', async () => {
  assertFreeMonthSession(await facilityCheckout(world({ subscriptionStatus: 'cancelled', subscriptionTrialEnd: ts(NOW - DAY) })), NOW);
});

test('facility: brand-new card-at-signup owner -> now + 60 days', async () => {
  assertFreeMonthSession(await facilityCheckout(world({ subscriptionStatus: 'pendingApproval' })), NOW + 30 * DAY);
});

test('facility: referred brand-new owner -> referral trial days, then the free month', async () => {
  const params = await facilityCheckout(
    world({ subscriptionStatus: 'pendingApproval' }, { fac_fake_1: { platformReferralReferredByAccountId: 'acct_fake_referrer' } }),
  );
  assertFreeMonthSession(params, NOW + 30 * DAY);
});

test('facility: referred owner inside a running app trial -> app trial end + 30 days, not referral days', async () => {
  const end = NOW + 20 * DAY;
  const params = await facilityCheckout(
    world(runningAppTrial(end), { fac_fake_1: { platformReferralReferredByAccountId: 'acct_fake_referrer' } }),
  );
  assertFreeMonthSession(params, end);
});

test("facility: the facility's own old trial record blocks a new trial and the free month", async () => {
  const params = await facilityCheckout(
    world(
      { subscriptionStatus: 'cancelled' },
      { fac_fake_1: { platformSubscriptionStatus: 'cancelled', platformSubscriptionTrialEnd: ts(NOW - 60 * DAY) } },
    ),
  );
  assert.deepEqual(offerOf(params), NOTHING);
});

test('facility: pastDue account with an existing trial end -> no trial, no free month', async () => {
  const params = await facilityCheckout(
    world({ subscriptionStatus: 'pastDue', subscriptionTrialEnd: ts(NOW - 40 * DAY), stripeCustomerId: 'cus_fake_1' }),
  );
  assert.deepEqual(offerOf(params), NOTHING);
});

test('facility: subscribe, webhook, cancel, resubscribe -> no trial and no free month the second time', async () => {
  const w = world({ subscriptionStatus: 'pendingApproval' });
  const first = await facilityCheckout(w);
  assertFreeMonthSession(first, NOW + 30 * DAY);

  w.subscriptions.set('sub_fake_fac', subscriptionFrom('sub_fake_fac', first));
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
  assert.deepEqual(offerOf(second), NOTHING);
});

test('facility: second facility during a running app trial -> the end of facility 1 free month, no second free month', async () => {
  const end = EXAMPLE_APP_TRIAL_END;
  const w = world(runningAppTrial(end), { fac_fake_1: {}, fac_fake_2: {} });

  // Facility 1: the free month, then the webhook mirrors the subscription.
  const first = await facilityCheckout(w, 'fac_fake_1');
  assertFreeMonthSession(first, end);
  w.subscriptions.set('sub_fake_fac1', subscriptionFrom('sub_fake_fac1', first));
  await updateFacilityFromPlatformSubscription('fac_fake_1', 'sub_fake_fac1', { db: w.deps.db, stripe: w.stripe });
  const fac1 = w.db.read('facilities/fac_fake_1')!;
  assert.equal(fac1.platformSubscriptionStatus, 'trialing');
  assert.equal((fac1.platformSubscriptionTrialEnd as admin.firestore.Timestamp).toMillis(), EXAMPLE_FREE_MONTH_END);
  const account = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.ok(account.platformFirstMonthFreeUsedAt, 'free month used by facility 1');
  assert.equal(
    (account.subscriptionTrialEnd as admin.firestore.Timestamp).toMillis(),
    end,
    'a facility subscription leaves the account app trial end alone',
  );
  const markersAfterFirst = { trial: account.platformTrialUsedAt, freeMonth: account.platformFirstMonthFreeUsedAt };

  // Facility 2, still inside the app trial: first charged when the free month ends, like
  // facility 1 (and like a facility added on the account path). No second free month.
  const second = await facilityCheckout(w, 'fac_fake_2');
  assert.deepEqual(offerOf(second), {
    trial_end: sec(EXAMPLE_FREE_MONTH_END),
    trial_period_days: undefined,
    discounts: undefined,
    firstMonthFree: 'false',
  });
  assert.equal(second.subscription_data?.metadata?.trialDecision, 'align_to_free_month');
  assert.equal(second.metadata?.firstMonthFree, 'false');

  // Its webhook uses up nothing new: the markers keep their first values.
  w.subscriptions.set('sub_fake_fac2', subscriptionFrom('sub_fake_fac2', second));
  await updateFacilityFromPlatformSubscription('fac_fake_2', 'sub_fake_fac2', { db: w.deps.db, stripe: w.stripe });
  const after = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.deepEqual({ trial: after.platformTrialUsedAt, freeMonth: after.platformFirstMonthFreeUsedAt }, markersAfterFirst);
  assert.equal(
    (w.db.read('facilities/fac_fake_2')!.platformSubscriptionTrialEnd as admin.firestore.Timestamp).toMillis(),
    EXAMPLE_FREE_MONTH_END,
  );
});

/** Per-facility billing after the app trial: facility 1 is in its free month, the account rolls it up as trialing. */
function freeMonthRunningWorld(freeMonthEndMs: number) {
  const appTrialEnd = freeMonthEndMs - FREE_MONTH;
  return world(
    {
      subscriptionStatus: 'trialing',
      subscriptionTrialEnd: ts(appTrialEnd),
      platformTrialUsedAt: ts(appTrialEnd - 30 * DAY),
      platformFirstMonthFreeUsedAt: ts(NOW - 10 * DAY),
    },
    {
      fac_fake_1: {
        stripePlatformSubscriptionId: 'sub_fake_fac1',
        platformSubscriptionStatus: 'trialing',
        platformSubscriptionTrialEnd: ts(freeMonthEndMs),
      },
      fac_fake_2: {},
    },
  );
}

test('facility: second facility after the app trial, during facility 1 free month -> trial until that free month ends', async () => {
  const freeMonthEnd = NOW - 2 * DAY + FREE_MONTH;
  const params = await facilityCheckout(freeMonthRunningWorld(freeMonthEnd), 'fac_fake_2');
  assert.deepEqual(offerOf(params), {
    trial_end: sec(freeMonthEnd),
    trial_period_days: undefined,
    discounts: undefined,
    firstMonthFree: 'false',
  });
  assert.equal(params.subscription_data?.metadata?.trialDecision, 'align_to_free_month');
  assert.equal(params.subscription_data?.metadata?.freeMonthTrialEnd, undefined);
});

test('facility: second facility when facility 1 free month ends within 48h10m -> no trial', async () => {
  const params = await facilityCheckout(freeMonthRunningWorld(NOW + 48 * HOUR + 5 * 60 * 1000), 'fac_fake_2');
  assert.deepEqual(offerOf(params), NOTHING);
  const later = await facilityCheckout(freeMonthRunningWorld(NOW + 48 * HOUR + 10 * 60 * 1000), 'fac_fake_2');
  assert.equal(later.subscription_data?.trial_end, sec(NOW + 48 * HOUR + 10 * 60 * 1000));
});

test('facility: second facility after facility 1 free month ended (now active) -> no trial, charged now', async () => {
  const w = freeMonthRunningWorld(NOW - DAY);
  await w.deps.db.collection('facilities').doc('fac_fake_1').update({ platformSubscriptionStatus: 'active' });
  assert.deepEqual(offerOf(await facilityCheckout(w, 'fac_fake_2')), NOTHING);
});

// --- The owner's other accounts and facilities -------------------------------------------

test("owner history: another account of the same owner that used the free month blocks it here", async () => {
  const w = world({ subscriptionStatus: 'pendingApproval' });
  // The owner's earlier account (for example deleted and made again, or a duplicate).
  await w.deps.db.collection('facilityCreatorAccounts').doc('acct_fake_old').set({
    ownerUid: UID,
    subscriptionStatus: 'cancelled',
    stripeSubscriptionIdClearedFrom: 'sub_fake_old',
    platformTrialUsedAt: ts(NOW - 90 * DAY),
    platformFirstMonthFreeUsedAt: ts(NOW - 60 * DAY),
  });
  // Someone else's account is not this owner's history.
  await w.deps.db.collection('facilityCreatorAccounts').doc('acct_fake_other_owner').set({
    ownerUid: 'uid_fake_someone_else',
    subscriptionStatus: 'active',
    stripeSubscriptionId: 'sub_fake_someone_else',
  });
  assert.deepEqual(offerOf(await accountCheckout(w)), NOTHING);
  assert.deepEqual(offerOf(await facilityCheckout(w)), NOTHING);
});

test("owner history: another owner's used offer, or an untouched duplicate, changes nothing", async () => {
  const w = world({ subscriptionStatus: 'pendingApproval' });
  await w.deps.db.collection('facilityCreatorAccounts').doc('acct_fake_other_owner').set({
    ownerUid: 'uid_fake_someone_else',
    subscriptionStatus: 'cancelled',
    platformFirstMonthFreeUsedAt: ts(NOW - 60 * DAY),
  });
  await w.deps.db.collection('facilityCreatorAccounts').doc('acct_fake_dup').set({ ownerUid: UID, subscriptionStatus: 'pendingApproval' });
  assertFreeMonthSession(await accountCheckout(w), NOW + 30 * DAY);
});

test("owner history: a facility the owner owns under another account counts", async () => {
  const w = world({ subscriptionStatus: 'pendingApproval' });
  await w.deps.db.collection('facilities').doc('fac_fake_elsewhere').set({
    ownerUid: UID,
    facilityCreatorAccountId: 'acct_fake_old',
    platformSubscriptionStatus: 'cancelled',
    platformSubscriptionTrialEnd: ts(NOW - 40 * DAY),
  });
  assert.deepEqual(offerOf(await facilityCheckout(w)), NOTHING);
});

// --- Webhook writers ---------------------------------------------------------------------

test('webhook: a free-month subscription with no discounts sets platformFirstMonthFreeUsedAt from its metadata', async () => {
  const w = world(runningAppTrial(EXAMPLE_APP_TRIAL_END));
  w.subscriptions.set('sub_fake_free', {
    id: 'sub_fake_free',
    status: 'trialing',
    trial_end: sec(EXAMPLE_FREE_MONTH_END),
    cancel_at_period_end: false,
    canceled_at: null,
    metadata: {
      accountId: ACCOUNT,
      trialDecision: 'free_month',
      firstMonthFree: 'true',
      freeMonthStart: '2026-10-21T03:30:00.000Z',
      freeMonthTrialEnd: '2026-11-20T03:30:00.000Z',
    },
    discounts: [],
  });
  await updateAccountFromSubscription(ACCOUNT, 'sub_fake_free', { db: w.deps.db, stripe: w.stripe });
  const account = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.ok(account.platformFirstMonthFreeUsedAt, 'free-month marker set');
  assert.ok(account.platformTrialUsedAt, 'trial marker kept');
  assert.equal((account.subscriptionTrialEnd as admin.firestore.Timestamp).toMillis(), EXAMPLE_FREE_MONTH_END);
});

test('webhook: a trial subscription not flagged as the free month does not set the free-month marker', async () => {
  const end = NOW + 5 * DAY;
  const w = world(runningAppTrial(end));
  w.subscriptions.set('sub_fake_aligned', {
    id: 'sub_fake_aligned',
    status: 'trialing',
    trial_end: sec(end),
    cancel_at_period_end: false,
    canceled_at: null,
    metadata: { accountId: ACCOUNT, trialDecision: 'align_to_app_trial', firstMonthFree: 'false' },
    discounts: [],
  });
  await updateAccountFromSubscription(ACCOUNT, 'sub_fake_aligned', { db: w.deps.db, stripe: w.stripe });
  const account = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.equal(account.platformFirstMonthFreeUsedAt, undefined);
  assert.ok(account.platformTrialUsedAt);
});

test('webhook: a subscription with no trial never nulls an existing subscriptionTrialEnd', async () => {
  const oldTrialEnd = ts(NOW - 10 * DAY);
  const w = world({ subscriptionStatus: 'cancelled', subscriptionTrialEnd: oldTrialEnd });
  w.subscriptions.set('sub_fake_notrial', {
    id: 'sub_fake_notrial',
    status: 'active',
    trial_end: null,
    cancel_at_period_end: false,
    canceled_at: null,
    metadata: { accountId: ACCOUNT, firstMonthFree: 'true' },
    discounts: [],
  });
  await updateAccountFromSubscription(ACCOUNT, 'sub_fake_notrial', { db: w.deps.db, stripe: w.stripe });
  const account = w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!;
  assert.equal(account.subscriptionStatus, 'active');
  assert.equal(account.stripeSubscriptionId, 'sub_fake_notrial');
  assert.equal((account.subscriptionTrialEnd as admin.firestore.Timestamp).toMillis(), oldTrialEnd.toMillis());
  assert.ok(account.platformFirstMonthFreeUsedAt, 'free-month marker set from subscription metadata');
  assert.equal(account.platformTrialUsedAt, undefined, 'no trial on this subscription');
});

test('webhook: a legacy subscription carrying the retired coupon still counts as the free month', async () => {
  const w = world({ subscriptionStatus: 'cancelled' });
  w.subscriptions.set('sub_fake_legacy', {
    id: 'sub_fake_legacy',
    status: 'active',
    trial_end: null,
    cancel_at_period_end: false,
    canceled_at: null,
    metadata: { accountId: ACCOUNT },
    discounts: ['di_fake_legacy'],
  } as unknown as Partial<Stripe.Subscription>);
  await updateAccountFromSubscription(ACCOUNT, 'sub_fake_legacy', { db: w.deps.db, stripe: w.stripe });
  assert.ok(w.db.read(`facilityCreatorAccounts/${ACCOUNT}`)!.platformFirstMonthFreeUsedAt);
});

test('webhook: a trial subscription writes its trial end and the trial marker; existing markers are kept', async () => {
  const firstUse = ts(NOW - 100 * DAY);
  const w = world({ platformFirstMonthFreeUsedAt: firstUse });
  const trialEndSec = sec(NOW + 5 * DAY);
  w.subscriptions.set('sub_fake_trial', {
    id: 'sub_fake_trial',
    status: 'trialing',
    trial_end: trialEndSec,
    cancel_at_period_end: false,
    metadata: { accountId: ACCOUNT, firstMonthFree: 'true' },
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
    metadata: { accountId: ACCOUNT, facilityId: 'fac_fake_1', firstMonthFree: 'false' },
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

test('webhook: a completed checkout carrying the free month sets the marker once; legacy coupon sessions count too', async () => {
  const session = { metadata: { accountId: ACCOUNT, firstMonthFree: 'true' }, discounts: [] } as unknown as Stripe.Checkout.Session;
  assert.deepEqual(platformOfferUsageFromCheckoutSession(session), { trialUsed: false, firstMonthFreeUsed: true });
  assert.deepEqual(
    platformOfferUsageFromCheckoutSession({
      metadata: { accountId: ACCOUNT },
      discounts: [{ coupon: FIRST_MONTH_FREE_COUPON_ID, promotion_code: null }],
    } as unknown as Stripe.Checkout.Session),
    { trialUsed: false, firstMonthFreeUsed: true },
    'a session created before this change, with the retired coupon',
  );
  assert.deepEqual(
    platformOfferUsageFromCheckoutSession({ metadata: { firstMonthFree: 'false' }, discounts: [] } as unknown as Stripe.Checkout.Session),
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
