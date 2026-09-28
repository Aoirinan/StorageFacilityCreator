import assert from 'node:assert/strict';
import test from 'node:test';
import {
  A2P_TRUST_PRODUCT_POLICY_SID,
  SECONDARY_CUSTOMER_PROFILE_POLICY_SID,
  buildAndEvaluateTrustBundle,
  describeBusinessDetailsLock,
  resetPrimaryCustomerProfileCache,
  resolveA2PPolicySids,
  type FacilityDocRef,
} from '../a2pTrustBundle';
import {
  buildBrandRegistrationParams,
  buildCampaignMessageFlow,
  campaignFilingFields,
  detectEmbeddedContent,
  fetchUsAppToPersonCampaign,
  fileCampaignWhenBrandApproved,
  prepareCampaignSamples,
} from '../a2pCampaign';
import type { A2PTwilioClient } from '../a2pTwilioTypes';
import type { TrustBundleInput } from '@sfc/functions-shared';

import { fakeTwilio, ops, type Call } from './fakeTwilio';


function facilityRef(id = 'facility123'): FacilityDocRef & { writes: Record<string, any>[] } {
  const writes: Record<string, any>[] = [];
  return {
    id,
    writes,
    set: async (data: Record<string, unknown>) => {
      writes.push(data);
    },
  };
}

const INPUT: TrustBundleInput = {
  legalBusinessName: 'Example Storage LLC',
  businessType: 'LLC',
  ein: '12-3456789',
  addressLine1: '100 Example Road',
  city: 'Austin',
  state: 'TX',
  postalCode: '78701',
  website: 'https://example.com',
  supportEmail: 'owner@example.com',
  supportPhone: '(512) 555-0147',
  representativeFirstName: 'Jane',
  representativeLastName: 'Doe',
};

const POLICIES = resolveA2PPolicySids({});


test.beforeEach(() => {
  resetPrimaryCustomerProfileCache();
  delete process.env.TWILIO_PRIMARY_CUSTOMER_PROFILE_SID;
});

// --- policy pinning ----------------------------------------------------------

test('policy SIDs are the documented ISV policies, whatever policies.list returns', async () => {
  assert.deepEqual(POLICIES, {
    customerProfilePolicySid: 'RNdfbf3fae0e1107f8aded0e7cead80bf5',
    trustProductPolicySid: 'RNb0d4771c2c98518d916a3d4cd70a8f8b',
  });

  const { client, calls } = fakeTwilio();
  await buildAndEvaluateTrustBundle(client, facilityRef(), {}, INPUT, POLICIES);

  assert.equal(ops(calls, 'policies.list').length, 0, 'policies must not be looked up by name');
  // The primary profile is found by a filtered list, not by scanning a page.
  assert.deepEqual(ops(calls, 'profile.list')[0].params, {
    policySid: 'RN6433641899984f951173ef1738c3bdd0',
    status: 'twilio-approved',
    limit: 20,
  });
  assert.equal(ops(calls, 'profile.create')[0].params.policySid, SECONDARY_CUSTOMER_PROFILE_POLICY_SID);
  assert.equal(ops(calls, 'product.create')[0].params.policySid, A2P_TRUST_PRODUCT_POLICY_SID);
  assert.equal(ops(calls, 'profile.evaluate')[0].params, SECONDARY_CUSTOMER_PROFILE_POLICY_SID);
  assert.equal(ops(calls, 'product.evaluate')[0].params, A2P_TRUST_PRODUCT_POLICY_SID);
});

test('policy env overrides must be well-formed policy SIDs', () => {
  const valid = 'RN' + 'a'.repeat(32);
  assert.equal(
    resolveA2PPolicySids({ TWILIO_A2P_TRUST_PRODUCT_POLICY_SID: valid }).trustProductPolicySid,
    valid,
  );
  for (const bad of ['A2P Messaging', 'RN123', 'rn' + 'a'.repeat(32), 'RN' + 'A'.repeat(32)]) {
    const sids = resolveA2PPolicySids({
      TWILIO_A2P_TRUST_PRODUCT_POLICY_SID: bad,
      TWILIO_SECONDARY_CUSTOMER_PROFILE_POLICY_SID: bad,
    });
    assert.equal(sids.trustProductPolicySid, A2P_TRUST_PRODUCT_POLICY_SID, bad);
    assert.equal(sids.customerProfilePolicySid, SECONDARY_CUSTOMER_PROFILE_POLICY_SID, bad);
  }
});

