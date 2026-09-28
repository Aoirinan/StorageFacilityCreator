import assert from 'node:assert/strict';
import test from 'node:test';
import {
  decideSharedNumberSend,
  isAccountInGoodStanding,
  SharedNumberInputs,
} from '../sharedNumberPolicy';

function input(overrides: Partial<SharedNumberInputs> = {}): SharedNumberInputs {
  return {
    usesOwnNumber: false,
    account: { subscriptionStatus: 'trialing' },
    sharedSendsThisMonth: 0,
    sharedMonthlyCap: 500,
    ...overrides,
  };
}

test('a facility on its own approved number is not limited here', () => {
  const decision = decideSharedNumberSend(
    input({
      usesOwnNumber: true,
      account: { subscriptionStatus: 'cancelled' },
      sharedSendsThisMonth: 10_000,
    }),
  );
  assert.equal(decision.allowed, true);
});

test('a trial facility sends on the shared number without registering first', () => {
  assert.equal(decideSharedNumberSend(input()).allowed, true);
});

// Owner decision 2026-09-27: the end of the trial no longer ends shared texting.
test('a paying facility keeps the shared number after its trial, registered or not', () => {
  for (const status of ['active', 'ACTIVE', 'pastDue', 'past_due']) {
    const decision = decideSharedNumberSend(input({ account: { subscriptionStatus: status } }));
    assert.equal(decision.allowed, true, status);
  }
});

test('a billing-exempt facility sends whatever its subscription says', () => {
  for (const status of ['cancelled', '', 'pendingApproval']) {
    const decision = decideSharedNumberSend(
      input({ account: { subscriptionStatus: status, billingExempt: true } }),
    );
    assert.equal(decision.allowed, true, status);
  }
});

test('a cancelled, suspended or unapproved account is refused', () => {
  const cases: SharedNumberInputs['account'][] = [
    { subscriptionStatus: 'cancelled' },
    { subscriptionStatus: 'canceled' },
    { subscriptionStatus: 'unpaid' },
    { subscriptionStatus: 'pendingApproval' },
    { subscriptionStatus: '' },
    { subscriptionStatus: 'active', suspended: true },
    { subscriptionStatus: 'active', suspended: true, billingExempt: true },
  ];
  for (const account of cases) {
    const decision = decideSharedNumberSend(input({ account }));
    assert.equal(decision.allowed, false, JSON.stringify(account));
    assert.equal(decision.refusal, 'account_inactive');
    assert.match(decision.message ?? '', /subscription/);
  }
});

test('an account we could not read is treated as in good standing', () => {
  assert.equal(isAccountInGoodStanding(null), true);
  assert.equal(decideSharedNumberSend(input({ account: null })).allowed, true);
});

test('the monthly ceiling on shared traffic is enforced', () => {
  const atCap = decideSharedNumberSend(input({ sharedSendsThisMonth: 500 }));
  assert.equal(atCap.allowed, false);
  assert.equal(atCap.refusal, 'shared_cap');

  const justUnder = decideSharedNumberSend(input({ sharedSendsThisMonth: 499 }));
  assert.equal(justUnder.allowed, true);
});

test('the ceiling applies to paying and exempt facilities too, since the number is shared', () => {
  for (const account of [{ subscriptionStatus: 'active' }, { subscriptionStatus: 'x', billingExempt: true }]) {
    const decision = decideSharedNumberSend(input({ account, sharedSendsThisMonth: 600 }));
    assert.equal(decision.allowed, false);
    assert.equal(decision.refusal, 'shared_cap');
  }
});

test('an inactive account is named before the ceiling, so the message names the real fix', () => {
  const decision = decideSharedNumberSend(
    input({ account: { subscriptionStatus: 'cancelled' }, sharedSendsThisMonth: 9_999 }),
  );
  assert.equal(decision.refusal, 'account_inactive');
});
