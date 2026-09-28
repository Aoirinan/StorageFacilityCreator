import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_PLATFORM_TRIAL_DAYS,
  STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS,
  TRIAL_END_SAFETY_MARGIN_MS,
  decidePlatformCheckoutTrial,
  platformCheckoutTrialSubscriptionData,
  trialEndToMillis,
  type PlatformCheckoutTrialInput,
} from '../stripe/platformCheckoutTrial';

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const NOW = Date.parse('2026-10-01T12:00:00Z');

/** Stand-in for a Firestore Timestamp: only `toMillis` is read. */
function ts(ms: number): { toMillis: () => number } {
  return { toMillis: () => ms };
}

function input(overrides: Partial<PlatformCheckoutTrialInput> = {}): PlatformCheckoutTrialInput {
  return {
    accountSubscriptionStatus: null,
    accountTrialEnd: null,
    accountHasStripeSubscription: false,
    defaultTrialDays: DEFAULT_PLATFORM_TRIAL_DAYS,
    nowMs: NOW,
    ...overrides,
  };
}

test('no app trial ever (card at signup): keeps the 30-day Stripe trial', () => {
  const d = decidePlatformCheckoutTrial(input());
  assert.equal(d.kind, 'default_trial');
  assert.deepEqual(platformCheckoutTrialSubscriptionData(d), { trial_period_days: 30 });
});

test('referral path with no app trial: uses the referral days unchanged', () => {
  const d = decidePlatformCheckoutTrial(input({ defaultTrialDays: 45 }));
  assert.deepEqual(platformCheckoutTrialSubscriptionData(d), { trial_period_days: 45 });
});

test('referral path with a running app trial: aligns to the app trial, not the referral days', () => {
  const end = NOW + 20 * DAY;
  const d = decidePlatformCheckoutTrial(
    input({ defaultTrialDays: 45, accountSubscriptionStatus: 'trialing', accountTrialEnd: ts(end) }),
  );
  assert.deepEqual(platformCheckoutTrialSubscriptionData(d), { trial_end: Math.floor(end / 1000) });
});

test('app trial still running: Stripe trial_end is the app trial end in epoch seconds', () => {
  const end = Date.parse('2026-10-21T09:30:15.750Z');
  const d = decidePlatformCheckoutTrial(input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: ts(end) }));
  assert.equal(d.kind, 'align_to_app_trial');
  const data = platformCheckoutTrialSubscriptionData(d);
  assert.equal('trial_period_days' in data, false, 'never sends both trial_end and trial_period_days');
  assert.deepEqual(data, { trial_end: Math.floor(end / 1000) });
});

test('app trial running: accepts Date and epoch-ms trial ends too', () => {
  const end = NOW + 10 * DAY;
  for (const value of [new Date(end), end]) {
    const d = decidePlatformCheckoutTrial(input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: value }));
    assert.deepEqual(platformCheckoutTrialSubscriptionData(d), { trial_end: Math.floor(end / 1000) });
  }
});

test('app trial with less than 48 hours left: no Stripe trial at all', () => {
  const end = NOW + 47 * HOUR;
  const d = decidePlatformCheckoutTrial(input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: ts(end) }));
  assert.equal(d.kind, 'no_trial');
  assert.deepEqual(platformCheckoutTrialSubscriptionData(d), {});
});

test('48-hour boundary: exactly 48h (inside the safety margin) is no trial; past the margin is aligned', () => {
  const atMin = NOW + STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS;
  assert.equal(
    decidePlatformCheckoutTrial(input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: ts(atMin) })).kind,
    'no_trial',
  );
  const justInside = NOW + STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS + TRIAL_END_SAFETY_MARGIN_MS - 1;
  assert.equal(
    decidePlatformCheckoutTrial(input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: ts(justInside) })).kind,
    'no_trial',
  );
  const clear = NOW + STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS + TRIAL_END_SAFETY_MARGIN_MS;
  const d = decidePlatformCheckoutTrial(input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: ts(clear) }));
  assert.equal(d.kind, 'align_to_app_trial');
  // Whatever we send must satisfy Stripe's rule at request time.
  const sent = platformCheckoutTrialSubscriptionData(d).trial_end!;
  assert.ok(sent * 1000 - NOW >= STRIPE_CHECKOUT_MIN_TRIAL_END_LEAD_MS);
});

test('app trial ended but still marked trialing (sweep has not run): no Stripe trial', () => {
  const d = decidePlatformCheckoutTrial(
    input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: ts(NOW - 3 * DAY) }),
  );
  assert.equal(d.kind, 'no_trial');
  assert.deepEqual(platformCheckoutTrialSubscriptionData(d), {});
});

test('app trial ended and swept to cancelled: no Stripe trial', () => {
  const d = decidePlatformCheckoutTrial(
    input({ accountSubscriptionStatus: 'cancelled', accountTrialEnd: ts(NOW - 10 * DAY) }),
  );
  assert.equal(d.kind, 'no_trial');
});

test('trial end exactly now counts as ended', () => {
  const d = decidePlatformCheckoutTrial(input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: ts(NOW) }));
  assert.equal(d.kind, 'no_trial');
});

test('a trial end on an account that already has a Stripe subscription is not an app trial', () => {
  const d = decidePlatformCheckoutTrial(
    input({
      accountSubscriptionStatus: 'trialing',
      accountTrialEnd: ts(NOW + 20 * DAY),
      accountHasStripeSubscription: true,
    }),
  );
  assert.deepEqual(platformCheckoutTrialSubscriptionData(d), { trial_period_days: 30 });
});

test('trialEndToMillis ignores values it cannot read', () => {
  assert.equal(trialEndToMillis(undefined), null);
  assert.equal(trialEndToMillis(null), null);
  assert.equal(trialEndToMillis('2026-10-21'), null);
  assert.equal(trialEndToMillis(Number.NaN), null);
  assert.equal(trialEndToMillis(new Date('nope')), null);
  assert.equal(trialEndToMillis({}), null);
  // An unreadable trial end falls back to the no-app-trial rule rather than guessing.
  assert.equal(
    decidePlatformCheckoutTrial(input({ accountSubscriptionStatus: 'trialing', accountTrialEnd: 'garbage' })).kind,
    'default_trial',
  );
});