// --- a fresh build -----------------------------------------------------------

test('fresh build assigns exactly the documented entities to profile and product', async () => {
  const { client, calls, profiles, products } = fakeTwilio();
  const ref = facilityRef();
  const result = await buildAndEvaluateTrustBundle(client, ref, {}, INPUT, POLICIES);

  const endUsers = ops(calls, 'endUser.create').map((c) => c.params.type);
  assert.deepEqual(endUsers, [
    'customer_profile_business_information',
    'authorized_representative_1',
    'us_a2p_messaging_profile_information',
  ]);

  const profile = profiles.get(result.sids.trustProfileSid)!;
  assert.deepEqual(
    [...profile.assignments].sort(),
    [
      result.sids.businessInfoEndUserSid,
      result.sids.authorizedRepEndUserSid,
      result.sids.addressDocumentSid,
      'BUprimary0000000000000000000000000',
    ].sort(),
  );

  const product = products.get(result.sids.trustProductSid)!;
  assert.deepEqual(
    [...product.assignments].sort(),
    [result.sids.trustProfileSid, result.sids.a2pProfileEndUserSid].sort(),
  );

  // The address document references the address, by the policy's field name.
  const doc = ops(calls, 'document.create')[0].params;
  assert.equal(doc.type, 'customer_profile_address');
  assert.deepEqual(doc.attributes, { address_sids: result.sids.addressSid });

  // The EIN goes to Twilio in full, and nowhere near Firestore.
  const businessInfo = ops(calls, 'endUser.create')[0].params.attributes;
  assert.equal(businessInfo.business_registration_number, '123456789');
  assert.ok(!JSON.stringify(ref.writes).includes('123456789'));

  // Profile evaluated and submitted before the product is evaluated.
  const order = calls.map((c) => c.op);
  assert.ok(order.indexOf('profile.update') < order.indexOf('product.evaluate'));
  assert.equal(result.profileStatus, 'pending-review');
  assert.equal(result.productStatus, 'pending-review');
  assert.equal(result.readyForBrand, true);
  assert.equal(result.approved, false);

  const stored = ref.writes[ref.writes.length - 1];
  assert.equal(stored.a2pBundleReady, true);
  assert.equal(stored.a2pBundleApproved, false);
  assert.equal(stored.a2pBundleProfileStatus, 'pending-review');
  assert.equal(stored.a2pBundleProductStatus, 'pending-review');
  assert.equal(stored.a2pBundleProductPolicySid, A2P_TRUST_PRODUCT_POLICY_SID);
  assert.equal(stored.a2pBundleProfilePolicySid, SECONDARY_CUSTOMER_PROFILE_POLICY_SID);
});

// --- EIN strictness ----------------------------------------------------------

test('a missing or partial EIN stops the build before any Twilio write', async () => {
  for (const ein of [undefined, '', '6789']) {
    const { client, calls } = fakeTwilio();
    await assert.rejects(
      buildAndEvaluateTrustBundle(client, facilityRef(), {}, { ...INPUT, ein }, POLICIES),
      (error: any) => error.code === 'invalid-argument' && /9-digit EIN/.test(error.message),
    );
    assert.deepEqual(
      calls.filter((c) => c.op.endsWith('.create') || c.op.endsWith('.update')),
      [],
      `EIN ${String(ein)} must not create anything in Twilio`,
    );
  }
});

// --- profile in review, product failed: the stuck facility -------------------

