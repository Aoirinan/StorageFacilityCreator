import test from 'node:test';
import assert from 'node:assert/strict';

import {
  activeTenantUnitClaims,
  enabledOnlineUnitTypes,
  facilityTakesOnlineRentals,
  hasTenantLink,
  isArchivedForOnlineRental,
  isInternalUseUnit,
  isUnitClaimedByActiveTenant,
  isUnitHeldByTenant,
  isUnitOfferedOnline,
  isUnitTypeOfferedOnline,
  isUnlistedUnit,
  readActiveTenantUnitClaims,
  unitNotOfferedOnlineReason,
  unitTypeOf,
} from '../units/onlineRental';
import * as shared from '../index';

test('a unit with none of the fields is offered online', () => {
  assert.equal(isUnitOfferedOnline({ status: 'available' }), true);
});

test('an explicitly listed, active, rentable unit is offered online', () => {
  assert.equal(
    isUnitOfferedOnline({ archived: false, internalUse: false, publicListingEnabled: true }),
    true,
  );
});

test('a unit not listed on the public website is not offered online', () => {
  assert.equal(isUnitOfferedOnline({ publicListingEnabled: false }), false);
});

test('an internal-use unit is not offered online, even when listed', () => {
  assert.equal(isUnitOfferedOnline({ internalUse: true, publicListingEnabled: true }), false);
});

test('an archived unit is not offered online', () => {
  assert.equal(isUnitOfferedOnline({ archived: true }), false);
});

test('archived follows the app: anything but false or missing is archived', () => {
  // UnitService.readFacilityUnits keeps a unit only when
  // `(archived ?? false) == false`, so a stray 'true' string is archived.
  assert.equal(isUnitOfferedOnline({ archived: 'true' }), false);
  assert.equal(isUnitOfferedOnline({ archived: null }), true);
});

test('internal use follows the app: only an exact true counts', () => {
  // UnitModel reads `data['internalUse'] == true`.
  assert.equal(isUnitOfferedOnline({ internalUse: 'true' }), true);
  assert.equal(isUnitOfferedOnline({ internalUse: null }), true);
});

test('listing follows the app: only an exact false unlists', () => {
  // UnitModel reads `publicListingEnabled as bool? ?? true`.
  assert.equal(isUnitOfferedOnline({ publicListingEnabled: null }), true);
});

test('the predicates the inventory sync reads agree with isUnitOfferedOnline', () => {
  // The sync filters with these one at a time; the callables use the
  // combination. A unit is offered exactly when none of them holds.
  const cases: Array<Record<string, unknown>> = [
    {},
    { archived: true },
    { archived: 'true' },
    { internalUse: true, publicListingEnabled: true },
    { publicListingEnabled: false },
    { internalUse: 'true', publicListingEnabled: null, archived: null },
  ];
  for (const unit of cases) {
    const excluded = isArchivedForOnlineRental(unit) || isInternalUseUnit(unit) || isUnlistedUnit(unit);
    assert.equal(isUnitOfferedOnline(unit), !excluded, JSON.stringify(unit));
  }
  assert.equal(isArchivedForOnlineRental({ archived: 'true' }), true);
  assert.equal(isInternalUseUnit({ internalUse: true, publicListingEnabled: true }), true);
  assert.equal(isUnlistedUnit({ publicListingEnabled: false }), true);
});

test('the reason a unit is not offered is the one the owner alert names', () => {
  assert.equal(unitNotOfferedOnlineReason({}), null);
  assert.equal(unitNotOfferedOnlineReason({ archived: true }), 'archived');
  assert.equal(unitNotOfferedOnlineReason({ internalUse: true, publicListingEnabled: true }), 'internal-use');
  assert.equal(unitNotOfferedOnlineReason({ publicListingEnabled: false }), 'unlisted');
});

test('a unit off online rental for several reasons is named by the one that hides it most', () => {
  // Archived hides the unit from the app altogether, so it comes first: the
  // owner cannot see an archived unit to check it. Internal use is next: it
  // takes the unit out of occupancy, which an unlisted unit still counts in.
  assert.equal(
    unitNotOfferedOnlineReason({ archived: true, internalUse: true, publicListingEnabled: false }),
    'archived',
  );
  assert.equal(unitNotOfferedOnlineReason({ archived: true, internalUse: true }), 'archived');
  assert.equal(unitNotOfferedOnlineReason({ internalUse: true, publicListingEnabled: false }), 'internal-use');
});

