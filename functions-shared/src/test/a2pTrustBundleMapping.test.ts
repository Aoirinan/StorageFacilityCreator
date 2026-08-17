import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildA2pMessagingProfileAttributes,
  buildAddressPayload,
  buildAuthorizedRepresentativeAttributes,
  buildBusinessInformationAttributes,
  formatEvaluationFailures,
  mapBusinessType,
  normalizeEin,
  normalizeWebsiteUrl,
  summarizeEvaluation,
  toE164UsPhone,
  type TrustBundleInput,
} from '../twilio/a2pTrustBundleMapping';

const input = (over: Partial<TrustBundleInput> = {}): TrustBundleInput => ({
  legalBusinessName: 'Keepsake Self Storage LLC',
  businessType: 'LLC',
  ein: '12-3456789',
  addressLine1: '4180 US HWY 82 East',
  city: 'Gainesville',
  state: 'tx',
  postalCode: '76240',
  website: 'keepsakestorage.com',
  supportEmail: 'owner@keepsakestorage.com',
  supportPhone: '(940) 555-0147',
  representativeFirstName: 'Russell',
  representativeLastName: 'Forsyth',
  ...over,
});

// --- normalizers ------------------------------------------------------------

test('normalizeEin strips formatting', () => {
  assert.equal(normalizeEin('12-3456789'), '123456789');
  assert.equal(normalizeEin('12 3456789'), '123456789');
  assert.equal(normalizeEin(undefined), '');
});

test('toE164UsPhone handles 10-digit, 11-digit and junk', () => {
  assert.equal(toE164UsPhone('(940) 555-0147'), '+19405550147');
  assert.equal(toE164UsPhone('1-940-555-0147'), '+19405550147');
  assert.equal(toE164UsPhone('+1 940 555 0147'), '+19405550147');
  // Too short to be a US number — better to send empty and fail evaluation
  // than to send a malformed number to carrier vetting.
  assert.equal(toE164UsPhone('5550147'), '');
});

test('normalizeWebsiteUrl forces an absolute URL', () => {
  assert.equal(normalizeWebsiteUrl('keepsakestorage.com'), 'https://keepsakestorage.com');
  assert.equal(normalizeWebsiteUrl('http://a.com'), 'http://a.com');
  assert.equal(normalizeWebsiteUrl('https://a.com'), 'https://a.com');
  assert.equal(normalizeWebsiteUrl('  '), '');
});

// --- business type mapping --------------------------------------------------

test('mapBusinessType covers every option the app form offers', () => {
  assert.deepEqual(mapBusinessType('LLC'), {
    businessType: 'Limited Liability Corporation',
    companyType: 'private',
    soleProprietor: false,
  });
  assert.deepEqual(mapBusinessType('Corp'), {
    businessType: 'Corporation',
    companyType: 'private',
    soleProprietor: false,
  });
  assert.deepEqual(mapBusinessType('Nonprofit'), {
    businessType: 'Non-profit Corporation',
    companyType: 'non-profit',
    soleProprietor: false,
  });
  assert.deepEqual(mapBusinessType('Sole Prop'), {
    businessType: 'Sole Proprietorship',
    companyType: 'private',
    soleProprietor: true,
  });
});

test('mapBusinessType rejects anything not on the form', () => {
  assert.equal(mapBusinessType('S-Corp'), undefined);
  assert.equal(mapBusinessType(''), undefined);
  assert.equal(mapBusinessType(undefined), undefined);
});

// --- attribute builders -----------------------------------------------------

test('buildBusinessInformationAttributes emits the policy field names', () => {
  const attrs = buildBusinessInformationAttributes(input());
  assert.deepEqual(Object.keys(attrs).sort(), [
    'business_identity',
    'business_industry',
    'business_name',
    'business_regions_of_operation',
    'business_registration_identifier',
    'business_registration_number',
    'business_type',
    'social_media_profile_urls',
    'website_url',
  ]);
  assert.equal(attrs.business_registration_number, '123456789');
  assert.equal(attrs.business_registration_identifier, 'EIN');
  assert.equal(attrs.business_type, 'Limited Liability Corporation');
  assert.equal(attrs.website_url, 'https://keepsakestorage.com');
});

