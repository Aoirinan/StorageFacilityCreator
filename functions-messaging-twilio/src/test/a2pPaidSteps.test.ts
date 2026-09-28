import assert from 'node:assert/strict';
import test from 'node:test';
import {
  MAX_FREE_BRAND_RESUBMISSIONS,
  buildRefreshStatusFields,
  resetRejectedRegistration,
  runGatedPaidSubmission,
} from '../a2pPaidSteps';
import { A2PLeaseHeldError } from '../a2pSubmission';
import { MAX_DEFERRED_FILING_FAILURES, deferredFilingFailureFields } from '../a2pCampaign';
import { composeOutboundSmsBody } from '../smsBody';
import { fakeTwilio, ops } from './fakeTwilio';
import { DELETE, SERVER_TIME, fakeDb, fakeDeps } from './fakeFirestore';

// Everything below runs the real paid-step code (runGatedPaidSubmission,
// resetRejectedRegistration, buildRefreshStatusFields) against a fake Twilio
// client and an in-memory Firestore.

const FACILITY_ID = 'facility-1';

const APPROVED_FACILITY = {
  name: 'Example Self Storage',
  twilioTrustProfileSid: 'BUprofile',
  twilioTrustProductSid: 'BUproduct',
  textingBusinessData: { legalBusinessName: 'Example Storage LLC', businessType: 'LLC' },
};

const REQUEST = {
  useCases: ['Payment reminders'],
  sampleMessages: [
    'Friendly reminder: your rent payment is due soon. Reply STOP to opt out, HELP for help.',
    'Your account is past due. Please make a payment to avoid late fees. Reply STOP to opt out.',
  ],
  consentMethods: ['online_form'],
  consentConfirmed: true,
};

function approvedTwilio(extra: Parameters<typeof fakeTwilio>[0] = {}) {
  return fakeTwilio({
    profile: { sid: 'BUprofile', status: 'twilio-approved' },
    product: { sid: 'BUproduct', status: 'twilio-approved' },
    ...extra,
  });
}

function setup(facility: Record<string, any>, twilio = approvedTwilio()) {
  const env = fakeDb();
  env.docs.set(FACILITY_ID, { ...facility });
  const deps = fakeDeps(env.db, twilio.client);
  return { env, deps, calls: twilio.calls, ref: env.ref(FACILITY_ID) };
}

// --- concurrency through the real runner ---------------------------------------

test('two tabs submitting at once buy one number and file one brand and campaign', async () => {
  const { env, deps, calls, ref } = setup(APPROVED_FACILITY, approvedTwilio({ purchaseDelayMs: 20 }));

  const results = await Promise.allSettled([
    runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST),
    runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST),
  ]);

  const refused = results.filter((r) => r.status === 'rejected') as PromiseRejectedResult[];
  assert.equal(refused.length, 1);
  assert.ok(refused[0].reason instanceof A2PLeaseHeldError);
  assert.equal(ops(calls, 'number.buy').length, 1);
  assert.equal(ops(calls, 'service.create').length, 1);
  assert.equal(ops(calls, 'brand.create').length, 1);
  assert.equal(ops(calls, 'campaign.create').length, 1);
  assert.equal(env.docs.get(FACILITY_ID)!.a2pSubmitLease, null, 'lease released');
});

test('a second submit after the first finished re-reads the facility and buys nothing again', async () => {
  const { env, deps, calls, ref } = setup(APPROVED_FACILITY);

  await runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST);
  const second = await runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST);

  assert.equal(ops(calls, 'number.buy').length, 1);
  assert.equal(ops(calls, 'brand.create').length, 1);
  assert.equal(ops(calls, 'campaign.create').length, 1);
  // The number is attached once; a re-run sees it (the old check never did).
  assert.equal(ops(calls, 'number.attach').length, 1);
  assert.equal(second.facility.twilioPhoneNumberE164, '+15125550100');
  assert.equal(env.docs.get(FACILITY_ID)!.a2pStatus, 'pending');
});

