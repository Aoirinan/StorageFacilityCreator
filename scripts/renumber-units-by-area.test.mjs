// node --test scripts/renumber-units-by-area.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';

import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  applyItemRefusal,
  defaultOutDir,
  isNearRentRun,
  parseArgs,
  parsePrefixMap,
  planItemRevert,
  planRenumber,
  repeatedNumbers,
  revertDocAction,
  runApplySteps,
  runRevertSteps,
  verifyAfterApply,
} from './renumber-units-by-area.mjs';

const MAP = parsePrefixMap('C2-=Complex 2,C3-=Complex 3');
const NOW = new Date('2026-09-15T12:00:00Z');
const unit = (id, data) => ({ id, data: { status: 'occupied', ...data } });
const tenant = (id, data) => ({ id, data: { isActive: true, ...data } });
const plan = (input) => planRenumber({ facilityId: 'f1', facility: {}, prefixMap: MAP, now: NOW, ...input });
const codes = (p) => p.aborts.map((a) => a.code);

test('strips the prefix, relabels the holding tenant, sets the facility flag', () => {
  const p = plan({
    units: [
      unit('u1', { unitNumber: 'C2-12', area: 'Complex 2', tenantId: 't1' }),
      unit('u2', { unitNumber: 'c3-12', area: ' complex 3 ', status: 'available' }),
      unit('u3', { unitNumber: 'Office' }),
    ],
    tenants: [tenant('t1', { unitNumber: 'c2-12 ', unitId: 'u1', unitArea: 'Complex 2' })],
  });
  assert.equal(p.ok, true, JSON.stringify(p.aborts));
  assert.deepEqual(
    p.units.map((u) => [u.unitId, u.before.unitNumber, u.after.unitNumber, u.after.legacyUnitNumber]),
    [
      ['u1', 'C2-12', '12', 'C2-12'],
      ['u2', 'c3-12', '12', 'c3-12'],
    ],
  );
  assert.deepEqual(p.units[0].beforeMissing, ['legacyUnitNumber']);
  assert.deepEqual(p.units[0].tenants, [
    {
      tenantId: 't1',
      expect: { unitId: 'u1', unitAreaKey: 'complex 2' },
      before: { unitNumber: 'c2-12 ', legacyUnitNumber: null },
      beforeMissing: ['legacyUnitNumber'],
      after: { unitNumber: '12', legacyUnitNumber: 'c2-12 ' },
    },
  ]);
  assert.deepEqual(p.facilityChange, {
    before: { unitNumbersRepeatAcrossAreas: null },
    beforeMissing: ['unitNumbersRepeatAcrossAreas'],
    after: { unitNumbersRepeatAcrossAreas: true },
  });
  assert.equal(p.counts.unitsToRenumber, 2);
  assert.equal(p.counts.tenantsToRelabel, 1);
});

test('collision: two units in one area end up with the same number (ignoring case and spaces)', () => {
  const p = plan({
    units: [
      unit('u1', { unitNumber: 'C2-12A', area: 'Complex 2' }),
      unit('u2', { unitNumber: '12 a', area: 'complex  2' }),
    ],
  });
  assert.equal(p.ok, false);
  assert.deepEqual(codes(p), ['collision']);
  assert.deepEqual(p.aborts[0].unitIds.sort(), ['u1', 'u2']);
});

test('collision: a new number equal to a unit with no area', () => {
  const p = plan({
    units: [unit('u1', { unitNumber: 'C2-12', area: 'Complex 2' }), unit('u9', { unitNumber: ' 12 ' })],
  });
  assert.deepEqual(codes(p), ['collision-with-no-area-unit']);
});

test('no collision for the same number in different areas', () => {
  const p = plan({
    units: [
      unit('u1', { unitNumber: 'C2-12', area: 'Complex 2' }),
      unit('u2', { unitNumber: 'C3-12', area: 'Complex 3' }),
      unit('u3', { unitNumber: '12', area: 'Outdoor' }),
    ],
  });
  assert.equal(p.ok, true, JSON.stringify(p.aborts));
});

test('an archived unit neither collides nor is renumbered, but is reported', () => {
  const p = plan({
    units: [
      unit('u1', { unitNumber: 'C2-12', area: 'Complex 2' }),
      unit('old', { unitNumber: '12', area: 'Complex 2', archived: true }),
      unit('old2', { unitNumber: 'C2-5', area: 'Complex 2', archived: true }),
    ],
  });
  assert.equal(p.ok, true);
  assert.deepEqual(p.units.map((u) => u.unitId), ['u1']);
  assert.deepEqual(p.warnings.map((w) => w.code).sort(), ['archived-collision', 'archived-unit-prefixed', 'prefix-unused']);
});