test('profile in review: profile untouched, product still built, evaluated and submitted', async () => {
  const { client, calls } = fakeTwilio({
    profile: { sid: 'BUprofile', status: 'in-review' },
    product: { sid: 'BUproduct', status: 'draft' },
  });
  const ref = facilityRef();
  const facility = {
    twilioTrustProfileSid: 'BUprofile',
    twilioTrustProductSid: 'BUproduct',
    twilioBusinessInfoEndUserSid: 'ITbusiness',
    twilioAuthorizedRepEndUserSid: 'ITrep',
    twilioA2pProfileEndUserSid: 'ITa2p',
  };
  // No EIN: a product-only rebuild must not need one.
  const result = await buildAndEvaluateTrustBundle(
    client,
    ref,
    facility,
    { ...INPUT, ein: undefined },
    POLICIES,
  );

  assert.equal(result.profileSkipped, true);
  assert.equal(ops(calls, 'profile.evaluate').length, 0);
  assert.equal(ops(calls, 'profile.update').length, 0);
  assert.equal(ops(calls, 'profile.assign').length, 0);
  assert.equal(ops(calls, 'address.create').length + ops(calls, 'address.update').length, 0);
  assert.deepEqual(
    ops(calls, 'endUser.update').map((c) => c.target),
    ['ITa2p'],
    'only the A2P end user is written',
  );

  assert.equal(ops(calls, 'product.evaluate').length, 1);
  assert.deepEqual(ops(calls, 'product.update')[0].params, { status: 'pending-review' });
  assert.equal(result.productStatus, 'pending-review');
  assert.equal(result.readyForBrand, true);

  const stored = ref.writes[ref.writes.length - 1];
  assert.equal(stored.a2pBundleProfileStatus, 'in-review');
  assert.equal(stored.a2pBundleProductStatus, 'pending-review');
  assert.equal(stored.twilioBusinessInfoEndUserSid, 'ITbusiness', 'existing SIDs kept');
});

test('a product in review blocks the save', async () => {
  const { client, calls } = fakeTwilio({
    profile: { sid: 'BUprofile', status: 'in-review' },
    product: { sid: 'BUproduct', status: 'in-review' },
  });
  await assert.rejects(
    buildAndEvaluateTrustBundle(
      client,
      facilityRef(),
      { twilioTrustProfileSid: 'BUprofile', twilioTrustProductSid: 'BUproduct' },
      INPUT,
      POLICIES,
    ),
    (error: any) => error.code === 'failed-precondition',
  );
  assert.equal(calls.filter((c) => c.op.endsWith('.create')).length, 0);
});

// --- wrong-policy product ----------------------------------------------------

test('a draft or rejected product under the wrong policy is replaced, not deleted', async () => {
  for (const status of ['draft', 'twilio-rejected']) {
    const decoyPolicy = 'RN' + 'd'.repeat(32);
    const { client, calls, products } = fakeTwilio({
      profile: { sid: 'BUprofile', status: 'twilio-approved' },
      product: { sid: 'BUwrong', status, policySid: decoyPolicy },
    });
    const ref = facilityRef();
    const result = await buildAndEvaluateTrustBundle(
      client,
      ref,
      {
        twilioTrustProfileSid: 'BUprofile',
        twilioTrustProductSid: 'BUwrong',
        twilioA2pProfileEndUserSid: 'ITa2p',
      },
      INPUT,
      POLICIES,
    );

    assert.equal(result.replacedProductSid, 'BUwrong');
    assert.notEqual(result.sids.trustProductSid, 'BUwrong');
    assert.equal(ops(calls, 'product.create')[0].params.policySid, A2P_TRUST_PRODUCT_POLICY_SID);
    assert.ok(products.has('BUwrong'), 'old product left in place');
    assert.equal(ops(calls, 'product.evaluate')[0].target, result.sids.trustProductSid);
    assert.deepEqual(
      [...products.get(result.sids.trustProductSid)!.assignments].sort(),
      ['BUprofile', 'ITa2p'],
    );
    const stored = ref.writes[ref.writes.length - 1];
    assert.equal(stored.twilioTrustProductSid, result.sids.trustProductSid);
    assert.equal(stored.a2pBundleProductPolicySid, A2P_TRUST_PRODUCT_POLICY_SID);
  }
});

test('a product under the right policy is reused', async () => {
  const { client, calls } = fakeTwilio({
    profile: { sid: 'BUprofile', status: 'in-review' },
    product: { sid: 'BUright', status: 'draft' },
  });
  const result = await buildAndEvaluateTrustBundle(
    client,
    facilityRef(),
    { twilioTrustProfileSid: 'BUprofile', twilioTrustProductSid: 'BUright' },
    INPUT,
    POLICIES,
  );
  assert.equal(result.sids.trustProductSid, 'BUright');
  assert.equal(ops(calls, 'product.create').length, 0);
});

