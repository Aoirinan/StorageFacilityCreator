import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import { facilityStatsTestUtils } from '../facility_stats';

const {
  tenantAutopayOn,
  calculateDaysLate,
  countCanonicalOccupied,
  isRentableUnit,
  summarizeFacilityStats,
  computeFacilityStats,
  recomputeAndPersistFacilityStats,
} = facilityStatsTestUtils;

function ts(date: Date): admin.firestore.Timestamp {
  return admin.firestore.Timestamp.fromDate(date);
}

test('tenantAutopayOn is true only when status is ON', () => {
  assert.equal(tenantAutopayOn({ autopay: { status: 'ON', enabled: true } } as any), true);
  assert.equal(tenantAutopayOn({ autopay: { status: 'REQUESTED', enabled: true } } as any), false);
  assert.equal(tenantAutopayOn({ autopay: { enabled: true } } as any), false);
  assert.equal(tenantAutopayOn({} as any), false);
});

test('calculateDaysLate returns 0 for new tenant without payment', () => {
  const now = new Date('2026-06-15T12:00:00.000Z');
  const tenant = {
    isActive: true,
    monthlyRate: 100,
    createdAt: ts(new Date('2026-05-20T12:00:00.000Z')),
  };
  assert.equal(calculateDaysLate(tenant as any, 3, now), 0);
});

test('calculateDaysLate returns days past onboarding window when never paid and older than 30 days', () => {
  const now = new Date('2026-06-15T12:00:00.000Z');
  const tenant = {
    isActive: true,
    monthlyRate: 100,
    createdAt: ts(new Date('2026-04-01T12:00:00.000Z')),
  };
  const daysLate = calculateDaysLate(tenant as any, 3, now);
  assert.equal(daysLate >= 30, true);
});

test('calculateDaysLate buckets paid-through before grace boundary', () => {
  const now = new Date('2026-06-15T12:00:00.000Z');
  const tenant = {
    isActive: true,
    monthlyRate: 100,
    createdAt: ts(new Date('2025-01-01T12:00:00.000Z')),
    paidThrough: ts(new Date('2026-05-01T12:00:00.000Z')),
  };
  const daysLate = calculateDaysLate(tenant as any, 3, now);
  assert.equal(daysLate >= 10, true);
  assert.equal(daysLate < 30, true);
});

test('countCanonicalOccupied ignores orphan occupied units', () => {
  const tenantIds = new Set(['t1']);
  const { occupiedUnits, orphanIds } = countCanonicalOccupied(
    [
      { id: 'u1', status: 'occupied', tenantId: 't1' },
      { id: 'u2', status: 'occupied', tenantId: 'missing' },
      { id: 'u3', status: 'available', tenantId: null },
    ],
    tenantIds,
  );
  assert.equal(occupiedUnits, 1);
  assert.deepEqual(orphanIds, ['u2']);
});

test('isRentableUnit excludes only units explicitly marked publicListingEnabled=false', () => {
  assert.equal(isRentableUnit({ id: 'u1', status: 'available', publicListingEnabled: true }), true);
  assert.equal(isRentableUnit({ id: 'u2', status: 'available', publicListingEnabled: false }), false);
  // Field absent (legacy unit docs predating this flag) must default to rentable.
  assert.equal(isRentableUnit({ id: 'u3', status: 'available' }), true);
});

test('isRentableUnit excludes archived units with the same test Flutter uses', () => {
  // Before: archived units counted here but not in the app, so the facility
  // mirror (cards, search, super admin) ran higher than every live count.
  assert.equal(isRentableUnit({ id: 'u1', status: 'available', archived: true }), false);
  assert.equal(isRentableUnit({ id: 'u2', status: 'available', archived: false }), true);
  assert.equal(isRentableUnit({ id: 'u3', status: 'available' }), true);
  // Flutter keeps a unit only when `(archived ?? false) == false`; a stray
  // non-boolean is dropped there, so it must be dropped here too.
  assert.equal(isRentableUnit({ id: 'u4', status: 'available', archived: 'true' as any }), false);
});

type StatsInputs = Parameters<typeof summarizeFacilityStats>[0];

function statsInputs(over: Partial<StatsInputs> = {}): StatsInputs {
  return {
    gracePeriodDays: 3,
    units: [],
    allTenantIds: new Set<string>(),
    activeTenants: [],
    ...over,
  };
}

test('an archived occupied unit with a real tenant is left out of total and occupied', () => {
  const stats = summarizeFacilityStats(
    statsInputs({
      units: [
        { id: 'live', status: 'occupied', tenantId: 't1' },
        { id: 'gone', status: 'occupied', tenantId: 't1', archived: true },
        { id: 'office', status: 'occupied', tenantId: 't1', publicListingEnabled: false },
        { id: 'free', status: 'available' },
      ],
      allTenantIds: new Set(['t1']),
    }),
  );
  assert.equal(stats.totalUnits, 2);
  assert.equal(stats.occupiedUnits, 1);
  assert.equal(stats.availableUnits, 1);
});

test('computeFacilityStats still heals an archived orphan unit', async () => {
  const healed: string[][] = [];
  const stats = await computeFacilityStats('fac-1', {
    load: async () =>
      statsInputs({
        units: [
          { id: 'ok', status: 'occupied', tenantId: 't1' },
          { id: 'archived-orphan', status: 'occupied', tenantId: 'deleted', archived: true },
          { id: 'staff-orphan', status: 'occupied', tenantId: null, publicListingEnabled: false },
        ],
        allTenantIds: new Set(['t1']),
      }),
    healOrphans: async (_facilityId, ids) => {
      healed.push(ids);
    },
  });
  assert.deepEqual(healed, [['archived-orphan', 'staff-orphan']]);
  assert.equal(stats.totalUnits, 1);
  assert.equal(stats.occupiedUnits, 1);
});

test('a failed read throws instead of returning zeros, and heals nothing', async () => {
  let healCalls = 0;
  await assert.rejects(
    computeFacilityStats('fac-1', {
      load: async () => {
        throw new Error('deadline-exceeded');
      },
      healOrphans: async () => {
        healCalls++;
      },
    }),
    /deadline-exceeded/,
  );
  // Before: resolved to all-zero stats, which the callers wrote over the
  // facility mirror.
  assert.equal(healCalls, 0);
});

test('recomputeAndPersist writes nothing when the compute fails', async () => {
  let persisted = 0;
  await assert.rejects(
    recomputeAndPersistFacilityStats(
      'fac-1',
      async () => {
        throw new Error('unavailable');
      },
      async () => {
        persisted++;
      },
    ),
    /unavailable/,
  );
  assert.equal(persisted, 0);
});
