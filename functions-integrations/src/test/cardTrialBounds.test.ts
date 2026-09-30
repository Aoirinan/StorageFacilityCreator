/**
 * A card-backed free month (`trialing` with a Stripe subscription id) counts as paid only
 * until its trial end plus a short grace. These cover the writers that must not leave or
 * make a `trialing` + id record that outlives that: cancelling in the free month, and the
 * app trial layered on a Stripe-billed account. Invented data only.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  accountHasPaidOrCardTrialSubscription,
  computeAccountRollup,
  isUnpaidAppTrial,
} from '@sfc/functions-shared';
import { accountUpdateForDeletedSubscription } from '../stripeWebhookSubscriptionDeleted';
import { START_TRIAL_STRIPE_SUBSCRIPTION_MESSAGE, startTrialRefusal } from '../stripePlatformStartTrial';

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse('2026-10-01T12:00:00Z');
const ts = (ms: number) => ({ toMillis: () => ms });
const STAMP = 'server-time';

/** What the deleted event and the reconcile pass after it leave on the account. */
function afterDeletedEvent(account: Record<string, unknown>, deletedSubscriptionId: string): Record<string, unknown> {
  const written: Record<string, unknown> = {
    ...account,
    ...accountUpdateForDeletedSubscription(account, deletedSubscriptionId, STAMP),
  };
  const trialEnd = written.subscriptionTrialEnd as { toMillis: () => number } | undefined;
  const rollup = computeAccountRollup({
    currentStatus: written.subscriptionStatus as string,
    localTrialEndMs: trialEnd?.toMillis() ?? null,
    facilities: [],
    nowMs: NOW,
  });
  return { ...written, subscriptionStatus: rollup.status };
}

const freeMonthAccount = {
  ownerUid: 'uid_fake_owner',
  subscriptionStatus: 'trialing',
  stripeSubscriptionId: 'sub_fake_free_month',
  subscriptionTrialEnd: ts(NOW + 20 * DAY),
};

test('deleted in the free month: the pointer to the deleted subscription is cleared with the status write', () => {
  const update = accountUpdateForDeletedSubscription(freeMonthAccount, 'sub_fake_free_month', STAMP);
  assert.deepEqual(update, {
    subscriptionStatus: 'cancelled',
    subscriptionCanceledAt: STAMP,
    updatedAt: STAMP,
    stripeSubscriptionId: null,
    stripeSubscriptionIdClearedAt: STAMP,
    stripeSubscriptionIdClearedFrom: 'sub_fake_free_month',
  });

  // The rollup puts it back on its trial until the (Stripe) trial end, but with no
  // subscription id: the unpaid app trial, not a paid card-backed trial.
  const after = afterDeletedEvent(freeMonthAccount, 'sub_fake_free_month');
  assert.equal(after.subscriptionStatus, 'trialing');
  assert.equal(after.stripeSubscriptionId, null);
  assert.equal(accountHasPaidOrCardTrialSubscription(after, NOW), false);
  assert.equal(isUnpaidAppTrial(after, [], NOW), true);
});

test('deleted: a pointer to a different (newer) subscription is left for reconcile to verify', () => {
  const account = { ...freeMonthAccount, stripeSubscriptionId: 'sub_fake_newer' };
  const update = accountUpdateForDeletedSubscription(account, 'sub_fake_old', STAMP);
  assert.equal('stripeSubscriptionId' in update, false);
  assert.equal(update.subscriptionStatus, 'cancelled');
  // Whitespace around the stored id does not hide a match.
  assert.equal(
    accountUpdateForDeletedSubscription({ stripeSubscriptionId: ' sub_fake_x ' }, 'sub_fake_x', STAMP).stripeSubscriptionId,
    null,
  );
  assert.equal('stripeSubscriptionId' in accountUpdateForDeletedSubscription({}, 'sub_fake_x', STAMP), false);
});

test('cancel at period end in the free month: a lost deleted event is not paid past the trial end plus grace', () => {
  // Stripe ends the subscription at the trial end; its deleted event never arrives.
  const stale = { ...freeMonthAccount, subscriptionTrialEnd: ts(NOW - 4 * DAY), subscriptionCancelAtPeriodEnd: true };
  assert.equal(accountHasPaidOrCardTrialSubscription(stale, NOW), false);
  assert.equal(isUnpaidAppTrial(stale, [], NOW), true);
  // The nightly sweep's rollup then moves it off `trialing`.
  const rollup = computeAccountRollup({
    currentStatus: 'trialing',
    localTrialEndMs: NOW - 4 * DAY,
    facilities: [],
    nowMs: NOW,
  });
  assert.equal(rollup.status, 'cancelled');
  // Within the grace (the deleted event is late, not lost) it still counts.
  assert.equal(accountHasPaidOrCardTrialSubscription({ ...stale, subscriptionTrialEnd: ts(NOW - DAY) }, NOW), true);
});

test('startTrial: never on an account with a Stripe subscription id, whatever its status', () => {
  for (const status of ['cancelled', 'pastDue', 'pendingApproval', 'trialing', 'active', undefined]) {
    assert.equal(
      startTrialRefusal({ subscriptionStatus: status, stripeSubscriptionId: 'sub_fake_1' }),
      START_TRIAL_STRIPE_SUBSCRIPTION_MESSAGE,
      String(status),
    );
  }
  assert.match(START_TRIAL_STRIPE_SUBSCRIPTION_MESSAGE, /Stripe subscription/);
});

test('startTrial: the existing rules still apply to accounts without one', () => {
  assert.equal(startTrialRefusal({ subscriptionStatus: 'pendingApproval' }), null);
  assert.equal(startTrialRefusal({ subscriptionStatus: 'cancelled', stripeSubscriptionId: '  ' }), null);
  assert.equal(startTrialRefusal({ subscriptionStatus: 'cancelled', stripeSubscriptionId: null }), null);
  assert.match(startTrialRefusal({ subscriptionStatus: 'trialing' })!, /active subscription or trial/);
  assert.match(startTrialRefusal({ subscriptionStatus: 'active' })!, /active subscription or trial/);
  assert.match(startTrialRefusal({ subscriptionStatus: 'cancelled', platformTrialUsedAt: ts(NOW) })!, /already used its free trial/);
  assert.match(startTrialRefusal({ subscriptionStatus: 'cancelled', subscriptionTrialEnd: ts(NOW) })!, /already used its free trial/);
});
