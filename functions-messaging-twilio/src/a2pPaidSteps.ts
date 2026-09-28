/**
 * The steps of texting registration that spend money or file with carriers,
 * and the reset/refresh logic around them.
 *
 * Everything here takes its Twilio client, Firestore handle and timestamps as
 * parameters (`PaidStepDeps`) so tests run this exact code against fakes; the
 * callables in twilioCallables.ts are thin wrappers that pass the real ones.
 */
import * as functions from 'firebase-functions/v1';
import {
  buildA2PRejectionReason,
  computeA2PStatus,
  ensureIdempotentResource,
  type A2PStatus,
} from '@sfc/functions-shared';
import type { A2PTwilioClient } from './a2pTwilioTypes';
import {
  buildBrandRegistrationParams,
  campaignFilingFields,
  fetchUsAppToPersonCampaign,
  fileCampaignWhenBrandApproved,
  planRegistrationReset,
  type CampaignFilingResult,
  type RegistrationResetPlan,
} from './a2pCampaign';
import {
  assertReadyForPaidSubmission,
  resolvePaidSubmissionInput,
  runPaidSubmission,
  withA2PSubmitLease,
  type LeaseDb,
  type PaidStep,
  type PaidSubmissionReadiness,
} from './a2pSubmission';

/** The facility document, as much of it as these steps use. */
export interface FacilityDocRef {
  id: string;
  get(): Promise<{ data(): Record<string, any> | undefined }>;
  set(data: Record<string, unknown>, options: { merge: true }): Promise<unknown>;
}

export interface PaidStepDeps {
  db: LeaseDb;
  /** Null in Twilio dry-run mode: deterministic fake SIDs, no Twilio calls. */
  twilio: A2PTwilioClient | null;
  serverTimestamp(): unknown;
  deleteField(): unknown;
  newId(): string;
  now?(): number;
}

export interface CampaignRequest {
  useCases?: string[];
  sampleMessages?: string[];
  consentConfirmed?: boolean;
  consentMethods?: string[];
  areaCode?: string;
}

/** Twilio's free self-service resubmissions of a FAILED brand. */
export const MAX_FREE_BRAND_RESUBMISSIONS = 3;

export function buildTwilioDryRunSid(prefix: string, facilityId: string): string {
  const normalized = facilityId.replace(/[^a-zA-Z0-9]/g, '').slice(0, 24).padEnd(24, '0');
  return `${prefix}${normalized}`;
}

export async function readFacilityData(ref: FacilityDocRef): Promise<Record<string, any>> {
  const data = (await ref.get()).data();
  if (!data) throw new functions.https.HttpsError('not-found', 'Facility not found');
  return data;
}

// ---- individual steps ----------------------------------------------------------

export async function ensureMessagingServiceForFacility(
  deps: PaidStepDeps,
  facilityRef: FacilityDocRef,
  facilityData: Record<string, any>,
  requestId: string,
): Promise<{ messagingServiceSid: string; created: boolean }> {
  const existing = facilityData.twilioMessagingServiceSid as string | undefined;
  const idempotent = await ensureIdempotentResource(
    existing,
    async () => {
      if (!deps.twilio) return { sid: buildTwilioDryRunSid('MG', facilityRef.id) };
      return deps.twilio.messaging.v1.services.create({
        friendlyName: `SFC-${facilityRef.id}-Messaging`,
      });
    },
    (resource: { sid: string }) => resource.sid,
  );

  if (idempotent.created) {
    await facilityRef.set({
      twilioMessagingServiceSid: idempotent.sid,
      a2pLastUpdatedAt: deps.serverTimestamp(),
    }, { merge: true });
    functions.logger.info('Created messaging service', { requestId, facilityId: facilityRef.id });
  }
  return { messagingServiceSid: idempotent.sid, created: idempotent.created };
}

