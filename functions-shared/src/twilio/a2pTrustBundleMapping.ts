/**
 * Maps the business details an owner types into the app onto the exact
 * attribute names and enum values Twilio's TrustHub policies expect.
 *
 * The field names here were read from the live policy requirement trees
 * (`trusthub.v1.policies(...)`) rather than from memory:
 *
 *   Secondary Customer Profile  RNdfbf3fae0e1107f8aded0e7cead80bf5
 *     end_user customer_profile_business_information
 *     end_user authorized_representative_1
 *     supporting_document customer_profile_address (field: address_sids)
 *
 *   A2P Messaging: Local - Business  RNb0d4771c2c98518d916a3d4cd70a8f8b
 *     end_user us_a2p_messaging_profile_information
 *
 * The policy API publishes field *names* but not the accepted *values*, and a
 * wrong enum only surfaces at brand registration, which charges a
 * non-refundable fee per attempt. So every enum below is constrained to a
 * closed union here, and the caller is expected to run the free TrustHub
 * evaluation before spending anything on a submission.
 */

/** Business types the app's own form offers. */
export type AppBusinessType = 'LLC' | 'Corp' | 'Nonprofit' | 'Sole Prop';

/** `business_type` values accepted by the customer profile policy. */
export type TrustHubBusinessType =
  | 'Sole Proprietorship'
  | 'Partnership'
  | 'Corporation'
  | 'Co-operative'
  | 'Limited Liability Corporation'
  | 'Non-profit Corporation';

/** `company_type` values accepted by the A2P messaging profile policy. */
export type TrustHubCompanyType = 'private' | 'public' | 'non-profit' | 'government';

interface BusinessTypeMapping {
  businessType: TrustHubBusinessType;
  companyType: TrustHubCompanyType;
  /**
   * Sole proprietors cannot be registered as a STANDARD brand. They take
   * Twilio's separate sole-proprietor path, which has its own policy, much
   * lower throughput, and requires OTP verification of the owner's mobile.
   */
  soleProprietor: boolean;
}

const BUSINESS_TYPE_MAP: Record<AppBusinessType, BusinessTypeMapping> = {
  LLC: {
    businessType: 'Limited Liability Corporation',
    companyType: 'private',
    soleProprietor: false,
  },
  Corp: { businessType: 'Corporation', companyType: 'private', soleProprietor: false },
  Nonprofit: {
    businessType: 'Non-profit Corporation',
    companyType: 'non-profit',
    soleProprietor: false,
  },
  'Sole Prop': {
    businessType: 'Sole Proprietorship',
    companyType: 'private',
    soleProprietor: true,
  },
};

export function mapBusinessType(value: unknown): BusinessTypeMapping | undefined {
  const key = typeof value === 'string' ? (value.trim() as AppBusinessType) : undefined;
  return key ? BUSINESS_TYPE_MAP[key] : undefined;
}

/**
 * Self storage is real estate under the carrier industry taxonomy. Hard-coded
 * rather than asked, because the app only serves self-storage operators and an
 * owner guessing at a carrier taxonomy is a rejection waiting to happen.
 */
export const A2P_BUSINESS_INDUSTRY = 'REAL_ESTATE';
/** These facilities are US-based; the app does not sell outside the US yet. */
export const A2P_REGIONS_OF_OPERATION = 'USA_AND_CANADA';
/** The facility owner is the end customer, not a reseller of messaging. */
export const A2P_BUSINESS_IDENTITY = 'direct_customer';
/** US businesses register with an EIN. */
export const A2P_REGISTRATION_IDENTIFIER = 'EIN';

export interface TrustBundleInput {
  legalBusinessName: string;
  businessType: AppBusinessType;
  /**
   * Full EIN, formatted or not. Carrier vetting matches this against public
   * registration records, so the last four the app persists is not enough.
   * Deliberately not stored: it is used to build the end user and discarded.
   */
  ein?: string;
  addressLine1: string;
  city: string;
  state: string;
  postalCode: string;
  country?: string;
  website: string;
  supportEmail: string;
  supportPhone: string;
  representativeFirstName: string;
  representativeLastName: string;
  representativeBusinessTitle?: string;
  /**
   * Sole proprietors have no EIN. Twilio verifies them instead by texting a
   * one-time code to this mobile, so it is required for a 'Sole Prop' bundle
   * and ignored for the others. It must be a real US/Canada mobile the owner
   * controls and cannot be a Twilio (CPaaS) number.
   */
  mobilePhone?: string;
}

