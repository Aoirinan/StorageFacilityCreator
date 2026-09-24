/**
 * Whether the owner offers a unit for online, self-service rental: the public
 * rental page, the tenant portal's "Rent another unit", and the online
 * move-in that completes either.
 *
 * The online rental callables checked only `status`, and every unit's id is
 * published in the world-readable publicFacilityMaps doc, unlisted ones
 * included (as 'unavailable'). Anyone could hold, pay for and move into a
 * unit the owner had not listed, or one kept as an office or residence.
 *
 * These are the app's own tests: archived as UnitService.readFacilityUnits
 * drops it, internal use as FacilityStatsService.countsTowardOccupancy, and
 * "List on public website" as UnitModel.publicListingEnabled (missing means
 * listed). This does not look at status; callers keep their status check.
 */
export function isUnitOfferedOnline(unit: Record<string, unknown>): boolean {
  return (
    (unit.archived ?? false) === false &&
    unit.internalUse !== true &&
    unit.publicListingEnabled !== false
  );
}
