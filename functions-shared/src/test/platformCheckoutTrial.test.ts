import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_PLATFORM_TRIAL_DAYS,
  FIRST_MONTH_FREE_DAYS,
  FIRST_MONTH_FREE_METADATA_KEY,
  FREE_MONTH_START_METADATA_KEY,
  FREE_MONTH_TRIAL_END_METADATA_KEY,
  STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS,
  TRIAL_END_SAFETY_MARGIN_MS,
  assessPlatformOfferHistory,
  decidePlatformCheckoutOffer,
  platformCheckoutOfferMetadata,
  platformCheckoutTrialSubscriptionData,
  platformOfferMarkerUpdates,
  platformOfferUsageFromSubscription,
  trialEndToMillis,
  type PlatformCheckoutOfferInput,
} from '../stripe/platformCheckoutTrial';

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const FREE_MONTH = FIRST_MONTH_FREE_DAYS * DAY;
const NOW = Date.parse('2026-10-01T12:00:00Z');

/** Stand-in for a Firestore Timestamp: only `toMillis` is read. */
function ts(ms: number): { toMillis: () => number } {
  return { toMillis: () => ms };
}

const sec = (ms: number) => Math.floor(ms / 1000);

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

/** A free-month offer: trial_end is `freeMonthStartMs` + 30 days, and nothing else is sent. */
function assertFreeMonth(i: PlatformCheckoutOfferInput, freeMonthStartMs: number, label = '') {
  const offer = decidePlatformCheckoutOffer(i);
  assert.equal(offer.trial.kind, 'free_month', label);
  assert.equal(offer.firstMonthFree, true, label);
  assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), { trial_end: sec(freeMonthStartMs + FREE_MONTH) }, label);
  if (offer.trial.kind === 'free_month') {
    assert.equal(offer.trial.freeMonthStartSeconds, sec(freeMonthStartMs), label);
  }
  return offer;
}

const runningAppTrial = (endMs = NOW + 20 * DAY) => ({
  subscriptionStatus: 'trialing',
  subscriptionTrialEnd: ts(endMs),
  platformTrialUsedAt: ts(endMs - 30 * DAY),
});

// --- Free month not used: it is trial time after the owner's trial ------------------------

test('worked example: app trial ends 2026-10-21T03:30Z, subscribe 2026-10-01 -> trial_end 2026-11-20T03:30Z', () => {
  const appTrialEnd = Date.parse('2026-10-21T03:30:00Z');
  const offer = decidePlatformCheckoutOffer(input(runningAppTrial(appTrialEnd), [], { nowMs: Date.parse('2026-10-01T15:00:00Z') }));
  assert.equal(offer.trial.kind, 'free_month');
  assert.equal(offer.firstMonthFree, true);
  const data = platformCheckoutTrialSubscriptionData(offer.trial);
  assert.deepEqual(data, { trial_end: sec(Date.parse('2026-11-20T03:30:00Z')) });
  assert.equal('trial_period_days' in data, false, 'never trial_period_days');
  assert.deepEqual(platformCheckoutOfferMetadata(offer.trial), {
    trialDecision: 'free_month',
    [FIRST_MONTH_FREE_METADATA_KEY]: 'true',
    [FREE_MONTH_START_METADATA_KEY]: '2026-10-21T03:30:00.000Z',
    [FREE_MONTH_TRIAL_END_METADATA_KEY]: '2026-11-20T03:30:00.000Z',
  });
});

test('app trial running: trial_end = app trial end + 30 days, in epoch seconds', () => {
  const end = Date.parse('2026-10-21T09:30:15.750Z');
  assertFreeMonth(input(runningAppTrial(end)), end);
});

test('legacy app trial (no marker, only subscriptionTrialEnd) running: app trial end + 30 days', () => {
  const end = NOW + 10 * DAY;
  for (const value of [ts(end), new Date(end), end]) {
    assertFreeMonth(input({ subscriptionStatus: 'trialing', subscriptionTrialEnd: value }), end);
  }
});

