import test from 'node:test';
import assert from 'node:assert/strict';
import { hasActiveWebsiteSubscription } from '../publicWebsite';

test('website entitlement requires an active Stripe subscription id', () => {
  assert.equal(
    hasActiveWebsiteSubscription({
      stripeWebsiteSubscriptionId: 'sub_website',
      websiteSubscriptionStatus: 'active',
    }),
    true,
  );
  assert.equal(
    hasActiveWebsiteSubscription({
      stripeWebsiteSubscriptionId: 'sub_website',
      websiteSubscriptionStatus: 'trialing',
    }),
    true,
  );
  assert.equal(
    hasActiveWebsiteSubscription({
      stripeWebsiteSubscriptionId: 'sub_website',
      websiteSubscriptionStatus: 'pastDue',
    }),
    false,
  );
  assert.equal(
    hasActiveWebsiteSubscription({ websiteSubscriptionStatus: 'active' }),
    false,
  );
});

test('website entitlement accepts only an unexpired superadmin trial', () => {
  const nowMs = 1_000_000;
  assert.equal(
    hasActiveWebsiteSubscription({
      websiteAdminTrialEndsAt: { toMillis: () => nowMs + 60_000 },
    }, nowMs),
    true,
  );
  assert.equal(
    hasActiveWebsiteSubscription({
      websiteAdminTrialEndsAt: { toMillis: () => nowMs },
    }, nowMs),
    false,
  );
  assert.equal(
    hasActiveWebsiteSubscription({
      websiteAdminTrialEndsAt: { toMillis: () => nowMs - 1 },
    }, nowMs),
    false,
  );
});

test('a billing-exempt facility has the website without a subscription or trial', () => {
  // Keepsake, the operator's own facility: its $25 subscription was cancelled
  // and a trial is refused for want of a paid $75 plan, so before this the
  // site could not be served at all.
  assert.equal(
    hasActiveWebsiteSubscription({
      billingExempt: true,
      stripeWebsiteSubscriptionId: 'sub_old',
      websiteSubscriptionStatus: 'cancelled',
    }),
    true,
  );
  assert.equal(hasActiveWebsiteSubscription({ billingExempt: true }), true);
  // Only exactly true exempts, as the flag is read everywhere else.
  for (const value of ['true', 1, false, null, undefined]) {
    assert.equal(
      hasActiveWebsiteSubscription({ billingExempt: value, websiteSubscriptionStatus: 'cancelled' }),
      false,
      String(value),
    );
  }
});