test('no enabled unit types means every type is offered online', () => {
  const settingsWithNoTypes: Array<Record<string, unknown> | null | undefined> = [
    undefined,
    null,
    {},
    { enabledPublicUnitTypes: [] },
    { enabledPublicUnitTypes: 'standard' },
  ];
  for (const settings of settingsWithNoTypes) {
    const types = enabledOnlineUnitTypes(settings);
    assert.deepEqual(types, [], JSON.stringify(settings));
    assert.equal(isUnitTypeOfferedOnline({ unitType: 'vehicle' }, types), true);
  }
});

test('with enabled unit types, only those types are offered online', () => {
  // Read as the app's publish and the sync read it: entries trimmed, blanks
  // dropped, the unit's own type matched exactly.
  const types = enabledOnlineUnitTypes({ enabledPublicUnitTypes: [' standard ', '', 'climateControlled'] });
  assert.deepEqual(types, ['standard', 'climateControlled']);
  assert.equal(isUnitTypeOfferedOnline({ unitType: 'standard' }, types), true);
  assert.equal(isUnitTypeOfferedOnline({ unitType: 'climateControlled' }, types), true);
  assert.equal(isUnitTypeOfferedOnline({ unitType: 'vehicle' }, types), false);
});

test("a unit's type is read as the app's UnitModel reads it", () => {
  // textFromField, else 'standard' (lib/models/unit_model.dart). This read
  // String(unitType || ''), so a unit with no type was refused by the holds
  // while the app's publish offered it as standard.
  assert.equal(unitTypeOf({}), 'standard');
  assert.equal(unitTypeOf({ unitType: null }), 'standard');
  assert.equal(unitTypeOf({ unitType: { name: 'vehicle' } }), 'standard');
  assert.equal(unitTypeOf({ unitType: ['vehicle'] }), 'standard');
  assert.equal(unitTypeOf({ unitType: 'vehicle' }), 'vehicle');
  // A string as stored, blank or padded included, as the app keeps it.
  assert.equal(unitTypeOf({ unitType: '' }), '');
  assert.equal(unitTypeOf({ unitType: ' standard ' }), ' standard ');
  // Numbers and booleans as their text, 0 and false included.
  assert.equal(unitTypeOf({ unitType: 5 }), '5');
  assert.equal(unitTypeOf({ unitType: 0 }), '0');
  assert.equal(unitTypeOf({ unitType: false }), 'false');

  const standardOnly = enabledOnlineUnitTypes({ enabledPublicUnitTypes: ['standard'] });
  assert.equal(isUnitTypeOfferedOnline({}, standardOnly), true);
  assert.equal(isUnitTypeOfferedOnline({ unitType: null }, standardOnly), true);
  assert.equal(isUnitTypeOfferedOnline({ unitType: { a: 1 } }, standardOnly), true);
  assert.equal(isUnitTypeOfferedOnline({ unitType: '' }, standardOnly), false);
  assert.equal(isUnitTypeOfferedOnline({ unitType: 0 }, standardOnly), false);
  assert.equal(isUnitTypeOfferedOnline({}, enabledOnlineUnitTypes({ enabledPublicUnitTypes: ['vehicle'] })), false);
});

test('a facility takes online rentals only when its switch is exactly true', () => {
  assert.equal(facilityTakesOnlineRentals({ publicRentalsEnabled: true }), true);
  // Off, never set up (no settings doc, or no field), or a stray non-boolean:
  // the hold refuses all of these, so no public page may offer a rental.
  const off: Array<Record<string, unknown> | null | undefined> = [
    { publicRentalsEnabled: false },
    {},
    null,
    undefined,
    { publicRentalsEnabled: 'true' },
    { publicRentalsEnabled: 1 },
    { publicRentalsEnabled: null },
  ];
  for (const settings of off) {
    assert.equal(facilityTakesOnlineRentals(settings), false, JSON.stringify(settings));
  }
});

