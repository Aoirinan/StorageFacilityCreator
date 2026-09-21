import test from 'node:test';
import assert from 'node:assert/strict';

import {
  anyCancelFailed,
  cancelSubscriptions,
  collectSubscriptionsToCancel,
  isAlreadyEndedError,
  isOrphanedSubscription,
  summarizeCancelOutcomes,
  type CancellableSubscription,
} from '../stripe/subscriptionCleanup';

function fakeStripe(behaviour: Record<string, 'ok' | Error>) {
  const called: string[] = [];
  return {
    called,
    subscriptions: {
      cancel: async (id: string) => {
        called.push(id);
        const outcome = behaviour[id];
        if (outcome && outcome !== 'ok') throw outcome;
        return { id, status: 'canceled' };
      },
    },
  };
}

test('collects every subscription a facility and its account can carry', () => {
  const subs = collectSubscriptionsToCancel(
    { stripePlatformSubscriptionId: 'sub_platform', stripeWebsiteSubscriptionId: 'sub_site' },
    { stripeSubscriptionId: 'sub_account' },
  );
  assert.deepEqual(subs, [
    { id: 'sub_platform', label: 'platform' },
    { id: 'sub_site', label: 'website' },
    { id: 'sub_account', label: 'account' },
  ]);
});

test('the same id is never cancelled twice', () => {
  // Two facilities on one legacy account both point at that account's
  // subscription; the second cancel would error on something already done.
  const subs = collectSubscriptionsToCancel(
    { stripePlatformSubscriptionId: 'sub_same' },
    { stripeSubscriptionId: 'sub_same' },
  );
  assert.equal(subs.length, 1);
  assert.equal(subs[0].label, 'platform');
});

test('missing, blank and whitespace ids are ignored', () => {
  assert.deepEqual(collectSubscriptionsToCancel(null, null), []);
  assert.deepEqual(
    collectSubscriptionsToCancel({ stripePlatformSubscriptionId: '   ' }, { stripeSubscriptionId: '' }),
    [],
  );
});

test('ids are trimmed before use', () => {
  const subs = collectSubscriptionsToCancel({ stripePlatformSubscriptionId: '  sub_x ' }, null);
  assert.deepEqual(subs, [{ id: 'sub_x', label: 'platform' }]);
});

test('a subscription Stripe has never heard of counts as already gone', () => {
  assert.equal(isAlreadyEndedError({ code: 'resource_missing' }), true);
  assert.equal(isAlreadyEndedError(new Error('No such subscription: sub_x')), true);
  assert.equal(isAlreadyEndedError(new Error('This subscription has already been canceled')), true);
  assert.equal(isAlreadyEndedError(new Error('card declined')), false);
  assert.equal(isAlreadyEndedError(null), false);
});

test('cancels each subscription and reports what happened', async () => {
  const stripe = fakeStripe({});
  const subs: CancellableSubscription[] = [
    { id: 'sub_a', label: 'platform' },
    { id: 'sub_b', label: 'website' },
  ];
  const outcomes = await cancelSubscriptions(stripe, subs);
  assert.deepEqual(stripe.called, ['sub_a', 'sub_b']);
  assert.deepEqual(outcomes.map((o) => o.status), ['canceled', 'canceled']);
  assert.equal(anyCancelFailed(outcomes), false);
});

test('one dead id does not stop the others being cancelled', async () => {
  // A half-cleaned customer is the exact state this module exists to prevent.
  const stripe = fakeStripe({ sub_b: new Error('card network unavailable') });
  const outcomes = await cancelSubscriptions(stripe, [
    { id: 'sub_a', label: 'platform' },
    { id: 'sub_b', label: 'website' },
    { id: 'sub_c', label: 'account' },
  ]);
  assert.deepEqual(stripe.called, ['sub_a', 'sub_b', 'sub_c']);
  assert.deepEqual(outcomes.map((o) => o.status), ['canceled', 'failed', 'canceled']);
  assert.equal(anyCancelFailed(outcomes), true);
  assert.match(summarizeCancelOutcomes(outcomes), /website sub_b: failed \(card network unavailable\)/);
});

test('re-running a cleanup is not an error', async () => {
  const stripe = fakeStripe({ sub_a: Object.assign(new Error('No such subscription: sub_a'), { code: 'resource_missing' }) });
  const outcomes = await cancelSubscriptions(stripe, [{ id: 'sub_a', label: 'platform' }]);
  assert.equal(outcomes[0].status, 'already_gone');
  assert.equal(anyCancelFailed(outcomes), false);
});

test('a subscription whose facility is gone is orphaned', () => {
  assert.equal(
    isOrphanedSubscription({
      metadata: { facilityId: 'fac_dead', accountId: 'acct_1' },
      facilityExists: () => false,
      accountExists: () => true,
    }),
    true,
  );
});

test('a subscription whose facility still exists is left alone', () => {
  assert.equal(
    isOrphanedSubscription({
      metadata: { facilityId: 'fac_live' },
      facilityExists: () => true,
      accountExists: () => false,
    }),
    false,
  );
});

test('an account-only subscription follows its account', () => {
  const args = { facilityExists: () => false, accountExists: (id: string) => id === 'acct_live' };
  assert.equal(isOrphanedSubscription({ metadata: { accountId: 'acct_live' }, ...args }), false);
  assert.equal(isOrphanedSubscription({ metadata: { accountId: 'acct_dead' }, ...args }), true);
});

test('a subscription with no metadata is never touched', () => {
  // We cannot prove who it belongs to, and cancelling a paying customer by
  // mistake is far worse than leaving a stray record for a human to read.
  for (const metadata of [null, undefined, {}, { somethingElse: 'x' }]) {
    assert.equal(
      isOrphanedSubscription({
        metadata: metadata as Record<string, string> | null,
        facilityExists: () => false,
        accountExists: () => false,
      }),
      false,
    );
  }
});

test('blank metadata values are treated as absent, not as a missing record', () => {
  assert.equal(
    isOrphanedSubscription({
      metadata: { facilityId: '  ', accountId: '' },
      facilityExists: () => false,
      accountExists: () => false,
    }),
    false,
  );
});
