/**
 * A facility's A2P 10DLC campaign: the copy carriers review, and the calls that
 * file and read it.
 *
 * Campaigns are a sub-resource of the facility's messaging service
 * (`messaging.v1.services(MG...).usAppToPerson`). The create call returns a
 * `QE...` resource SID, which is what fetch needs, and a separate carrier
 * campaign id (`CM...`) that Twilio's console and carrier notices quote. Both
 * are stored. The earlier code called `messaging.v1.campaigns`, which does not
 * exist in the SDK, so the first real campaign would have thrown after the
 * brand fee was already spent.
 *
 * Everything filed here is a claim a carrier can check, so the message flow is
 * built only from the consent methods the owner says the facility actually
 * uses, and the opt-in message is the same sentence the START reply sends.
 */
import * as functions from 'firebase-functions/v1';
import { buildTenantOptInConfirmation, isSoleProprietorBusinessType } from '@sfc/functions-shared';
import type {
  A2PTwilioClient,
  BrandRegistrationListInstanceCreateOptions,
  UsAppToPersonListInstanceCreateOptions,
  UsAppToPersonRecord,
} from './a2pTwilioTypes';

/** Public SMS programme pages on the platform site (live, no login). */
export const SMS_TERMS_URL = 'https://www.storagefacilitycreator.com/sms-terms';
export const SMS_CONSENT_DEMO_URL = 'https://www.storagefacilitycreator.com/sms-consent-demo';
export const PRIVACY_POLICY_URL = 'https://www.storagefacilitycreator.com/privacy';

/** The exact checkbox wording tenants see on the online rental form. */
export const TENANT_CONSENT_TEXT =
  'I consent to receive SMS notifications regarding my storage account. Message frequency varies. ' +
  'Message & data rates may apply. Reply STOP to opt out, HELP for help.';

/** Twilio's limits on `messageSamples`. */
export const MIN_CAMPAIGN_SAMPLES = 2;
export const MAX_CAMPAIGN_SAMPLES = 5;
export const MIN_SAMPLE_LENGTH = 20;
export const MAX_SAMPLE_LENGTH = 1024;

/**
 * How a facility's tenants agree to texts. The owner picks the ones the
 * facility really uses on the texting setup form ("How your tenants agree to
 * texts"); the Flutter keys in texting_setup_screen.dart must match.
 */
export const CONSENT_METHODS = [
  'online_form',
  'lease_clause',
  'signed_form',
  'verbal_recorded',
  'text_start',
] as const;
export type ConsentMethod = (typeof CONSENT_METHODS)[number];

const GENERIC_DESCRIPTION =
  'Per-facility account notifications sent by self-storage operators to their own tenants: payment and past-due reminders, gate/access code information, move-in and move-out confirmations, and other operational account notices. Recipients are existing tenants who provided their mobile number and expressly opted in to text messages.';

const UNNAMED_FACILITY = 'Your storage facility';