test('buildBusinessInformationAttributes throws on an unmapped business type', () => {
  assert.throws(
    () => buildBusinessInformationAttributes(input({ businessType: 'Partnership' as any })),
    /Unsupported business type/,
  );
});

test('buildAuthorizedRepresentativeAttributes emits the policy field names', () => {
  const attrs = buildAuthorizedRepresentativeAttributes(input());
  assert.equal(attrs.first_name, 'Russell');
  assert.equal(attrs.last_name, 'Forsyth');
  assert.equal(attrs.phone_number, '+19405550147');
  assert.equal(attrs.business_title, 'Owner');
  assert.equal(attrs.job_position, 'Other');
});

test('buildA2pMessagingProfileAttributes maps nonprofit to non-profit', () => {
  assert.equal(
    buildA2pMessagingProfileAttributes(input({ businessType: 'Nonprofit' })).company_type,
    'non-profit',
  );
  assert.equal(buildA2pMessagingProfileAttributes(input()).company_type, 'private');
});

test('buildAddressPayload upper-cases region and defaults country to US', () => {
  const addr = buildAddressPayload(input());
  assert.equal(addr.region, 'TX');
  assert.equal(addr.isoCountry, 'US');
  assert.equal(addr.street, '4180 US HWY 82 East');
});

// --- evaluation summarizing -------------------------------------------------

test('summarizeEvaluation treats a compliant evaluation as compliant', () => {
  const summary = summarizeEvaluation({
    status: 'compliant',
    results: [{ passed: true, friendly_name: 'Business Information' }],
  });
  assert.equal(summary.compliant, true);
  assert.deepEqual(summary.failures, []);
  assert.equal(formatEvaluationFailures(summary), '');
});

test('summarizeEvaluation pulls out the specific failing fields', () => {
  const summary = summarizeEvaluation({
    status: 'noncompliant',
    results: [
      { passed: true, friendly_name: 'Authorized Representative #1' },
      {
        passed: false,
        friendly_name: 'Business Information',
        fields: [
          { passed: true, friendly_name: 'Business Name' },
          {
            passed: false,
            friendly_name: 'Business Registration Number',
            failure_reason: 'Value is required',
          },
        ],
      },
    ],
  });
  assert.equal(summary.compliant, false);
  assert.deepEqual(summary.failures, [
    {
      objectType: 'Business Information',
      field: 'Business Registration Number',
      reason: 'Value is required',
    },
  ]);
  assert.match(formatEvaluationFailures(summary), /Business Registration Number: Value is required/);
});

test('summarizeEvaluation still reports a requirement that fails with no field detail', () => {
  const summary = summarizeEvaluation({
    status: 'noncompliant',
    results: [{ passed: false, friendly_name: 'Physical Business Address' }],
  });
  assert.deepEqual(summary.failures, [
    {
      objectType: 'Physical Business Address',
      field: 'missing',
      reason: 'Required item is missing from the bundle',
    },
  ]);
});

test('summarizeEvaluation is not fooled by a compliant status with failing results', () => {
  // Defensive: only trust "compliant" when nothing underneath actually failed,
  // because submitting on a false positive costs a non-refundable brand fee.
  const summary = summarizeEvaluation({
    status: 'compliant',
    results: [
      {
        passed: false,
        friendly_name: 'Business Information',
        fields: [{ passed: false, friendly_name: 'Website Url', failure_reason: 'Invalid' }],
      },
    ],
  });
  assert.equal(summary.compliant, false);
});

test('summarizeEvaluation tolerates a missing or malformed payload', () => {
  assert.deepEqual(summarizeEvaluation(undefined), {
    compliant: false,
    status: '',
    failures: [],
  });
  assert.equal(summarizeEvaluation({ status: 'compliant', results: null }).compliant, true);
});
