import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_PLATFORM_TRIAL_DAYS,
  FIRST_MONTH_FREE_METADATA_KEY,
  STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS,
  TRIAL_END_SAFETY_MARGIN_MS,
  assessPlatformOfferHistory,
  decidePlatformCheckoutOffer,
  platformCheckoutTrialSubscriptionData,
  platformOfferMarkerUpdates,
  platformOfferUsageFromSubscription,
  trialEndToMillis,
  type PlatformCheckoutOfferInput,
} from '../stripe/platformCheckoutTrial';

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const NOW = Date.parse('2026-10-01T12:00:00Z');

/** Stand-in for a Firestore Timestamp: only `toMillis` is read. */
function ts(ms: number): { toMillis: () => number } {
  return { toMillis: () => ms };
}

function input(
  account: Record<string, unknown> = {},
  facilities: Record<string, unknown>[] = [],
  overrides: Partial<PlatformCheckoutOfferInput> = {},
): PlatformCheckoutOfferInput {
  return { account, facilities, defaultTrialDays: DEFAULT_PLATFORM_TRIAL_DAYS, nowMs: NOW, ...overrides };
}

function trialData(i: PlatformCheckoutOfferInput) {
  return platformCheckoutTrialSubscriptionData(decidePlatformCheckoutOffer(i).trial);
}

const runningAppTrial = (endMs = NOW + 20 * DAY) => ({
  subscriptionStatus: 'trialing',
  subscriptionTrialEnd: ts(endMs),
  platformTrialUsedAt: ts(endMs - 30 * DAY),
});

// --- Brand-new owner -------------------------------------------------------------

test('brand-new owner with no trial record: 30-day trial and the coupon', () => {
  const offer = decidePlatformCheckoutOffer(input({ subscriptionStatus: 'pendingApproval' }));
  assert.equal(offer.trial.kind, 'default_trial');
  assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), { trial_period_days: 30 });
  assert.equal(offer.attachFirstMonthFree, true);
});

test('brand-new owner who abandoned a checkout (customer id, fresh status): still 30 days + coupon', () => {
  const offer = decidePlatformCheckoutOffer(input({ subscriptionStatus: 'pendingApproval', stripeCustomerId: 'cus_fake' }));
  assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), { trial_period_days: 30 });
  assert.equal(offer.attachFirstMonthFree, true);
});

test('referral path with no trial record: referral days unchanged', () => {
  assert.deepEqual(trialData(input({}, [], { defaultTrialDays: 45 })), { trial_period_days: 45 });
});

test('referral path with a running app trial: the app trial end wins over referral days', () => {
  const end = NOW + 20 * DAY;
  assert.deepEqual(trialData(input(runningAppTrial(end), [], { defaultTrialDays: 45 })), {
    trial_end: Math.floor(end / 1000),
  });
});

// --- App trial ---------------------------------------------------------------------

test('app trial running: trial_end = app trial end in epoch seconds, coupon attached', () => {
  const end = Date.parse('2026-10-21T09:30:15.750Z');
  const offer = decidePlatformCheckoutOffer(input(runningAppTrial(end)));
  assert.equal(offer.trial.kind, 'align_to_app_trial');
  const data = platformCheckoutTrialSubscriptionData(offer.trial);
  assert.equal('trial_period_days' in data, false, 'never sends both trial_end and trial_period_days');
  assert.deepEqual(data, { trial_end: Math.floor(end / 1000) });
  assert.equal(offer.attachFirstMonthFree, true);
});

test('legacy app trial (no marker, only subscriptionTrialEnd) running: aligned, coupon attached', () => {
  const end = NOW + 10 * DAY;
  for (const value of [ts(end), new Date(end), end]) {
    const offer = decidePlatformCheckoutOffer(input({ subscriptionStatus: 'trialing', subscriptionTrialEnd: value }));
    assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), { trial_end: Math.floor(end / 1000) });
    assert.equal(offer.attachFirstMonthFree, true);
  }
});

test('app trial running and the owner already has a customer id from an abandoned checkout: still aligned + coupon', () => {
  const offer = decidePlatformCheckoutOffer(input({ ...runningAppTrial(), stripeCustomerId: 'cus_fake' }));
  assert.equal(offer.trial.kind, 'align_to_app_trial');
  assert.equal(offer.attachFirstMonthFree, true);
});