test('prefix/area mismatch aborts; so does a prefixed unit with no area', () => {
  const p = plan({
    units: [unit('u1', { unitNumber: 'C2-12', area: 'Complex 3' }), unit('u2', { unitNumber: 'C3-4' })],
  });
  assert.deepEqual(codes(p), ['unit-area-mismatch', 'unit-area-missing']);
  assert.deepEqual(p.units, []);
});

test('empty stripped number aborts', () => {
  const p = plan({ units: [unit('u1', { unitNumber: ' C2- ', area: 'Complex 2' })] });
  assert.deepEqual(codes(p), ['empty-stripped-number']);
});

test('a stripped number that still has a mapped prefix aborts', () => {
  const p = plan({ units: [unit('u1', { unitNumber: 'C2-C3-1', area: 'Complex 2' })] });
  assert.deepEqual(codes(p), ['stripped-still-prefixed']);
});

test('idempotent re-run: migrated units are skipped and nothing is planned', () => {
  const units = [
    unit('u1', { unitNumber: '12', legacyUnitNumber: 'C2-12', area: 'Complex 2', tenantId: 't1' }),
    unit('u2', { unitNumber: '12', legacyUnitNumber: 'C3-12', area: 'Complex 3' }),
  ];
  const tenants = [tenant('t1', { unitNumber: '12', legacyUnitNumber: 'C2-12', unitId: 'u1', unitArea: 'Complex 2' })];
  const p = plan({ units, tenants, facility: { unitNumbersRepeatAcrossAreas: true } });
  assert.equal(p.ok, true, JSON.stringify(p.aborts));
  assert.deepEqual(p.units, []);
  assert.equal(p.facilityChange, null);
  assert.equal(p.counts.alreadyMigrated, 2);
  assert.equal(p.counts.tenantsToRelabel, 0);
});

test('a half-applied run picks up where it stopped', () => {
  const p = plan({
    units: [
      unit('u1', { unitNumber: '12', legacyUnitNumber: 'C2-12', area: 'Complex 2' }),
      unit('u2', { unitNumber: 'C3-12', area: 'Complex 3' }),
    ],
    facility: { unitNumbersRepeatAcrossAreas: false },
  });
  assert.equal(p.ok, true);
  assert.deepEqual(p.units.map((u) => u.unitId), ['u2']);
  assert.deepEqual(p.facilityChange.before, { unitNumbersRepeatAcrossAreas: false });
  assert.deepEqual(p.facilityChange.beforeMissing, []);
});

test('tenant consistency: unitId unit not held, missing unitId, area mismatch', () => {
  const units = [
    unit('u1', { unitNumber: 'C2-1', area: 'Complex 2', tenantId: 'someone-else' }),
    unit('u2', { unitNumber: 'C2-2', area: 'Complex 2', tenantId: 't2' }),
    unit('u3', { unitNumber: 'C2-3', area: 'Complex 2', tenantId: 't3' }),
  ];
  const tenants = [
    tenant('t1', { unitNumber: 'C2-1', unitId: 'u1', unitArea: 'Complex 2' }),
    tenant('t2', { unitNumber: 'C2-2' }),
    tenant('t3', { unitNumber: 'C2-3', unitId: 'u3', unitArea: 'Complex 3' }),
    tenant('gone', { unitNumber: 'C2-1', isActive: false }),
  ];
  const p = plan({ units, tenants });
  assert.deepEqual(codes(p), ['tenant-unit-not-held', 'tenant-missing-unit-id', 'tenant-unit-area-mismatch']);
  assert.equal(p.counts.inactiveTenantsWithOldLabel, 1);
});

test('a tenant holding a second renumbered unit keeps its label', () => {
  const p = plan({
    units: [
      unit('u1', { unitNumber: 'C2-1', area: 'Complex 2', tenantId: 't1' }),
      unit('u2', { unitNumber: 'C2-2', area: 'Complex 2', tenantId: 't1' }),
    ],
    tenants: [tenant('t1', { unitNumber: 'C2-1', unitId: 'u1', unitArea: 'Complex 2' })],
  });
  assert.equal(p.ok, true);
  assert.equal(p.units.find((u) => u.unitId === 'u2').tenants.length, 0);
  assert.equal(p.counts.secondaryUnitsRenumbered, 1);
});

