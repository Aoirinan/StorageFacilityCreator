/**
 * "30-day trial, then first month free" must be two months free, never three.
 * Checks the Checkout Session params both platform checkout paths send to Stripe.
 * Pure: no Stripe or Firestore calls.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import {
  DEFAULT_PLATFORM_TRIAL_DAYS,
  FIRST_MONTH_FREE_COUPON_ID,
  decidePlatformCheckoutTrial,
  getOrCreateFirstMonthFreeCouponId,
  getRefereePlatformTrialDays,
} from '@sfc/functions-shared';
import { buildAccountSubscriptionCheckoutParams } from '../stripePlatformSubscriptionCheckoutSessionCreate';
import { buildFacilitySubscriptionCheckoutParams } from '../stripePlatformFacilitySubscriptionCheckoutLogic';

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const NOW = Date.parse('2026-10-01T12:00:00Z');

function ts(ms: number): { toMillis: () => number } {
  return { toMillis: () => ms };
}

/** Only `data()` is read by getRefereePlatformTrialDays. */
function facilitySnap(data: Record<string, unknown>): FirebaseFirestore.DocumentSnapshot {
  return { data: () => data } as unknown as FirebaseFirestore.DocumentSnapshot;
}

/** Fake Stripe: the coupon already exists; anything else throws. */
function fakeStripeWithCoupon(): Stripe {
  return {
    coupons: {
      retrieve: async (id: string) => ({ id, valid: true, percent_off: 100, duration: 'once' }),
      create: async () => {
        throw new Error('should not create');
      },
    },
  } as unknown as Stripe;
}

type Scenario = {
  name: string;
  account: { subscriptionStatus?: string; subscriptionTrialEnd?: unknown; stripeSubscriptionId?: string };
  facility?: Record<string, unknown>;
  expectTrial: { trial_end?: number; trial_period_days?: number };
};

const appTrialEnd = NOW + 20 * DAY;

const scenarios: Scenario[] = [
  {
    name: 'app trial still running -> trial_end = app trial end',
    account: { subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(appTrialEnd) },
    expectTrial: { trial_end: Math.floor(appTrialEnd / 1000) },
  },
  {
    name: 'app trial with under 48h left -> no trial',
    account: { subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(NOW + 30 * HOUR) },
    expectTrial: {},
  },
  {
    name: 'app trial already ended (swept to cancelled) -> no trial',
    account: { subscriptionStatus: 'cancelled', subscriptionTrialEnd: ts(NOW - 5 * DAY) },
    expectTrial: {},
  },
  {
    name: 'no app trial ever -> 30-day trial',
    account: {},
    expectTrial: { trial_period_days: DEFAULT_PLATFORM_TRIAL_DAYS },
  },
  {
    name: 'no app trial ever, referred facility -> referral trial days',
    account: {},
    facility: { platformReferralReferredByAccountId: 'acct_fake_referrer' },
    expectTrial: { trial_period_days: 30 },
  },
  {
    name: 'running app trial, referred facility -> still the app trial end',
    account: { subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(appTrialEnd) },
    facility: { platformReferralReferredByAccountId: 'acct_fake_referrer' },
    expectTrial: { trial_end: Math.floor(appTrialEnd / 1000) },
  },
];

function trialFields(params: Stripe.Checkout.SessionCreateParams) {
  const sd = params.subscription_data ?? {};
  const out: { trial_end?: number; trial_period_days?: number } = {};
  if (sd.trial_end !== undefined) out.trial_end = sd.trial_end;
  if (sd.trial_period_days !== undefined) out.trial_period_days = sd.trial_period_days;
  return out;
}

