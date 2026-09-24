/**
 * Which platform account belongs to an owner, and the copy of its standing
 * that each of the owner's facilities carries for their invited staff.
 *
 * An owner should have exactly one `facilityCreatorAccounts` doc, but the app
 * used to create a second, pendingApproval one whenever its account read
 * failed. Server code then took whichever doc `limit(1)` returned, so the same
 * owner could be billed, linked or rewarded on the duplicate. Every lookup by
 * owner goes through [findOwnerAccountDoc], which prefers the same doc the app
 * does (FacilityCreatorAccountService.preferredOwnerAccount).
 */
import type * as admin from 'firebase-admin';

/** Bound on one owner lookup: one doc is the intent, this stops a runaway read. */
export const OWNER_ACCOUNT_READ_LIMIT = 20;

/** The facility field that mirrors the owner's account standing. */
export const OWNER_ACCOUNT_STANDING_FIELD = 'ownerAccountStanding';

/** Anything shaped like a Firestore document snapshot. */
export interface AccountDocLike {
  id: string;
  data(): Record<string, unknown> | undefined;
}

function millis(value: unknown): number | null {
  if (value == null) return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (value instanceof Date) return value.getTime();
  const toMillis = (value as { toMillis?: unknown }).toMillis;
  if (typeof toMillis === 'function') {
    const ms = (toMillis as () => number).call(value);
    return Number.isFinite(ms) ? ms : null;
  }
  return null;
}

/**
 * The account to use for an owner with [docs]: any that is not
 * pendingApproval before one that is, then the oldest (the original, which is
 * the one a super admin approved, billed or suspended), then by id so the
 * answer never depends on read order. A doc without a readable createdAt
 * counts as the newest, as the app reads it. Null when there are none.
 */
