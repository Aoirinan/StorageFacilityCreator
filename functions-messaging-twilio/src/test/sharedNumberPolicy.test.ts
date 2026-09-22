import assert from 'node:assert/strict';
import test from 'node:test';
import {
  decideSharedNumberSend,
  isRegistrationInProgress,
  SharedNumberInputs,
} from '../sharedNumberPolicy';

function input(overrides: Partial<SharedNumberInputs> = {}): SharedNumberInputs {
  return {
    usesOwnNumber: false,
    a2pStatus: 'draft',
    registrationAvailable: true,
    inTrial: true,
    sharedSendsThisMonth: 0,
    sharedMonthlyCap: 500,
    ...overrides,
  };
}

test('a facility on its own approved number is not limited here', () => {
  const decision = decideSharedNumberSend(
    input({ usesOwnNumber: true, inTrial: false, sharedSendsThisMonth: 10_000 }),
  );
  assert.equal(decision.allowed, true);
});

test('a trial facility sends on the shared number without registering first', () => {
  assert.equal(decideSharedNumberSend(input()).allowed, true);
});

test('a paying facility that never started registration is refused', () => {
  const decision = decideSharedNumberSend(input({ inTrial: false }));
  assert.equal(decision.allowed, false);
  assert.equal(decision.refusal, 'registration_required');
  assert.match(decision.message ?? '', /Texting setup/);
  assert.match(decision.message ?? '', /Email reminders are unaffected/);
});

test('a paying facility waiting on the carrier keeps sending', () => {
  for (const status of ['pending', 'in_review', 'submitted', 'verifying', 'PENDING_REVIEW']) {
    const decision = decideSharedNumberSend(input({ inTrial: false, a2pStatus: status }));
    assert.equal(decision.allowed, true, status);
  }
});

test('a rejected registration is not "in progress"', () => {
  assert.equal(isRegistrationInProgress('rejected'), false);
  const decision = decideSharedNumberSend(input({ inTrial: false, a2pStatus: 'rejected' }));
  assert.equal(decision.allowed, false);
  assert.equal(decision.refusal, 'registration_required');
});

test('we do not demand a registration the operator cannot yet start', () => {
  const decision = decideSharedNumberSend(
    input({ inTrial: false, registrationAvailable: false }),
  );
  assert.equal(decision.allowed, true);
});

test('the monthly ceiling on shared traffic is enforced', () => {
  const atCap = decideSharedNumberSend(input({ sharedSendsThisMonth: 500 }));
  assert.equal(atCap.allowed, false);
  assert.equal(atCap.refusal, 'shared_cap');

  const justUnder = decideSharedNumberSend(input({ sharedSendsThisMonth: 499 }));
  assert.equal(justUnder.allowed, true);
});

test('the ceiling applies to a trial facility too, since the number is shared', () => {
  const decision = decideSharedNumberSend(
    input({ inTrial: true, sharedSendsThisMonth: 600 }),
  );
  assert.equal(decision.allowed, false);
  assert.equal(decision.refusal, 'shared_cap');
});

test('registration is checked before the ceiling, so the message names the real fix', () => {
  const decision = decideSharedNumberSend(
    input({ inTrial: false, sharedSendsThisMonth: 9_999 }),
  );
  assert.equal(decision.refusal, 'registration_required');
});

test('an unknown or blank status is treated as not filed', () => {
  assert.equal(isRegistrationInProgress(undefined), false);
  assert.equal(isRegistrationInProgress(''), false);
  assert.equal(isRegistrationInProgress('draft'), false);
  assert.equal(isRegistrationInProgress('approved'), false);
});
