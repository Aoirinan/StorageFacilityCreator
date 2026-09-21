/**
 * Shapes a facility created by a super admin on behalf of an owner.
 *
 * The client cannot do this: the Firestore create rule requires a new
 * facility's `ownerUid` to be whoever is creating it, deliberately, so that
 * nobody can plant a facility under someone else's name. A super admin
 * setting up a customer is the one legitimate exception, and it goes through
 * the Admin SDK rather than by loosening that rule.
 *
 * Pure on purpose: this decides the document, the caller writes it.
 */

export interface FacilityForOwnerInput {
  /** The owner the facility belongs to, never the super admin creating it. */
  ownerUid: string;
  name: string;
  address?: string | null;
  phone?: string | null;
  email?: string | null;
  timeZone?: string | null;
  /** Physical capacity; occupancy maths reads this. */
  totalUnits?: number | null;
  /** Days after the due date before a late fee applies. */
  gracePeriodDays?: number | null;
  /** Flat late fee in dollars. */
  lateFeeAmount?: number | null;
}

export interface FacilityForOwnerDoc {
  name: string;
  ownerUid: string;
  totalUnits: number;
  occupiedUnits: number;
  active: true;
  roles: Record<string, string>;
  address?: string;
  phone?: string;
  email?: string;
  timeZone?: string;
  billingSettings?: { gracePeriodDays: number; lateFeeAmount: number; lateFeeType: 'flat' };
  /** Records that this facility was set up by support rather than the owner. */
  createdBySuperAdminUid: string;
}

export class FacilityForOwnerError extends Error {}

function cleanString(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

function cleanNumber(value: unknown, fallback: number): number {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

export const DEFAULT_GRACE_PERIOD_DAYS = 5;
export const DEFAULT_LATE_FEE_AMOUNT = 25;
export const DEFAULT_TIME_ZONE = 'America/Chicago';

/**
 * Builds the facility document. Throws when the two things that cannot be
 * guessed are missing, and fills sensible defaults for everything else so a
 * facility can be stood up from a name and an owner alone.
 */
export function buildFacilityForOwner(
  input: FacilityForOwnerInput,
  createdBySuperAdminUid: string,
): FacilityForOwnerDoc {
  const ownerUid = cleanString(input.ownerUid);
  if (!ownerUid) throw new FacilityForOwnerError('ownerUid is required.');

  const name = cleanString(input.name);
  if (!name) throw new FacilityForOwnerError('A facility name is required.');

  const creator = cleanString(createdBySuperAdminUid);
  if (!creator) throw new FacilityForOwnerError('createdBySuperAdminUid is required.');

  const doc: FacilityForOwnerDoc = {
    name,
    ownerUid,
    totalUnits: Math.floor(cleanNumber(input.totalUnits, 0)),
    occupiedUnits: 0,
    active: true,
    // The owner is the owner from the first write; support adds itself
    // separately and temporarily.
    roles: { [ownerUid]: 'owner' },
    billingSettings: {
      gracePeriodDays: Math.floor(cleanNumber(input.gracePeriodDays, DEFAULT_GRACE_PERIOD_DAYS)),
      lateFeeAmount: cleanNumber(input.lateFeeAmount, DEFAULT_LATE_FEE_AMOUNT),
      lateFeeType: 'flat',
    },
    timeZone: cleanString(input.timeZone) || DEFAULT_TIME_ZONE,
    createdBySuperAdminUid: creator,
  };

  const address = cleanString(input.address);
  if (address) doc.address = address;
  const phone = cleanString(input.phone);
  if (phone) doc.phone = phone;
  const email = cleanString(input.email);
  if (email) doc.email = email;

  return doc;
}

/** The owner's own staff-role row, matching what the app writes on self-serve creation. */
export function buildOwnerRoleRow(
  ownerUid: string,
  facilityId: string,
  assignedBy: string,
): Record<string, unknown> {
  return {
    userId: ownerUid,
    facilityId,
    roleType: 'owner',
    assignedBy,
    isActive: true,
  };
}