test('a reused draft bundle is reconciled to exactly the expected assignments', async () => {
  const { client, calls, profiles, products } = fakeTwilio({
    profile: {
      sid: 'BUprofile',
      status: 'draft',
      assignments: ['ITbusiness', 'ITstaleRep', 'ITrep'],
    },
    product: {
      sid: 'BUproduct',
      status: 'twilio-rejected',
      assignments: ['BUdeadProfile', 'ITa2p', 'ITa2pDuplicate'],
    },
  });
  await buildAndEvaluateTrustBundle(
    client,
    facilityRef(),
    {
      twilioTrustProfileSid: 'BUprofile',
      twilioTrustProductSid: 'BUproduct',
      twilioBusinessInfoEndUserSid: 'ITbusiness',
      twilioAuthorizedRepEndUserSid: 'ITrep',
      twilioA2pProfileEndUserSid: 'ITa2p',
      twilioAddressSid: 'ADaddress',
      twilioAddressDocumentSid: 'RDdoc',
    },
    INPUT,
    POLICIES,
  );
  assert.deepEqual(
    [...profiles.get('BUprofile')!.assignments].sort(),
    ['BUprimary0000000000000000000000000', 'ITbusiness', 'ITrep', 'RDdoc'].sort(),
  );
  assert.deepEqual([...products.get('BUproduct')!.assignments].sort(), ['BUprofile', 'ITa2p']);
  assert.deepEqual(
    ops(calls, 'product.unassign').map((c) => c.params).sort(),
    ['BUdeadProfile', 'ITa2pDuplicate'],
  );
  assert.deepEqual(ops(calls, 'profile.unassign').map((c) => c.params), ['ITstaleRep']);
});

// --- failed evaluation -------------------------------------------------------

test('a noncompliant product is stored with its field failures and evaluation/policy SIDs', async () => {
  const { client, calls } = fakeTwilio({
    profile: { sid: 'BUprofile', status: 'in-review' },
    product: { sid: 'BUproduct', status: 'draft' },
    productEvaluation: {
      status: 'noncompliant',
      results: [
        {
          passed: false,
          requirement_friendly_name: 'A2P Messaging Profile Information',
          requirement_name: 'us_a2p_messaging_profile_information',
          invalid: [
            {
              friendly_name: 'Company Type',
              object_field: 'company_type',
              failure_reason: 'Value is not allowed.',
            },
          ],
          valid: [],
        },
      ],
    },
  });
  const ref = facilityRef();
  const result = await buildAndEvaluateTrustBundle(
    client,
    ref,
    { twilioTrustProfileSid: 'BUprofile', twilioTrustProductSid: 'BUproduct' },
    INPUT,
    POLICIES,
  );

  assert.equal(result.readyForBrand, false);
  assert.equal(ops(calls, 'product.update').length, 0, 'a failed product is not submitted');
  const stored = ref.writes[ref.writes.length - 1];
  assert.equal(stored.a2pBundleReady, false);
  assert.equal(stored.a2pBundleProductStatus, 'draft');
  assert.match(stored.a2pBundleIssues, /A2P Messaging Profile Information — Company Type: Value is not allowed/);
  assert.match(stored.a2pBundleIssues, /evaluation EL\d+/);
  assert.match(stored.a2pBundleIssues, new RegExp(`policy ${A2P_TRUST_PRODUCT_POLICY_SID}`));
});

test('a noncompliant profile blocks the product evaluation', async () => {
  const { client, calls } = fakeTwilio({
    profileEvaluation: {
      status: 'noncompliant',
      results: [{ passed: false, requirement_friendly_name: 'Business Information', invalid: [] }],
    },
  });
  const result = await buildAndEvaluateTrustBundle(client, facilityRef(), {}, INPUT, POLICIES);
  assert.equal(ops(calls, 'product.evaluate').length, 0);
  assert.equal(result.trustProductEvaluation.status, 'blocked');
  assert.equal(result.profileStatus, 'draft');
  assert.equal(result.readyForBrand, false);
});

// --- form lock ---------------------------------------------------------------

