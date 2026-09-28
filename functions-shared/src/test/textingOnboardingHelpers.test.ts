import test from 'node:test';
import assert from 'node:assert/strict';
import { buildTenantOptInConfirmation, computeA2PStatus } from '../twilio/textingOnboardingHelpers';

test('computeA2PStatus: an approved brand alone is not approved texting', () => {
  // Regression: "APPROVED" on the brand matched and flipped the facility to
  // approved while its campaign was still in carrier review.
  assert.equal(computeA2PStatus('submitted', 'APPROVED', undefined), 'pending');
  assert.equal(computeA2PStatus('pending', 'APPROVED', 'IN_PROGRESS'), 'pending');
});

test('computeA2PStatus: a verified campaign is approved', () => {
  assert.equal(computeA2PStatus('pending', 'APPROVED', 'VERIFIED'), 'approved');
});

test('computeA2PStatus: FAILED on brand or campaign is rejected', () => {
  assert.equal(computeA2PStatus('pending', 'FAILED', undefined), 'rejected');
  assert.equal(computeA2PStatus('pending', 'APPROVED', 'FAILED'), 'rejected');
});

test('computeA2PStatus: nothing filed leaves the status alone', () => {
  assert.equal(computeA2PStatus('draft', undefined, undefined), 'draft');
  assert.equal(computeA2PStatus('approved', undefined, undefined), 'approved');
});

test('opt-in confirmation matches the START reply wording exactly', () => {
  // Filed with the campaign as its opt-in message and sent as the live START
  // reply; carriers compare the two, so this string is pinned verbatim.
  assert.equal(
    buildTenantOptInConfirmation('Example Storage'),
    "Example Storage: you're opted in to account texts about your storage unit. " +
      'Msg frequency varies. Msg & data rates may apply. Reply HELP for help, STOP to opt out.',
  );
});
