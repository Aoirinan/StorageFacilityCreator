import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  hasActiveWebsiteAdminTrial,
  isWebsiteAddonSubscription,
} from '../stripeWebhookSubscriptionInternal';
import { hasActiveBasePlatformSubscription } from '../stripePlatformWebsiteSubscription';

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

test('website checkout accepts either account-level or facility-level base access', () => {
  const nowMs = 1_000_000;
  assert.equal(
    hasActiveBasePlatformSubscription(
      { subscriptionStatus: 'active' },
      {},
      nowMs,
    ),
    true,
  );
  assert.equal(
    hasActiveBasePlatformSubscription(
      {},
      {
        platformSubscriptionStatus: 'trialing',
        platformSubscriptionTrialEnd:
          admin.firestore.Timestamp.fromMillis(nowMs + 1),
      },
      nowMs,
    ),
    true,
  );
  assert.equal(
    hasActiveBasePlatformSubscription(
      { subscriptionStatus: 'cancelled' },
      { platformSubscriptionStatus: 'pastDue' },
      nowMs,
    ),
    false,
  );
});

test('website checkout rejects suspended and expired base subscriptions', () => {
  const nowMs = 1_000_000;
  assert.equal(
    hasActiveBasePlatformSubscription(
      { subscriptionStatus: 'active', suspended: true },
      { platformSubscriptionStatus: 'active' },
      nowMs,
    ),
    false,
  );
  assert.equal(
    hasActiveBasePlatformSubscription(
      {
        subscriptionStatus: 'trialing',
        subscriptionTrialEnd: admin.firestore.Timestamp.fromMillis(nowMs),
      },
      {},
      nowMs,
    ),
    false,
  );
});

test('website checkout counts the card-backed free month as the base plan, like active', () => {
  const nowMs = 1_000_000;
  const ended = admin.firestore.Timestamp.fromMillis(nowMs - 1);
  // Trialing with a Stripe subscription: paid for, whatever the trial end says.
  assert.equal(
    hasActiveBasePlatformSubscription(
      { subscriptionStatus: 'trialing', stripeSubscriptionId: 'sub_test_account', subscriptionTrialEnd: ended },
      {},
      nowMs,
    ),
    true,
  );
  assert.equal(
    hasActiveBasePlatformSubscription(
      { subscriptionStatus: 'trialing', subscriptionTrialEnd: ended },
      {
        platformSubscriptionStatus: 'trialing',
        stripePlatformSubscriptionId: 'sub_test_facility',
        platformSubscriptionTrialEnd: ended,
      },
      nowMs,
    ),
    true,
  );
  // The unpaid app trial still ends at its trial end.
  assert.equal(
    hasActiveBasePlatformSubscription(
      { subscriptionStatus: 'trialing', subscriptionTrialEnd: ended },
      {},
      nowMs,
    ),
    false,
  );
  // Suspension still wins.
  assert.equal(
    hasActiveBasePlatformSubscription(
      { subscriptionStatus: 'trialing', stripeSubscriptionId: 'sub_test_account', suspended: true },
      {},
      nowMs,
    ),
    false,
  );
});

test('website admin trial is active only before its expiry', () => {
  const nowMs = 1_000_000;
  assert.equal(
    hasActiveWebsiteAdminTrial({
      websiteAdminTrialEndsAt: admin.firestore.Timestamp.fromMillis(nowMs + 1),
    }, nowMs),
    true,
  );
  assert.equal(
    hasActiveWebsiteAdminTrial({
      websiteAdminTrialEndsAt: admin.firestore.Timestamp.fromMillis(nowMs),
    }, nowMs),
    false,
  );
});