test('app trial running and a customer id from an abandoned checkout: still app trial end + 30 days', () => {
  const end = NOW + 20 * DAY;
  assertFreeMonth(input({ ...runningAppTrial(end), stripeCustomerId: 'cus_fake' }), end);
});

test('app trial ending in under 48 hours: app trial end + 30 days, well past the 48-hour minimum', () => {
  for (const left of [47 * HOUR, STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS, HOUR, 60 * 1000]) {
    const offer = assertFreeMonth(input(runningAppTrial(NOW + left)), NOW + left, `${left}ms left`);
    const trialEndMs = platformCheckoutTrialSubscriptionData(offer.trial).trial_end! * 1000;
    assert.ok(trialEndMs - NOW >= FREE_MONTH - 1000, 'at least a month away');
    assert.ok(trialEndMs - NOW >= STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS + TRIAL_END_SAFETY_MARGIN_MS);
  }
});

test('app trial ended, still marked trialing (sweep not run yet): free month from now', () => {
  assertFreeMonth(input({ subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(NOW - 3 * DAY) }), NOW);
});

test('app trial ended and swept to cancelled, with a customer from an abandoned checkout: now + 30 days', () => {
  assertFreeMonth(
    input({
      subscriptionStatus: 'cancelled',
      subscriptionTrialEnd: ts(NOW - 10 * DAY),
      trialExpiredAt: ts(NOW - 10 * DAY),
      stripeCustomerId: 'cus_fake',
      platformTrialUsedAt: ts(NOW - 40 * DAY),
    }),
    NOW,
  );
});

test('trial marker set but trial end revoked (null): no fresh 30-day trial, only the free month from now', () => {
  assertFreeMonth(
    input({ subscriptionStatus: 'cancelled', subscriptionTrialEnd: null, platformTrialUsedAt: ts(NOW - 40 * DAY) }),
    NOW,
  );
});

test('trial end exactly now counts as ended: free month from now', () => {
  assertFreeMonth(input(runningAppTrial(NOW)), NOW);
});

test('a future trial end on an account no longer trialing (cut short) is not stretched: free month from now', () => {
  assertFreeMonth(input({ subscriptionStatus: 'cancelled', subscriptionTrialEnd: ts(NOW + 10 * DAY) }), NOW);
});

test('customer id with a non-fresh status (T4) uses the trial but not the free month', () => {
  const h = assessPlatformOfferHistory({ account: { subscriptionStatus: 'cancelled', stripeCustomerId: 'cus_fake' }, facilities: [] });
  assert.equal(h.trialUsed, true);
  assert.equal(h.hadPlatformSubscription, false);
  assert.equal(h.firstMonthFreeUsed, false);
  assertFreeMonth(input({ subscriptionStatus: 'cancelled', stripeCustomerId: 'cus_fake' }), NOW);
});

// --- Brand-new owner (no trial record at all) --------------------------------------------

test('brand-new owner with no trial record: 30-day trial then the free month, as one trial_end 60 days out', () => {
  assertFreeMonth(input({ subscriptionStatus: 'pendingApproval' }), NOW + 30 * DAY);
});

test('brand-new owner who abandoned a checkout (customer id, fresh status): still trial + free month', () => {
  assertFreeMonth(input({ subscriptionStatus: 'pendingApproval', stripeCustomerId: 'cus_fake' }), NOW + 30 * DAY);
});

test('referral path with no trial record: referral days, then the free month', () => {
  assertFreeMonth(input({}, [], { defaultTrialDays: 45 }), NOW + 45 * DAY);
});

test('referral path with a running app trial: the app trial end wins over referral days', () => {
  const end = NOW + 20 * DAY;
  assertFreeMonth(input(runningAppTrial(end), [], { defaultTrialDays: 45 }), end);
});

// --- Free month used: never fresh time --------------------------------------------------

test('subscribed, cancelled, resubscribing (markers set): no trial, no free month', () => {
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
  assert.equal(offer.firstMonthFree, false);
  assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), {});
  assert.deepEqual(platformCheckoutOfferMetadata(offer.trial), {
    trialDecision: 'no_trial',
    [FIRST_MONTH_FREE_METADATA_KEY]: 'false',
  });
});