test('form lock follows the real bundle state', () => {
  assert.deepEqual(describeBusinessDetailsLock({}), {
    businessDetailsLocked: false,
    profileDetailsLocked: false,
    lockReason: null,
  });

  const profileInReview = describeBusinessDetailsLock({
    a2pBundleProfileStatus: 'in-review',
    a2pBundleProductStatus: 'draft',
  });
  assert.equal(profileInReview.businessDetailsLocked, false, 'the product can still be rebuilt');
  assert.equal(profileInReview.profileDetailsLocked, true);
  assert.match(profileInReview.lockReason!, /A2P messaging registration/);

  const productInReview = describeBusinessDetailsLock({
    a2pBundleProfileStatus: 'in-review',
    a2pBundleProductStatus: 'pending-review',
  });
  assert.equal(productInReview.businessDetailsLocked, true);

  assert.equal(
    describeBusinessDetailsLock({ twilioBrandSid: 'BN1', a2pStatus: 'submitted' }).businessDetailsLocked,
    true,
  );
});

// --- brand -------------------------------------------------------------------

test('brand registration sends a2PProfileBundleSid (SDK spelling)', () => {
  const params = buildBrandRegistrationParams({
    twilioTrustProfileSid: 'BUprofile',
    twilioTrustProductSid: 'BUproduct',
    textingBusinessData: { businessType: 'LLC' },
  });
  assert.deepEqual(params, {
    customerProfileBundleSid: 'BUprofile',
    a2PProfileBundleSid: 'BUproduct',
    brandType: 'STANDARD',
    // LOW_VOLUME campaign: automatic secondary vetting buys nothing.
    skipAutomaticSecVet: true,
  });
  assert.equal('a2pProfileBundleSid' in params, false);
});

// --- campaign ----------------------------------------------------------------

const FACILITY = {
  textingConsentMethods: ['online_form', 'verbal_recorded'],
  twilioBrandSid: 'BNbrand',
  twilioMessagingServiceSid: 'MGservice',
  textingBusinessData: {
    legalBusinessName: 'Example Storage LLC',
    dba: 'Example Self Storage',
    businessType: 'LLC',
    city: 'Austin',
    state: 'TX',
    website: 'example.com',
  },
};

const SAMPLES = [
  'Example Self Storage: Friendly reminder, your rent payment is due soon. Reply STOP to opt out, HELP for help.',
  'Example Self Storage: Your account is past due. Please make a payment to avoid late fees. Reply STOP to opt out, HELP for help.',
];

test('campaign is filed through services(MG).usAppToPerson with QE and CM stored separately', async () => {
  const { client, calls } = fakeTwilio({ brandStatus: 'APPROVED' });
  const filing = await fileCampaignWhenBrandApproved(client, FACILITY, SAMPLES);

  const create = ops(calls, 'campaign.create');
  assert.equal(create.length, 1);
  assert.equal(create[0].target, 'MGservice');
  const params = create[0].params;
  assert.equal(params.brandRegistrationSid, 'BNbrand');
  assert.equal(params.usAppToPersonUsecase, 'LOW_VOLUME');
  assert.deepEqual(params.messageSamples, SAMPLES);
  assert.equal(params.hasEmbeddedPhone, false);
  assert.equal(params.hasEmbeddedLinks, false);
  // No keyword opt-in is filed: START only restores a tenant's own STOP.
  assert.equal('optInKeywords' in params, false);
  assert.equal('optInMessage' in params, false);
  assert.equal(params.privacyPolicyUrl, 'https://www.storagefacilitycreator.com/privacy');
  assert.equal(params.termsAndConditionsUrl, 'https://www.storagefacilitycreator.com/sms-terms');
  assert.ok(params.description.length >= 40);

  const fields = campaignFilingFields(filing);
  assert.equal(fields.twilioCampaignSid, 'QE' + '2'.repeat(32));
  assert.equal(fields.twilioCampaignId, 'CM' + '3'.repeat(32));
  assert.equal(fields.a2pCampaignPending, false);
});

test('campaign waits for the brand: nothing filed while the brand is pending', async () => {
  const { client, calls } = fakeTwilio({ brandStatus: 'PENDING' });
  const filing = await fileCampaignWhenBrandApproved(client, FACILITY, SAMPLES);
  assert.equal(filing.filed, false);
  assert.equal(ops(calls, 'campaign.create').length, 0);
  assert.deepEqual(campaignFilingFields(filing), { a2pCampaignPending: true, a2pBrandStatus: 'PENDING' });
});

