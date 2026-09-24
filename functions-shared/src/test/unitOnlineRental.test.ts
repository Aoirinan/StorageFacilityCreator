import test from 'node:test';
import assert from 'node:assert/strict';

import {
  enabledOnlineUnitTypes,
  isArchivedForOnlineRental,
  isInternalUseUnit,
  isUnitOfferedOnline,
  isUnitTypeOfferedOnline,
  isUnlistedUnit,
  unitNotOfferedOnlineReason,
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
  assert.equal(isUnitTypeOfferedOnline({}, types), false);
});

test('the online rental rules are exported from the package root the callables import', () => {
  assert.equal(shared.isUnitOfferedOnline, isUnitOfferedOnline);
  assert.equal(shared.isArchivedForOnlineRental, isArchivedForOnlineRental);
  assert.equal(shared.isInternalUseUnit, isInternalUseUnit);
  assert.equal(shared.isUnlistedUnit, isUnlistedUnit);
  assert.equal(shared.enabledOnlineUnitTypes, enabledOnlineUnitTypes);
  assert.equal(shared.isUnitTypeOfferedOnline, isUnitTypeOfferedOnline);
  assert.equal(shared.unitNotOfferedOnlineReason, unitNotOfferedOnlineReason);
});