test('the hourly poll holding the lease makes a tab submit refuse without buying', async () => {
  const { env, deps, calls, ref } = setup({
    ...APPROVED_FACILITY,
    a2pSubmitLease: { holder: 'poller:facility-1', expiresAtMs: Date.now() + 60_000 },
  });
  await assert.rejects(runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST), A2PLeaseHeldError);
  assert.equal(ops(calls, 'number.buy').length, 0);
  assert.equal(env.docs.get(FACILITY_ID)!.a2pSubmitLease.holder, 'poller:facility-1');
});

test('nothing is bought, not even the messaging service, before the bundles are approved', async () => {
  const twilio = fakeTwilio({
    profile: { sid: 'BUprofile', status: 'twilio-approved' },
    product: { sid: 'BUproduct', status: 'in-review' },
  });
  const { env, deps, calls, ref } = setup(APPROVED_FACILITY, twilio);
  await assert.rejects(
    runGatedPaidSubmission(deps, ref, 'owner', 'number', REQUEST),
    /A2P registration: in-review/,
  );
  assert.deepEqual(
    calls.filter((c) => /create|buy|attach|update/.test(c.op)),
    [],
  );
  assert.equal(env.docs.get(FACILITY_ID)!.a2pSubmitLease, null);
});

test('with the brand still in review the campaign is deferred, not filed', async () => {
  const { env, deps, calls, ref } = setup(APPROVED_FACILITY, approvedTwilio({ brandStatus: 'PENDING' }));
  await runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST);
  const doc = env.docs.get(FACILITY_ID)!;
  assert.equal(ops(calls, 'campaign.create').length, 0);
  assert.equal(doc.a2pCampaignPending, true);
  assert.equal(doc.a2pStatus, 'submitted');
  assert.deepEqual(doc.textingConsentMethods, ['online_form']);
});

// --- reset: the three plans ----------------------------------------------------------

const FILED = {
  ...APPROVED_FACILITY,
  twilioMessagingServiceSid: 'MGservice',
  twilioPhoneNumberSid: 'PNnumber',
  twilioPhoneNumberE164: '+15125550100',
  twilioBrandSid: 'BNbrand',
  textingSampleMessages: REQUEST.sampleMessages.map((s) => `Example Self Storage: ${s}`),
  textingConsentMethods: ['online_form'],
  textingConsentConfirmedAt: SERVER_TIME,
  a2pStatus: 'rejected',
  a2pRejectionReason: 'Rejected',
};

test('reset of a failed campaign: campaign withdrawn, approved brand kept, refile makes no new brand', async () => {
  const twilio = approvedTwilio({ brandStatus: 'APPROVED', campaignStatus: 'FAILED' });
  const { env, deps, calls, ref } = setup(
    { ...FILED, twilioCampaignSid: 'QEold', twilioCampaignId: 'CMold' },
    twilio,
  );

  const plan = await resetRejectedRegistration(deps, ref, 'owner');
  assert.equal(plan.rejected, 'campaign');
  assert.deepEqual(ops(calls, 'campaign.remove').map((c) => c.target), ['MGservice/QEold']);
  const doc = env.docs.get(FACILITY_ID)!;
  assert.equal(doc.twilioBrandSid, 'BNbrand');
  assert.equal('twilioCampaignSid' in doc, false);
  assert.equal(doc.a2pStatus, 'draft');
  assert.equal(doc.a2pRejectedAt, null);

  await runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST);
  assert.equal(ops(calls, 'brand.create').length, 0);
  assert.equal(ops(calls, 'number.buy').length, 0);
  assert.equal(ops(calls, 'campaign.create').length, 1);
});

