import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CARD_TRIAL_GRACE_MS,
  accountHasPaidOrCardTrialSubscription,
  facilityHasPaidOrCardTrialSubscription,
  hasPaidOrCardTrialSubscription,
  isUnpaidAppTrial,
  ownerHasPaidOrCardTrialSubscription,
  ownerOnUnpaidAppTrial,
} from '../subscription/paidSubscription';

// Invented fixtures only.
const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const NOW = Date.parse('2026-10-01T12:00:00Z');
const ts = (ms: number) => ({ toMillis: () => ms });
const AHEAD = ts(NOW + 20 * DAY);

// The account's app trial ended; the card-backed free month runs on.
const cardTrialAccount = {
  subscriptionStatus: 'trialing',
  stripeSubscriptionId: 'sub_test_card_trial',
  subscriptionTrialEnd: AHEAD,
};
const appTrialAccount = { subscriptionStatus: 'trialing', subscriptionTrialEnd: ts(NOW - 2 * DAY) };
const cardTrialFacility = {
  platformSubscriptionStatus: 'trialing',
  stripePlatformSubscriptionId: 'sub_test_facility_trial',
  platformSubscriptionTrialEnd: AHEAD,
};

test('hasPaidOrCardTrialSubscription: active, or trialing with a Stripe subscription and a trial end still counting', () => {
  assert.equal(hasPaidOrCardTrialSubscription('active', undefined, undefined, NOW), true);
  assert.equal(hasPaidOrCardTrialSubscription('active', 'sub_test_1', ts(NOW - 90 * DAY), NOW), true);
  assert.equal(hasPaidOrCardTrialSubscription('trialing', 'sub_test_1', AHEAD, NOW), true);
  // The unpaid app trial: no subscription id behind it.
  for (const id of [undefined, null, '', '   ', 42]) {
    assert.equal(hasPaidOrCardTrialSubscription('trialing', id, AHEAD, NOW), false, `id ${String(id)}`);
  }
  // A subscription id does not make any other status paid.
  for (const status of ['pastDue', 'past_due', 'cancelled', 'unpaid', 'incomplete', 'pendingApproval', '', undefined]) {
    assert.equal(hasPaidOrCardTrialSubscription(status, 'sub_test_1', AHEAD, NOW), false, `status ${String(status)}`);
  }
});

test('the card-backed trial is bounded: its trial end plus the webhook grace, never with no trial end', () => {
  assert.equal(CARD_TRIAL_GRACE_MS, 3 * DAY);
  const at = (trialEndMs: number) => hasPaidOrCardTrialSubscription('trialing', 'sub_test_1', trialEndMs, NOW);
  // Inside the grace: the webhook that moves it on may be late.
  assert.equal(at(NOW), true);
  assert.equal(at(NOW - DAY), true);
  assert.equal(at(NOW - CARD_TRIAL_GRACE_MS + 1), true);
  // At and past the grace: stale.
  assert.equal(at(NOW - CARD_TRIAL_GRACE_MS), false);
  assert.equal(at(NOW - 30 * DAY), false);
  // Missing or unreadable trial end: not paid.
  for (const end of [undefined, null, '', 'soon', Number.NaN, {}]) {
    assert.equal(hasPaidOrCardTrialSubscription('trialing', 'sub_test_1', end, NOW), false, `end ${String(end)}`);
  }
  // Timestamp, Date and epoch ms all read.
  for (const end of [AHEAD, new Date(NOW + DAY), NOW + DAY]) {
    assert.equal(hasPaidOrCardTrialSubscription('trialing', 'sub_test_1', end, NOW), true);
  }
});

test('account and facility forms read their own fields', () => {
  assert.equal(accountHasPaidOrCardTrialSubscription(cardTrialAccount, NOW), true);
  assert.equal(accountHasPaidOrCardTrialSubscription(appTrialAccount, NOW), false);
  assert.equal(accountHasPaidOrCardTrialSubscription({ subscriptionStatus: 'active' }, NOW), true);
  assert.equal(accountHasPaidOrCardTrialSubscription(null, NOW), false);
  // The facility's field names, not the account's.
  assert.equal(
    accountHasPaidOrCardTrialSubscription(
      { subscriptionStatus: 'trialing', stripePlatformSubscriptionId: 'sub_x', subscriptionTrialEnd: AHEAD },
      NOW,
    ),
    false,
  );
  assert.equal(
    accountHasPaidOrCardTrialSubscription(
      { subscriptionStatus: 'trialing', stripeSubscriptionId: 'sub_x', platformSubscriptionTrialEnd: AHEAD },
      NOW,
    ),
    false,
    'the account trial end is subscriptionTrialEnd',
  );
  // Stale account card trial.
  assert.equal(
    accountHasPaidOrCardTrialSubscription({ ...cardTrialAccount, subscriptionTrialEnd: ts(NOW - 10 * DAY) }, NOW),
    false,
  );

  assert.equal(facilityHasPaidOrCardTrialSubscription(cardTrialFacility, NOW), true);
  assert.equal(facilityHasPaidOrCardTrialSubscription({ platformSubscriptionStatus: 'active' }, NOW), true);
  assert.equal(facilityHasPaidOrCardTrialSubscription({ platformSubscriptionStatus: 'trialing' }, NOW), false);
  assert.equal(
    facilityHasPaidOrCardTrialSubscription(
      { platformSubscriptionStatus: 'trialing', stripeSubscriptionId: 'sub_x', platformSubscriptionTrialEnd: AHEAD },
      NOW,
    ),
    false,
  );
  assert.equal(
    facilityHasPaidOrCardTrialSubscription(
      { platformSubscriptionStatus: 'trialing', stripePlatformSubscriptionId: 'sub_x', subscriptionTrialEnd: AHEAD },
      NOW,
    ),
    false,
    'the facility trial end is platformSubscriptionTrialEnd',
  );
  assert.equal(
    facilityHasPaidOrCardTrialSubscription({ ...cardTrialFacility, platformSubscriptionTrialEnd: ts(NOW - 10 * DAY) }, NOW),
    false,
  );
  assert.equal(facilityHasPaidOrCardTrialSubscription(undefined, NOW), false);
});

