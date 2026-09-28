/**
 * Whether the owner offers a unit for online, self-service rental: the public
 * rental page, the tenant portal's "Rent another unit", and the online
 * move-in that completes either. The public map inventory sync
 * (functions-public-website) reads the same predicates, so the map and the
 * callables cannot disagree about a unit.
 *
 * The online rental callables checked only `status`, and every unit's id is
 * published in the world-readable publicFacilityMaps doc, unlisted ones
 * included (as 'unavailable'). Anyone could hold, pay for and move into a
 * unit the owner had not listed, or one kept as an office or residence.
 *
 * These are the app's own tests: archived as UnitService.readFacilityUnits
 * drops it, internal use as FacilityStatsService.countsTowardOccupancy, and
 * "List on public website" as UnitModel.publicListingEnabled (missing means
 * listed). None of them look at status; callers keep their status check.
 */

import type * as admin from 'firebase-admin';

type UnitData = Record<string, unknown>;

/** Archived: anything but a missing or false `archived`, as the app's unit read drops it. */
export function isArchivedForOnlineRental(unit: UnitData): boolean {
  return (unit.archived ?? false) !== false;
}

/** Office, residence or personal space the owner does not rent out (only an exact true). */
export function isInternalUseUnit(unit: UnitData): boolean {
  return unit.internalUse === true;
}

/** "List on public website" turned off (only an exact false; missing is listed). */
export function isUnlistedUnit(unit: UnitData): boolean {
  return unit.publicListingEnabled === false;
}

export type UnitNotOfferedReason = 'archived' | 'internal-use' | 'unlisted';

/** Why [unit] is not offered online, or null when it is. */
export function unitNotOfferedOnlineReason(unit: UnitData): UnitNotOfferedReason | null {
  if (isArchivedForOnlineRental(unit)) return 'archived';
  if (isInternalUseUnit(unit)) return 'internal-use';
  if (isUnlistedUnit(unit)) return 'unlisted';
  return null;
}

export function isUnitOfferedOnline(unit: UnitData): boolean {
  return unitNotOfferedOnlineReason(unit) === null;
}

/**
 * The unit types the owner opened to online rental, from the facility's
 * settings/public `enabledPublicUnitTypes`. Empty means every type, as the
 * app's publish and the inventory sync read it.
 */
export function enabledOnlineUnitTypes(publicSettings: UnitData | null | undefined): string[] {
  const raw = publicSettings?.enabledPublicUnitTypes;
  return Array.isArray(raw)
    ? raw.map((e) => String(e).trim()).filter((e) => e.length > 0)
    : [];
}

/**
 * [unit]'s type as the app's UnitModel reads it (textFromField, else
 * 'standard'): a string as stored, a number or boolean as its text, and
 * anything else, missing included, 'standard'. This read String(unitType ||
 * ''), so a unit with no type was '' here and 'standard' in the app: the
 * app's publish offered it and the hold refused it.
 */
export function unitTypeOf(unit: UnitData): string {
  const raw = unit.unitType;
  if (typeof raw === 'string') return raw;
  if (typeof raw === 'number' || typeof raw === 'boolean') return String(raw);
  return 'standard';
}

/**
 * Whether [unit]'s type is one the owner rents online. The public map marks
 * other types not rentable, but a direct hold call used to accept them.
 */
export function isUnitTypeOfferedOnline(unit: UnitData, enabledTypes: string[]): boolean {
  return enabledTypes.length === 0 || enabledTypes.includes(unitTypeOf(unit));
}

/**
 * Linked to a tenant: a `tenantId` that is text and not blank. Anything else,
 * a number included, is no link, as the public map reads it.
 */
export function hasTenantLink(unit: UnitData): boolean {
  return typeof unit.tenantId === 'string' && unit.tenantId.trim() !== '';
}

/**
 * The unit numbers active tenants claim, as both writers of the public map
 * read them: a tenant whose `isActive` is exactly true claims its
 * `unitNumber`, trimmed and lower-cased; a blank one claims nothing.
 *
 * A tenant can be added with a unit number and no link from the unit (the
 * owner typing it in, an import, a shared parking space). The map shows such
 * a unit as rented; the online rental callables looked only at the unit and
 * rented it again.
 */
export function unitNumbersClaimedByActiveTenants(tenants: Iterable<UnitData>): Set<string> {
  const claimed = new Set<string>();
  for (const tenant of tenants) {
    if (tenant.isActive !== true) continue;
    const n = String(tenant.unitNumber || '').trim().toLowerCase();
    if (n.length > 0) claimed.add(n);
  }
  return claimed;
}

/** Whether [unit]'s number is one of [claimed] (from unitNumbersClaimedByActiveTenants). */
export function isUnitClaimedByActiveTenant(unit: UnitData, claimed: ReadonlySet<string>): boolean {
  return claimed.has(String(unit.unitNumber ?? '').trim().toLowerCase());
}

/**
 * Whether a tenant has [unit]: it is linked to one, or an active tenant
 * claims its number. The public map shows either as rented. Status is not
 * looked at; callers keep their status check.
 */
export function isUnitHeldByTenant(unit: UnitData, claimed: ReadonlySet<string>): boolean {
  return hasTenantLink(unit) || isUnitClaimedByActiveTenant(unit, claimed);
}

/**
 * Reads the unit numbers the active tenants in [tenants] (a facility's
 * tenants collection) claim. Pass [tx] to read them in a transaction, so an
 * active tenant added meanwhile makes it retry. The caller's own collection,
 * so the caller's Firestore is the one read.
 */
export async function readUnitNumbersClaimedByActiveTenants(
  tenants: admin.firestore.CollectionReference,
  tx?: admin.firestore.Transaction,
): Promise<Set<string>> {
  const active = tenants.where('isActive', '==', true);
  const snap = tx ? await tx.get(active) : await active.get();
  return unitNumbersClaimedByActiveTenants(snap.docs.map((doc) => doc.data() as UnitData));
}