test('the online rental rules are exported from the package root the callables import', () => {
  assert.equal(shared.facilityTakesOnlineRentals, facilityTakesOnlineRentals);
  assert.equal(shared.isUnitOfferedOnline, isUnitOfferedOnline);
  assert.equal(shared.isArchivedForOnlineRental, isArchivedForOnlineRental);
  assert.equal(shared.isInternalUseUnit, isInternalUseUnit);
  assert.equal(shared.isUnlistedUnit, isUnlistedUnit);
  assert.equal(shared.enabledOnlineUnitTypes, enabledOnlineUnitTypes);
  assert.equal(shared.isUnitTypeOfferedOnline, isUnitTypeOfferedOnline);
  assert.equal(shared.unitNotOfferedOnlineReason, unitNotOfferedOnlineReason);
  assert.equal(shared.unitTypeOf, unitTypeOf);
  assert.equal(shared.hasTenantLink, hasTenantLink);
  assert.equal(shared.activeTenantUnitClaims, activeTenantUnitClaims);
  assert.equal(shared.isUnitClaimedByActiveTenant, isUnitClaimedByActiveTenant);
  assert.equal(shared.isUnitHeldByTenant, isUnitHeldByTenant);
  assert.equal(shared.readActiveTenantUnitClaims, readActiveTenantUnitClaims);
});

/** Whether the unit [id] ([unit] is its doc) is claimed by one of [tenants]. */
function claimedBy(tenants: Array<Record<string, unknown>>, id: string, unit: Record<string, unknown>): boolean {
  return isUnitClaimedByActiveTenant(id, unit, activeTenantUnitClaims(tenants));
}

test('only a tenant whose isActive is exactly true claims a unit, by its number trimmed and lower-cased', () => {
  // As the public map's two writers read it: the app's TenantUnitClaims and
  // the inventory sync.
  const claims = activeTenantUnitClaims([
    { isActive: true, unitNumber: '  A1 ' },
    { isActive: true, unitNumber: 'Row-B2' },
    { isActive: true, unitNumber: '\tc3' },
    { isActive: true, unitNumber: '   ' },
    { isActive: true },
    { isActive: false, unitNumber: 'D4' },
    { isActive: 'true', unitNumber: 'E5' },
    { unitNumber: 'F6' },
    { isActive: false, unitNumber: 'G7', unitId: 'g7' },
  ]);
  assert.deepEqual([...claims.byNumber.keys()].sort(), ['a1', 'c3', 'row-b2']);
  assert.deepEqual([...claims.unitIds], []);
});

test("a unit is claimed when an id-less active tenant's number matches its own, whatever the case or spacing", () => {
  const tenants = [{ isActive: true, unitNumber: 'a1' }, { isActive: true, unitNumber: '102' }];
  assert.equal(claimedBy(tenants, 'u1', { unitNumber: 'A1' }), true);
  assert.equal(claimedBy(tenants, 'u1', { unitNumber: ' a1  ' }), true);
  // A number stored as a number is read as its text, as the app reads it.
  assert.equal(claimedBy(tenants, 'u1', { unitNumber: 102 }), true);
  assert.equal(claimedBy(tenants, 'u1', { unitNumber: 'A2' }), false);
  // No number is claimed by no one: a blank tenant number claims nothing.
  assert.equal(claimedBy(tenants, 'u1', {}), false);
  assert.equal(claimedBy([{ isActive: true, unitNumber: ' ' }], 'u1', { unitNumber: '' }), false);
});

test('a tenant with a unitId claims that unit only, not one with their number in another area', () => {
  // Numbers repeat across areas: "12" in Complex 2 and "12" in Complex 3.
  const tenants = [{ isActive: true, unitNumber: '12', unitId: ' c3-12 ', unitArea: 'Complex 3' }];
  // Before: claimed by number, so both 12s were off the market.
  assert.equal(claimedBy(tenants, 'c2-12', { unitNumber: '12', area: 'Complex 2' }), false);
  assert.equal(claimedBy(tenants, 'c3-12', { unitNumber: '12', area: 'Complex 3' }), true);
  // Their unitId decides even when their label has gone stale.
  assert.equal(claimedBy([{ isActive: true, unitNumber: 'OLD', unitId: 'x' }], 'x', { unitNumber: 'NEW' }), true);
  assert.equal(claimedBy([{ isActive: true, unitNumber: 'OLD', unitId: 'x' }], 'y', { unitNumber: 'OLD' }), false);
  // A blank unitId is no unitId: the number decides.
  assert.equal(
    claimedBy([{ isActive: true, unitNumber: '12', unitId: '  ' }], 'c2-12', { unitNumber: '12', area: 'Complex 2' }),
    true,
  );
  // Not while inactive.
  assert.equal(claimedBy([{ isActive: false, unitNumber: '12', unitId: 'c3-12' }], 'c3-12', { unitNumber: '12' }), false);
});

