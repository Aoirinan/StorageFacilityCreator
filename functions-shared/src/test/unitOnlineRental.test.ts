import test from 'node:test';
import assert from 'node:assert/strict';

import { isUnitOfferedOnline } from '../units/onlineRental';

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