export async function provisionFacilityPhoneNumber(
  deps: PaidStepDeps,
  facilityRef: FacilityDocRef,
  facilityData: Record<string, any>,
  areaCode: string | undefined,
  requestId: string,
): Promise<{ phoneNumberSid: string; phoneNumberE164: string; created: boolean }> {
  const existingSid = facilityData.twilioPhoneNumberSid as string | undefined;
  const existingE164 = facilityData.twilioPhoneNumberE164 as string | undefined;
  if (existingSid && existingE164) {
    return { phoneNumberSid: existingSid, phoneNumberE164: existingE164, created: false };
  }

  if (!deps.twilio) {
    const sid = buildTwilioDryRunSid('PN', facilityRef.id);
    const e164 = `+1555${Math.floor(Math.random() * 9000000 + 1000000)}`;
    await facilityRef.set({
      twilioPhoneNumberSid: sid,
      twilioPhoneNumberE164: e164,
      a2pLastUpdatedAt: deps.serverTimestamp(),
    }, { merge: true });
    return { phoneNumberSid: sid, phoneNumberE164: e164, created: true };
  }

  const numbers = await deps.twilio.availablePhoneNumbers('US').local.list({
    smsEnabled: true,
    limit: 1,
    ...(areaCode ? { areaCode: Number(areaCode) } : {}),
  });
  if (!numbers?.length) {
    throw new functions.https.HttpsError('resource-exhausted', 'No local Twilio number available for requested area');
  }

  const purchased = await deps.twilio.incomingPhoneNumbers.create({
    phoneNumber: numbers[0].phoneNumber,
  });

  await facilityRef.set({
    twilioPhoneNumberSid: purchased.sid,
    twilioPhoneNumberE164: purchased.phoneNumber,
    a2pLastUpdatedAt: deps.serverTimestamp(),
  }, { merge: true });
  functions.logger.info('Provisioned Twilio number', { requestId, facilityId: facilityRef.id, phoneSid: purchased.sid });
  return { phoneNumberSid: purchased.sid, phoneNumberE164: purchased.phoneNumber, created: true };
}

/**
 * Attach the number to the messaging service, once. A messaging service's
 * phone-number records carry the PN SID in `sid`; the old check compared a
 * `phoneNumberSid` field that does not exist, so it never matched and every
 * re-run tried to attach the number again.
 */
export async function attachPhoneNumberToMessagingService(
  deps: PaidStepDeps,
  messagingServiceSid: string,
  phoneNumberSid: string,
): Promise<void> {
  if (!deps.twilio) return;
  const service = deps.twilio.messaging.v1.services(messagingServiceSid);
  const existing = await service.phoneNumbers.list({ limit: 200 });
  if ((existing || []).some((p) => p.sid === phoneNumberSid)) return;
  await service.phoneNumbers.create({ phoneNumberSid });
}

/**
 * Refuse to submit a brand unless Twilio has approved both TrustHub bundles.
 * (assertReadyForPaidSubmission already checked; this is the last guard in
 * front of the fee.)
 */
async function assertTrustBundleReadyForBrand(
  twilio: A2PTwilioClient,
  trustProfileSid: string | undefined,
  trustProductSid: string | undefined,
): Promise<void> {
  if (!trustProfileSid || !trustProductSid) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Business profile has not been created yet. Save your business details first.',
    );
  }
  const [profile, product] = await Promise.all([
    twilio.trusthub.v1.customerProfiles(trustProfileSid).fetch(),
    twilio.trusthub.v1.trustProducts(trustProductSid).fetch(),
  ]);
  const approved = (status: unknown) => String(status || '').toLowerCase() === 'twilio-approved';
  if (approved(profile.status) && approved(product.status)) return;
  throw new functions.https.HttpsError(
    'failed-precondition',
    'Your business profile has not been approved by Twilio yet, so carrier brand registration ' +
      `cannot be submitted (profile: ${profile.status}, A2P profile: ${product.status}).`,
  );
}

/**
 * Register the facility's brand, or resubmit it.
 *
 * With no brand yet, registers one. With a brand whose reset marked it for
 * resubmission (`a2pBrandResubmitRequired`), resubmits that same brand if it
 * is still FAILED — a new registration would be a second brand and a second
 * fee. Twilio allows three free resubmissions; after that it needs support.
 */
