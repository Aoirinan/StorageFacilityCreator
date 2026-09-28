import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  formatUnitLabel,
  tenantUnitLabel,
  unitLabelsIncludeArea,
  UnitLabelStyle,
} from '../units/unitLabel';

/**
 * The same table test/unit_label_test.dart runs against the app's
 * formatUnitLabel. Read from src/ (tsc does not copy JSON).
 */
type ParityCase = {
  number: unknown;
  area?: unknown;
  includeArea: boolean;
  style: UnitLabelStyle;
  expected: string;
};
const parity = JSON.parse(
  readFileSync(join(__dirname, '..', '..', 'src', 'test', 'fixtures', 'unitLabelParity.json'), 'utf8'),
) as { cases: ParityCase[] };

test('formatUnitLabel matches the shared table', () => {
  assert.ok(parity.cases.length > 10);
  for (const c of parity.cases) {
    const options = 'area' in c
      ? { number: c.number, area: c.area, includeArea: c.includeArea, style: c.style }
      : { number: c.number, includeArea: c.includeArea, style: c.style };
    assert.equal(formatUnitLabel(options), c.expected, JSON.stringify(c));
  }
});

test('never "()" or a double space', () => {
  for (const c of parity.cases) {
    const label = formatUnitLabel({ number: c.number, area: c.area, includeArea: true, style: c.style });
    assert.ok(!label.includes('()'), label);
    assert.ok(!label.includes('  '), label);
    assert.equal(label, label.trim());
  }
});

test('style defaults to plain', () => {
  assert.equal(formatUnitLabel({ number: '12', area: 'Complex 2', includeArea: true }), '12 (Complex 2)');
});

test('the facility setting is on only when exactly true', () => {
  assert.equal(unitLabelsIncludeArea(undefined), false);
  assert.equal(unitLabelsIncludeArea(null), false);
  assert.equal(unitLabelsIncludeArea({}), false);
  assert.equal(unitLabelsIncludeArea({ unitNumbersRepeatAcrossAreas: 'true' }), false);
  assert.equal(unitLabelsIncludeArea({ unitNumbersRepeatAcrossAreas: 1 }), false);
  assert.equal(unitLabelsIncludeArea({ unitNumbersRepeatAcrossAreas: false }), false);
  assert.equal(unitLabelsIncludeArea({ unitNumbersRepeatAcrossAreas: true }), true);
});

test('tenantUnitLabel: setting off returns the stored number untouched', () => {
  const off = { unitNumbersRepeatAcrossAreas: false };
  assert.equal(tenantUnitLabel({ unitNumber: '12', unitArea: 'Complex 2' }, off), '12');
  assert.equal(tenantUnitLabel({ unitNumber: ' 12 ', unitArea: 'Complex 2' }, {}), ' 12 ');
  assert.equal(tenantUnitLabel({ unitNumber: 12 }, {}), '12');
  assert.equal(tenantUnitLabel({}, {}), '');
  assert.equal(tenantUnitLabel(null, null), '');
});

test('tenantUnitLabel: setting on adds the tenant unitArea', () => {
  const on = { unitNumbersRepeatAcrossAreas: true };
  assert.equal(tenantUnitLabel({ unitNumber: '12', unitArea: 'Complex 2' }, on), '12 (Complex 2)');
  assert.equal(tenantUnitLabel({ unitNumber: '12' }, on), '12');
  assert.equal(tenantUnitLabel({ unitNumber: '12', unitArea: null }, on), '12');
  assert.equal(tenantUnitLabel({ unitNumber: '', unitArea: 'Complex 2' }, on), '');
});
