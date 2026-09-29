import test from 'node:test';
import assert from 'node:assert/strict';
import {
  accountHasPaidOrCardTrialSubscription,
  facilityHasPaidOrCardTrialSubscription,
  hasPaidOrCardTrialSubscription,
  isUnpaidAppTrial,
  ownerHasPaidOrCardTrialSubscription,
  ownerOnUnpaidAppTrial,
} from '../subscription/paidSubscription';

// Invented fixtures only. The account's app trial ended; the card-backed free month runs on.
const cardTrialAccount = {
  subscriptionStatus: 'trialing',
  stripeSubscriptionId: 'sub_test_card_trial',
};
const appTrialAccount = { subscriptionStatus: 'trialing' };
const cardTrialFacility = {
  platformSubscriptionStatus: 'trialing',
  stripePlatformSubscriptionId: 'sub_test_facility_trial',
};

test('hasPaidOrCardTrialSubscription: active, or trialing with a Stripe subscription', () => {
  assert.equal(hasPaidOrCardTrialSubscription('active', undefined), true);
  assert.equal(hasPaidOrCardTrialSubscription('active', 'sub_test_1'), true);
  assert.equal(hasPaidOrCardTrialSubscription('trialing', 'sub_test_1'), true);
  // The unpaid app trial: no subscription id behind it.
  for (const id of [undefined, null, '', '   ', 42]) {
    assert.equal(hasPaidOrCardTrialSubscription('trialing', id), false, `id ${String(id)}`);
  }
  // A subscription id does not make any other status paid.
  for (const status of ['pastDue', 'past_due', 'cancelled', 'unpaid', 'incomplete', 'pendingApproval', '', undefined]) {
    assert.equal(hasPaidOrCardTrialSubscription(status, 'sub_test_1'), false, `status ${String(status)}`);
  }
});

test('account and facility forms read their own fields', () => {
  assert.equal(accountHasPaidOrCardTrialSubscription(cardTrialAccount), true);
  assert.equal(accountHasPaidOrCardTrialSubscription(appTrialAccount), false);
  assert.equal(accountHasPaidOrCardTrialSubscription({ subscriptionStatus: 'active' }), true);
  assert.equal(accountHasPaidOrCardTrialSubscription(null), false);
  // The facility's field names, not the account's.
  assert.equal(
    accountHasPaidOrCardTrialSubscription({ subscriptionStatus: 'trialing', stripePlatformSubscriptionId: 'sub_x' }),
    false,
  );

  assert.equal(facilityHasPaidOrCardTrialSubscription(cardTrialFacility), true);
  assert.equal(facilityHasPaidOrCardTrialSubscription({ platformSubscriptionStatus: 'active' }), true);
  assert.equal(facilityHasPaidOrCardTrialSubscription({ platformSubscriptionStatus: 'trialing' }), false);
  assert.equal(
    facilityHasPaidOrCardTrialSubscription({ platformSubscriptionStatus: 'trialing', stripeSubscriptionId: 'sub_x' }),
    false,
  );
  assert.equal(facilityHasPaidOrCardTrialSubscription(undefined), false);
});

test('owner: the account, or any facility given', () => {
  assert.equal(ownerHasPaidOrCardTrialSubscription(cardTrialAccount, []), true);
  // Per-facility billing: the account rolls up to trialing with no subscription id.
  assert.equal(ownerHasPaidOrCardTrialSubscription(appTrialAccount, [{}, cardTrialFacility]), true);
  assert.equal(ownerHasPaidOrCardTrialSubscription(appTrialAccount, [{ platformSubscriptionStatus: 'past_due' }]), false);
  assert.equal(ownerHasPaidOrCardTrialSubscription(null, []), false);
});

test('isUnpaidAppTrial: trialing with no card anywhere', () => {
  assert.equal(isUnpaidAppTrial(appTrialAccount, []), true);
  assert.equal(isUnpaidAppTrial(appTrialAccount, [{ platformSubscriptionStatus: 'cancelled' }]), true);
  assert.equal(isUnpaidAppTrial(cardTrialAccount, []), false);
  assert.equal(isUnpaidAppTrial(appTrialAccount, [cardTrialFacility]), false);
  assert.equal(isUnpaidAppTrial(appTrialAccount, [{ platformSubscriptionStatus: 'active' }]), false);
  // Not trialing at all is not the trial, whatever else is true.
  for (const status of ['active', 'pastDue', 'cancelled', 'pendingApproval']) {
    assert.equal(isUnpaidAppTrial({ subscriptionStatus: status }, []), false, status);
  }
  assert.equal(isUnpaidAppTrial(undefined, []), false);
});

test('ownerOnUnpaidAppTrial reads linked facilities only when it has to', async () => {
  let loads = 0;
  const load = (docs: Record<string, unknown>[]) => async () => {
    loads += 1;
    return docs;
  };

  // The account decides: no read.
  assert.equal(await ownerOnUnpaidAppTrial(cardTrialAccount, {}, load([])), false);
  assert.equal(await ownerOnUnpaidAppTrial({ subscriptionStatus: 'active' }, {}, load([])), false);
  assert.equal(await ownerOnUnpaidAppTrial({ subscriptionStatus: 'cancelled' }, {}, load([])), false);
  // This facility has the card: no read.
  assert.equal(await ownerOnUnpaidAppTrial(appTrialAccount, cardTrialFacility, load([])), false);
  assert.equal(loads, 0);

  // Another facility of the account has the card.
  assert.equal(await ownerOnUnpaidAppTrial(appTrialAccount, {}, load([{}, cardTrialFacility])), false);
  // Nothing has one: the unpaid app trial.
  assert.equal(await ownerOnUnpaidAppTrial(appTrialAccount, {}, load([{ platformSubscriptionStatus: 'trialing' }])), true);
  assert.equal(loads, 2);

  await assert.rejects(
    ownerOnUnpaidAppTrial(appTrialAccount, {}, async () => {
      throw new Error('read failed');
    }),
    /read failed/,
  );
});