test('reset of a failed brand keeps it and the next submit resubmits the same brand', async () => {
  const twilio = approvedTwilio({ brandStatus: 'FAILED' });
  const { env, deps, calls, ref } = setup(FILED, twilio);

  const plan = await resetRejectedRegistration(deps, ref, 'owner');
  assert.equal(plan.rejected, 'brand');
  assert.equal(plan.resubmitBrand, true);
  let doc = env.docs.get(FACILITY_ID)!;
  assert.equal(doc.twilioBrandSid, 'BNbrand');
  assert.equal(doc.a2pBrandResubmitRequired, true);

  await runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST);
  assert.equal(ops(calls, 'brand.create').length, 0, 'no second brand');
  assert.deepEqual(ops(calls, 'brand.update').map((c) => c.target), ['BNbrand']);
  doc = env.docs.get(FACILITY_ID)!;
  assert.equal(doc.a2pBrandResubmissions, 1);
  assert.equal(doc.a2pBrandResubmitRequired, false);
  assert.equal(doc.a2pStatus, 'submitted');
  // Brand is back in review, so the campaign waits for it.
  assert.equal(doc.a2pCampaignPending, true);
});

test('brand resubmission stops at Twilio\'s free limit', async () => {
  const twilio = approvedTwilio({ brandStatus: 'FAILED' });
  const { deps, calls, ref } = setup(
    { ...FILED, a2pStatus: 'draft', a2pBrandResubmitRequired: true, a2pBrandResubmissions: MAX_FREE_BRAND_RESUBMISSIONS },
    twilio,
  );
  await assert.rejects(
    runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST),
    /free limit/,
  );
  assert.equal(ops(calls, 'brand.update').length, 0);
  assert.equal(ops(calls, 'brand.create').length, 0);
});

test('reset refuses unless the registration is rejected, and when Twilio shows nothing rejected', async () => {
  const notRejected = setup({ ...FILED, a2pStatus: 'pending' });
  await assert.rejects(resetRejectedRegistration(notRejected.deps, notRejected.ref, 'owner'), /Only a rejected/);

  const verified = setup(
    { ...FILED, twilioCampaignSid: 'QElive' },
    approvedTwilio({ brandStatus: 'APPROVED', campaignStatus: 'VERIFIED' }),
  );
  await assert.rejects(resetRejectedRegistration(verified.deps, verified.ref, 'owner'), /nothing to reset/);
  assert.equal(ops(verified.calls, 'campaign.remove').length, 0);
  assert.equal(verified.env.docs.get(FACILITY_ID)!.twilioCampaignSid, 'QElive');
});

// --- the stuck-facility path ------------------------------------------------------------

test('poll gives up -> owner refreshes -> reset -> refile is allowed', async () => {
  const twilio = approvedTwilio({ brandStatus: 'APPROVED' });
  const { env, deps, calls, ref } = setup(
    { ...FILED, a2pStatus: 'submitted', a2pCampaignPending: true, a2pRejectionReason: null },
    twilio,
  );

  // 1. The hourly poll fails to file the campaign three times and gives up.
  for (let attempt = 1; attempt <= MAX_DEFERRED_FILING_FAILURES; attempt++) {
    const current = env.docs.get(FACILITY_ID)!;
    await ref.set(deferredFilingFailureFields(current, new Error('Invalid message flow')), { merge: true });
  }
  let doc = env.docs.get(FACILITY_ID)!;
  assert.equal(doc.a2pStatus, 'rejected');
  assert.equal(doc.a2pCampaignPending, false);
  const reason = doc.a2pRejectionReason;
  assert.match(reason, /could not be filed after 3 attempts/);

  // 2. The owner presses Refresh: brand APPROVED, no campaign on file. It must
  //    stay rejected with its reason (it used to become 'pending' for good).
  await ref.set(buildRefreshStatusFields(doc, { brandStatus: 'APPROVED' }, () => SERVER_TIME), { merge: true });
  doc = env.docs.get(FACILITY_ID)!;
  assert.equal(doc.a2pStatus, 'rejected');
  assert.equal(doc.a2pRejectionReason, reason);

  // 3. Reset accepts the gave-up state and keeps the brand.
  const plan = await resetRejectedRegistration(deps, ref, 'owner');
  assert.equal(plan.rejected, 'campaign_filing');
  doc = env.docs.get(FACILITY_ID)!;
  assert.equal(doc.a2pStatus, 'draft');
  assert.equal(doc.twilioBrandSid, 'BNbrand');
  assert.equal('a2pCampaignPending' in doc, false);
  assert.equal('a2pCampaignFilingFailures' in doc, false);

  // 4. Submitting again files the campaign under the same brand and number.
  await runGatedPaidSubmission(deps, ref, 'owner', 'all', REQUEST);
  assert.equal(ops(calls, 'campaign.create').length, 1);
  assert.equal(ops(calls, 'brand.create').length, 0);
  assert.equal(ops(calls, 'number.buy').length, 0);
  assert.equal(env.docs.get(FACILITY_ID)!.a2pStatus, 'pending');
});

