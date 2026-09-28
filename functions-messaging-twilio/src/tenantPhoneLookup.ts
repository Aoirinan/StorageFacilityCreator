import * as admin from 'firebase-admin';
import { formatPhoneNumber } from '@sfc/functions-shared';

/**
 * Finding the tenants behind an inbound phone number.
 *
 * Tenant phones are stored the way the operator typed them, which in
 * production is mostly "903-555-0100". The inbound webhook used to query
 * `phone` only as +19035550100 / 19035550100 / 9035550100, so it matched no
 * one: a tenant's STOP was never recorded (they still showed as consenting),
 * HELP got no reply, and a tenant's reply to the shared toll-free was filed as
 * a new SFC sales lead and sent the lead auto-reply.
 *
 * Tenants carry no stored digits-only field (TenantModel.phoneDigits is a
 * getter in the app), so this queries every common written form of the
 * number, then confirms each hit by comparing digits.
 */

export interface TenantPhoneMatch {
  facilityId: string;
  id: string;
  phone: string;
  isActive: boolean;
}

/** The last ten digits of a US number, or null. */
export function nationalDigits(phone: string | null | undefined): string | null {
  const e164 = formatPhoneNumber(phone ?? '');
  if (!e164) return null;
  const digits = e164.replace(/\D/g, '');
  if (digits.length === 11 && digits.startsWith('1')) return digits.slice(1);
  return null;
}

/** Whether two written phone numbers are the same US number. */
export function samePhone(a: string | null | undefined, b: string | null | undefined): boolean {
  const da = nationalDigits(a);
  return da != null && da === nationalDigits(b);
}

/**
 * Every way the number is plausibly written in a tenant doc. At most 30, the
 * limit for a Firestore `in` filter.
 */
export function phoneLookupVariants(phone: string): string[] {
  const d = nationalDigits(phone);
  if (!d) return [];
  const a = d.slice(0, 3);
  const b = d.slice(3, 6);
  const c = d.slice(6);
  const variants = [
    `+1${d}`,
    `1${d}`,
    d,
    `${a}-${b}-${c}`,
    `(${a}) ${b}-${c}`,
    `(${a})${b}-${c}`,
    `(${a}) ${b} ${c}`,
    `${a}.${b}.${c}`,
    `${a} ${b} ${c}`,
    `${a} ${b}-${c}`,
    `1-${a}-${b}-${c}`,
    `1 (${a}) ${b}-${c}`,
    `+1-${a}-${b}-${c}`,
    `+1 ${a}-${b}-${c}`,
    `+1 (${a}) ${b}-${c}`,
    `+1 ${a} ${b} ${c}`,
    `+1 ${d}`,
    `+1${a}${b}-${c}`,
  ];
  return Array.from(new Set(variants));
}

/**
 * Orders matches so the most relevant tenant comes first: the facility that
 * owns the inbound number, then active tenants, then the rest.
 */
export function rankTenantMatches(
  matches: TenantPhoneMatch[],
  facilityIdHint?: string | null,
): TenantPhoneMatch[] {
  const seen = new Set<string>();
  const unique = matches.filter((m) => {
    const key = `${m.facilityId}/${m.id}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  const score = (m: TenantPhoneMatch) =>
    (facilityIdHint && m.facilityId === facilityIdHint ? 0 : 2) + (m.isActive ? 0 : 1);
  return unique
    .map((m, i) => ({ m, i }))
    .sort((x, y) => score(x.m) - score(y.m) || x.i - y.i)
    .map(({ m }) => m);
}

/** What the finder needs from Firestore, so the rule can be tested without it. */
export interface TenantPhoneStore {
  /** Tenants in any facility whose `phone` is one of [phones] and isActive == [isActive]. */
  queryByPhones(phones: string[], isActive: boolean): Promise<TenantPhoneMatch[]>;
  /** Every tenant of one facility, for the digits scan fallback. */
  listFacilityTenants(facilityId: string): Promise<TenantPhoneMatch[]>;
}

export const firestoreTenantPhoneStore: TenantPhoneStore = {
  async queryByPhones(phones, isActive) {
    // Equality on isActive plus `in` on phone uses the existing collection
    // group index (isActive, phone); no new index is needed.
    const snap = await admin
      .firestore()
      .collectionGroup('tenants')
      .where('isActive', '==', isActive)
      .where('phone', 'in', phones)
      .limit(50)
      .get();
    const out: TenantPhoneMatch[] = [];
    for (const doc of snap.docs) {
      const facilityId = doc.ref.parent.parent?.id;
      if (!facilityId) continue;
      out.push({ facilityId, id: doc.id, phone: String(doc.get('phone') ?? ''), isActive });
    }
    return out;
  },
  async listFacilityTenants(facilityId) {
    const snap = await admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .select('phone', 'isActive')
      .get();
    return snap.docs.map((doc) => ({
      facilityId,
      id: doc.id,
      phone: String(doc.get('phone') ?? ''),
      isActive: doc.get('isActive') === true,
    }));
  },
};

/**
 * Every tenant (active or not, any facility) whose phone is [phoneNumber],
 * best match first. Former tenants are included on purpose: a STOP from them
 * must still be recorded, and their reply is not a sales lead.
 *
 * When nothing matches in any written form and the number was texted on a
 * facility's own line, that facility's tenants are scanned by digits, which
 * catches formats the variant list does not.
 */
export async function findTenantsByPhoneNumber(
  phoneNumber: string,
  facilityIdHint?: string | null,
  store: TenantPhoneStore = firestoreTenantPhoneStore,
): Promise<TenantPhoneMatch[]> {
  const variants = phoneLookupVariants(phoneNumber);
  if (variants.length === 0) return [];

  const [active, inactive] = await Promise.all([
    store.queryByPhones(variants, true),
    store.queryByPhones(variants, false),
  ]);
  let matches = [...active, ...inactive].filter((m) => samePhone(m.phone, phoneNumber));

  if (matches.length === 0 && facilityIdHint) {
    const all = await store.listFacilityTenants(facilityIdHint);
    matches = all.filter((m) => samePhone(m.phone, phoneNumber));
  }

  return rankTenantMatches(matches, facilityIdHint);
}