test('free-month marker alone: no fresh trial either (the free month comes after the trial)', () => {
  const offer = decidePlatformCheckoutOffer(input({ platformFirstMonthFreeUsedAt: ts(NOW - DAY) }));
  assert.equal(offer.history.trialUsed, true);
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.firstMonthFree, false);
});

test('a subscriptionTrialEnd written by a Stripe subscription that has ended: no trial, no free month', () => {
  const offer = decidePlatformCheckoutOffer(
    input({ subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(NOW - 20 * DAY), stripeSubscriptionId: 'sub_fake' }),
  );
  assert.equal(offer.history.trialUsed, true);
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.firstMonthFree, false);
});

test('legacy cancelled subscriber with no markers: no trial, no free month', () => {
  for (const account of [
    { subscriptionStatus: 'cancelled', subscriptionCanceledAt: ts(NOW - 5 * DAY), stripeCustomerId: 'cus_fake' },
    { subscriptionStatus: 'cancelled', stripeSubscriptionIdClearedFrom: 'sub_fake_old' },
    { subscriptionStatus: 'cancelled', subscriptionCancelAtPeriodEnd: true },
  ]) {
    const offer = decidePlatformCheckoutOffer(input(account));
    assert.equal(offer.trial.kind, 'no_trial', JSON.stringify(Object.keys(account)));
    assert.equal(offer.firstMonthFree, false, JSON.stringify(Object.keys(account)));
  }
});

test('pastDue account with an old trial end: no fresh trial, no free month', () => {
  const offer = decidePlatformCheckoutOffer(
    input({ subscriptionStatus: 'pastDue', subscriptionTrialEnd: ts(NOW - 40 * DAY), stripeCustomerId: 'cus_fake' }),
  );
  assert.equal(offer.trial.kind, 'no_trial');
  assert.equal(offer.firstMonthFree, false);
});

test('free month used, app trial still running (second facility): trial_end = app trial end, no free month', () => {
  const end = NOW + 15 * DAY;
  const offer = decidePlatformCheckoutOffer(
    input(
      { ...runningAppTrial(end), platformFirstMonthFreeUsedAt: ts(NOW - DAY) },
      [{ stripePlatformSubscriptionId: 'sub_fake_fac1', platformSubscriptionStatus: 'trialing', platformSubscriptionTrialEnd: ts(end + FREE_MONTH) }],
    ),
  );
  assert.equal(offer.history.hadPlatformSubscription, true);
  assert.equal(offer.trial.kind, 'align_to_app_trial');
  assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), { trial_end: sec(end) });
  assert.equal(offer.firstMonthFree, false);
  assert.deepEqual(platformCheckoutOfferMetadata(offer.trial), {
    trialDecision: 'align_to_app_trial',
    [FIRST_MONTH_FREE_METADATA_KEY]: 'false',
  });
});

test('free month used, app trial with under 48 hours left: no trial', () => {
  const offer = decidePlatformCheckoutOffer(input({ ...runningAppTrial(NOW + 47 * HOUR), platformFirstMonthFreeUsedAt: ts(NOW - DAY) }));
  assert.equal(offer.trial.kind, 'no_trial');
  assert.deepEqual(platformCheckoutTrialSubscriptionData(offer.trial), {});
});

test('free month used, 48-hour boundary: inside the 10-minute margin is no trial; at the margin is aligned', () => {
  const used = { platformFirstMonthFreeUsedAt: ts(NOW - DAY) };
  const lead = STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS + TRIAL_END_SAFETY_MARGIN_MS;
  assert.equal(
    decidePlatformCheckoutOffer(input({ ...runningAppTrial(NOW + STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS), ...used })).trial.kind,
    'no_trial',
  );
  assert.equal(decidePlatformCheckoutOffer(input({ ...runningAppTrial(NOW + lead - 1), ...used })).trial.kind, 'no_trial');
  const offer = decidePlatformCheckoutOffer(input({ ...runningAppTrial(NOW + lead), ...used }));
  assert.equal(offer.trial.kind, 'align_to_app_trial');
  const sent = platformCheckoutTrialSubscriptionData(offer.trial).trial_end!;
  assert.ok(sent * 1000 - NOW >= STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS);
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
    assert.equal(offer.firstMonthFree, false, JSON.stringify(Object.keys(facility)));
  }
});