test('owner: the account, or any facility given', () => {
  assert.equal(ownerHasPaidOrCardTrialSubscription(cardTrialAccount, [], NOW), true);
  // Per-facility billing: the account rolls up to trialing with no subscription id.
  assert.equal(ownerHasPaidOrCardTrialSubscription(appTrialAccount, [{}, cardTrialFacility], NOW), true);
  assert.equal(ownerHasPaidOrCardTrialSubscription(appTrialAccount, [{ platformSubscriptionStatus: 'past_due' }], NOW), false);
  assert.equal(
    ownerHasPaidOrCardTrialSubscription(appTrialAccount, [{ ...cardTrialFacility, platformSubscriptionTrialEnd: undefined }], NOW),
    false,
  );
  assert.equal(ownerHasPaidOrCardTrialSubscription(null, [], NOW), false);
});

test('isUnpaidAppTrial: trialing with no card anywhere (a stale card trial is not a card)', () => {
  assert.equal(isUnpaidAppTrial(appTrialAccount, [], NOW), true);
  assert.equal(isUnpaidAppTrial(appTrialAccount, [{ platformSubscriptionStatus: 'cancelled' }], NOW), true);
  assert.equal(isUnpaidAppTrial(cardTrialAccount, [], NOW), false);
  assert.equal(isUnpaidAppTrial(appTrialAccount, [cardTrialFacility], NOW), false);
  assert.equal(isUnpaidAppTrial(appTrialAccount, [{ platformSubscriptionStatus: 'active' }], NOW), false);
  // A trialing account whose card trial ended long ago, with no webhook since: back to the trial limits.
  assert.equal(isUnpaidAppTrial({ ...cardTrialAccount, subscriptionTrialEnd: ts(NOW - 10 * DAY) }, [], NOW), true);
  // Not trialing at all is not the trial, whatever else is true.
  for (const status of ['active', 'pastDue', 'cancelled', 'pendingApproval']) {
    assert.equal(isUnpaidAppTrial({ subscriptionStatus: status }, [], NOW), false, status);
  }
  assert.equal(isUnpaidAppTrial(undefined, [], NOW), false);
});

test('the default clock is now', () => {
  const soon = ts(Date.now() + DAY);
  assert.equal(hasPaidOrCardTrialSubscription('trialing', 'sub_test_1', soon), true);
  assert.equal(accountHasPaidOrCardTrialSubscription({ ...cardTrialAccount, subscriptionTrialEnd: soon }), true);
  assert.equal(hasPaidOrCardTrialSubscription('trialing', 'sub_test_1', Date.now() - 10 * DAY), false);
});

test('ownerOnUnpaidAppTrial reads linked facilities only when it has to', async () => {
  let loads = 0;
  const load = (docs: Record<string, unknown>[]) => async () => {
    loads += 1;
    return docs;
  };

  // The account decides: no read.
  assert.equal(await ownerOnUnpaidAppTrial(cardTrialAccount, {}, load([]), NOW), false);
  assert.equal(await ownerOnUnpaidAppTrial({ subscriptionStatus: 'active' }, {}, load([]), NOW), false);
  assert.equal(await ownerOnUnpaidAppTrial({ subscriptionStatus: 'cancelled' }, {}, load([]), NOW), false);
  // This facility has the card: no read.
  assert.equal(await ownerOnUnpaidAppTrial(appTrialAccount, cardTrialFacility, load([]), NOW), false);
  assert.equal(loads, 0);

  // Another facility of the account has the card.
  assert.equal(await ownerOnUnpaidAppTrial(appTrialAccount, {}, load([{}, cardTrialFacility]), NOW), false);
  // Nothing has one: the unpaid app trial.
  assert.equal(await ownerOnUnpaidAppTrial(appTrialAccount, {}, load([{ platformSubscriptionStatus: 'trialing' }]), NOW), true);
  // Another facility's card trial went stale: the unpaid app trial.
  assert.equal(
    await ownerOnUnpaidAppTrial(appTrialAccount, {}, load([{ ...cardTrialFacility, platformSubscriptionTrialEnd: ts(NOW - 5 * DAY) }]), NOW),
    true,
  );
  assert.equal(loads, 3);

  await assert.rejects(
    ownerOnUnpaidAppTrial(appTrialAccount, {}, async () => {
      throw new Error('read failed');
    }, NOW),
    /read failed/,
  );
});