/** True when this business registers on Twilio's sole-proprietor path. */
export function isSoleProprietorBusinessType(value: unknown): boolean {
  return mapBusinessType(value)?.soleProprietor === true;
}

/** Digits-only EIN, e.g. "12-3456789" -> "123456789". */
export function normalizeEin(value: unknown): string {
  return typeof value === 'string' ? value.replace(/\D/g, '') : '';
}

/** E.164 for a US number, e.g. "(512) 555-0147" -> "+15125550147". */
export function toE164UsPhone(value: unknown): string {
  const digits = typeof value === 'string' ? value.replace(/\D/g, '') : '';
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  if (digits.length === 10) return `+1${digits}`;
  return '';
}

/** Carrier vetting rejects bare hostnames; force an absolute https URL. */
export function normalizeWebsiteUrl(value: unknown): string {
  const raw = typeof value === 'string' ? value.trim() : '';
  if (!raw) return '';
  if (/^https?:\/\//i.test(raw)) return raw;
  return `https://${raw}`;
}

export function buildBusinessInformationAttributes(
  input: TrustBundleInput,
): Record<string, string> {
  const mapping = mapBusinessType(input.businessType);
  if (!mapping) {
    throw new Error(`Unsupported business type: ${String(input.businessType)}`);
  }
  const attrs: Record<string, string> = {
    business_name: input.legalBusinessName.trim(),
    business_type: mapping.businessType,
    business_identity: A2P_BUSINESS_IDENTITY,
    business_industry: A2P_BUSINESS_INDUSTRY,
    business_regions_of_operation: A2P_REGIONS_OF_OPERATION,
    website_url: normalizeWebsiteUrl(input.website),
    social_media_profile_urls: '',
  };
  // Sole proprietors have no tax ID; Twilio forbids an EIN on that path and
  // verifies the owner by mobile OTP instead. Only send the registration
  // number for entities that actually have one.
  if (!mapping.soleProprietor) {
    // Never send an empty or partial registration number. Twilio accepts the
    // end user either way and the gap only surfaces at brand vetting, after
    // the fee is spent; the caller must supply all nine digits.
    const ein = normalizeEin(input.ein);
    if (ein.length !== 9) {
      throw new Error(
        'A 9-digit EIN is required to register a business that is not a sole proprietor.',
      );
    }
    attrs.business_registration_identifier = A2P_REGISTRATION_IDENTIFIER;
    attrs.business_registration_number = ein;
  }
  return attrs;
}

export function buildAuthorizedRepresentativeAttributes(
  input: TrustBundleInput,
): Record<string, string> {
  return {
    first_name: input.representativeFirstName.trim(),
    last_name: input.representativeLastName.trim(),
    email: input.supportEmail.trim(),
    phone_number: toE164UsPhone(input.supportPhone),
    business_title: (input.representativeBusinessTitle || 'Owner').trim(),
    // The policy accepts a fixed set of positions; an owner-operator of a
    // storage facility is not a Director/VP/CFO, so "Other" is the honest one.
    job_position: 'Other',
  };
}

export function buildA2pMessagingProfileAttributes(
  input: TrustBundleInput,
): Record<string, string> {
  const mapping = mapBusinessType(input.businessType);
  if (!mapping) {
    throw new Error(`Unsupported business type: ${String(input.businessType)}`);
  }
  const attrs: Record<string, string> = {
    company_type: mapping.companyType,
    brand_contact_email: input.supportEmail.trim(),
  };
  // The sole-proprietor messaging profile carries the mobile number Twilio
  // texts the verification code to. E.164, and never a Twilio number.
  if (mapping.soleProprietor) {
    const mobile = toE164UsPhone(input.mobilePhone);
    if (mobile) attrs.mobile_phone_number = mobile;
  }
  return attrs;
}

export function buildAddressPayload(input: TrustBundleInput): {
  customerName: string;
  street: string;
  city: string;
  region: string;
  postalCode: string;
  isoCountry: string;
} {
  return {
    customerName: input.legalBusinessName.trim(),
    street: input.addressLine1.trim(),
    city: input.city.trim(),
    region: input.state.trim().toUpperCase(),
    postalCode: input.postalCode.trim(),
    isoCountry: (input.country || 'US').trim().toUpperCase(),
  };
}

export interface EvaluationFieldFailure {
  objectType: string;
  field: string;
  reason: string;
}

export interface EvaluationSummary {
  compliant: boolean;
  status: string;
  failures: EvaluationFieldFailure[];
  /** SID of the evaluation (EL...), so a stored issue can be looked up in Twilio. */
  evaluationSid?: string;
  /** Policy the bundle was evaluated against (RN...). */
  policySid?: string;
}

function firstText(...values: unknown[]): string {
  for (const value of values) {
    if (typeof value === 'string' && value.trim()) return value.trim();
  }
  return '';
}

/**
 * Flatten a TrustHub evaluation into the specific fields that failed.
 *
 * Twilio reports each policy requirement as a result carrying
 * `requirement_friendly_name` / `requirement_name`, the overall `passed` flag,
 * and the failing fields in `invalid[]` (with `valid[]` for the ones that
 * passed). An older shape used `friendly_name` and `fields[]` with a per-field
 * `passed`; both are read. Without this the owner sees "noncompliant" and no way
 * to know which box to fix, and every failure collapsed to "missing".
 */
export function summarizeEvaluation(evaluation: unknown): EvaluationSummary {
  const ev = (evaluation || {}) as Record<string, any>;
  const status = String(ev.status || '').toLowerCase();
  const failures: EvaluationFieldFailure[] = [];

  for (const result of Array.isArray(ev.results) ? ev.results : []) {
    const r = (result || {}) as Record<string, any>;
    if (r.passed === true) continue;
    const objectType =
      firstText(r.requirement_friendly_name, r.friendly_name, r.requirement_name, r.object_type) ||
      'requirement';

    const invalid = Array.isArray(r.invalid) ? r.invalid : [];
    const legacyFields = (Array.isArray(r.fields) ? r.fields : []).filter(
      (f: unknown) => (f as Record<string, any> | null)?.passed !== true,
    );
    let addedForThisResult = false;
    for (const field of [...invalid, ...legacyFields]) {
      const f = (field || {}) as Record<string, any>;
      failures.push({
        objectType,
        field: firstText(f.friendly_name, f.object_field, f.name) || 'unknown',
        reason: firstText(f.failure_reason) || 'Did not meet the carrier policy',
      });
      addedForThisResult = true;
    }

    // A requirement can fail wholesale (e.g. missing entirely) with no
    // per-field detail; without this the failure would vanish from the summary.
    if (!addedForThisResult) {
      failures.push({
        objectType,
        field: 'missing',
        reason: firstText(r.failure_reason) || 'Required item is missing from the bundle',
      });
    }
  }

  const evaluationSid = firstText(ev.sid);
  const policySid = firstText(ev.policySid, ev.policy_sid);
  return {
    compliant: status === 'compliant' && failures.length === 0,
    status,
    failures,
    ...(evaluationSid ? { evaluationSid } : {}),
    ...(policySid ? { policySid } : {}),
  };
}

/**
 * Owner-facing one-liner naming exactly what to fix, followed by the
 * evaluation and policy SIDs so support can find the same verdict in Twilio.
 */
export function formatEvaluationFailures(summary: EvaluationSummary): string {
  if (summary.compliant) return '';
  const refs = [
    summary.evaluationSid ? `evaluation ${summary.evaluationSid}` : '',
    summary.policySid ? `policy ${summary.policySid}` : '',
  ]
    .filter(Boolean)
    .join(', ');
  const suffix = refs ? ` (${refs})` : '';
  if (summary.failures.length === 0) {
    return `Twilio reported the business profile as ${summary.status}.${suffix}`;
  }
  return (
    summary.failures.map((f) => `${f.objectType} — ${f.field}: ${f.reason}`).join('; ') + suffix
  );
}