function businessOf(facilityData: Record<string, any>): Record<string, any> {
  return (facilityData.textingBusinessData || {}) as Record<string, any>;
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function absoluteUrl(value: unknown): string {
  const raw = text(value);
  if (!raw) return '';
  return /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
}

/**
 * The name every text from the facility opens with.
 *
 * The facility's own name comes first because it is what live sends and the
 * START reply use; samples filed with the campaign must match live traffic.
 * The DBA and legal name are fallbacks for a facility with no name set.
 */
export function facilityDisplayName(facilityData: Record<string, any>): string {
  const business = businessOf(facilityData);
  return (
    text(facilityData.name) ||
    text(facilityData.facilityName) ||
    text(business.dba) ||
    text(business.legalBusinessName) ||
    UNNAMED_FACILITY
  );
}

/** Prefix a message body with the facility's name unless it already opens with it. */
export function withSenderPrefix(facilityData: Record<string, any>, body: string): string {
  const name = facilityDisplayName(facilityData);
  // A facility with no name at all is left unprefixed rather than labelled
  // with the placeholder (it cannot file a campaign without a legal name).
  if (name === UNNAMED_FACILITY) return body;
  return body.trim().toLowerCase().startsWith(name.toLowerCase()) ? body : `${name}: ${body}`;
}

/** The consent methods on the facility (or a request), known values only, deduplicated. */
export function normalizeConsentMethods(value: unknown): ConsentMethod[] {
  const list = Array.isArray(value) ? value : [];
  const known = new Set<string>(CONSENT_METHODS);
  return CONSENT_METHODS.filter((m) => list.includes(m) && known.has(m));
}

/**
 * The campaign description, named to the facility under review.
 *
 * Evidence from the two campaigns in the SFC Twilio account: the Hochatown
 * Saloon campaign (approved the same day it was filed) opens by naming the
 * registered business and what it is. SFC's own campaign (rejected 30909)
 * described a *class* of businesses texting on other companies' behalf and
 * never named the brand under review. A facility's brand is its own legal
 * entity, so the description reads as that facility describing itself.
 */
export function buildCampaignDescription(facilityData: Record<string, any>): string {
  const business = businessOf(facilityData);
  const legalName = text(business.legalBusinessName);
  if (!legalName) return GENERIC_DESCRIPTION;

  const dba = text(business.dba);
  const city = text(business.city);
  const state = text(business.state);
  const website = absoluteUrl(business.website);

  const named = dba && dba !== legalName ? `${legalName}, doing business as ${dba},` : legalName;
  const place = [city, state].filter(Boolean).join(', ');

  return (
    `${named} is a self-storage facility${place ? ` in ${place}` : ''}` +
    `${website ? ` (${website})` : ''}. This campaign sends account notifications ` +
    'from the facility to its own tenants: payment and past-due reminders, gate/access code ' +
    'information, move-in and move-out confirmations, and other operational account notices. ' +
    'Recipients are existing tenants of this facility who provided their mobile number and ' +
    'expressly opted in to text messages. No marketing or promotional messages are sent, and ' +
    'no numbers are purchased, rented or imported.'
  );
}

/** Auto-reply to START, naming the facility; identical to the live START reply. */
export function buildOptInMessage(facilityData: Record<string, any>): string {
  return buildTenantOptInConfirmation(facilityDisplayName(facilityData)).slice(0, 320);
}

function describeConsentMethod(
  method: ConsentMethod,
  name: string,
  facilityData: Record<string, any>,
): string {
  switch (method) {
    case 'online_form':
      return `on ${name}'s online rental form, by ticking a separate, unchecked box that reads "${TENANT_CONSENT_TEXT}"`;
    case 'lease_clause':
      return `by initialling a separate, optional SMS consent clause in ${name}'s written rental agreement`;
    case 'signed_form':
      return `by signing a separate SMS consent form at ${name}'s office`;
    case 'verbal_recorded':
      return `by agreeing in person at ${name}'s office, which staff record on the tenant's account with the date`;
    case 'text_start':
      return `by texting START to ${name}'s number, which replies "${buildOptInMessage(facilityData)}"`;
  }
}

/**
 * How tenants of *this* facility opt in — the field carriers read to verify
 * consent, and the one that failed 30909 when it described a checkbox on a
 * platform site the reviewer could not tie to the brand.
 *
 * Built only from the methods the owner selected: describing a paper or
 * in-person route a facility does not really use is a false filing. Throws if
 * none were selected.
 */
export function buildCampaignMessageFlow(
  facilityData: Record<string, any>,
  consentMethods: readonly ConsentMethod[] = normalizeConsentMethods(facilityData.textingConsentMethods),
): string {
  if (consentMethods.length === 0) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Choose how your tenants agree to texts before submitting the registration.',
    );
  }
  const business = businessOf(facilityData);
  const name = facilityDisplayName(facilityData);
  const legalName = text(business.legalBusinessName);
  const website = absoluteUrl(business.website);
  const who = legalName && legalName !== name ? `${name} (${legalName})` : name;

  const ways = consentMethods.map((m) => describeConsentMethod(m, name, facilityData));
  const waysText =
    ways.length === 1
      ? `Tenants agree to texts ${ways[0]}.`
      : `Tenants agree to texts in one of these ways: ${ways.map((w, i) => `(${i + 1}) ${w}`).join('; ')}.`;

  const parts = [
    `${who} texts only its own storage tenants, and only those who have agreed to receive texts from ${name}.`,
    waysText,
    'Consent is optional and is not a condition of renting.',
    `${name} records each tenant's consent, with its date and source, on the tenant's account in the facility's management software, which does not text a tenant without recorded consent.`,
    website ? `${name}'s website: ${website}.` : '',
    `Programme terms: ${SMS_TERMS_URL}. Privacy policy: ${PRIVACY_POLICY_URL}.`,
    consentMethods.includes('online_form')
      ? `A public copy of the online consent box, no login needed: ${SMS_CONSENT_DEMO_URL}.`
      : '',
    'Msg frequency varies. Msg & data rates may apply. Reply STOP to opt out, HELP for help. No numbers are bought, rented or shared.',
  ];
  return parts.filter(Boolean).join(' ').slice(0, 2048);
}

