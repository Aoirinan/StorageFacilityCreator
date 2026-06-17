import test from 'node:test';
import assert from 'node:assert/strict';
import { canReconcileStripePayment } from '../reconcileStripePayment';

test('canReconcileStripePayment allows facility owner', () => {
  assert.equal(canReconcileStripePayment('uid1', 'uid1', {}), true);
});

test('canReconcileStripePayment allows manager and owner roles', () => {
  assert.equal(canReconcileStripePayment('uid2', 'uid1', { uid2: 'manager' }), true);
  assert.equal(canReconcileStripePayment('uid3', 'uid1', { uid3: 'owner' }), true);
});

test('canReconcileStripePayment denies unrelated users', () => {
  assert.equal(canReconcileStripePayment('uid4', 'uid1', {}), false);
  assert.equal(canReconcileStripePayment('uid4', 'uid1', { uid4: 'staff' }), false);
});