export async function submitBrandRegistrationInternal(
  deps: PaidStepDeps,
  facilityRef: FacilityDocRef,
  facilityData: Record<string, any>,
): Promise<string> {
  const existingBrand = String(facilityData.twilioBrandSid || '').trim();
  if (existingBrand && facilityData.a2pBrandResubmitRequired !== true) return existingBrand;

  if (existingBrand) {
    let status = 'FAILED';
    if (deps.twilio) {
      await assertTrustBundleReadyForBrand(
        deps.twilio,
        facilityData.twilioTrustProfileSid as string | undefined,
        facilityData.twilioTrustProductSid as string | undefined,
      );
      const brand = deps.twilio.messaging.v1.brandRegistrations(existingBrand);
      status = String((await brand.fetch()).status || '').toUpperCase();
      if (status === 'FAILED') {
        const used = Number(facilityData.a2pBrandResubmissions || 0);
        if (used >= MAX_FREE_BRAND_RESUBMISSIONS) {
          throw new functions.https.HttpsError(
            'failed-precondition',
            `This brand has already been resubmitted ${used} times, Twilio's free limit. ` +
              'Contact support to have it re-vetted.',
          );
        }
        status = String((await brand.update()).status || 'PENDING').toUpperCase();
        functions.logger.info('Resubmitted failed A2P brand', {
          facilityId: facilityRef.id,
          brandSid: existingBrand,
          resubmission: used + 1,
          status,
        });
        await facilityRef.set({
          a2pBrandResubmissions: used + 1,
        }, { merge: true });
      }
    }
    await facilityRef.set({
      a2pBrandResubmitRequired: false,
      a2pBrandStatus: status,
      a2pStatus: 'submitted',
      textingPlatformApproved: false,
      textingPlatformApprovedAt: null,
      textingPlatformApprovedBy: null,
      a2pSubmittedAt: deps.serverTimestamp(),
      a2pLastUpdatedAt: deps.serverTimestamp(),
    }, { merge: true });
    return existingBrand;
  }

  let sid: string;
  if (!deps.twilio) {
    sid = buildTwilioDryRunSid('BN', facilityRef.id);
  } else {
    await assertTrustBundleReadyForBrand(
      deps.twilio,
      facilityData.twilioTrustProfileSid as string | undefined,
      facilityData.twilioTrustProductSid as string | undefined,
    );
    const brand = await deps.twilio.messaging.v1.brandRegistrations.create(
      buildBrandRegistrationParams(facilityData),
    );
    sid = brand.sid;
  }

  await facilityRef.set({
    twilioBrandSid: sid,
    a2pStatus: 'submitted',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pSubmittedAt: deps.serverTimestamp(),
    a2pLastUpdatedAt: deps.serverTimestamp(),
  }, { merge: true });
  return sid;
}

export async function submitCampaignInternal(
  deps: PaidStepDeps,
  facilityRef: FacilityDocRef,
  facilityData: Record<string, any>,
  campaignData: { useCases: string[]; consentConfirmed: boolean },
  readiness: PaidSubmissionReadiness,
): Promise<string> {
  if (facilityData.twilioCampaignSid) return facilityData.twilioCampaignSid as string;
  if (!facilityData.twilioBrandSid || !facilityData.twilioMessagingServiceSid || !facilityData.twilioPhoneNumberSid) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Missing Twilio brand, messaging service, or phone number. Complete previous steps first.',
    );
  }

  // Samples and consent methods were validated by assertReadyForPaidSubmission
  // before anything was bought; they are stored so a deferred filing by the
  // hourly poll uses exactly what the owner submitted.
  const withMethods = { ...facilityData, textingConsentMethods: readiness.consentMethods };
  const filing: CampaignFilingResult = deps.twilio
    ? await fileCampaignWhenBrandApproved(deps.twilio, withMethods, readiness.samples)
    : {
        filed: true,
        brandStatus: 'APPROVED',
        sid: buildTwilioDryRunSid('QE', facilityRef.id),
        campaignId: buildTwilioDryRunSid('CM', facilityRef.id),
        campaignStatus: 'VERIFIED',
      };

  await facilityRef.set({
    ...campaignFilingFields(filing),
    a2pCampaignFilingFailures: 0,
    a2pLastError: null,
    textingUseCases: Array.isArray(campaignData.useCases) ? campaignData.useCases : [],
    textingSampleMessages: readiness.samples,
    textingConsentMethods: readiness.consentMethods,
    textingConsentConfirmedAt: campaignData.consentConfirmed ? deps.serverTimestamp() : null,
    a2pStatus: !deps.twilio ? 'approved' : filing.filed ? 'pending' : 'submitted',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pLastUpdatedAt: deps.serverTimestamp(),
    ...(!deps.twilio ? { a2pApprovedAt: deps.serverTimestamp() } : {}),
  }, { merge: true });

  await attachPhoneNumberToMessagingService(
    deps,
    facilityData.twilioMessagingServiceSid as string,
    facilityData.twilioPhoneNumberSid as string,
  );

  return filing.sid ?? '';
}

