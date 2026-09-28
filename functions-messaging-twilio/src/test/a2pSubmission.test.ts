import assert from 'node:assert/strict';
import test from 'node:test';
import {
  A2PLeaseHeldError,
  assertReadyForPaidSubmission,
  resolvePaidSubmissionInput,
  runPaidSubmission,
  withA2PSubmitLease,
  type LeaseDb,
} from '../a2pSubmission';
import {
  MAX_DEFERRED_FILING_FAILURES,
  deferredFilingFailureFields,
  normalizeConsentMethods,
  planRegistrationReset,
  withSenderPrefix,
} from '../a2pCampaign';
import { fakeTwilio } from './fakeTwilio';
import { fakeDb } from './fakeFirestore';

const tick = () => new Promise((resolve) => setTimeout(resolve, 5));

// Concurrent and repeated submissions through the real runGatedPaidSubmission
// are in a2pPaidSteps.test.ts; these cover the lease primitive itself.

test('the hourly poll and a tab cannot both hold the lease', async () => {
  const env = fakeDb();
  env.docs.set('facility-1', {});
  const facility = env.ref('facility-1');
  let release!: () => void;
  const held = withA2PSubmitLease(env.db, facility, 'poller', () => new Promise<void>((r) => (release = r)));
  await tick();
  await assert.rejects(
    withA2PSubmitLease(env.db, facility, 'tab-a', async () => 'ran'),
    A2PLeaseHeldError,
  );
  release();
  await held;
  assert.equal(await withA2PSubmitLease(env.db, facility, 'tab-a', async () => 'ran'), 'ran');
});

test('an expired lease (crashed holder) can be taken over', async () => {
  const env = fakeDb();
  env.docs.set('facility-1', { a2pSubmitLease: { holder: 'crashed', expiresAtMs: 1_000 } });
  const result = await withA2PSubmitLease(
    env.db,
    env.ref('facility-1'),
    'tab-a',
    async () => 'ran',
    () => 2_000,
  );
  assert.equal(result, 'ran');
});

test('the lease is released when the paid step throws', async () => {
  const env = fakeDb();
  env.docs.set('facility-1', {});
  await assert.rejects(
    withA2PSubmitLease(env.db, env.ref('facility-1'), 'tab-a', async () => {
      throw new Error('Twilio said no');
    }),
    /Twilio said no/,
  );
  assert.equal(env.docs.get('facility-1')!.a2pSubmitLease, null);
});

// --- readiness gate -------------------------------------------------------------

const READY_FACILITY = {
  name: 'Example Self Storage',
  twilioTrustProfileSid: 'BUprofile',
  twilioTrustProductSid: 'BUproduct',
  textingBusinessData: { legalBusinessName: 'Example Storage LLC', businessType: 'LLC' },
};
const SAMPLES = [
  'Friendly reminder: your rent payment is due soon. Reply STOP to opt out, HELP for help.',
  'Your account is past due. Please make a payment to avoid late fees. Reply STOP to opt out.',
];
const INPUT = { sampleMessages: SAMPLES, consentMethods: ['online_form'], consentConfirmed: true };

const nothingSpent = (calls: Array<{ op: string }>) =>
  calls.filter((c) => /create|update|remove|assign/.test(c.op));

test('nothing is bought until both bundles are twilio-approved', async () => {
  for (const [profileStatus, productStatus] of [
    ['in-review', 'draft'],
    ['twilio-approved', 'pending-review'],
    ['twilio-approved', 'twilio-rejected'],
  ]) {
    const { client, calls } = fakeTwilio({
      profile: { sid: 'BUprofile', status: profileStatus },
      product: { sid: 'BUproduct', status: productStatus },
    });
    await assert.rejects(
      assertReadyForPaidSubmission(client, READY_FACILITY, INPUT),
      (error: any) =>
        error.code === 'failed-precondition' &&
        error.message.includes(`business profile: ${profileStatus}`) &&
        error.message.includes(`A2P registration: ${productStatus}`),
    );
    assert.deepEqual(nothingSpent(calls), []);
  }
});

test('the gate reads bundle status live, not from the facility document', async () => {
  const { client } = fakeTwilio({
    profile: { sid: 'BUprofile', status: 'twilio-approved' },
    product: { sid: 'BUproduct', status: 'in-review' },
  });
  await assert.rejects(
    assertReadyForPaidSubmission(
      client,
      { ...READY_FACILITY, a2pBundleApproved: true, a2pBundleProductStatus: 'twilio-approved' },
      INPUT,
    ),
    /A2P registration: in-review/,
  );
});

