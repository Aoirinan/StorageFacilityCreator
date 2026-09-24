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
 * Whether [unit]'s type is one the owner rents online. The public map marks
 * other types not rentable, but a direct hold call used to accept them.
 */
export function isUnitTypeOfferedOnline(unit: UnitData, enabledTypes: string[]): boolean {
  return enabledTypes.length === 0 || enabledTypes.includes(String(unit.unitType || ''));
}