test('campaign fetch uses the QE sid, and finds a legacy CM id by listing', async () => {
  const { client, calls } = fakeTwilio();
  const qe = 'QE' + '5'.repeat(32);
  const fetched = await fetchUsAppToPersonCampaign(client, 'MGservice', qe);
  assert.equal(fetched?.campaignStatus, 'VERIFIED');
  assert.equal(ops(calls, 'campaign.fetch')[0].target, `MGservice/${qe}`);

  const legacy = await fetchUsAppToPersonCampaign(client, 'MGservice', 'CMlegacy');
  assert.equal(legacy?.campaignStatus, 'IN_PROGRESS');
});

test('fewer than two samples, or a sample under 20 characters, is rejected', () => {
  assert.throws(
    () => prepareCampaignSamples(FACILITY, [SAMPLES[0]]),
    (error: any) => error.code === 'invalid-argument' && /at least 2/.test(error.message),
  );
  assert.throws(() => prepareCampaignSamples(FACILITY, [SAMPLES[0], SAMPLES[0]]), /at least 2/);
  assert.throws(() => prepareCampaignSamples(FACILITY, undefined), /at least 2/);
  assert.throws(
    () => prepareCampaignSamples(FACILITY, [SAMPLES[0], 'Too short']),
    (error: any) => error.code === 'invalid-argument' && /20 characters/.test(error.message),
  );
});

test('samples open with the facility name and are capped at five', () => {
  const prepared = prepareCampaignSamples(FACILITY, [
    'Your gate code has changed. Contact the office for the new one. Reply STOP to opt out.',
    ...SAMPLES,
    'a'.repeat(30),
    'b'.repeat(30),
    'c'.repeat(30),
  ]);
  assert.equal(prepared.length, 5);
  for (const sample of prepared) assert.match(sample, /^Example Self Storage/);
});

test('embedded link / phone flags are computed from the samples', () => {
  assert.deepEqual(detectEmbeddedContent(SAMPLES), { hasEmbeddedLinks: false, hasEmbeddedPhone: false });
  assert.equal(detectEmbeddedContent(['Pay at https://pay.example.com today']).hasEmbeddedLinks, true);
  assert.equal(detectEmbeddedContent(['Call us at (512) 555-0147 today']).hasEmbeddedPhone, true);
  assert.equal(detectEmbeddedContent(['Rent of $130.00 for unit 12 is due']).hasEmbeddedPhone, false);
});

test('message flow names the facility, its website and only the selected consent methods', () => {
  const flow = buildCampaignMessageFlow(FACILITY);
  assert.match(flow, /^Example Self Storage \(Example Storage LLC\)/);
  assert.match(flow, /online rental form/);
  assert.match(flow, /agreeing in person/);
  // START is not an opt-in route on this platform, so it is never claimed.
  assert.doesNotMatch(flow, /START/);
  assert.match(flow, /records each tenant's consent/);
  assert.match(flow, /https:\/\/example\.com/);
  assert.match(flow, /https:\/\/www\.storagefacilitycreator\.com\/sms-terms/);
  assert.match(flow, /https:\/\/www\.storagefacilitycreator\.com\/sms-consent-demo/);
  assert.match(flow, /Reply STOP to opt out, HELP for help/);
  // Not selected, so not claimed.
  assert.doesNotMatch(flow, /rental agreement|consent form/);
  // The old copy pointed reviewers at the operator app, which they cannot use.
  assert.doesNotMatch(flow, /app\.storagefacilitycreator\.com/);
  assert.ok(flow.length >= 40 && flow.length <= 2048);

  const paperOnly = buildCampaignMessageFlow(FACILITY, ['signed_form', 'verbal_recorded']);
  assert.match(paperOnly, /signing a separate SMS consent form/);
  assert.match(paperOnly, /agreeing in person/);
  assert.doesNotMatch(paperOnly, /START|online rental form|sms-consent-demo/);

  assert.throws(() => buildCampaignMessageFlow(FACILITY, []), /how your tenants agree/);
});

test('a stored text_start method (from an earlier build) is dropped, not filed', async () => {
  const { client, calls } = fakeTwilio({ brandStatus: 'APPROVED' });
  await fileCampaignWhenBrandApproved(
    client,
    { ...FACILITY, textingConsentMethods: ['text_start', 'lease_clause'] },
    SAMPLES,
  );
  const params = ops(calls, 'campaign.create')[0].params;
  assert.doesNotMatch(params.messageFlow, /START/);
  assert.match(params.messageFlow, /rental agreement/);
  assert.equal('optInKeywords' in params, false);
});