test('active holds and open reservations abort; expired ones warn', () => {
  const later = new Date(NOW.getTime() + 60_000);
  const earlier = new Date(NOW.getTime() - 60_000);
  const p = plan({
    units: [
      unit('u1', { unitNumber: 'C2-1', area: 'Complex 2', status: 'available' }),
      unit('u2', { unitNumber: 'C2-2', area: 'Complex 2', status: 'available' }),
      unit('u3', { unitNumber: 'C2-3', area: 'Complex 2', status: 'available' }),
    ],
    holds: [
      { id: 'u1', data: { unitId: 'u1', expiresAt: later } },
      { id: 'u2', data: { unitId: 'u2', expiresAt: earlier } },
    ],
    publicReservations: [
      { id: 'r1', data: { facilityId: 'f1', unitNumber: 'c2-3', status: 'pending', expiresAt: later } },
      { id: 'r2', data: { facilityId: 'f1', unitId: 'u2', status: 'completed' } },
      { id: 'r3', data: { facilityId: 'f1', unitId: 'u2', status: 'pending', expiresAt: earlier } },
    ],
    facilityReservations: [{ id: 'fr1', data: { unitId: 'u2', status: 'confirmed' } }],
  });
  assert.deepEqual(codes(p), ['active-hold', 'open-public-reservation', 'open-facility-reservation']);
  const w = p.warnings.map((x) => x.code);
  assert.ok(w.includes('expired-hold'));
  assert.ok(w.includes('expired-public-reservation'));
});

test('near the monthly rent run aborts unless overridden; missing facility aborts', () => {
  assert.equal(isNearRentRun(new Date('2026-10-01T05:59:00Z')), true);
  assert.equal(isNearRentRun(new Date('2026-09-30T18:01:00Z')), true);
  assert.equal(isNearRentRun(new Date('2026-09-30T17:59:00Z')), false);
  assert.equal(isNearRentRun(new Date('2026-10-01T06:01:00Z')), false);
  const near = new Date('2026-10-01T01:00:00Z');
  const units = [unit('u1', { unitNumber: 'C2-1', area: 'Complex 2' })];
  assert.deepEqual(codes(plan({ units, now: near })), ['near-rent-run']);
  const overridden = plan({ units, now: near, allowNearRentRun: true });
  assert.equal(overridden.ok, true);
  assert.ok(overridden.warnings.some((w) => w.code === 'near-rent-run-overridden'));
  assert.deepEqual(codes(plan({ units, facility: null })), ['facility-missing']);
});

test('online rentals on is a warning', () => {
  const p = plan({ units: [], publicSettings: { publicRentalsEnabled: true } });
  assert.ok(p.warnings.some((w) => w.code === 'online-rentals-on'));
});

test('apply re-check refuses an item changed since planning', () => {
  const p = plan({
    units: [unit('u1', { unitNumber: 'C2-1', area: 'Complex 2', tenantId: 't1' })],
    tenants: [tenant('t1', { unitNumber: 'C2-1', unitId: 'u1', unitArea: 'Complex 2' })],
  });
  const item = p.units[0];
  const u = { unitNumber: 'C2-1', area: 'Complex 2', tenantId: 't1' };
  const t = { t1: { unitNumber: 'C2-1', unitId: 'u1', unitArea: 'Complex 2', isActive: true } };
  assert.equal(applyItemRefusal(item, u, t, null, NOW), null);
  assert.match(applyItemRefusal(item, { ...u, unitNumber: 'C2-9' }, t, null, NOW), /number changed/);
  assert.match(applyItemRefusal(item, { ...u, tenantId: null }, t, null, NOW), /tenant changed/);
  assert.match(applyItemRefusal(item, u, { t1: { ...t.t1, unitNumber: 'X' } }, null, NOW), /label changed/);
  assert.match(applyItemRefusal(item, u, t, { expiresAt: new Date(NOW.getTime() + 1000) }, NOW), /hold/);
  assert.equal(applyItemRefusal(item, u, t, { expiresAt: new Date(NOW.getTime() - 1000) }, NOW), null);
});