// --- Never three months -------------------------------------------------------------------

test('never three months: trial_end is never past (end of the owner one trial) + 30 days', () => {
  const accounts: Record<string, unknown>[] = [
    {},
    { subscriptionStatus: 'pendingApproval' },
    runningAppTrial(NOW + 29 * DAY),
    runningAppTrial(NOW + HOUR),
    { ...runningAppTrial(NOW + 20 * DAY), platformFirstMonthFreeUsedAt: ts(NOW) },
    { subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(NOW - DAY) },
    { subscriptionStatus: 'cancelled', platformTrialUsedAt: ts(NOW - 60 * DAY) },
    { subscriptionStatus: 'cancelled', platformTrialUsedAt: ts(NOW - 60 * DAY), platformFirstMonthFreeUsedAt: ts(NOW - 20 * DAY) },
    { subscriptionStatus: 'active', stripeSubscriptionId: 'sub_fake' },
  ];
  for (const account of accounts) {
    const i = input(account);
    const offer = decidePlatformCheckoutOffer(i);
    const trialEnd = platformCheckoutTrialSubscriptionData(offer.trial).trial_end;
    if (trialEnd === undefined) continue;
    const appTrialEnd = trialEndToMillis(account.subscriptionTrialEnd);
    const running = account.subscriptionStatus === 'trialing' && appTrialEnd !== null && appTrialEnd > NOW;
    const trialLeftEnd = running ? appTrialEnd! : offer.history.trialUsed ? NOW : NOW + DEFAULT_PLATFORM_TRIAL_DAYS * DAY;
    const limit = offer.history.firstMonthFreeUsed ? trialLeftEnd : trialLeftEnd + FREE_MONTH;
    assert.ok(trialEnd * 1000 <= limit, JSON.stringify(account));
  }
});

test('the subscription data never carries trial_period_days, for any decision', () => {
  for (const account of [{}, runningAppTrial(), { ...runningAppTrial(), platformFirstMonthFreeUsedAt: ts(NOW) }, { subscriptionStatus: 'pastDue' }]) {
    const data = trialData(input(account));
    assert.equal('trial_period_days' in data, false, JSON.stringify(account));
  }
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

test('platformOfferUsageFromSubscription: a free-month subscription uses the trial and the free month', () => {
  assert.deepEqual(
    platformOfferUsageFromSubscription({
      trial_end: 1_900_000_000,
      metadata: { [FIRST_MONTH_FREE_METADATA_KEY]: 'true', [FREE_MONTH_TRIAL_END_METADATA_KEY]: '2030-03-17T17:46:40.000Z' },
      discounts: [],
    }),
    { trialUsed: true, firstMonthFreeUsed: true },
  );
});

test('platformOfferUsageFromSubscription: a trial without the free-month flag uses only the trial', () => {
  assert.deepEqual(platformOfferUsageFromSubscription({ trial_end: 1_900_000_000, metadata: {}, discounts: [] }), {
    trialUsed: true,
    firstMonthFreeUsed: false,
  });
  assert.deepEqual(
    platformOfferUsageFromSubscription({ trial_end: 1_900_000_000, metadata: { [FIRST_MONTH_FREE_METADATA_KEY]: 'false' } }),
    { trialUsed: true, firstMonthFreeUsed: false },
  );
  assert.deepEqual(platformOfferUsageFromSubscription({ trial_end: null, metadata: { [FIRST_MONTH_FREE_METADATA_KEY]: 'false' } }), {
    trialUsed: false,
    firstMonthFreeUsed: false,
  });
});

test('platformOfferUsageFromSubscription: any discount (the retired coupon) counts as the free month', () => {
  assert.deepEqual(platformOfferUsageFromSubscription({ trial_end: null, discounts: ['di_fake'] }), {
    trialUsed: false,
    firstMonthFreeUsed: true,
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