test('app trial with less than 48 hours left: no trial, coupon attached', () => {
  const offer = decidePlatformCheckoutOffer(input(runningAppTrial(NOW + 47 * HOUR)));
  assert.equal(offer.trial.kind, 'no_trial');
  assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), {});
  assert.equal(offer.attachFirstMonthFree, true);
});

test('48-hour boundary: inside the 10-minute margin is no trial; at the margin is aligned', () => {
  const lead = STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS + TRIAL_END_SAFETY_MARGIN_MS;
  assert.equal(decidePlatformCheckoutOffer(input(runningAppTrial(NOW + STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS))).trial.kind, 'no_trial');
  assert.equal(decidePlatformCheckoutOffer(input(runningAppTrial(NOW + lead - 1))).trial.kind, 'no_trial');
  const offer = decidePlatformCheckoutOffer(input(runningAppTrial(NOW + lead)));
  assert.equal(offer.trial.kind, 'align_to_app_trial');
  const sent = platformCheckoutTrialSubscriptionData(offer.trial).trial_end!;
  assert.ok(sent * 1000 - NOW >= STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS);
});

test('app trial ended, still marked trialing (sweep not run yet): no trial, coupon attached', () => {
  const offer = decidePlatformCheckoutOffer(input({ subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(NOW - 3 * DAY) }));
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.attachFirstMonthFree, true);
});

test('app trial ended and swept to cancelled, with a customer from an abandoned checkout: no trial, coupon attached', () => {
  const offer = decidePlatformCheckoutOffer(
    input({
      subscriptionStatus: 'cancelled',
      subscriptionTrialEnd: ts(NOW - 10 * DAY),
      trialExpiredAt: ts(NOW - 10 * DAY),
      stripeCustomerId: 'cus_fake',
    }),
  );
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.attachFirstMonthFree, true);
});

test('trial marker set but trial end revoked (null): no fresh trial', () => {
  const offer = decidePlatformCheckoutOffer(
    input({ subscriptionStatus: 'cancelled', subscriptionTrialEnd: null, platformTrialUsedAt: ts(NOW - 40 * DAY) }),
  );
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.attachFirstMonthFree, true);
});

test('trial end exactly now counts as ended', () => {
  assert.equal(decidePlatformCheckoutOffer(input(runningAppTrial(NOW))).trial.kind, 'no_trial');
});

// --- Subscription history -------------------------------------------------------------

test('a subscriptionTrialEnd counts as a used trial even when a Stripe subscription wrote it', () => {
  const offer = decidePlatformCheckoutOffer(
    input({ subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(NOW - 20 * DAY), stripeSubscriptionId: 'sub_fake' }),
  );
  assert.equal(offer.history.trialUsed, true);
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.attachFirstMonthFree, false);
});

test('subscribed, cancelled, resubscribing (markers set): no trial, no coupon', () => {
  const offer = decidePlatformCheckoutOffer(
    input({
      subscriptionStatus: 'cancelled',
      subscriptionCanceledAt: ts(NOW - 5 * DAY),
      stripeCustomerId: 'cus_fake',
      stripeSubscriptionIdClearedFrom: 'sub_fake_old',
      platformTrialUsedAt: ts(NOW - 90 * DAY),
      platformFirstMonthFreeUsedAt: ts(NOW - 90 * DAY),
    }),
  );
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.attachFirstMonthFree, false);
});

test('legacy cancelled subscriber with no markers: no trial, no coupon', () => {
  for (const account of [
    { subscriptionStatus: 'cancelled', subscriptionCanceledAt: ts(NOW - 5 * DAY), stripeCustomerId: 'cus_fake' },
    { subscriptionStatus: 'cancelled', stripeSubscriptionIdClearedFrom: 'sub_fake_old' },
    { subscriptionStatus: 'cancelled', subscriptionCancelAtPeriodEnd: true },
  ]) {
    const offer = decidePlatformCheckoutOffer(input(account));
    assert.equal(offer.trial.kind, 'no_trial', JSON.stringify(Object.keys(account)));
    assert.equal(offer.attachFirstMonthFree, false, JSON.stringify(Object.keys(account)));
  }
});

test('pastDue account with an old trial end: no fresh trial, no coupon', () => {
  const offer = decidePlatformCheckoutOffer(
    input({ subscriptionStatus: 'pastDue', subscriptionTrialEnd: ts(NOW - 40 * DAY), stripeCustomerId: 'cus_fake' }),
  );
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.attachFirstMonthFree, false);
});

