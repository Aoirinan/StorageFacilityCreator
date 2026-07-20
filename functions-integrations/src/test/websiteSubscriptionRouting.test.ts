import test from 'node:test';
import assert from 'node:assert/strict';
import type Stripe from 'stripe';
import { isWebsiteAddonSubscription } from '../stripeWebhookSubscriptionInternal';

function subscriptionWithMetadata(
  metadata: Record<string, string>,
): Stripe.Subscription {
  return { metadata } as unknown as Stripe.Subscription;
}

test('website add-on subscriptions are separated from platform subscriptions', () => {
  assert.equal(
    isWebsiteAddonSubscription(
      subscriptionWithMetadata({ subscriptionType: 'website_addon' }),
    ),
    true,
  );
  assert.equal(
    isWebsiteAddonSubscription(
      subscriptionWithMetadata({ facilityId: 'facility-1' }),
    ),
    false,
  );
});
