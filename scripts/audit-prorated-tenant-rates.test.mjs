// node --test scripts/audit-prorated-tenant-rates.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';

import { auditTenantRates, isWholeCents, parseArgs } from './audit-prorated-tenant-rates.mjs';

const tenant = (id, data) => ({ id, data: { name: `Tenant ${id}`, isActive: true, unitNumber: '1', ...data } });
const unit = (id, data) => ({ id, data: { status: 'occupied', ...data } });
const row = (id, data) => ({ id, data: { status: 'posted', ...data } });

test('whole cents, within float noise', () => {
  assert.equal(isWholeCents(40), true);
  assert.equal(isWholeCents(24.52), true);
  assert.equal(isWholeCents(0.1 + 0.2), true);
  assert.equal(isWholeCents(24.516129032258064), false);
  assert.equal(isWholeCents(Number.NaN), false);
});

test('an online move-in whose rate is its unrounded prorated row: flagged both ways, with the shortfall', () => {
  const rate = 24.516129032258064;
  const { flagged } = auditTenantRates({
    tenants: [tenant('t1', { monthlyRate: rate, createdBy: 'publicMoveIn' })],
    units: [unit('u1', { unitNumber: 'Parking 1', tenantId: 't1', monthlyRate: 40 })],
    ledgers: [
      row('p', { tenantId: 't1', type: 'proratedRent', amount: rate, metadata: { isProrated: true } }),
      row('pay', { tenantId: 't1', type: 'payment', amount: -24.52 }),
      row('aug', {
        tenantId: 't1', type: 'rentCharge', amount: rate, status: 'voided',
        entryDate: new Date('2026-08-01T00:00:00Z'), metadata: { recurringCharge: true, month: 8, year: 2026 },
      }),
      row('sep', {
        tenantId: 't1', type: 'rentCharge', amount: rate,
        entryDate: new Date('2026-09-01T00:00:00Z'), metadata: { recurringCharge: true, month: 9, year: 2026 },
      }),
    ],
  });
  assert.equal(flagged.length, 1);
  const f = flagged[0];
  assert.deepEqual(f.reasons, ['fractional-cents', 'equals-prorated-row']);
  assert.equal(f.proposedMonthlyRate, 40);
  assert.deepEqual(
    f.recurringCharges.map((c) => [c.month, c.status, c.shortfall]),
    [[8, 'voided', 15.48], [9, 'posted', 15.48]],
  );
  // Only the posted charge is short.
  assert.equal(f.shortfallTotal, 15.48);
});

test("the wizard's rounded prorated rate equals its prorated row: flagged", () => {
  const { flagged } = auditTenantRates({
    tenants: [tenant('t1', { monthlyRate: 24.52 })],
    units: [unit('u1', { tenantId: 't1', monthlyRate: 40 })],
    ledgers: [
      row('p', {
        tenantId: 't1', type: 'rentCharge', amount: 24.516129032258064,
        metadata: { lineItemType: 'proratedRent', isProrated: true },
      }),
    ],
  });
  assert.deepEqual(flagged.map((f) => f.reasons), [['equals-prorated-row']]);
});

test('a negotiated rate below the unit rate is not flagged', () => {
  const { flagged, activeTenants } = auditTenantRates({
    tenants: [
      tenant('t1', { monthlyRate: 110 }),
      // Prorated at move-in, but billed the full month since.
      tenant('t2', { monthlyRate: 40 }),
      // Inactive tenants are left out, whatever their rate.
      tenant('t3', { monthlyRate: 12.3456, isActive: false }),
    ],
    units: [
      unit('u1', { tenantId: 't1', monthlyRate: 120 }),
      unit('u2', { tenantId: 't2', monthlyRate: 40 }),
    ],
    ledgers: [
      row('p1', { tenantId: 't1', type: 'proratedRent', amount: 70.97 }),
      row('p2', { tenantId: 't2', type: 'proratedRent', amount: 24.52 }),
      // Another tenant's row with t1's rate is not t1's.
      row('px', { tenantId: 't9', type: 'proratedRent', amount: 110 }),
    ],
  });
  assert.deepEqual(flagged, []);
  assert.equal(activeTenants, 2);
});

test('the proposed rate is the sum of the units they hold, not ones marked available', () => {
  const { flagged } = auditTenantRates({
    tenants: [tenant('t1', { monthlyRate: 99.999 })],
    units: [
      unit('a', { tenantId: 't1', monthlyRate: 60 }),
      unit('b', { tenantId: 't1', monthlyRate: 40.5 }),
      unit('c', { tenantId: 't1', monthlyRate: 70, status: 'available' }),
      unit('d', { tenantId: 't1', monthlyRate: 80, archived: true }),
    ],
    ledgers: [],
  });
  assert.equal(flagged[0].proposedMonthlyRate, 100.5);
  assert.deepEqual(flagged[0].heldUnits.map((u) => u.unitId), ['a', 'b']);
});

test('arguments: read only, so there is no --apply', () => {
  assert.deepEqual(parseArgs(['--facility', 'f1', '--json']), { facilities: ['f1'], project: null, json: true });
  assert.throws(() => parseArgs(['--apply']), /Unknown argument: --apply/);
});