// ---- the gated, leased sequence --------------------------------------------------

export type PaidScope = 'service' | 'number' | 'brand' | 'campaign' | 'all';

/**
 * Run a paid texting-registration sequence for one facility.
 *
 * Holds the facility's submission lease for the whole sequence, checks every
 * prerequisite (live bundle approval, samples, consent) before the first
 * purchase, and re-reads the facility before each step so a number or brand
 * bought by an earlier run is reused rather than bought again. Creating the
 * messaging service alone is free and skips the readiness check.
 */
export async function runGatedPaidSubmission(
  deps: PaidStepDeps,
  ref: FacilityDocRef,
  uid: string,
  scope: PaidScope,
  campaignData: CampaignRequest | undefined,
): Promise<{ requestId: string; facility: Record<string, any> }> {
  const requestId = deps.newId();
  const holder = `${uid}:${requestId}`;
  const facility = await withA2PSubmitLease(deps.db, ref, holder, async () => {
    const first = await readFacilityData(ref);
    const readiness =
      scope === 'service'
        ? null
        : await assertReadyForPaidSubmission(deps.twilio, first, resolvePaidSubmissionInput(campaignData, first));

    const wants = (step: PaidScope) => scope === 'all' || scope === step;
    const steps: PaidStep[] = [];
    if (scope !== 'brand') {
      steps.push(async (d) => {
        await ensureMessagingServiceForFacility(deps, ref, d, requestId);
      });
    }
    if (wants('number')) {
      steps.push(async (d) => {
        await provisionFacilityPhoneNumber(deps, ref, d, campaignData?.areaCode, requestId);
      });
      steps.push(async (d) => {
        await attachPhoneNumberToMessagingService(
          deps,
          String(d.twilioMessagingServiceSid),
          String(d.twilioPhoneNumberSid),
        );
      });
    }
    if (wants('brand')) {
      steps.push(async (d) => {
        await submitBrandRegistrationInternal(deps, ref, d);
      });
    }
    if (wants('campaign') && readiness) {
      steps.push(async (d) => {
        await submitCampaignInternal(
          deps,
          ref,
          d,
          {
            useCases: campaignData?.useCases ?? d.textingUseCases ?? [],
            consentConfirmed: resolvePaidSubmissionInput(campaignData, d).consentConfirmed === true,
          },
          readiness,
        );
      });
    }
    return runPaidSubmission(() => readFacilityData(ref), steps);
  }, deps.now);
  return { requestId, facility };
}

// ---- reset after rejection ----------------------------------------------------------

/**
 * Reset a rejected registration so the owner can fix it and submit again.
 *
 * Callers check that the caller is the owner or a super admin. Runs under the
 * facility lease and reads Twilio to decide what to clear (planRegistrationReset):
 * a failed campaign is removed from the messaging service and the brand kept;
 * a failed brand is kept and marked for in-place resubmission; a campaign the
 * poll gave up filing keeps the brand.
 */
