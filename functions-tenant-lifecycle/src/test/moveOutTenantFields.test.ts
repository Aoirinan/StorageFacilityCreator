import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import { FieldValue } from 'firebase-admin/firestore';

import { UnitRent, primaryUnitFields, rentAfterUnitChange, tenantFieldsAfterMoveOut } from '../moveOutTenantFields';

const deleted = FieldValue.delete();

const unit101 = { unitNumber: '101', status: 'occupied', tenantId: 't1', monthlyRate: 100 };
const unit102 = { unitNumber: '102', status: 'occupied', tenantId: 't1', monthlyRate: 150 };

function after(overrides: Partial<Parameters<typeof tenantFieldsAfterMoveOut>[0]> = {}) {
  return tenantFieldsAfterMoveOut({
    tenantId: 't1',
    tenant: { name: 'Ada Park', unitNumber: '101', monthlyRate: 250 },
    unitId: 'u101',
    unit: unit101,
    linkedUnits: [
      { id: 'u101', data: unit101 },
      { id: 'u102', data: unit102 },
    ],
    ...overrides,
  });
}

test("still holding another unit: the vacated unit's rate comes off and the unit number moves", () => {
  assert.deepEqual(after(), {
    fields: { monthlyRate: 150, unitNumber: '102', unitId: 'u102', unitArea: deleted },
    rentNotice: 'Monthly rent is now $150.00 for unit 102.',
    rentWarning: null,
    endsTenancy: false,
  });
});

test('the last unit ends the tenancy and leaves the rate alone', () => {
  assert.deepEqual(after({ linkedUnits: [{ id: 'u101', data: unit101 }] }), {
    fields: { unitNumber: '', isActive: false, unitId: deleted, unitArea: deleted },
    rentNotice: null,
    rentWarning: null,
    endsTenancy: true,
  });
});

test('held units decide it, not contracts: a second unit with no contract keeps them active', () => {
  // The old test was another active contract; a unit given by Edit Tenant
  // or Units > Assign Tenant has none, so they were switched off in it.
  assert.equal(after().endsTenancy, false);
});

test('one rate for two units (from before the rule) is left alone, with a warning, never taken to 0', () => {
  // processMoveOut took 100 - 100 = 0 while they still held unit 102.
  const settled = after({ tenant: { name: 'Ada Park', unitNumber: '102', monthlyRate: 100 } });
  assert.deepEqual(settled.fields, {});
  assert.equal(settled.rentNotice, null);
  assert.equal(settled.rentWarning, "Check Ada Park's rent: they now hold unit 102; their rent is $100.00.");
});

test("a unit that isn't theirs, or already freed, takes nothing off", () => {
  // A unitId the tenant didn't hold came off their rate (250 to 170).
  for (const unit of [
    { ...unit101, tenantId: 't2' },
    { ...unit101, status: 'available', tenantId: null },
  ]) {
    const settled = after({ unit });
    assert.equal(settled.fields.monthlyRate, undefined);
    assert.equal(settled.rentNotice, null);
    assert.equal(settled.rentWarning, null);
  }
});

test('a stale link on an available or archived unit is not somewhere they rent', () => {
  const settled = after({
    linkedUnits: [
      { id: 'u101', data: unit101 },
      { id: 'u9', data: { unitNumber: '9', status: 'available', tenantId: 't1' } },
      { id: 'u8', data: { unitNumber: '8', status: 'occupied', tenantId: 't1', archived: true } },
    ],
  });
  assert.deepEqual(settled.fields, { unitNumber: '', isActive: false, unitId: deleted, unitArea: deleted });
});

test("the unit number's move takes unitId and unitArea to the unit they keep", () => {
  const settled = after({
    tenant: { name: 'Ada Park', unitNumber: '101', unitId: 'u101', unitArea: 'Complex 2', monthlyRate: 250 },
    linkedUnits: [
      { id: 'u101', data: { ...unit101, area: 'Complex 2' } },
      { id: 'u102', data: { ...unit102, area: '  Complex 3 ' } },
    ],
  });
  assert.equal(settled.fields.unitNumber, '102');
  assert.equal(settled.fields.unitId, 'u102');
  assert.equal(settled.fields.unitArea, 'Complex 3');
});

test('a unit number naming a unit they keep leaves unitId and unitArea alone', () => {
  const settled = after({ tenant: { name: 'Ada Park', unitNumber: '102', unitId: 'u102', monthlyRate: 250 } });
  assert.equal('unitNumber' in settled.fields, false);
  assert.equal('unitId' in settled.fields, false);
  assert.equal('unitArea' in settled.fields, false);
});

test('primaryUnitFields: the unit and its trimmed area, or deletes (TenantModel.primaryUnitUpdate)', () => {
  assert.deepEqual(primaryUnitFields('u12', { area: ' Complex 2 ' }), { unitId: 'u12', unitArea: 'Complex 2' });
  assert.deepEqual(primaryUnitFields('u12', { area: '   ' }), { unitId: 'u12', unitArea: deleted });
  assert.deepEqual(primaryUnitFields('u12', { area: 7 }), { unitId: 'u12', unitArea: deleted });
  assert.deepEqual(primaryUnitFields(null, { area: 'Complex 2' }), { unitId: deleted, unitArea: deleted });
  assert.deepEqual(primaryUnitFields('  '), { unitId: deleted, unitArea: deleted });
});

test('rounded to the cent', () => {
  const settled = after({
    tenant: { name: 'Ada Park', unitNumber: '102', monthlyRate: 250.3 },
    unit: { ...unit101, monthlyRate: 100.1 },
    linkedUnits: [
      { id: 'u101', data: { ...unit101, monthlyRate: 100.1 } },
      { id: 'u102', data: { ...unit102, monthlyRate: 150.2 } },
    ],
  });
  assert.equal(settled.fields.monthlyRate, 150.2);
});

test('a rate that is not a number counts as 0', () => {
  const settled = after({ tenant: { name: 'Ada Park', unitNumber: '7', monthlyRate: '250' } });
  assert.equal(settled.fields.monthlyRate, undefined);
  assert.match(settled.rentWarning ?? '', /their rent is \$0\.00\.$/);
});

type Fixture = {
  cases: Array<{
    name: string;
    current: number;
    heldBefore: Array<[string, number]>;
    released: Array<[string, number]>;
    added: [string, number] | null;
    monthlyRate: number | null;
    notice: string | null;
  }>;
};

const units = (rows: Array<[string, number]>): UnitRent[] => rows.map(([unitNumber, rate]) => ({ unitNumber, rate }));

test('rentAfterUnitChange matches the shared table (the app runs it too)', () => {
  const fixture = JSON.parse(
    readFileSync(join(__dirname, '..', '..', 'src', 'test', 'fixtures', 'rentAfterUnitChange.json'), 'utf8'),
  ) as Fixture;
  assert.ok(fixture.cases.length > 5);
  for (const c of fixture.cases) {
    const change = rentAfterUnitChange({
      tenantName: 'Ada Park',
      current: c.current,
      heldBefore: units(c.heldBefore),
      released: units(c.released),
      added: c.added ? units([c.added])[0] : null,
    });
    assert.equal(change.monthlyRate, c.monthlyRate, c.name);
    assert.equal(change.notice, c.notice, c.name);
    assert.equal(change.needsCheck, (c.notice ?? '').startsWith('Check '), c.name);
  }
});