export function preferredOwnerAccountDoc<T extends AccountDocLike>(docs: readonly T[]): T | null {
  if (docs.length === 0) return null;
  const rank = (doc: T) => {
    const data = doc.data() ?? {};
    return {
      pending: data.subscriptionStatus === 'pendingApproval' ? 1 : 0,
      created: millis(data.createdAt) ?? Number.POSITIVE_INFINITY,
    };
  };
  const sorted = [...docs].sort((a, b) => {
    const ra = rank(a);
    const rb = rank(b);
    if (ra.pending !== rb.pending) return ra.pending - rb.pending;
    if (ra.created !== rb.created) return ra.created < rb.created ? -1 : 1;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  return sorted[0];
}

/** Every account doc with this ownerUid (bounded), in no particular order. */
export async function listOwnerAccountDocs(
  db: admin.firestore.Firestore,
  ownerUid: string,
): Promise<admin.firestore.QueryDocumentSnapshot[]> {
  const snap = await db
    .collection('facilityCreatorAccounts')
    .where('ownerUid', '==', ownerUid)
    .limit(OWNER_ACCOUNT_READ_LIMIT)
    .get();
  return snap.docs;
}

/** [ownerUid]'s account doc (see [preferredOwnerAccountDoc]), or null when they have none. */
export async function findOwnerAccountDoc(
  db: admin.firestore.Firestore,
  ownerUid: string,
): Promise<admin.firestore.QueryDocumentSnapshot | null> {
  return preferredOwnerAccountDoc(await listOwnerAccountDocs(db, ownerUid));
}

/**
 * What an invited team member's app needs to know about the owner's account.
 * Staff cannot read the account doc (the rules only let its owner), so the
 * owner's facilities carry this copy, written only by the backend.
 *
 * The dates are copied rather than turned into a yes/no here so the app can
 * apply them as time passes (a trial or paid period ends between writes).
 */
export interface OwnerAccountStanding {
  accountId: string;
  subscriptionStatus: string;
  /** The account's Timestamp, as stored, or null. */
  subscriptionTrialEnd: unknown;
  /** The account's Timestamp, as stored, or null. */
  subscriptionCurrentPeriodEnd: unknown;
  suspended: boolean;
  billingExempt: boolean;
}

function timestampOrNull(value: unknown): unknown {
  return millis(value) == null ? null : value;
}

export function buildOwnerAccountStanding(doc: AccountDocLike): OwnerAccountStanding {
  const data = doc.data() ?? {};
  return {
    accountId: doc.id,
    subscriptionStatus: typeof data.subscriptionStatus === 'string' ? data.subscriptionStatus : '',
    subscriptionTrialEnd: timestampOrNull(data.subscriptionTrialEnd),
    subscriptionCurrentPeriodEnd: timestampOrNull(data.subscriptionCurrentPeriodEnd),
    suspended: data.suspended === true,
    billingExempt: data.billingExempt === true,
  };
}

/** Whether the [stored] facility field already says what [wanted] does. */
export function sameOwnerAccountStanding(stored: unknown, wanted: OwnerAccountStanding | null): boolean {
  if (wanted == null) return stored == null;
  if (stored == null || typeof stored !== 'object') return false;
  const s = stored as Record<string, unknown>;
  return (
    s.accountId === wanted.accountId &&
    s.subscriptionStatus === wanted.subscriptionStatus &&
    millis(s.subscriptionTrialEnd) === millis(wanted.subscriptionTrialEnd) &&
    millis(s.subscriptionCurrentPeriodEnd) === millis(wanted.subscriptionCurrentPeriodEnd) &&
    s.suspended === wanted.suspended &&
    s.billingExempt === wanted.billingExempt
  );
}

/** Account fields the mirror, or the set of facilities that carry it, depends on. */
const STANDING_INPUTS = [
  'ownerUid',
  'subscriptionStatus',
  'subscriptionTrialEnd',
  'subscriptionCurrentPeriodEnd',
  'suspended',
  'billingExempt',
  'createdAt',
  'facilityIds',
];

/**
 * Whether an account write can change any facility's mirror. Most account
 * writes (updatedAt, referral codes, onboarding email marks) cannot, and the
 * trigger skips its reads for them. facilityIds is included because a newly
 * linked facility needs the mirror written.
 */
export function accountWriteAffectsStanding(
  before: Record<string, unknown> | undefined,
  after: Record<string, unknown> | undefined,
): boolean {
  if (!before || !after) return before !== after;
  return STANDING_INPUTS.some((key) => {
    const a = before[key];
    const b = after[key];
    const am = millis(a);
    const bm = millis(b);
    if (am != null || bm != null) return am !== bm;
    return JSON.stringify(a ?? null) !== JSON.stringify(b ?? null);
  });
}

export interface OwnerStandingSyncDeps {
  /** Every account doc with this ownerUid (bounded). */
  listOwnerAccounts(ownerUid: string): Promise<AccountDocLike[]>;
  /** Every facility doc with this ownerUid, archived ones included. */
  listOwnerFacilities(ownerUid: string): Promise<AccountDocLike[]>;
  /** Sets the facility's mirror, or removes it when [standing] is null. */
  writeFacilityStanding(facilityId: string, standing: OwnerAccountStanding | null): Promise<void>;
}

/**
 * Brings the mirror on every facility [ownerUid] owns in line with their
 * preferred account, writing only the facilities that differ. With no account
 * at all the mirror is removed: the app lets an owner with no account in, and
 * treats a facility without the mirror the same way.
 *
 * Facilities are found by ownerUid, not facilityCreatorAccountId, so a
 * facility whose link to the account failed or is still being written gets it
 * too.
 */
export async function syncOwnerAccountStanding(
  ownerUid: string,
  deps: OwnerStandingSyncDeps,
): Promise<{ facilities: number; updated: number }> {
  const [accounts, facilities] = await Promise.all([
    deps.listOwnerAccounts(ownerUid),
    deps.listOwnerFacilities(ownerUid),
  ]);
  const preferred = preferredOwnerAccountDoc(accounts);
  const standing = preferred ? buildOwnerAccountStanding(preferred) : null;
  let updated = 0;
  for (const facility of facilities) {
    const stored = (facility.data() ?? {})[OWNER_ACCOUNT_STANDING_FIELD];
    if (sameOwnerAccountStanding(stored, standing)) continue;
    await deps.writeFacilityStanding(facility.id, standing);
    updated += 1;
  }
  return { facilities: facilities.length, updated };
}
