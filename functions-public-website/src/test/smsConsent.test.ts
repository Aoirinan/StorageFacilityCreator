import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveSmsConsentFields } from '../smsConsent';

const NOW = { __serverTimestamp: true };

test('explicit consent opts the tenant in and records when and how', () => {
  const fields = resolveSmsConsentFields(
    { smsConsent: true, smsConsentSource: 'publicRentalForm' },
    NOW,
  );
  assert.deepEqual(fields, {
    smsConsentStatus: 'opted_in',
    smsConsentSource: 'publicRentalForm',
    smsConsentTimestamp: NOW,
    smsOptInDate: NOW,
    smsOptOut: false,
  });
});

test('consent defaults to a known source when none is supplied', () => {
  const fields = resolveSmsConsentFields({ smsConsent: true }, NOW);
  assert.equal(fields.smsConsentSource, 'publicRentalForm');
});

test('an unchecked box records a refusal and leaves the tenant opted out', () => {
  const fields = resolveSmsConsentFields({ smsConsent: false }, NOW);
  assert.deepEqual(fields, {
    smsConsentStatus: 'unknown',
    smsConsentSource: null,
    smsConsentTimestamp: null,
    smsOptInDate: null,
    smsOptOut: true,
  });
});

test('the string "false" is not consent', () => {
  // A non-empty string is truthy in JS; a loose check here would opt in a
  // tenant who explicitly declined.
  const fields = resolveSmsConsentFields({ smsConsent: 'false' }, NOW);
  assert.equal(fields.smsConsentStatus, 'unknown');
  assert.equal(fields.smsOptOut, true);
});

test('the string "true" is not consent either', () => {
  // Only a real boolean counts, so a client that stringifies the flag cannot
  // accidentally manufacture consent.
  const fields = resolveSmsConsentFields({ smsConsent: 'true' }, NOW);
  assert.equal(fields.smsConsentStatus, 'unknown');
  assert.equal(fields.smsOptOut, true);
});

test('a reservation predating the consent checkbox is not consent', () => {
  // Reservations created before the checkbox existed carry no flag at all.
  // Those tenants never saw an opt-in, so they must not be textable.
  for (const metadata of [{}, null, undefined, { source: 'publicWebsite' }]) {
    const fields = resolveSmsConsentFields(metadata as any, NOW);
    assert.equal(fields.smsConsentStatus, 'unknown', JSON.stringify(metadata));
    assert.equal(fields.smsOptOut, true, JSON.stringify(metadata));
  }
});