const LINK_PATTERN = /(https?:\/\/|www\.)|\b[a-z0-9-]+\.(com|net|org|us|io|co|biz|info|storage)\b/i;
const PHONE_PATTERN = /(\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b/;

/** Whether the samples contain links / phone numbers, as the campaign must declare. */
export function detectEmbeddedContent(samples: readonly string[]): {
  hasEmbeddedLinks: boolean;
  hasEmbeddedPhone: boolean;
} {
  return {
    hasEmbeddedLinks: samples.some((s) => LINK_PATTERN.test(s)),
    hasEmbeddedPhone: samples.some((s) => PHONE_PATTERN.test(s)),
  };
}

/**
 * Validate the owner's sample messages and make each one open with the
 * facility's name.
 *
 * Twilio requires two to five samples of at least 20 characters. Fewer is a
 * rejected API call after the brand fee is paid, so it is refused here. The
 * name prefix is what reviewers look for, and it is what live sends carry.
 */
export function prepareCampaignSamples(
  facilityData: Record<string, any>,
  samples: unknown,
): string[] {
  const list = (Array.isArray(samples) ? samples : [])
    .map((s) => text(s))
    .filter(Boolean);

  const unique = Array.from(new Set(list));
  if (unique.length < MIN_CAMPAIGN_SAMPLES) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      `Carrier registration needs at least ${MIN_CAMPAIGN_SAMPLES} different sample messages; ` +
        `${unique.length} provided. Select at least two message types.`,
    );
  }
  const tooShort = unique.filter((s) => s.length < MIN_SAMPLE_LENGTH);
  if (tooShort.length) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      `Each sample message must be at least ${MIN_SAMPLE_LENGTH} characters; ` +
        `too short: ${tooShort.map((s) => `"${s}"`).join(', ')}.`,
    );
  }

  return unique
    .slice(0, MAX_CAMPAIGN_SAMPLES)
    .map((s) => withSenderPrefix(facilityData, s).slice(0, MAX_SAMPLE_LENGTH));
}

/** Everything `usAppToPerson.create` needs for this facility. */
export function buildCampaignCreateParams(
  facilityData: Record<string, any>,
  brandRegistrationSid: string,
  usecase: string,
  samples: string[],
  consentMethods: readonly ConsentMethod[] = normalizeConsentMethods(facilityData.textingConsentMethods),
): UsAppToPersonListInstanceCreateOptions {
  return {
    brandRegistrationSid,
    usAppToPersonUsecase: usecase,
    description: buildCampaignDescription(facilityData),
    messageFlow: buildCampaignMessageFlow(facilityData, consentMethods),
    messageSamples: samples,
    ...detectEmbeddedContent(samples),
    // Keyword opt-in is declared only when the owner says tenants use it.
    ...(consentMethods.includes('text_start')
      ? { optInKeywords: ['START'], optInMessage: buildOptInMessage(facilityData) }
      : {}),
    privacyPolicyUrl: PRIVACY_POLICY_URL,
    termsAndConditionsUrl: SMS_TERMS_URL,
  };
}

/**
 * The campaign use case. A sole-proprietor brand only accepts SOLE_PROPRIETOR
 * (one campaign per brand); everyone else files LOW_VOLUME (Low Volume Mixed).
 *
 * This was ACCOUNT_NOTIFICATION until 2026-09-21. Both describe what a facility
 * sends, but ACCOUNT_NOTIFICATION draws the manual call-to-action review that
 * rejected SFC's own campaign on 30909, and costs ~$10/mo against Low Volume
 * Mixed's ~$1.50. LOW_VOLUME's ceiling (roughly 2,000 segments/day to
 * T-Mobile) is far above what one facility sends its own tenants.
 */
export function campaignUsecaseFor(facilityData: Record<string, any>): string {
  return isSoleProprietorBusinessType(businessOf(facilityData).businessType)
    ? 'SOLE_PROPRIETOR'
    : 'LOW_VOLUME';
}

