import test from 'node:test';
import assert from 'node:assert/strict';

import {
  DEFAULT_OWNER_ONBOARDING_GATE,
  isOwnerOnboardingRecipientAllowed,
  type OwnerOnboardingGateConfig,
} from '../email/ownerOnboardingGate';

const admins = new Set(['boss@sfc.com']);
const isAdmin = (email: string) => admins.has(email);

function config(overrides: Partial<OwnerOnboardingGateConfig> = {}): OwnerOnboardingGateConfig {
  return { ...DEFAULT_OWNER_ONBOARDING_GATE, ...overrides };
}

test('defaults are closed: a new owner gets nothing before launch', () => {
  assert.equal(DEFAULT_OWNER_ONBOARDING_GATE.ownerEmailsEnabled, false);
  assert.deepEqual(DEFAULT_OWNER_ONBOARDING_GATE.allowedTestRecipients, []);
  assert.equal(isOwnerOnboardingRecipientAllowed('owner@example.com', config(), isAdmin), false);
});

test('flipping the flag lets every owner through', () => {
  const c = config({ ownerEmailsEnabled: true });
  assert.equal(isOwnerOnboardingRecipientAllowed('owner@example.com', c, isAdmin), true);
});

test('super admins always pass, so the flow can be tested before launch', () => {
  assert.equal(isOwnerOnboardingRecipientAllowed('boss@sfc.com', config(), isAdmin), true);
  assert.equal(isOwnerOnboardingRecipientAllowed('BOSS@SFC.COM', config(), isAdmin), true);
});

test('one named address can be let through while the flag is still off', () => {
  const c = config({ allowedTestRecipients: ['caprockstorage@gmail.com'] });
  assert.equal(isOwnerOnboardingRecipientAllowed('caprockstorage@gmail.com', c, isAdmin), true);
  assert.equal(isOwnerOnboardingRecipientAllowed('someone.else@gmail.com', c, isAdmin), false);
});

test('recipient matching ignores case and surrounding whitespace', () => {
  const c = config({ allowedTestRecipients: ['  CapRockStorage@Gmail.com '] });
  assert.equal(isOwnerOnboardingRecipientAllowed(' caprockstorage@GMAIL.com ', c, isAdmin), true);
});

test('an empty recipient is never allowed, even with the flag on', () => {
  assert.equal(isOwnerOnboardingRecipientAllowed('', config({ ownerEmailsEnabled: true }), isAdmin), false);
  assert.equal(isOwnerOnboardingRecipientAllowed('   ', config({ ownerEmailsEnabled: true }), isAdmin), false);
});

test('the onboarding flag is independent of the tenant outbound flag', () => {
  // Same shape as customerOutboundGate on purpose, but a separate document, so
  // switching on owner mail must not unmute tenant mail or vice versa.
  const c = config({ ownerEmailsEnabled: true });
  assert.equal(isOwnerOnboardingRecipientAllowed('owner@example.com', c, isAdmin), true);
  assert.equal(isOwnerOnboardingRecipientAllowed('owner@example.com', config(), isAdmin), false);
});