test('revert maps after back to before, deleting fields that were missing', () => {
  const p = plan({
    units: [unit('u1', { unitNumber: 'C2-1', area: 'Complex 2', tenantId: 't1' })],
    tenants: [tenant('t1', { unitNumber: 'C2-1', unitId: 'u1', unitArea: 'Complex 2' })],
  });
  const item = p.units[0];
  const t1After = { unitNumber: '1', legacyUnitNumber: 'C2-1', unitId: 'u1', unitArea: 'Complex 2', isActive: true };
  const applied = {
    unit: { unitNumber: '1', legacyUnitNumber: 'C2-1', area: 'Complex 2', tenantId: 't1' },
    tenants: { t1: t1After },
    holders: [{ id: 't1', data: t1After }],
  };
  const r = planItemRevert(item, applied);
  assert.equal(r.refused, false);
  assert.deepEqual(
    r.docs.map((d) => [d.kind, d.id, d.action, d.set, d.remove]),
    [
      ['unit', 'u1', 'restore', { unitNumber: 'C2-1' }, ['legacyUnitNumber']],
      ['tenant', 't1', 'restore', { unitNumber: 'C2-1' }, ['legacyUnitNumber']],
    ],
  );

  // Never applied (or already reverted): nothing to do.
  const untouched = {
    unit: { unitNumber: 'C2-1', area: 'Complex 2', tenantId: 't1' },
    tenants: { t1: { unitNumber: 'C2-1', unitId: 'u1', isActive: true } },
  };
  assert.deepEqual(planItemRevert(item, untouched).docs.map((d) => d.action), ['already-before', 'already-before']);

  // Edited since the run, tenant still attached: the whole item is refused.
  const edited = { ...applied, tenants: { t1: { ...t1After, unitNumber: '1B' } } };
  const refused = planItemRevert(item, edited);
  assert.equal(refused.refused, true);
  assert.deepEqual(refused.refusedDocs, ['tenant t1']);

  // The unit itself edited since: refused.
  assert.deepEqual(planItemRevert(item, { ...applied, unit: { ...applied.unit, unitNumber: '1X' } }).refusedDocs, ['unit u1']);

  // Facility flag: a recorded false comes back as false, a missing flag is deleted.
  assert.deepEqual(
    revertDocAction({ before: { unitNumbersRepeatAcrossAreas: false }, beforeMissing: [], after: { unitNumbersRepeatAcrossAreas: true } }, { unitNumbersRepeatAcrossAreas: true }),
    { action: 'restore', set: { unitNumbersRepeatAcrossAreas: false }, remove: [] },
  );
  assert.deepEqual(
    revertDocAction(p.facilityChange, { unitNumbersRepeatAcrossAreas: true, name: 'x' }),
    { action: 'restore', set: {}, remove: ['unitNumbersRepeatAcrossAreas'] },
  );
});

const revertItem = () =>
  plan({
    units: [unit('u1', { unitNumber: 'C2-1', area: 'Complex 2', tenantId: 't1' })],
    tenants: [tenant('t1', { unitNumber: 'C2-1', unitId: 'u1', unitArea: 'Complex 2' })],
  }).units[0];

test('revert: a recorded tenant who moved on is detached and the unit still reverts', () => {
  const item = revertItem();
  const unitAfter = { unitNumber: '1', legacyUnitNumber: 'C2-1', area: 'Complex 2', tenantId: null };
  for (const t1 of [
    { unitNumber: '1', legacyUnitNumber: 'C2-1', unitId: 'u1', isActive: false },
    { unitNumber: '7', legacyUnitNumber: 'C2-1', unitId: 'u7', isActive: true },
    null,
  ]) {
    const r = planItemRevert(item, { unit: unitAfter, tenants: { t1 }, holders: [] });
    assert.equal(r.refused, false);
    assert.deepEqual(r.docs.map((d) => [d.kind, d.id, d.action]), [
      ['unit', 'u1', 'restore'],
      ['tenant', 't1', 'detached'],
    ]);
  }
});

