import test from 'node:test';
import assert from 'node:assert/strict';

import { tenantFieldsAfterMoveOut } from '../moveOutTenantFields';

const unit101 = { unitNumber: '101', status: 'occupied', tenantId: 't1', monthlyRate: 100 };

function after(overrides: Partial<Parameters<typeof tenantFieldsAfterMoveOut>[0]> = {}) {
  return tenantFieldsAfterMoveOut({
    tenantId: 't1',
    tenant: { unitNumber: '101', monthlyRate: 250 },
    unitId: 'u101',
    unit: unit101,
    stillRentsElsewhere: true,
    linkedUnits: [
      { id: 'u101', data: unit101 },
      { id: 'u102', data: { unitNumber: '102', status: 'occupied', tenantId: 't1', monthlyRate: 150 } },
    ],
    ...overrides,
  });
}

test("still renting elsewhere: the vacated unit's rate comes off and the unit number moves", () => {
  assert.deepEqual(after(), { monthlyRate: 150, unitNumber: '102' });
});

test('the last unit ends the tenancy and leaves the rate alone', () => {
  assert.deepEqual(after({ stillRentsElsewhere: false }), { unitNumber: '', isActive: false });
});

test('never below 0; a unit number naming another unit is left alone', () => {
  assert.deepEqual(after({ tenant: { unitNumber: '102', monthlyRate: 40 } }), { monthlyRate: 0 });
});

test('a stale link on an available or archived unit is not somewhere they rent', () => {
  const fields = after({
    linkedUnits: [
      { id: 'u9', data: { unitNumber: '9', status: 'available', tenantId: 't1' } },
      { id: 'u8', data: { unitNumber: '8', status: 'occupied', tenantId: 't1', archived: true } },
    ],
  });
  // No unit to move to: the number is kept rather than cleared, which would stop their rent.
  assert.deepEqual(fields, { monthlyRate: 150 });
});

test('a rate that is not a number counts as 0', () => {
  assert.deepEqual(after({ tenant: { unitNumber: '7', monthlyRate: '250' } }), { monthlyRate: 0 });
  assert.deepEqual(after({ unit: { ...unit101, monthlyRate: null } }).monthlyRate, 250);
});
