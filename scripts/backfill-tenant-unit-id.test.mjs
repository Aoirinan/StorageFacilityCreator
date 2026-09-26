// node --test scripts/backfill-tenant-unit-id.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';

import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { defaultOutDir, parseArgs, planTenantUnitIdBackfill } from './backfill-tenant-unit-id.mjs';

const tenant = (id, data) => ({ id, data: { name: `Tenant ${id}`, isActive: true, ...data } });
const unit = (id, data) => ({ id, data: { status: 'occupied', ...data } });

test('one held unit with the label (trimmed, ignoring case): unitId and its area', () => {
  const plan = planTenantUnitIdBackfill({
    tenants: [tenant('t1', { unitNumber: ' 12a ' })],
    units: [
      unit('u12', { unitNumber: '12A', tenantId: 't1', area: ' Complex 2 ' }),
      unit('u7', { unitNumber: '7', tenantId: 't1' }),
    ],
  });
  assert.deepEqual(plan.updates, [
    {
      tenantId: 't1',
      name: 'Tenant t1',
      label: '12a',
      unitId: 'u12',
      unitArea: 'Complex 2',
      unitNumber: '12A',
      before: { unitId: null, unitArea: null },
    },
  ]);
  assert.equal(plan.counts.toUpdate, 1);
  assert.deepEqual(plan.skipped, []);
});

test('a unit with no area: unitArea null', () => {
  const plan = planTenantUnitIdBackfill({
    tenants: [tenant('t1', { unitNumber: '12' })],
    units: [unit('u12', { unitNumber: '12', tenantId: 't1', area: '  ' })],
  });
  assert.equal(plan.updates[0].unitArea, null);
});

test('a label matching no unit they hold is never touched, even if another tenant has that number', () => {
  const plan = planTenantUnitIdBackfill({
    tenants: [tenant('t1', { unitNumber: '12' })],
    units: [
      unit('u12', { unitNumber: '12', tenantId: 't2' }),
      unit('u14', { unitNumber: '14', tenantId: 't1' }),
      unit('u99', { unitNumber: '12' }),
    ],
  });
  assert.deepEqual(plan.updates, []);
  assert.equal(plan.skipped[0].reason, 'no-held-unit-matches');
  assert.deepEqual(plan.skipped[0].heldUnits.map((u) => u.unitId), ['u14']);
  assert.equal(plan.counts.noHeldUnitMatches, 1);
});

test('two held units with the number: ambiguous, skipped', () => {
  const plan = planTenantUnitIdBackfill({
    tenants: [tenant('t1', { unitNumber: '12' })],
    units: [
      unit('c2-12', { unitNumber: '12', tenantId: 't1', area: 'Complex 2' }),
      unit('c3-12', { unitNumber: ' 12', tenantId: 't1', area: 'Complex 3' }),
    ],
  });
  assert.deepEqual(plan.updates, []);
  assert.equal(plan.skipped[0].reason, 'ambiguous');
});

test('archived units do not count; a stale link on an available unit is skipped', () => {
  const archived = planTenantUnitIdBackfill({
    tenants: [tenant('t1', { unitNumber: '12' })],
    units: [
      unit('old', { unitNumber: '12', tenantId: 't1', archived: true }),
      unit('u12', { unitNumber: '12', tenantId: 't1' }),
    ],
  });
  assert.equal(archived.updates[0].unitId, 'u12');

  const stale = planTenantUnitIdBackfill({
    tenants: [tenant('t1', { unitNumber: '12' })],
    units: [unit('u12', { unitNumber: '12', tenantId: 't1', status: 'available' })],
  });
  assert.deepEqual(stale.updates, []);
  assert.equal(stale.skipped[0].reason, 'match-is-available');
});

test('inactive, unlabelled and already linked tenants are left out', () => {
  const plan = planTenantUnitIdBackfill({
    tenants: [
      tenant('t1', { unitNumber: '12', isActive: false }),
      tenant('t2', { unitNumber: '12', isActive: 'true' }),
      tenant('t3', { unitNumber: '  ' }),
      tenant('t4', { unitNumber: '14', unitId: 'u14' }),
    ],
    units: [
      unit('u12', { unitNumber: '12', tenantId: 't1' }),
      unit('u14', { unitNumber: '14', tenantId: 't4' }),
    ],
  });
  assert.deepEqual(plan.updates, []);
  assert.deepEqual(plan.skipped, []);
  assert.equal(plan.counts.inactive, 2);
  assert.equal(plan.counts.noLabel, 1);
  assert.equal(plan.counts.alreadyLinked, 1);
  assert.equal(plan.counts.tenants, 4);
});

test('a blank unitId counts as none', () => {
  const plan = planTenantUnitIdBackfill({
    tenants: [tenant('t1', { unitNumber: '12', unitId: ' ' })],
    units: [unit('u12', { unitNumber: '12', tenantId: 't1' })],
  });
  assert.equal(plan.updates[0].unitId, 'u12');
  assert.deepEqual(plan.updates[0].before, { unitId: ' ', unitArea: null });
});

test('parseArgs: dry run by default, a facility is required, --apply is explicit', () => {
  assert.deepEqual(parseArgs(['--facility', 'f1']), {
    apply: false,
    facilities: ['f1'],
    project: null,
    outDir: null,
    json: false,
  });
  assert.equal(parseArgs(['--apply', '--facility', 'f1', '--facility', 'f2']).apply, true);
  assert.deepEqual(parseArgs(['--facility', 'f1', '--facility', 'f2']).facilities, ['f1', 'f2']);
  assert.throws(() => parseArgs([]), /--facility/);
  assert.throws(() => parseArgs(['--apply']), /--facility/);
  assert.throws(() => parseArgs(['--facility']), /needs a value/);
  assert.throws(() => parseArgs(['--facility', 'f1', '--force']), /Unknown argument/);
});

test('records default to the repo root backfill-records/ (gitignored), whatever the working directory', () => {
  // They hold tenant names; relative to the working directory they could
  // land where the .gitignore entry doesn't reach.
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const before = process.cwd();
  try {
    process.chdir(os.tmpdir());
    assert.equal(path.resolve(defaultOutDir()), path.join(repoRoot, 'backfill-records'));
  } finally {
    process.chdir(before);
  }
  const ignore = readFileSync(path.join(repoRoot, '.gitignore'), 'utf8').split(/\r?\n/);
  assert.ok(ignore.includes('backfill-records/'));
});
