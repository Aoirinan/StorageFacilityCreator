import * as admin from 'firebase-admin';
import { phoneLookupVariants, samePhone } from './tenantPhoneLookup';

/**
 * Whether a text may go to a number that belongs to a tenant of the sending
 * facility.
 *
 * sendSMS used to check opt-out and consent only when the facility had the
 * enhancedOptOut feature or texting onboarding switched on, and only for the
 * tenant id the client passed. A facility with neither could text a tenant who
 * had replied STOP. Now any tenant of the facility whose phone is the
 * recipient number (matched on digits, as the inbound STOP handler matches)
 * is checked, whatever the facility's settings and whatever forceSend says.
 */

export interface TenantConsentFields {
  id: string;
  phone?: unknown;
  smsOptOut?: unknown;
  smsConsentStatus?: unknown;
  smsOptInDate?: unknown;
}

export function tenantOptedOut(t: TenantConsentFields): boolean {
  return t.smsOptOut === true || String(t.smsConsentStatus ?? '').toLowerCase() === 'opted_out';
}

/**
 * Consent is recorded two ways: the public move-in form and the inbound START
 * handler write smsConsentStatus 'opted_in'; the operator screens record an
 * smsOptInDate with smsOptOut false. Both count.
 */
export function tenantHasSmsConsent(t: TenantConsentFields): boolean {
  if (tenantOptedOut(t)) return false;
  if (String(t.smsConsentStatus ?? '').toLowerCase() === 'opted_in') return true;
  return Boolean(t.smsOptInDate);
}

export type TenantConsentRefusal = 'opted_out' | 'no_consent';

export interface TenantConsentDecision {
  allowed: boolean;
  refusal?: TenantConsentRefusal;
  /** Whether the number belongs to any tenant of the facility at all. */
  isTenantNumber: boolean;
}

/**
 * [matches] are the facility's tenants whose phone is the recipient number.
 * Any opt-out among them blocks: STOP belongs to the number. Otherwise the
 * targeted tenant's consent decides when it is among them, else any match's.
 * A number that belongs to no tenant is not decided here.
 */
export function decideTenantRecipientConsent(
  matches: TenantConsentFields[],
  targetTenantId?: string | null,
): TenantConsentDecision {
  if (matches.length === 0) return { allowed: true, isTenantNumber: false };
  if (matches.some(tenantOptedOut)) {
    return { allowed: false, refusal: 'opted_out', isTenantNumber: true };
  }
  const target = targetTenantId ? matches.find((m) => m.id === targetTenantId) : undefined;
  const consented = target ? tenantHasSmsConsent(target) : matches.some(tenantHasSmsConsent);
  return consented
    ? { allowed: true, isTenantNumber: true }
    : { allowed: false, refusal: 'no_consent', isTenantNumber: true };
}

/** The facility's tenants (any status) whose phone is [phoneNumber]. */
export async function findFacilityTenantsForNumber(
  facilityId: string,
  phoneNumber: string,
  targetTenantId?: string | null,
): Promise<TenantConsentFields[]> {
  const tenantsRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants');
  const variants = phoneLookupVariants(phoneNumber);
  const byId = new Map<string, TenantConsentFields>();
  const add = (doc: admin.firestore.DocumentSnapshot) => {
    const data = doc.data();
    if (!data) return;
    const fields: TenantConsentFields = { id: doc.id, ...data };
    if (samePhone(fields.phone as string | undefined, phoneNumber)) byId.set(doc.id, fields);
  };
  if (variants.length > 0) {
    const snap = await tenantsRef.where('phone', 'in', variants).limit(50).get();
    snap.docs.forEach(add);
  }
  // The targeted tenant may have its phone written in a form the variant list
  // does not cover; read it directly.
  if (targetTenantId && !byId.has(targetTenantId)) {
    add(await tenantsRef.doc(targetTenantId).get());
  }
  return Array.from(byId.values());
}
