import assert from 'node:assert/strict';
import test from 'node:test';
import {
  decideTenantRecipientConsent,
  tenantHasSmsConsent,
  tenantOptedOut,
} from '../tenantSmsConsent';

const consented = { id: 't1', phone: '903-555-0100', smsOptInDate: new Date(2026, 8, 1), smsOptOut: false };

test('a number that belongs to no tenant is not decided here', () => {
  assert.deepEqual(decideTenantRecipientConsent([]), { allowed: true, isTenantNumber: false });
});

test('a consenting tenant may be texted, in either recorded shape', () => {
  assert.equal(decideTenantRecipientConsent([consented]).allowed, true);
  assert.equal(
    decideTenantRecipientConsent([{ id: 't1', smsConsentStatus: 'opted_in' }]).allowed,
    true,
  );
});

// This used to be checked only when the facility had enhancedOptOut or
// texting onboarding on; the decision no longer takes those inputs at all.
test('a tenant who replied STOP is refused, whatever the facility settings', () => {
  for (const t of [
    { ...consented, smsOptOut: true },
    { ...consented, smsConsentStatus: 'opted_out' },
  ]) {
    const d = decideTenantRecipientConsent([t], 't1');
    assert.equal(d.allowed, false);
    assert.equal(d.refusal, 'opted_out');
  }
});

test('a tenant with no recorded consent is refused', () => {
  const d = decideTenantRecipientConsent([{ id: 't1', phone: '903-555-0100' }]);
  assert.equal(d.allowed, false);
  assert.equal(d.refusal, 'no_consent');
});

test('an opt-out on any tenant with the number blocks it: STOP belongs to the number', () => {
  const d = decideTenantRecipientConsent([consented, { id: 't2', smsOptOut: true }], 't1');
  assert.equal(d.refusal, 'opted_out');
});

test('the targeted tenant decides consent when it has the number', () => {
  const noConsent = { id: 't2', phone: '903-555-0100' };
  assert.equal(decideTenantRecipientConsent([consented, noConsent], 't2').refusal, 'no_consent');
  assert.equal(decideTenantRecipientConsent([consented, noConsent], 't1').allowed, true);
  // Without a target, one consenting holder of the number is enough.
  assert.equal(decideTenantRecipientConsent([consented, noConsent]).allowed, true);
});

test('field readers', () => {
  assert.equal(tenantOptedOut({ id: 'x', smsConsentStatus: 'OPTED_OUT' }), true);
  assert.equal(tenantHasSmsConsent({ id: 'x', smsOptInDate: new Date(), smsOptOut: true }), false);
  assert.equal(tenantHasSmsConsent({ id: 'x' }), false);
});