test('running app trial wins over subscription history: aligned trial, but no second coupon', () => {
  const end = NOW + 15 * DAY;
  const offer = decidePlatformCheckoutOffer(
    input(
      { ...runningAppTrial(end), platformFirstMonthFreeUsedAt: ts(NOW - DAY) },
      [{ stripePlatformSubscriptionId: 'sub_fake_fac1', platformSubscriptionStatus: 'trialing', platformSubscriptionTrialEnd: ts(end) }],
    ),
  );
  assert.equal(offer.history.hadPlatformSubscription, true);
  assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), { trial_end: Math.floor(end / 1000) });
  assert.equal(offer.attachFirstMonthFree, false);
});

test('coupon marker alone blocks the coupon but not a first trial', () => {
  const offer = decidePlatformCheckoutOffer(input({ platformFirstMonthFreeUsedAt: ts(NOW - DAY) }));
  assert.equal(offer.trial.kind, 'default_trial');
  assert.equal(offer.attachFirstMonthFree, false);
});

test('a facility with its own trial or subscription record blocks both', () => {
  for (const facility of [
    { platformSubscriptionTrialEnd: ts(NOW - 50 * DAY) },
    { platformSubscriptionStatus: 'cancelled' },
    { stripePlatformSubscriptionId: 'sub_fake' },
    { platformSubscriptionCancelledAt: ts(NOW - DAY) },
  ]) {
    const offer = decidePlatformCheckoutOffer(input({ subscriptionStatus: 'cancelled' }, [{}, facility]));
    assert.equal(offer.trial.kind, 'no_trial', JSON.stringify(Object.keys(facility)));
    assert.equal(offer.attachFirstMonthFree, false, JSON.stringify(Object.keys(facility)));
  }
});

test('customer id with a non-fresh status (T4) uses the trial but not the coupon', () => {
  const h = assessPlatformOfferHistory({ account: { subscriptionStatus: 'cancelled', stripeCustomerId: 'cus_fake' }, facilities: [] });
  assert.equal(h.trialUsed, true);
  assert.equal(h.hadPlatformSubscription, false);
  assert.equal(h.firstMonthFreeUsed, false);
});

test('trialEndToMillis ignores values it cannot read', () => {
  assert.equal(trialEndToMillis(undefined), null);
  assert.equal(trialEndToMillis(null), null);
  assert.equal(trialEndToMillis('2026-10-21'), null);
  assert.equal(trialEndToMillis(Number.NaN), null);
  assert.equal(trialEndToMillis(new Date('nope')), null);
  assert.equal(trialEndToMillis({}), null);
});

// --- Webhook helpers -------------------------------------------------------------------

test('platformOfferUsageFromSubscription reads trial and coupon usage', () => {
  assert.deepEqual(platformOfferUsageFromSubscription({ trial_end: 1_900_000_000, metadata: {}, discounts: [] }), {
    trialUsed: true,
    firstMonthFreeUsed: false,
  });
  assert.deepEqual(
    platformOfferUsageFromSubscription({ trial_end: null, metadata: { [FIRST_MONTH_FREE_METADATA_KEY]: 'true' }, discounts: [] }),
    { trialUsed: false, firstMonthFreeUsed: true },
  );
  assert.deepEqual(platformOfferUsageFromSubscription({ trial_end: null, discounts: ['di_fake'] }), {
    trialUsed: false,
    firstMonthFreeUsed: true,
  });
  assert.deepEqual(platformOfferUsageFromSubscription({ trial_end: null, metadata: { [FIRST_MONTH_FREE_METADATA_KEY]: 'false' } }), {
    trialUsed: false,
    firstMonthFreeUsed: false,
  });
});

test('platformOfferMarkerUpdates only writes markers that are not set yet', () => {
  const both = { trialUsed: true, firstMonthFreeUsed: true };
  assert.deepEqual(platformOfferMarkerUpdates({}, both, 'STAMP'), {
    platformTrialUsedAt: 'STAMP',
    platformFirstMonthFreeUsedAt: 'STAMP',
  });
  assert.deepEqual(platformOfferMarkerUpdates({ platformTrialUsedAt: ts(1) }, both, 'STAMP'), {
    platformFirstMonthFreeUsedAt: 'STAMP',
  });
  assert.deepEqual(platformOfferMarkerUpdates({}, { trialUsed: false, firstMonthFreeUsed: false }, 'STAMP'), {});
});