test('an id-less tenant claims their number in their unitArea when they have one, and in every area when not', () => {
  const inArea = [{ isActive: true, unitNumber: '14', unitArea: '  complex   2 ' }];
  assert.equal(claimedBy(inArea, 'a', { unitNumber: '14', area: 'Complex 2' }), true);
  assert.equal(claimedBy(inArea, 'b', { unitNumber: '14', area: 'Complex 3' }), false);
  assert.equal(claimedBy(inArea, 'c', { unitNumber: '14' }), false);
  // Nothing says which 14 an id-less tenant with no area is in: every 14.
  const noArea = [{ isActive: true, unitNumber: '14' }];
  assert.equal(claimedBy(noArea, 'a', { unitNumber: '14', area: 'Complex 2' }), true);
  assert.equal(claimedBy(noArea, 'b', { unitNumber: '14', area: 'Complex 3' }), true);
  assert.equal(claimedBy(noArea, 'c', { unitNumber: '14' }), true);
});

test("an id-less tenant still labelled with a unit's number from before a renumbering claims it", () => {
  // renumber-units-by-area.mjs keeps "C2-16" as legacyUnitNumber on what is now 16 in Complex 2.
  const unit = { unitNumber: '16', area: 'Complex 2', legacyUnitNumber: ' C2-16 ' };
  assert.equal(claimedBy([{ isActive: true, unitNumber: 'c2-16' }], 'u16', unit), true);
  assert.equal(claimedBy([{ isActive: true, unitNumber: 'c2-16', unitArea: 'Complex 3' }], 'u16', unit), false);
  assert.equal(claimedBy([{ isActive: true, unitNumber: 'c3-16' }], 'u16', unit), false);
  // Only text is a legacy number, as the app's UnitModel reads it.
  assert.equal(claimedBy([{ isActive: true, unitNumber: '5' }], 'u16', { ...unit, legacyUnitNumber: 5 }), false);
});

test('a unit is held by a tenant when linked to one or claimed; its status is not looked at', () => {
  const none = activeTenantUnitClaims([]);
  assert.equal(hasTenantLink({ tenantId: 't1' }), true);
  assert.equal(hasTenantLink({ tenantId: '  ' }), false);
  // Only text is a link, as the public map reads it.
  assert.equal(hasTenantLink({ tenantId: 5 }), false);
  assert.equal(hasTenantLink({}), false);
  assert.equal(isUnitHeldByTenant('u', { status: 'available', tenantId: 't1' }, none), true);
  assert.equal(
    isUnitHeldByTenant('u', { status: 'available', unitNumber: 'A1' }, activeTenantUnitClaims([{ isActive: true, unitNumber: 'a1' }])),
    true,
  );
  assert.equal(
    isUnitHeldByTenant('u', { status: 'available', unitNumber: 'A9' }, activeTenantUnitClaims([{ isActive: true, unitId: 'u' }])),
    true,
  );
  assert.equal(isUnitHeldByTenant('u', { status: 'occupied', unitNumber: 'A1' }, none), false);
});

test("the claims are read from the facility's active tenants, in the transaction when given one", async () => {
  const docs = [
    { data: () => ({ isActive: true, unitNumber: ' U7 ' }) },
    { data: () => ({ isActive: true, unitNumber: 'U8', unitId: 'u8' }) },
  ];
  const filters: unknown[][] = [];
  const query = { get: async () => ({ docs }) };
  const tenants = {
    where: (...args: unknown[]) => {
      filters.push(args);
      return query;
    },
  } as unknown as Parameters<typeof readActiveTenantUnitClaims>[0];
  const txReads: unknown[] = [];
  const tx = {
    get: async (q: unknown) => {
      txReads.push(q);
      return { docs };
    },
  } as unknown as Parameters<typeof readActiveTenantUnitClaims>[1];

  for (const claims of [await readActiveTenantUnitClaims(tenants), await readActiveTenantUnitClaims(tenants, tx)]) {
    assert.deepEqual([...claims.byNumber.keys()], ['u7']);
    assert.deepEqual([...claims.unitIds], ['u8']);
  }
  assert.deepEqual(filters, [['isActive', '==', true], ['isActive', '==', true]]);
  assert.deepEqual(txReads, [query]);
});