export async function resetRejectedRegistration(
  deps: PaidStepDeps,
  ref: FacilityDocRef,
  holderUid: string,
): Promise<RegistrationResetPlan> {
  return withA2PSubmitLease(deps.db, ref, `${holderUid}:${deps.newId()}`, async () => {
    const facilityData = await readFacilityData(ref);
    if (String(facilityData.a2pStatus || '').toLowerCase() !== 'rejected') {
      throw new functions.https.HttpsError('failed-precondition', 'Only a rejected registration can be reset.');
    }

    const brandSid = String(facilityData.twilioBrandSid || '').trim();
    const campaignSid = String(facilityData.twilioCampaignSid || '').trim();
    const messagingServiceSid = String(facilityData.twilioMessagingServiceSid || '').trim();
    let brandStatus = '';
    let campaignStatus = '';
    let liveCampaignSid = '';
    const twilio = deps.twilio;
    if (twilio && brandSid) {
      brandStatus = String((await twilio.messaging.v1.brandRegistrations(brandSid).fetch()).status || '');
    }
    if (twilio && campaignSid && messagingServiceSid) {
      const campaign = await fetchUsAppToPersonCampaign(twilio, messagingServiceSid, campaignSid);
      campaignStatus = String(campaign?.campaignStatus || '');
      liveCampaignSid = campaign?.sid || '';
    }

    const plan: RegistrationResetPlan = twilio
      ? planRegistrationReset({
          hasBrand: Boolean(brandSid),
          brandStatus,
          hasCampaign: Boolean(campaignSid),
          campaignStatus,
        })
      : { rejected: 'campaign', keepBrand: true, resubmitBrand: false, removeCampaign: false };

    if (twilio && plan.removeCampaign && liveCampaignSid && messagingServiceSid) {
      await twilio.messaging.v1.services(messagingServiceSid).usAppToPerson(liveCampaignSid).remove();
      functions.logger.info('Removed rejected A2P campaign before refiling', {
        facilityId: ref.id,
        usAppToPersonSid: liveCampaignSid,
        campaignStatus,
      });
    }

    const del = deps.deleteField();
    await ref.set({
      ...(plan.keepBrand ? {} : { twilioBrandSid: del, a2pBrandStatus: del }),
      ...(plan.resubmitBrand ? { a2pBrandResubmitRequired: true } : {}),
      twilioCampaignSid: del,
      twilioCampaignId: del,
      a2pCampaignStatus: del,
      a2pCampaignPending: del,
      a2pCampaignFilingFailures: del,
      a2pStatus: 'draft',
      textingPlatformApproved: false,
      textingPlatformApprovedAt: null,
      textingPlatformApprovedBy: null,
      a2pLastError: null,
      a2pRejectionReason: null,
      a2pRejectedAt: null,
      a2pLastResetOf: plan.rejected,
      a2pLastUpdatedAt: deps.serverTimestamp(),
    }, { merge: true });
    return plan;
  }, deps.now);
}

// ---- refresh --------------------------------------------------------------------------

export interface LiveRegistrationStatus {
  brandStatus?: string;
  brandErrors?: unknown;
  brandFailureReason?: unknown;
  campaignStatus?: string;
  campaignErrors?: unknown;
}

/**
 * The status fields a refresh writes, from Twilio's live brand and campaign.
 *
 * A registration that stays rejected keeps its recorded reason, date and last
 * error unless Twilio supplies a more specific one; the refresh used to
 * overwrite the poll's "campaign could not be filed after 3 attempts" with a
 * generic message (or, before computeA2PStatus kept it rejected, clear it).
 */
export function buildRefreshStatusFields(
  facilityData: Record<string, any>,
  live: LiveRegistrationStatus,
  serverTimestamp: () => unknown,
): Record<string, unknown> {
  const current = ((facilityData.a2pStatus as string) || 'draft') as A2PStatus;
  const next = computeA2PStatus(current, live.brandStatus, live.campaignStatus);
  const stillRejected = current === 'rejected' && next === 'rejected';
  const liveReason = buildA2PRejectionReason({
    campaignErrors: live.campaignErrors,
    brandErrors: live.brandErrors,
    brandFailureReason: live.brandFailureReason,
    campaignStatus: live.campaignStatus,
    brandStatus: live.brandStatus,
  });

  const update: Record<string, unknown> = {
    ...(live.campaignStatus ? { a2pCampaignStatus: live.campaignStatus } : {}),
    ...(live.brandStatus ? { a2pBrandStatus: String(live.brandStatus).toUpperCase() } : {}),
    a2pStatus: next,
    a2pLastUpdatedAt: serverTimestamp(),
    ...(next !== 'approved'
      ? { textingPlatformApproved: false, textingPlatformApprovedAt: null, textingPlatformApprovedBy: null }
      : {}),
  };
  if (next === 'rejected') {
    update.a2pRejectionReason =
      liveReason ?? (stillRejected ? facilityData.a2pRejectionReason : null) ?? 'Rejected by Twilio';
    if (!stillRejected) {
      update.a2pRejectedAt = serverTimestamp();
      update.a2pLastError = null;
    }
  } else {
    update.a2pRejectionReason = null;
    update.a2pLastError = null;
  }
  if (next === 'approved' && current !== 'approved') update.a2pApprovedAt = serverTimestamp();
  return update;
}
