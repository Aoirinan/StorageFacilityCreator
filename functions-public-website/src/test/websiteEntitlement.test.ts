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