/**
 * Brand registration parameters. SDK 5.x spells the A2P bundle field
 * `a2PProfileBundleSid`; the lower-case `a2pProfileBundleSid` the code used to
 * send is not a known option and would have been dropped, filing the brand
 * without its A2P bundle.
 *
 * A STANDARD brand that will only carry a LOW_VOLUME campaign skips automatic
 * secondary vetting: vetting buys throughput Low Volume Mixed cannot use and
 * costs about $40 per brand.
 */
export function buildBrandRegistrationParams(
  facilityData: Record<string, any>,
): BrandRegistrationListInstanceCreateOptions {
  const soleProp = isSoleProprietorBusinessType(businessOf(facilityData).businessType);
  return {
    customerProfileBundleSid: text(facilityData.twilioTrustProfileSid),
    a2PProfileBundleSid: text(facilityData.twilioTrustProductSid),
    // Sole proprietors (no EIN) register on Twilio's separate SOLE_PROPRIETOR
    // brand path; everyone else is STANDARD.
    brandType: soleProp ? 'SOLE_PROPRIETOR' : 'STANDARD',
    ...(!soleProp && campaignUsecaseFor(facilityData) === 'LOW_VOLUME'
      ? { skipAutomaticSecVet: true }
      : {}),
  };
}

export interface CampaignFilingResult {
  /** False when the brand is not approved yet and nothing was filed. */
  filed: boolean;
  brandStatus: string;
  /** usAppToPerson resource SID (QE...). */
  sid: string | null;
  /** Carrier campaign id (CM...). */
  campaignId: string | null;
  campaignStatus: string | null;
}

/**
 * File the facility's campaign if its brand is approved.
 *
 * A campaign is filed against an approved brand; brand review takes a day or
 * more, so the submit call usually finds it still pending. Rather than throw
 * after the brand fee has been spent, the caller records the request as pending
 * and the hourly poll files it once the brand clears. Callers hold the
 * facility's submission lease and pass freshly read facility data.
 */
export async function fileCampaignWhenBrandApproved(
  twilio: A2PTwilioClient,
  facilityData: Record<string, any>,
  samples: string[],
): Promise<CampaignFilingResult> {
  const brandSid = text(facilityData.twilioBrandSid);
  const messagingServiceSid = text(facilityData.twilioMessagingServiceSid);
  const brand = await twilio.messaging.v1.brandRegistrations(brandSid).fetch();
  const brandStatus = String(brand.status || '').toUpperCase();
  if (brandStatus !== 'APPROVED') {
    return { filed: false, brandStatus, sid: null, campaignId: null, campaignStatus: null };
  }

  const params = buildCampaignCreateParams(
    facilityData,
    brandSid,
    campaignUsecaseFor(facilityData),
    samples,
  );
  const campaign = await createUsAppToPersonCampaign(twilio, messagingServiceSid, params);
  functions.logger.info('A2P campaign filed', {
    brandSid,
    messagingServiceSid,
    usAppToPersonSid: campaign.sid,
    campaignId: campaign.campaignId || null,
    campaignStatus: campaign.campaignStatus || null,
    usecase: params.usAppToPersonUsecase,
    hasEmbeddedLinks: params.hasEmbeddedLinks,
    hasEmbeddedPhone: params.hasEmbeddedPhone,
    sampleCount: samples.length,
  });
  return {
    filed: true,
    brandStatus,
    sid: campaign.sid,
    campaignId: campaign.campaignId || null,
    campaignStatus: campaign.campaignStatus || null,
  };
}

/**
 * Facility fields recording a filing attempt. A deferred filing sets
 * `a2pCampaignPending`, which the hourly poll picks up once the brand clears.
 */
export function campaignFilingFields(result: CampaignFilingResult): Record<string, unknown> {
  if (!result.filed) {
    return { a2pCampaignPending: true, a2pBrandStatus: result.brandStatus };
  }
  return {
    // QE... usAppToPerson resource SID (what fetch needs) and the CM...
    // carrier campaign id (what Twilio's console and notices quote).
    twilioCampaignSid: result.sid,
    twilioCampaignId: result.campaignId,
    a2pCampaignStatus: result.campaignStatus,
    a2pCampaignPending: false,
    a2pCampaignFilingFailures: 0,
    a2pBrandStatus: result.brandStatus,
  };
}

/** File the campaign under the facility's messaging service. */
export async function createUsAppToPersonCampaign(
  twilio: A2PTwilioClient,
  messagingServiceSid: string,
  params: UsAppToPersonListInstanceCreateOptions,
): Promise<UsAppToPersonRecord> {
  return twilio.messaging.v1.services(messagingServiceSid).usAppToPerson.create(params);
}