for (const s of scenarios) {
  test(`facility checkout: ${s.name}; coupon always attached`, async () => {
    const couponId = await getOrCreateFirstMonthFreeCouponId(fakeStripeWithCoupon());
    const trial = decidePlatformCheckoutTrial({
      accountSubscriptionStatus: s.account.subscriptionStatus,
      accountTrialEnd: s.account.subscriptionTrialEnd,
      accountHasStripeSubscription: !!s.account.stripeSubscriptionId,
      defaultTrialDays: getRefereePlatformTrialDays(facilitySnap(s.facility ?? {})),
      nowMs: NOW,
    });
    const params = buildFacilitySubscriptionCheckoutParams({
      accountId: 'acct_fake_1',
      facilityId: 'fac_fake_1',
      customerId: 'cus_fake_1',
      basePriceId: 'price_fake_base',
      firstMonthFreeCouponId: couponId,
      trial,
      ownerUid: 'uid_fake_1',
    });
    assert.deepEqual(params.discounts, [{ coupon: FIRST_MONTH_FREE_COUPON_ID }]);
    assert.deepEqual(trialFields(params), s.expectTrial);
    assert.equal(params.subscription_data?.metadata?.facilityId, 'fac_fake_1');
    assert.equal(params.subscription_data?.metadata?.trialDecision, trial.kind);
  });
}

for (const s of scenarios.filter((x) => !x.facility)) {
  test(`account checkout: ${s.name}; coupon always attached`, async () => {
    const couponId = await getOrCreateFirstMonthFreeCouponId(fakeStripeWithCoupon());
    const trial = decidePlatformCheckoutTrial({
      accountSubscriptionStatus: s.account.subscriptionStatus,
      accountTrialEnd: s.account.subscriptionTrialEnd,
      accountHasStripeSubscription: !!s.account.stripeSubscriptionId,
      defaultTrialDays: DEFAULT_PLATFORM_TRIAL_DAYS,
      nowMs: NOW,
    });
    const params = buildAccountSubscriptionCheckoutParams({
      accountId: 'acct_fake_1',
      customerId: 'cus_fake_1',
      facilityCount: 2,
      lineItems: [
        { price: 'price_fake_base', quantity: 1 },
        { price: 'price_fake_addon', quantity: 1 },
      ],
      firstMonthFreeCouponId: couponId,
      trial,
      ownerUid: 'uid_fake_1',
    });
    assert.deepEqual(params.discounts, [{ coupon: FIRST_MONTH_FREE_COUPON_ID }]);
    assert.deepEqual(trialFields(params), s.expectTrial);
    assert.equal(params.subscription_data?.metadata?.accountId, 'acct_fake_1');
    assert.equal(params.subscription_data?.metadata?.facilityCount, '2');
  });
}

test('the months-free total is two in every case, never three', () => {
  // Free time = app trial actually used + Stripe trial + one coupon month.
  const APP_TRIAL_DAYS = 30;
  const cases = [
    // Running app trial with 20 days left: 10 used, Stripe trial covers the other 20.
    { account: { subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(NOW + 20 * DAY) }, appDaysUsed: 10 },
    // Trial over: all 30 used, no Stripe trial.
    { account: { subscriptionStatus: 'cancelled', subscriptionTrialEnd: ts(NOW - 1 * DAY) }, appDaysUsed: 30 },
    // Never trialled: the Stripe trial is the whole trial.
    { account: {}, appDaysUsed: 0 },
  ];
  for (const c of cases) {
    const trial = decidePlatformCheckoutTrial({
      accountSubscriptionStatus: c.account.subscriptionStatus,
      accountTrialEnd: c.account.subscriptionTrialEnd,
      accountHasStripeSubscription: false,
      defaultTrialDays: DEFAULT_PLATFORM_TRIAL_DAYS,
      nowMs: NOW,
    });
    const stripeTrialDays =
      trial.kind === 'default_trial'
        ? trial.trialPeriodDays
        : trial.kind === 'align_to_app_trial'
          ? Math.round((trial.trialEndSeconds * 1000 - NOW) / DAY)
          : 0;
    const trialDaysTotal = c.appDaysUsed + stripeTrialDays;
    assert.equal(trialDaysTotal, APP_TRIAL_DAYS, `one 30-day trial in total for ${trial.reason}`);
  }
});