test('revert: the active tenant now in the unit is relabelled when their label is the new number', () => {
  const item = revertItem();
  const r = planItemRevert(item, {
    unit: { unitNumber: '1', legacyUnitNumber: 'C2-1', area: 'Complex 2', tenantId: 'new' },
    tenants: { t1: { unitNumber: '1', legacyUnitNumber: 'C2-1', unitId: 'u1', isActive: false } },
    holders: [
      { id: 'new', data: { unitNumber: ' 1 ', unitId: 'u1', unitArea: 'Complex 2', isActive: true } },
      // Holds this unit too, but their label names their primary unit elsewhere.
      { id: 'multi', data: { unitNumber: '1', unitId: 'u-other', isActive: true } },
      { id: 'other', data: { unitNumber: '1-annex', unitId: 'u1', isActive: true } },
      { id: 'old', data: { unitNumber: '1', unitId: 'u1', isActive: false } },
    ],
  });
  assert.equal(r.refused, false);
  assert.deepEqual(r.docs.map((d) => [d.kind, d.id, d.action, d.set]), [
    ['unit', 'u1', 'restore', { unitNumber: 'C2-1' }],
    ['tenant', 't1', 'detached', undefined],
    ['tenant', 'new', 'relabel', { unitNumber: 'C2-1' }],
    ['tenant', 'other', 'holder-other-label', undefined],
  ]);
  // A holder with no unitId counts only when the unit's tenantId is them.
  const noId = planItemRevert(item, {
    unit: { unitNumber: '1', legacyUnitNumber: 'C2-1', area: 'Complex 2', tenantId: 'h' },
    tenants: {},
    holders: [{ id: 'h', data: { unitNumber: '1', isActive: true } }],
  });
  assert.deepEqual(noId.docs.map((d) => d.action), ['restore', 'detached', 'relabel']);
});

test('revert honours the apply record: refused items skipped, flag only when applied, pending by state', async () => {
  const item = revertItem();
  const fc = { before: { unitNumbersRepeatAcrossAreas: null }, beforeMissing: ['unitNumbersRepeatAcrossAreas'], after: { unitNumbersRepeatAcrossAreas: true } };
  const rec = {
    units: [
      { ...item, unitId: 'a', status: 'applied' },
      { ...item, unitId: 'b', status: 'refused' },
      { ...item, unitId: 'c', status: 'pending' },
      { ...item, unitId: 'd', status: 'skipped' },
    ],
    facilityChange: { ...fc, status: 'applied' },
  };
  const calls = [];
  const out = await runRevertSteps(rec, {
    revertItem: async (i) => {
      calls.push(i.unitId);
      return { status: 'reverted', docs: [] };
    },
    revertFlag: async () => {
      calls.push('flag');
      return { status: 'restored' };
    },
  });
  assert.deepEqual(calls, ['a', 'c', 'flag']);
  assert.deepEqual(out.units.map((u) => u.status), ['reverted', 'skipped', 'reverted', 'skipped']);

  // Flag change not recorded as applied: left alone.
  const notApplied = await runRevertSteps({ units: [], facilityChange: { ...fc, status: 'pending' } }, {
    revertItem: async () => ({}),
    revertFlag: async () => assert.fail('flag must not be reverted'),
  });
  assert.equal(notApplied.facility.status, 'kept');

  // An item refused: the flag stays on.
  const oneRefused = await runRevertSteps({ units: [{ ...item, status: 'applied' }], facilityChange: { ...fc, status: 'applied' } }, {
    revertItem: async () => {
      throw new Error('changed');
    },
    revertFlag: async () => assert.fail('flag must not be reverted'),
  });
  assert.equal(oneRefused.refusedItems, 1);
  assert.equal(oneRefused.facility.status, 'kept');
});

test('flag revert is refused while a number is used by two live units', () => {
  assert.deepEqual(
    repeatedNumbers([
      unit('a', { unitNumber: '12', area: 'Complex 2' }),
      unit('b', { unitNumber: ' 12 ', area: 'Complex 3' }),
      unit('c', { unitNumber: '12', archived: true }),
      unit('d', { unitNumber: '5A' }),
      unit('e', { unitNumber: '5a' }),
      unit('f', { unitNumber: '7' }),
    ]),
    [
      { number: '12', unitIds: ['a', 'b'] },
      { number: '5A', unitIds: ['d', 'e'] },
    ],
  );
  assert.deepEqual(repeatedNumbers([unit('a', { unitNumber: 'C2-12' }), unit('b', { unitNumber: 'C3-12' })]), []);
});

