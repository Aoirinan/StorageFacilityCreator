import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildRentChargeDescription,
  hasRentChargeForMonth,
  shouldChargeTenant,
} from '../rentChargeHelpers';

/** Mimics a Firestore Timestamp well enough for the duplicate check. */
const ts = (date: Date) => ({ toDate: () => date });

// --- who gets charged -------------------------------------------------------

test('shouldChargeTenant requires an assigned unit and a positive rate', () => {
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: 120 }), true);
});

test('shouldChargeTenant skips tenants with no real unit', () => {
  assert.equal(shouldChargeTenant({ unitNumber: '', monthlyRate: 120 }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '   ', monthlyRate: 120 }), false);
  assert.equal(shouldChargeTenant({ monthlyRate: 120 }), false);
});

test('shouldChargeTenant skips non-billable rates rather than inventing revenue', () => {
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: 0 }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: -50 }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '101' }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: '120' }), false);
  assert.equal(shouldChargeTenant({ unitNumber: '101', monthlyRate: NaN }), false);
});

test('shouldChargeTenant handles missing tenant data', () => {
  assert.equal(shouldChargeTenant(undefined), false);
  assert.equal(shouldChargeTenant(null), false);
});

// --- duplicate protection ---------------------------------------------------

const recurring = (date: Date, month: number, year: number) => ({
  entryDate: ts(date),
  metadata: { recurringCharge: true, chargeType: 'monthlyRent', month, year },
});

test('hasRentChargeForMonth detects this month\'s recurring charge', () => {
  const entries = [recurring(new Date(2026, 2, 1), 3, 2026)];
  assert.equal(hasRentChargeForMonth(entries, 3, 2026), true);
});

test('hasRentChargeForMonth ignores other months and years', () => {
  const entries = [
    recurring(new Date(2026, 1, 1), 2, 2026),
    recurring(new Date(2025, 2, 1), 3, 2025),
  ];
  assert.equal(hasRentChargeForMonth(entries, 3, 2026), false);
});

test('hasRentChargeForMonth does not mistake a manual charge for the recurring one', () => {
  // A one-off adjustment dated in the same month must not suppress rent, or the
  // tenant silently goes un-billed for the month.
  const entries = [
    {
      entryDate: ts(new Date(2026, 2, 10)),
      metadata: { chargeType: 'lateFee' },
    },
    {
      entryDate: ts(new Date(2026, 2, 12)),
      metadata: {},
    },
  ];
  assert.equal(hasRentChargeForMonth(entries, 3, 2026), false);
});

test('hasRentChargeForMonth tolerates entries with no date', () => {
  assert.equal(hasRentChargeForMonth([{ metadata: {} }, {}], 3, 2026), false);
  assert.equal(hasRentChargeForMonth([], 3, 2026), false);
});

// --- description ------------------------------------------------------------

test('buildRentChargeDescription names the month and year', () => {
  assert.equal(buildRentChargeDescription(new Date(2026, 2, 1)), 'Monthly Rent - March 2026');
  assert.equal(buildRentChargeDescription(new Date(2026, 11, 1)), 'Monthly Rent - December 2026');
  assert.equal(buildRentChargeDescription(new Date(2027, 0, 1)), 'Monthly Rent - January 2027');
});
