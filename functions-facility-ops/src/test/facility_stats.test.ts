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
  healOrphanUnitsWith,
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
    healOrphans: async (_facilityId, orphans) => {
      healed.push(orphans.map((o) => o.id));
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

test('each heal carries the version of the unit the pass read', async () => {
  const readAt = ts(new Date('2026-09-23T12:00:00.000Z'));
  const healed: Array<{ id: string; updateTime?: admin.firestore.Timestamp }> = [];
  await computeFacilityStats('fac-1', {
    load: async () =>
      statsInputs({
        units: [{ id: 'orphan', status: 'occupied', tenantId: 'gone', updateTime: readAt }],
      }),
    healOrphans: async (_facilityId, orphans) => {
      healed.push(...orphans);
    },
  });
  assert.equal(healed.length, 1);
  assert.equal(healed[0].updateTime, readAt);
});

function firestoreError(code: number, message: string): Error {
  return Object.assign(new Error(message), { code });
}

test('a unit that changed since the read is skipped, not overwritten', async () => {
  const readAt = ts(new Date('2026-09-23T12:00:00.000Z'));
  const writes: Array<[string, admin.firestore.Timestamp]> = [];
  const result = await healOrphanUnitsWith(
    'fac-1',
    [
      { id: 'still-orphan', updateTime: readAt },
      // A move-in relinked this unit between the read and the heal.
      { id: 'just-rented', updateTime: readAt },
      { id: 'deleted', updateTime: readAt },
    ],
    async (unitId, updateTime) => {
      writes.push([unitId, updateTime]);
      if (unitId === 'just-rented') throw firestoreError(9, 'FAILED_PRECONDITION');
      if (unitId === 'deleted') throw firestoreError(5, 'NOT_FOUND');
    },
  );
  // Before: one blind batch.update set the rented unit back to available.
  assert.deepEqual(result, { healed: 1, skipped: 2 });
  assert.deepEqual(
    writes.map(([id, t]) => [id, t === readAt]),
    [
      ['still-orphan', true],
      ['just-rented', true],
      ['deleted', true],
    ],
  );
});

test('any other heal failure still fails the pass', async () => {
  await assert.rejects(
    healOrphanUnitsWith('fac-1', [{ id: 'u1', updateTime: ts(new Date()) }], async () => {
      throw firestoreError(14, 'UNAVAILABLE');
    }),
    /UNAVAILABLE/,
  );
});

test('a unit with no read version is left for the next pass', async () => {
  let writes = 0;
  const result = await healOrphanUnitsWith('fac-1', [{ id: 'u1' }], async () => {
    writes++;
  });
  assert.equal(writes, 0);
  assert.deepEqual(result, { healed: 0, skipped: 1 });
});

test('one tenant with unreadable dates does not fail the facility', () => {
  const now = new Date('2026-06-15T12:00:00.000Z');
  const stats = summarizeFacilityStats(
    statsInputs({
      activeTenants: [
        // Never paid, created long ago: 30+ days late.
        { id: 'late', isActive: true, monthlyRate: 100, createdAt: ts(new Date('2026-01-01T12:00:00.000Z')) },
        // No createdAt and no paidThrough.
        { id: 'no-created', isActive: true, monthlyRate: 50 } as any,
        // paidThrough stored as a string.
        { id: 'string-date', isActive: true, monthlyRate: 25, paidThrough: '2026-05-01', createdAt: ts(now) } as any,
        // monthlyRate stored as a string.
        { id: 'string-rate', isActive: true, monthlyRate: '75', paidThrough: ts(now), createdAt: ts(now) } as any,
      ],
    }),
    now,
  );
  // Before: summarizeFacilityStats threw on the first bad tenant, so every
  // pass for the facility failed and its counts froze.
  assert.equal(stats.totalTenantsActive, 4);
  assert.equal(stats.tenantsSeverelyOverdue, 1);
  assert.equal(stats.totalPastDue, 1);
  assert.equal(stats.scheduledMonthlyRevenue, 175);
});
