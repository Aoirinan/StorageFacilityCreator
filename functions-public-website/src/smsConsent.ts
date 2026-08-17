/**
 * SMS consent captured on the public rental form.
 *
 * Under A2P 10DLC the operator has to be able to show, per tenant, that
 * consent was given and how. Carriers audit this, and "we have their number"
 * is not consent. So the decision is deliberately one-sided: only an explicit
 * boolean `true` from the reservation counts, and everything else — missing,
 * absent, the string "false", a truthy-looking value from an older client —
 * records as not consented and leaves the tenant opted out.
 *
 * A refusal is stored as positively as an approval: if a complaint is ever
 * raised, being able to show the box was unchecked matters as much as being
 * able to show it was checked.
 */

export interface SmsConsentFields {
  smsConsentStatus: 'opted_in' | 'unknown';
  smsConsentSource: string | null;
  smsConsentTimestamp: unknown | null;
  smsOptInDate: unknown | null;
  smsOptOut: boolean;
}

/**
 * Map reservation metadata onto the tenant's consent fields.
 *
 * `now` is passed in rather than read here so the caller can use the same
 * server timestamp it writes everything else with.
 */
export function resolveSmsConsentFields(
  metadata: Record<string, unknown> | null | undefined,
  now: unknown,
): SmsConsentFields {
  const meta = metadata || {};
  // Strict identity check: a string "false" is truthy in JS, and treating it
  // as consent would opt a tenant in who explicitly declined.
  const consented = meta.smsConsent === true;

  if (!consented) {
    return {
      smsConsentStatus: 'unknown',
      smsConsentSource: null,
      smsConsentTimestamp: null,
      smsOptInDate: null,
      smsOptOut: true,
    };
  }

  const source = String(meta.smsConsentSource || '').trim() || 'publicRentalForm';
  return {
    smsConsentStatus: 'opted_in',
    smsConsentSource: source,
    smsConsentTimestamp: now,
    smsOptInDate: now,
    smsOptOut: false,
  };
}
