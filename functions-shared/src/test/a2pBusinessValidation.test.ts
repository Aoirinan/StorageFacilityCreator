import test from 'node:test';
import assert from 'node:assert/strict';
import {
  formatA2PValidationIssues,
  isValidEinLast4,
  isValidFullEin,
  isValidUsPhone,
  isValidWebsite,
  validateA2PBusinessData,
} from '../twilio/a2pBusinessValidation';

const VALID = {
  legalBusinessName: 'Example Storage LLC',
  businessType: 'LLC',
  ein: '12-3456789',
  addressLine1: '100 Example Road',
  city: 'Austin',
  state: 'TX',
  postalCode: '78701',
  country: 'US',
  supportEmail: 'support@example.com',
  supportPhone: '512-555-0147',
  website: 'https://example.com',
  representativeFirstName: 'Jane',
  representativeLastName: 'Doe',
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
    'ein',
    'legalBusinessName',
    'postalCode',
    'representativeFirstName',
    'representativeLastName',
    'state',
    'supportEmail',
    'supportPhone',
    'website',
  ]);
});

// --- EIN --------------------------------------------------------------------

test('validateA2PBusinessData accepts the full EIN the submission form sends', () => {
  // Regression: the validator only read `einLast4`, but the form posts `ein`,
  // so every business-info save was rejected with "enter the last 4 digits".
  assert.deepEqual(validateA2PBusinessData({ ...VALID, ein: '123456789' }), []);
  assert.deepEqual(validateA2PBusinessData({ ...VALID, ein: '12-3456789' }), []);
});

test('validateA2PBusinessData does not accept a stored einLast4 in place of the EIN', () => {
  // Regression: the stored last four used to satisfy validation, so a save with
  // no EIN reached Twilio with an empty business_registration_number.
  const { ein, ...withoutEin } = VALID;
  const fields = validateA2PBusinessData({ ...withoutEin, einLast4: '6789' } as any).map(
    (i) => i.field,
  );
  assert.ok(fields.includes('ein'));
  assert.ok(validateA2PBusinessData({ ...VALID, ein: '' }).some((i) => i.field === 'ein'));
});

test('validateA2PBusinessData can skip the EIN for a product-only rebuild', () => {
  const { ein, ...withoutEin } = VALID;
  assert.deepEqual(validateA2PBusinessData(withoutEin, { requireEin: false }), []);
});

test('validateA2PBusinessData rejects a malformed or placeholder EIN', () => {
  for (const bad of ['1234', '12345678', '1234567890', '000000000', '111111111']) {
    const fields = validateA2PBusinessData({ ...VALID, ein: bad }).map((i) => i.field);
    assert.ok(fields.includes('ein'), `EIN ${bad} must be rejected`);
  }
});

test('isValidFullEin requires nine non-repeating digits', () => {
  assert.equal(isValidFullEin('12-3456789'), true);
  assert.equal(isValidFullEin('123456789'), true);
  assert.equal(isValidFullEin('12345678'), false);
  assert.equal(isValidFullEin('999999999'), false);
  assert.equal(isValidFullEin(undefined), false);
});

// --- authorized representative ----------------------------------------------

test('validateA2PBusinessData requires a named authorized representative', () => {
  const fields = validateA2PBusinessData({
    ...VALID,
    representativeFirstName: '',
    representativeLastName: 'X',
  }).map((i) => i.field);
  assert.ok(fields.includes('representativeFirstName'));
  assert.ok(fields.includes('representativeLastName'));
});

// --- phone ------------------------------------------------------------------

test('isValidUsPhone accepts real formats', () => {
  for (const p of ['5125550147', '512-555-0147', '(512) 555-0147', '+1 512 555 0147']) {
    assert.equal(isValidUsPhone(p), true, `${p} should be valid`);
  }
});

test('isValidUsPhone rejects placeholders and malformed numbers', () => {
  for (const p of ['99999', '000-000-0000', '5555555555', '123', '', '103-555-0147']) {
    assert.equal(isValidUsPhone(p), false, `${p} should be invalid`);
  }
});

// --- ZIP / state ------------------------------------------------------------

test('validateA2PBusinessData accepts ZIP+4 and rejects malformed ZIPs', () => {
  assert.deepEqual(validateA2PBusinessData({ ...VALID, postalCode: '78701-1234' }), []);
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

// --- sole proprietor -------------------------------------------------------

const SOLE_PROP_VALID = {
  legalBusinessName: 'Example Storage',
  businessType: 'Sole Prop',
  // no EIN
  addressLine1: '100 Example Road',
  city: 'Austin',
  state: 'TX',
  postalCode: '78701',
  country: 'US',
  supportEmail: 'owner@example.com',
  supportPhone: '512-555-0147',
  website: 'https://example.com',
  representativeFirstName: 'Jane',
  representativeLastName: 'Doe',
  mobilePhone: '512-555-0175',
};

test('sole proprietor: valid with a mobile and no EIN', () => {
  assert.deepEqual(validateA2PBusinessData(SOLE_PROP_VALID), []);
});

test('sole proprietor: EIN is not required', () => {
  const issues = validateA2PBusinessData({ ...SOLE_PROP_VALID });
  assert.equal(issues.some((i) => i.field === 'ein'), false);
});

test('sole proprietor: a missing/invalid mobile is rejected', () => {
  const issues = validateA2PBusinessData({ ...SOLE_PROP_VALID, mobilePhone: '' });
  assert.equal(issues.some((i) => i.field === 'mobilePhone'), true);
  const bad = validateA2PBusinessData({ ...SOLE_PROP_VALID, mobilePhone: '5555555555' });
  assert.equal(bad.some((i) => i.field === 'mobilePhone'), true);
});

test('non-sole-prop still requires an EIN and ignores mobile', () => {
  const noEin = { ...VALID };
  delete (noEin as { ein?: unknown }).ein;
  const issues = validateA2PBusinessData(noEin);
  assert.equal(issues.some((i) => i.field === 'ein'), true);
});