test('the gate also requires samples, consent methods and confirmation', async () => {
  const approved = () =>
    fakeTwilio({
      profile: { sid: 'BUprofile', status: 'twilio-approved' },
      product: { sid: 'BUproduct', status: 'twilio-approved' },
    }).client;

  await assert.rejects(
    assertReadyForPaidSubmission(approved(), READY_FACILITY, { ...INPUT, sampleMessages: [SAMPLES[0]] }),
    /at least 2/,
  );
  await assert.rejects(
    assertReadyForPaidSubmission(approved(), READY_FACILITY, { ...INPUT, consentMethods: [] }),
    /how your tenants agree/,
  );
  await assert.rejects(
    assertReadyForPaidSubmission(approved(), READY_FACILITY, { ...INPUT, consentConfirmed: false }),
    /Confirm that tenants opt in/,
  );
  await assert.rejects(
    assertReadyForPaidSubmission(approved(), { ...READY_FACILITY, textingBusinessData: {} }, INPUT),
    /business details/,
  );

  const ready = await assertReadyForPaidSubmission(approved(), READY_FACILITY, INPUT);
  assert.deepEqual(ready.consentMethods, ['online_form']);
  assert.equal(ready.samples.length, 2);
  for (const sample of ready.samples) assert.match(sample, /^Example Self Storage: /);
});

test('stored campaign inputs are used when a paid call carries none', () => {
  const stored = {
    textingSampleMessages: SAMPLES,
    textingConsentMethods: ['text_start'],
    textingConsentConfirmedAt: { seconds: 1 },
  };
  assert.deepEqual(resolvePaidSubmissionInput(undefined, stored), {
    sampleMessages: SAMPLES,
    consentMethods: ['text_start'],
    consentConfirmed: true,
  });
  assert.equal(resolvePaidSubmissionInput(undefined, {}).consentConfirmed, false);
});

// --- reset after rejection ------------------------------------------------------

test('reset keeps an approved brand and removes only the failed campaign', () => {
  assert.deepEqual(
    planRegistrationReset({ hasBrand: true, brandStatus: 'APPROVED', hasCampaign: true, campaignStatus: 'FAILED' }),
    { rejected: 'campaign', keepBrand: true, resubmitBrand: false, removeCampaign: true },
  );
});

test('reset keeps a failed brand for in-place resubmission (no second brand)', () => {
  assert.deepEqual(
    planRegistrationReset({ hasBrand: true, brandStatus: 'FAILED', hasCampaign: true, campaignStatus: 'PENDING' }),
    { rejected: 'brand', keepBrand: true, resubmitBrand: true, removeCampaign: true },
  );
  assert.deepEqual(
    planRegistrationReset({ hasBrand: true, brandStatus: 'FAILED', hasCampaign: false, campaignStatus: '' }),
    { rejected: 'brand', keepBrand: true, resubmitBrand: true, removeCampaign: false },
  );
});

test('reset after a deferred filing gave up keeps the brand', () => {
  assert.deepEqual(
    planRegistrationReset({ hasBrand: true, brandStatus: 'APPROVED', hasCampaign: false, campaignStatus: '' }),
    { rejected: 'campaign_filing', keepBrand: true, resubmitBrand: false, removeCampaign: false },
  );
});

test('reset refuses when Twilio shows nothing rejected', () => {
  for (const campaignStatus of ['VERIFIED', 'IN_PROGRESS', 'PENDING']) {
    assert.throws(
      () =>
        planRegistrationReset({ hasBrand: true, brandStatus: 'APPROVED', hasCampaign: true, campaignStatus }),
      (error: any) =>
        error.code === 'failed-precondition' &&
        /nothing to reset/.test(error.message) &&
        !/Refresh status/.test(error.message),
    );
  }
});

// --- deferred filing failures ----------------------------------------------------

test('deferred filing failures are recorded, then stop after the limit', () => {
  let facility: Record<string, any> = { a2pCampaignPending: true };
  for (let attempt = 1; attempt < MAX_DEFERRED_FILING_FAILURES; attempt++) {
    const fields = deferredFilingFailureFields(facility, new Error('Invalid messageFlow'));
    assert.equal(fields.a2pCampaignFilingFailures, attempt);
    assert.match(String(fields.a2pLastError), /Invalid messageFlow/);
    assert.equal('a2pStatus' in fields, false, 'still retrying');
    facility = { ...facility, ...fields };
  }
  const final = deferredFilingFailureFields(facility, new Error('Invalid messageFlow'));
  assert.equal(final.a2pCampaignFilingFailures, MAX_DEFERRED_FILING_FAILURES);
  assert.equal(final.a2pCampaignPending, false);
  assert.equal(final.a2pStatus, 'rejected');
  assert.match(String(final.a2pRejectionReason), /Invalid messageFlow/);
});

// --- sender prefix & consent methods -----------------------------------------------

test('every body opens with the facility name exactly once', () => {
  const facility = { name: 'Example Self Storage' };
  assert.equal(withSenderPrefix(facility, 'Your rent is due.'), 'Example Self Storage: Your rent is due.');
  assert.equal(
    withSenderPrefix(facility, 'Example Self Storage: Your rent is due.'),
    'Example Self Storage: Your rent is due.',
  );
});

test('a facility with no name is not prefixed with a placeholder', () => {
  assert.equal(withSenderPrefix({}, 'Your rent is due.'), 'Your rent is due.');
});

test('consent methods keep only known values, in a stable order', () => {
  // text_start is not a consent method (START only restores a tenant's own STOP).
  assert.deepEqual(
    normalizeConsentMethods(['verbal_recorded', 'text_start', 'bogus', 'online_form', 'verbal_recorded']),
    ['online_form', 'verbal_recorded'],
  );
  assert.deepEqual(normalizeConsentMethods(undefined), []);
});
