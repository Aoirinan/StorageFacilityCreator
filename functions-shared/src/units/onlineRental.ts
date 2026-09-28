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

/** A doc's text field trimmed, or null when it is not a string or is blank (TenantModel.textField). */
function textOf(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

/** A tenant's unit number as lookups compare it: trimmed, ignoring case (unitNumberKey in the app). */
function tenantNumberKey(tenant: UnitData): string {
  return String(tenant.unitNumber || '').trim().toLowerCase();
}

/** A unit's number the same way; a number stored as a number is its text, as the app reads it. */
function unitNumberKeyOf(unit: UnitData): string {
  return String(unit.unitNumber ?? '').trim().toLowerCase();
}

/**
 * An area as areas compare: trimmed, each run of whitespace one space,
 * ignoring case (unitAreaKey in lib/utils/unit_areas.dart); null for none.
 */
function areaKeyOf(raw: unknown): string | null {
  const area = textOf(raw);
  return area === null ? null : area.replace(/\s+/g, ' ').toLowerCase();
}

/**
 * The units a facility's active tenants have by their own records, as the
 * public map's two writers and the online rental callables read them. Build
 * with activeTenantUnitClaims; ask with isUnitClaimedByActiveTenant.
 *
 * PARITY: TenantUnitClaims in lib/utils/tenant_unit_claims.dart. Both run
 * test/fixtures/public_map_units.json.
 */
export interface ActiveTenantUnitClaims {
  /** Units named by an active tenant's `unitId`. */
  readonly unitIds: ReadonlySet<string>;
  /**
   * For active tenants with no `unitId`: their unit number key, and the area
   * keys it is claimed in. A null area key is a tenant with no `unitArea`,
   * who claims the number in every area.
   */
  readonly byNumber: ReadonlyMap<string, ReadonlySet<string | null>>;
}

/**
 * What [tenants] (a facility's tenant docs) claim. Only a tenant whose
 * `isActive` is exactly true claims anything.
 *
 * A tenant can be added with a unit number and no link from the unit (the
 * owner typing it in, an import, a shared parking space). The map shows such
 * a unit as rented; the online rental callables looked only at the unit and
 * rented it again.
 *
 * By `unitId` when the tenant has one: that is the unit their label names.
 * Matching their number instead, where numbers repeat across areas
 * (unitNumbersRepeatAcrossAreas), took "12" in Complex 2 off the market for a
 * tenant in "12" in Complex 3. A tenant with no `unitId` claims by number
 * (trimmed, ignoring case), in their `unitArea` when they have one and in
 * every area when not, since nothing then says which "12" they are in.
 */
export function activeTenantUnitClaims(tenants: Iterable<UnitData>): ActiveTenantUnitClaims {
  const unitIds = new Set<string>();
  const byNumber = new Map<string, Set<string | null>>();
  for (const tenant of tenants) {
    if (tenant.isActive !== true) continue;
    const unitId = textOf(tenant.unitId);
    if (unitId !== null) {
      unitIds.add(unitId);
      continue;
    }
    const n = tenantNumberKey(tenant);
    if (n.length === 0) continue;
    let areas = byNumber.get(n);
    if (!areas) byNumber.set(n, (areas = new Set()));
    areas.add(areaKeyOf(tenant.unitArea));
  }
  return { unitIds, byNumber };
}

/**
 * Whether an active tenant claims the unit [unitId] ([unit] is its doc):
 * its id is a tenant's `unitId`, or its number, or the number it had before
 * a renumbering (`legacyUnitNumber`, "C2-12" for "12" in Complex 2), is an
 * id-less tenant's number in the unit's area or in any area.
 */
export function isUnitClaimedByActiveTenant(
  unitId: string,
  unit: UnitData,
  claims: ActiveTenantUnitClaims,
): boolean {
  if (claims.unitIds.has(unitId.trim())) return true;
  const area = areaKeyOf(unit.area);
  const legacy = textOf(unit.legacyUnitNumber)?.toLowerCase() ?? '';
  for (const n of [unitNumberKeyOf(unit), legacy]) {
    if (n.length === 0) continue;
    const areas = claims.byNumber.get(n);
    if (areas && (areas.has(null) || (area !== null && areas.has(area)))) return true;
  }
  return false;
}

/**
 * Whether a tenant has the unit [unitId] ([unit] is its doc): it is linked to
 * one, or an active tenant claims it (isUnitClaimedByActiveTenant). The public
 * map shows either as rented. Status is not looked at; callers keep their
 * status check.
 */
export function isUnitHeldByTenant(unitId: string, unit: UnitData, claims: ActiveTenantUnitClaims): boolean {
  return hasTenantLink(unit) || isUnitClaimedByActiveTenant(unitId, unit, claims);
}

/**
 * Reads what the active tenants in [tenants] (a facility's tenants
 * collection) claim. Pass [tx] to read them in a transaction, so an active
 * tenant added meanwhile makes it retry. The caller's own collection, so the
 * caller's Firestore is the one read.
 */
export async function readActiveTenantUnitClaims(
  tenants: admin.firestore.CollectionReference,
  tx?: admin.firestore.Transaction,
): Promise<ActiveTenantUnitClaims> {
  const active = tenants.where('isActive', '==', true);
  const snap = tx ? await tx.get(active) : await active.get();
  return activeTenantUnitClaims(snap.docs.map((doc) => doc.data() as UnitData));
}
