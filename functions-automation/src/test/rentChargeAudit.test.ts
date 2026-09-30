import test from 'node:test';
import assert from 'node:assert/strict';
import {
  RENT_CHARGE_GENERATED_EVENT,
  RENT_CHARGE_NEEDS_REVIEW_EVENT,
  RentChargeRun,
  SCHEDULED_JOB_ACTOR,
  rentChargeGeneratedAudit,
  rentChargeNeedsReviewAudit,
  scheduledRentChargeRunId,
} from '../rentChargeAudit';

const scheduled: RentChargeRun = {
  runId: scheduledRentChargeRunId(2026, 10),
  source: 'scheduled',
  ...SCHEDULED_JOB_ACTOR,
  year: 2026,
  month: 10,
};

const manual: RentChargeRun = {
  runId: 'manual_abc',
  source: 'manual',
  actorUid: 'owner-1',
  year: 2026,
  month: 10,
};

test('the event names are the ones the app reads', () => {
  // lib/services/rent_generation_history.dart queries these.
  assert.equal(RENT_CHARGE_GENERATED_EVENT, 'recurringCharge.generated');
  assert.equal(RENT_CHARGE_NEEDS_REVIEW_EVENT, 'recurringCharge.needsReview');
});

test('a scheduled run is one per month, zero-padded', () => {
  assert.equal(scheduledRentChargeRunId(2026, 10), 'scheduled_2026_10');
  assert.equal(scheduledRentChargeRunId(2027, 1), 'scheduled_2027_01');
});

test('the job and the callable write a charge in one shape', () => {
  const charge = { ledgerEntryId: 'le-1', tenantId: 't-1', amount: 120 };
  const fromJob = rentChargeGeneratedAudit(scheduled, charge);
  const fromCallable = rentChargeGeneratedAudit(manual, { ...charge, idempotencyKey: 'charge_f_t-1_2026_10' });

  assert.deepEqual(fromJob, {
    eventType: 'recurringCharge.generated',
    actorUid: 'system',
    actorEmail: 'system@scheduled-job',
    targetType: 'ledgerEntry',
    targetId: 'le-1',
    tenantId: 't-1',
    after: { amount: 120, chargeType: 'monthlyRent', month: 10, year: 2026 },
    metadata: { runId: 'scheduled_2026_10', source: 'scheduled' },
  });
  assert.deepEqual(fromCallable, {
    eventType: 'recurringCharge.generated',
    actorUid: 'owner-1',
    targetType: 'ledgerEntry',
    targetId: 'le-1',
    tenantId: 't-1',
    after: { amount: 120, chargeType: 'monthlyRent', month: 10, year: 2026 },
    metadata: { runId: 'manual_abc', source: 'manual', idempotencyKey: 'charge_f_t-1_2026_10' },
  });
});

test('a reduced charge keeps what the move-in covered in after', () => {
  const covered = {
    monthlyRate: 150,
    lessCoveredAtMoveIn: 100,
    coveredAtMoveIn: [{ contractId: 'c-b1', monthlyShare: 100, ledgerEntryIds: ['le-0'] }],
  };
  const row = rentChargeGeneratedAudit(scheduled, { ledgerEntryId: 'le-2', tenantId: 't-2', amount: 50, covered });
  assert.deepEqual(row.after, { amount: 50, chargeType: 'monthlyRent', month: 10, year: 2026, ...covered });
});

test('a tenant left to check is logged against the tenant, with the reason', () => {
  const row = rentChargeNeedsReviewAudit(scheduled, {
    tenantId: 'short',
    reason: 'rate is less than the rent charged at move-in',
    monthlyRate: 100,
    coveredAtMoveIn: [{ contractId: 'c-b3', monthlyShare: 100, ledgerEntryIds: ['le-3'] }],
  });
  assert.equal(row.eventType, 'recurringCharge.needsReview');
  assert.equal(row.targetType, 'tenant');
  assert.equal(row.targetId, 'short');
  assert.equal(row.after, undefined);
  assert.deepEqual(row.metadata, {
    runId: 'scheduled_2026_10',
    source: 'scheduled',
    reason: 'rate is less than the rent charged at move-in',
    monthlyRate: 100,
    coveredAtMoveIn: [{ contractId: 'c-b3', monthlyShare: 100, ledgerEntryIds: ['le-3'] }],
    chargeType: 'monthlyRent',
    month: 10,
    year: 2026,
  });
});
