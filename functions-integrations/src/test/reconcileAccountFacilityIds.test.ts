import test from 'node:test';
import assert from 'node:assert/strict';
import {
  additionalFacilityAddonQuantity,
  facilityIdsInSync,
} from '../reconcileAccountFacilityIds';

test('facilityIdsInSync treats same set with different order as in sync', () => {
  assert.equal(facilityIdsInSync(['a', 'b'], ['b', 'a']), true);
});

test('facilityIdsInSync detects missing or extra facility ids', () => {
  assert.equal(facilityIdsInSync(['a', 'b'], ['a']), false);
  assert.equal(facilityIdsInSync(['a'], ['a', 'b']), false);
  assert.equal(facilityIdsInSync(['a', 'c'], ['a', 'b']), false);
});

test('additionalFacilityAddonQuantity matches Stripe addon billing model', () => {
  assert.equal(additionalFacilityAddonQuantity(0), 0);
  assert.equal(additionalFacilityAddonQuantity(1), 0);
  assert.equal(additionalFacilityAddonQuantity(3), 2);
});
