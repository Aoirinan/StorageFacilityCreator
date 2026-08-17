/**
 * Validation for the business details submitted to A2P 10DLC brand vetting.
 *
 * Carrier vetting checks these against public records and rejects the brand if
 * they do not hold up. Rejections cost money ($4.50-$46 per brand, $15 per
 * campaign) and days of turnaround, and a facility owner cannot send a single
 * message until it clears — so it is far cheaper to refuse bad input at
 * submission than to discover it after review.
 *
 * This was not theoretical: a live facility reached carrier submission with
 * postal code "959595" and support phone "99999".
 */

export interface A2PBusinessData {
  legalBusinessName?: unknown;
  businessType?: unknown;
  /**
   * Full EIN as submitted from the form. Carrier vetting matches all nine
   * digits against public registration records, so this is what a submission
   * must carry — only the last four are ever persisted.
   */
  ein?: unknown;
  /** Last four, as persisted on the facility after a submission. */
  einLast4?: unknown;
  representativeFirstName?: unknown;
  representativeLastName?: unknown;
  addressLine1?: unknown;
  city?: unknown;
  state?: unknown;
  postalCode?: unknown;
  country?: unknown;
  supportEmail?: unknown;
  supportPhone?: unknown;
  website?: unknown;
}

export interface A2PValidationIssue {
  field: string;
  message: string;
}

const str = (v: unknown): string => (typeof v === 'string' ? v.trim() : '');

/** US ZIP: 5 digits, optionally +4. */
const US_ZIP = /^\d{5}(-\d{4})?$/;
/** Two-letter US state code. */
const US_STATE = /^[A-Za-z]{2}$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/**
 * Digits in a US phone number, ignoring formatting and an optional +1.
 * Rejects the repeated-digit placeholders people type to get past a form.
 */
export function isValidUsPhone(value: unknown): boolean {
  const digits = str(value).replace(/\D/g, '');
  const local = digits.length === 11 && digits.startsWith('1') ? digits.slice(1) : digits;
  if (local.length !== 10) return false;
  // NANP: area code and exchange cannot start with 0 or 1.
  if (/^[01]/.test(local) || /^[01]/.test(local.slice(3))) return false;
  // 5555555555, 0000000000 and friends are placeholders, not phone numbers.
  if (/^(\d)\1{9}$/.test(local)) return false;
  return true;
}

/** Last four of an EIN — exactly four digits. */
export function isValidEinLast4(value: unknown): boolean {
  return /^\d{4}$/.test(str(value));
}

/** A full EIN is nine digits; formatting such as "12-3456789" is fine. */
export function isValidFullEin(value: unknown): boolean {
  const digits = str(value).replace(/\D/g, '');
  if (digits.length !== 9) return false;
  // 000000000 / 111111111 and friends are placeholders, not EINs.
  if (/^(\d)\1{8}$/.test(digits)) return false;
  return true;
}

/**
 * Website must be a syntactically valid http(s) URL with a dotted host.
 * Carriers actually visit this, so "russ.com" style guesses are worth catching
 * as at least structurally plausible before submission.
 */
export function isValidWebsite(value: unknown): boolean {
  const raw = str(value);
  if (!raw) return false;
  const candidate = /^https?:\/\//i.test(raw) ? raw : `https://${raw}`;
  try {
    const url = new URL(candidate);
    if (!/^https?:$/.test(url.protocol)) return false;
    const host = url.hostname;
    if (!host.includes('.')) return false;
    if (host.startsWith('.') || host.endsWith('.')) return false;
    const tld = host.split('.').pop() || '';
    return /^[a-z]{2,}$/i.test(tld);
  } catch {
    return false;
  }
}

/**
 * Validate everything carrier vetting will look at.
 * Returns every problem at once so the operator fixes the form in one pass.
 */
export function validateA2PBusinessData(data: A2PBusinessData): A2PValidationIssue[] {
  const issues: A2PValidationIssue[] = [];
  const add = (field: string, message: string) => issues.push({ field, message });

  const legalName = str(data.legalBusinessName);
  if (legalName.length < 2) {
    add('legalBusinessName', 'Enter the full legal business name as registered with the IRS.');
  }

  if (!str(data.businessType)) {
    add('businessType', 'Select a business type.');
  }

  // The submission form sends the full EIN; a facility that has already been
  // saved carries only the last four. Accept whichever is present, because
  // requiring `einLast4` alone rejected every submission the form could make.
  if (data.ein !== undefined && data.ein !== null && str(data.ein) !== '') {
    if (!isValidFullEin(data.ein)) {
      add('ein', 'Enter the 9-digit business EIN, for example 12-3456789.');
    }
  } else if (!isValidEinLast4(data.einLast4)) {
    add('ein', 'Enter the 9-digit business EIN, for example 12-3456789.');
  }

  if (str(data.representativeFirstName).length < 2) {
    add(
      'representativeFirstName',
      "Enter the authorized representative's first name — carriers require a named contact.",
    );
  }

  if (str(data.representativeLastName).length < 2) {
    add(
      'representativeLastName',
      "Enter the authorized representative's last name — carriers require a named contact.",
    );
  }

  if (str(data.addressLine1).length < 3) {
    add('addressLine1', 'Enter the registered business street address.');
  }

  if (!str(data.city)) {
    add('city', 'Enter the business city.');
  }

  const country = str(data.country).toUpperCase() || 'US';
  const state = str(data.state);
  if (country === 'US' && !US_STATE.test(state)) {
    add('state', 'Enter a two-letter state code, for example TX.');
  }

  const postal = str(data.postalCode);
  if (country === 'US' && !US_ZIP.test(postal)) {
    add('postalCode', 'Enter a valid US ZIP code, for example 75460 or 75460-1234.');
  }

  if (!EMAIL.test(str(data.supportEmail))) {
    add('supportEmail', 'Enter a valid support email address.');
  }

  if (!isValidUsPhone(data.supportPhone)) {
    add('supportPhone', 'Enter a valid 10-digit US support phone number.');
  }

  if (!isValidWebsite(data.website)) {
    add('website', 'Enter the business website, for example https://example.com. Carriers visit this URL during review.');
  }

  return issues;
}

/** One-line summary suitable for an error message back to the client. */
export function formatA2PValidationIssues(issues: readonly A2PValidationIssue[]): string {
  return issues.map((i) => `${i.field}: ${i.message}`).join(' ');
}