test('refresh keeps a stored rejection reason when Twilio gives none, and takes a specific one', () => {
  const rejected = { a2pStatus: 'rejected', a2pRejectionReason: 'Stored reason' };
  const kept = buildRefreshStatusFields(rejected, { brandStatus: 'APPROVED' }, () => SERVER_TIME);
  assert.equal(kept.a2pRejectionReason, 'Stored reason');
  assert.equal('a2pRejectedAt' in kept, false, 'rejection date not bumped');

  const fresh = buildRefreshStatusFields(
    { a2pStatus: 'pending' },
    { brandStatus: 'APPROVED', campaignStatus: 'FAILED', campaignErrors: [{ code: 30909, description: 'CTA' }] },
    () => SERVER_TIME,
  );
  assert.equal(fresh.a2pStatus, 'rejected');
  assert.match(String(fresh.a2pRejectionReason), /30909/);
  assert.equal(fresh.a2pRejectedAt, SERVER_TIME);
});

// --- the body sendSMS sends -------------------------------------------------------------

const footer = async (body: string) => `${body} Reply STOP to opt out.`;

test('sendSMS body: facility name added once, before logging and counting', async () => {
  const facility = { name: 'Example Self Storage' };
  assert.equal(
    await composeOutboundSmsBody(facility, 'Your rent is due Oct 1.', footer),
    'Example Self Storage: Your rent is due Oct 1. Reply STOP to opt out.',
  );
});

test('sendSMS body: a body that already names the facility is not prefixed twice', async () => {
  const facility = { name: 'Example Self Storage' };
  assert.equal(
    await composeOutboundSmsBody(facility, 'Example Self Storage: Your rent is due.', footer),
    'Example Self Storage: Your rent is due. Reply STOP to opt out.',
  );
  assert.equal(
    await composeOutboundSmsBody(facility, 'example self storage: Your rent is due.', footer),
    'example self storage: Your rent is due. Reply STOP to opt out.',
  );
});

test('sendSMS body: a shared-number send still carries the name, and an unnamed facility still sends', async () => {
  // The prefix does not depend on which number sends: a facility on the
  // shared toll-free number gets the same named body it always did.
  const facility = { name: 'Example Self Storage', twilioPhoneNumberE164: null, a2pStatus: 'draft' };
  assert.match(await composeOutboundSmsBody(facility, 'Gate code changed.', footer), /^Example Self Storage: /);
  assert.equal(
    await composeOutboundSmsBody({}, 'Gate code changed.', footer),
    'Gate code changed. Reply STOP to opt out.',
  );
});

test('fake Firestore delete sentinel is honoured (test harness check)', async () => {
  const env = fakeDb();
  env.docs.set('x', { a: 1, b: 2 });
  await env.ref('x').set({ a: DELETE }, { merge: true });
  assert.deepEqual(env.docs.get('x'), { b: 2 });
});