/**
 * Read a filed campaign. Accepts the QE resource SID (what is stored now) or,
 * for anything recorded before, a CM carrier campaign id, found by listing the
 * service's campaigns.
 */
export async function fetchUsAppToPersonCampaign(
  twilio: A2PTwilioClient,
  messagingServiceSid: string,
  campaignSid: string,
): Promise<UsAppToPersonRecord | null> {
  const campaigns = twilio.messaging.v1.services(messagingServiceSid).usAppToPerson;
  if (campaignSid.startsWith('QE')) {
    return campaigns(campaignSid).fetch();
  }
  const all = await campaigns.list({ limit: 20 });
  return all.find((c) => c.campaignId === campaignSid || c.sid === campaignSid) ?? null;
}

// ---- deferred filing failures ------------------------------------------------

/** Deferred filings the poll attempts before giving up and asking the owner. */
export const MAX_DEFERRED_FILING_FAILURES = 3;

/**
 * Facility fields after a failed deferred campaign filing.
 *
 * Every failure is written to `a2pLastError` so it reaches the page instead of
 * only the logs. After MAX_DEFERRED_FILING_FAILURES the poll stops retrying and
 * marks the registration rejected, which shows the owner the reason and the
 * "Review and resubmit" action; that reset keeps the approved brand.
 */
export function deferredFilingFailureFields(
  facilityData: Record<string, any>,
  error: unknown,
): Record<string, unknown> {
  const message = String((error as any)?.message || error || 'unknown error').slice(0, 500);
  const failures = Number(facilityData.a2pCampaignFilingFailures || 0) + 1;
  const base: Record<string, unknown> = {
    a2pCampaignFilingFailures: failures,
    a2pLastError: `Campaign filing failed (attempt ${failures} of ${MAX_DEFERRED_FILING_FAILURES}): ${message}`,
  };
  if (failures < MAX_DEFERRED_FILING_FAILURES) return base;
  return {
    ...base,
    a2pCampaignPending: false,
    a2pStatus: 'rejected',
    a2pRejectionReason:
      `Your brand is approved, but the campaign could not be filed after ${failures} attempts: ` +
      `${message}. Review the messaging plan and submit again.`,
  };
}

// ---- reset after rejection ---------------------------------------------------

const failedStatus = (status: string): boolean =>
  /fail|reject|denied|suspend|delet/i.test(status);

export interface RegistrationResetPlan {
  /** What Twilio says was rejected. */
  rejected: 'brand' | 'campaign' | 'campaign_filing' | 'nothing_filed';
  /** Keep the brand SID: it is approved (or still usable) and cost a fee. */
  keepBrand: boolean;
  /** Remove the failed usAppToPerson from the messaging service before refiling. */
  removeCampaign: boolean;
}

/**
 * Decide what a reset after rejection clears, from Twilio's live statuses.
 *
 * The old reset deleted both the brand and campaign SIDs whatever had failed,
 * so a rejected *campaign* under an approved brand made the owner pay for a
 * second brand, and left the failed campaign on the messaging service.
 * Throws when Twilio shows nothing rejected, so a stale page cannot throw away
 * a campaign that is still in review or approved.
 */
export function planRegistrationReset(input: {
  hasBrand: boolean;
  brandStatus: string;
  hasCampaign: boolean;
  campaignStatus: string;
}): RegistrationResetPlan {
  const brand = input.brandStatus.toUpperCase();
  const campaign = input.campaignStatus.toUpperCase();
  if (!input.hasBrand) {
    return { rejected: 'nothing_filed', keepBrand: false, removeCampaign: false };
  }
  if (failedStatus(brand)) {
    return { rejected: 'brand', keepBrand: false, removeCampaign: input.hasCampaign };
  }
  if (input.hasCampaign && failedStatus(campaign)) {
    return { rejected: 'campaign', keepBrand: true, removeCampaign: true };
  }
  if (!input.hasCampaign) {
    // Brand fine, campaign never filed (deferred filing gave up).
    return { rejected: 'campaign_filing', keepBrand: true, removeCampaign: false };
  }
  throw new functions.https.HttpsError(
    'failed-precondition',
    `Twilio does not show this registration as rejected right now (brand ${brand || 'unknown'}, ` +
      `campaign ${campaign || 'unknown'}). Press Refresh status instead of resetting.`,
  );
}
