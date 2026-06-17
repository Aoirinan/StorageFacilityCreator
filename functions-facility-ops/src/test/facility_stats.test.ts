import test from 'node:test';
import assert from 'node:assert/strict';
import * as admin from 'firebase-admin';
import { facilityStatsTestUtils } from '../facility_stats';

const { tenantAutopayOn, calculateDaysLate, countCanonicalOccupied } = facilityStatsTestUtils;

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
  assert.equal(calculateDaysLate(tenant as any, now), 0);
});

test('calculateDaysLate returns days since creation when never paid and older than 30 days', () => {
  const now = new Date('2026-06-15T12:00:00.000Z');
  const tenant = {
    isActive: true,
    monthlyRate: 100,
    createdAt: ts(new Date('2026-04-01T12:00:00.000Z')),
  };
  const daysLate = calculateDaysLate(tenant as any, now);
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
  const daysLate = calculateDaysLate(tenant as any, now);
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