test('apply sets the facility flag first; a refused flag writes no unit', async () => {
  const record = () => ({
    units: [
      { unitId: 'a', tenants: [] },
      { unitId: 'b', tenants: [] },
    ],
    facilityChange: { before: {}, beforeMissing: [], after: { unitNumbersRepeatAcrossAreas: true }, status: 'pending' },
  });
  const calls = [];
  const r1 = record();
  const res = await runApplySteps(r1, {
    setFlag: async () => calls.push('flag'),
    applyItem: async (i) => {
      calls.push(i.unitId);
      if (i.unitId === 'b') throw new Error('unit number changed since planning');
    },
  });
  assert.deepEqual(calls, ['flag', 'a', 'b']);
  assert.deepEqual(res, { applied: 1, refused: 1, result: 'partial' });
  assert.equal(r1.facilityChange.status, 'applied');
  assert.deepEqual(r1.units.map((u) => u.status), ['applied', 'refused']);

  const r2 = record();
  const res2 = await runApplySteps(r2, {
    setFlag: async () => {
      throw new Error('flag changed since planning');
    },
    applyItem: async () => assert.fail('no unit may be written without the flag'),
  });
  assert.equal(res2.result, 'aborted');
  assert.deepEqual(r2.units.map((u) => u.status), ['skipped', 'skipped']);

  // Flag already on: straight to the units.
  const r3 = { ...record(), facilityChange: null };
  assert.equal((await runApplySteps(r3, { setFlag: async () => assert.fail(), applyItem: async () => {} })).result, 'applied');
});

test('check after apply reports duplicates, no-area clashes, holds and reservations', () => {
  const items = [{ unitId: 'a', before: { unitNumber: 'C2-12' }, after: { unitNumber: '12' } }];
  const clean = verifyAfterApply({
    facilityId: 'f1',
    items,
    units: [unit('a', { unitNumber: '12', area: 'Complex 2' }), unit('b', { unitNumber: '12', area: 'Complex 3' })],
    now: NOW,
  });
  assert.deepEqual(clean, []);
  const later = new Date(NOW.getTime() + 60_000);
  const issues = verifyAfterApply({
    facilityId: 'f1',
    items,
    units: [
      unit('a', { unitNumber: '12', area: 'Complex 2' }),
      unit('dup', { unitNumber: '12 ', area: 'complex 2' }),
      unit('bare', { unitNumber: '12' }),
    ],
    holds: [{ id: 'a', data: { unitId: 'a', expiresAt: later } }],
    publicReservations: [{ id: 'r1', data: { facilityId: 'f1', unitNumber: 'C2-12', status: 'pending', expiresAt: later } }],
    facilityReservations: [{ id: 'fr1', data: { unitId: 'a', status: 'confirmed' } }],
    now: NOW,
  });
  assert.deepEqual(issues.map((i) => i.code), [
    'duplicate-after-apply',
    'no-area-clash-after-apply',
    'active-hold-after-apply',
    'open-public-reservation-after-apply',
    'open-facility-reservation-after-apply',
  ]);
});

test('prefix map and args parsing', () => {
  assert.deepEqual(MAP, [
    { prefix: 'C2-', area: 'Complex 2' },
    { prefix: 'C3-', area: 'Complex 3' },
  ]);
  assert.throws(() => parsePrefixMap('C2-=Complex 2,c2-=Other'), /repeats/);
  assert.throws(() => parsePrefixMap('C2=A,C2-=B'), /overlap/);
  assert.throws(() => parsePrefixMap('C2-'), /prefix=area/);
  assert.throws(() => parsePrefixMap('=Complex 2'), /no prefix/);
  assert.throws(() => parseArgs(['--prefix-map', 'C2-=A']), /--facility/);
  assert.throws(() => parseArgs(['--facility', 'f1']), /--prefix-map/);
  assert.throws(() => parseArgs(['--facility', 'f1', '--facility', 'f2', '--prefix-map', 'C2-=A']), /One --facility/);
  const a = parseArgs(['--facility', 'f1', '--prefix-map', 'C2-=A']);
  assert.equal(a.apply, false);
  assert.equal(a.allowNearRentRun, false);
  assert.equal(parseArgs(['--revert', 'r.json']).revert, 'r.json');
  assert.equal(parseArgs(['--revert', 'r.json', '--apply']).apply, true);
  assert.throws(() => parseArgs(['--facility', 'f1', '--prefix-map', 'C2-=A', '--apply']), /--confirm-app-supports-repeats/);
  const b = parseArgs(['--facility', 'f1', '--prefix-map', 'C2-=A', '--apply', '--confirm-app-supports-repeats', '--out', 'x']);
  assert.equal(b.apply, true);
  assert.equal(b.confirmAppSupportsRepeats, true);
  assert.equal(b.outDir, 'x');
});

test('default out dir is the repo root backfill-records/, whatever the cwd', () => {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
  assert.equal(defaultOutDir(), path.join(root, 'backfill-records'));
});
