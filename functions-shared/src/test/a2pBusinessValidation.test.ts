import test from 'node:test';
import assert from 'node:assert/strict';
import {
  formatA2PValidationIssues,
  isValidEinLast4,
  isValidUsPhone,
  isValidWebsite,
  validateA2PBusinessData,
} from '../twilio/a2pBusinessValidation';

const VALID = {
  legalBusinessName: 'Keepsake Self Storage LLC',
  businessType: 'LLC',
  einLast4: '6565',
  addressLine1: '4180 US HWY 82 East',
  city: 'Paris',
  state: 'TX',
  postalCode: '75460',
  country: 'US',
  supportEmail: 'support@keepsakeselfstorage.com',
  supportPhone: '903-715-7504',
  website: 'https://keepsakeselfstorage.com',
};

test('validateA2PBusinessData accepts a complete, real submission', () => {
  assert.deepEqual(validateA2PBusinessData(VALID), []);
});

// --- the data that actually reached carrier submission ----------------------

test('validateA2PBusinessData rejects the placeholder data found in production', () => {
  const issues = validateA2PBusinessData({
    ...VALID,
    postalCode: '959595', // not a US ZIP
    supportPhone: '99999', // not a phone number
  });
  const fields = issues.map((i) => i.field);
  assert.ok(fields.includes('postalCode'), 'ZIP 959595 must be rejected');
  assert.ok(fields.includes('supportPhone'), 'phone 99999 must be rejected');
});

test('validateA2PBusinessData reports every problem at once', () => {
  const issues = validateA2PBusinessData({});
  const fields = issues.map((i) => i.field).sort();
  assert.deepEqual(fields, [
    'addressLine1',
    'businessType',
    'city',
    'einLast4',
    'legalBusinessName',
    'postalCode',
    'state',
    'supportEmail',
    'supportPhone',
    'website',
  ]);
});

// --- phone ------------------------------------------------------------------

test('isValidUsPhone accepts real formats', () => {
  for (const p of ['9037157504', '903-715-7504', '(903) 715-7504', '+1 903 715 7504']) {
    assert.equal(isValidUsPhone(p), true, `${p} should be valid`);
  }
});

test('isValidUsPhone rejects placeholders and malformed numbers', () => {
  for (const p of ['99999', '000-000-0000', '5555555555', '123', '', '103-715-7504']) {
    assert.equal(isValidUsPhone(p), false, `${p} should be invalid`);
  }
});

// --- ZIP / state ------------------------------------------------------------

test('validateA2PBusinessData accepts ZIP+4 and rejects malformed ZIPs', () => {
  assert.deepEqual(validateA2PBusinessData({ ...VALID, postalCode: '75460-1234' }), []);
  for (const zip of ['959595', '7546', 'ABCDE', '']) {
    const issues = validateA2PBusinessData({ ...VALID, postalCode: zip });
    assert.ok(issues.some((i) => i.field === 'postalCode'), `${zip} should be rejected`);
  }
});

test('validateA2PBusinessData only enforces US ZIP/state rules for US addresses', () => {
  const issues = validateA2PBusinessData({
    ...VALID,
    country: 'CA',
    state: 'Ontario',
    postalCode: 'M5H 2N2',
  });
  const fields = issues.map((i) => i.field);
  assert.ok(!fields.includes('postalCode'));
  assert.ok(!fields.includes('state'));
});

// --- EIN --------------------------------------------------------------------

test('isValidEinLast4 requires exactly four digits', () => {
  assert.equal(isValidEinLast4('6565'), true);
  for (const v of ['656', '65655', 'abcd', '', null]) {
    assert.equal(isValidEinLast4(v), false, `${v} should be invalid`);
  }
});

// --- website ----------------------------------------------------------------

test('isValidWebsite accepts real URLs, with or without scheme', () => {
  for (const w of ['https://example.com', 'http://example.com', 'example.com', 'https://sub.example.co.uk/path']) {
    assert.equal(isValidWebsite(w), true, `${w} should be valid`);
  }
});

test('isValidWebsite rejects values that are not resolvable hostnames', () => {
  for (const w of ['', 'notaurl', 'http://', 'https://nodot', 'ftp://example.com']) {
    assert.equal(isValidWebsite(w), false, `${w} should be invalid`);
  }
});

// --- formatting -------------------------------------------------------------

test('formatA2PValidationIssues produces a readable single-line summary', () => {
  const out = formatA2PValidationIssues([
    { field: 'postalCode', message: 'Enter a valid US ZIP code.' },
    { field: 'supportPhone', message: 'Enter a valid 10-digit US support phone number.' },
  ]);
  assert.match(out, /postalCode/);
  assert.match(out, /supportPhone/);
});
