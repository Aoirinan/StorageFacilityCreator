/**
 * The audit rows monthly rent generation writes: one per tenant charged, and
 * one per tenant left uncharged for the owner to check.
 *
 * The scheduled job (rentChargeJob.ts) and the generateMonthlyRentCharges
 * callable both build them here and write them through writeAuditLog, so they
 * have the shape the app's audit readers use: eventType and timestamp (the
 * Audit Log screen and its CSV export), after.amount/month/year and
 * metadata.runId (the Recurring Charges screen's Generation History, which
 * totals a run's rows by runId; lib/services/rent_generation_history.dart).
 *
 * Rows from before this shape are still read there: the job wrote
 * action/at/details with the same event names, and the app's old client-side
 * writer wrote action 'recurringcharge.generated'.
 */

export const RENT_CHARGE_GENERATED_EVENT = 'recurringCharge.generated';
export const RENT_CHARGE_NEEDS_REVIEW_EVENT = 'recurringCharge.needsReview';

/** Who the scheduled job writes as. writeAuditLog keeps the email for 'system'. */
export const SCHEDULED_JOB_ACTOR = { actorUid: 'system', actorEmail: 'system@scheduled-job' } as const;

export type RentChargeRun = {
  /** Groups a run's rows. */
  runId: string;
  source: 'scheduled' | 'manual';
  actorUid: string;
  actorEmail?: string;
  year: number;
  /** 1-based, as in the ledger entry's metadata. */
  month: number;
};

/** The subset of writeAuditLog's entry these rows use. */
export type RentChargeAuditEntry = {
  eventType: string;
  actorUid: string;
  actorEmail?: string;
  targetType: string;
  targetId: string;
  tenantId: string;
  after?: Record<string, unknown>;
  metadata: Record<string, unknown>;
};

/**
 * A facility's scheduled run for a month. The job runs once per facility per
 * month, so a retried job's rows join the first attempt's.
 */
export function scheduledRentChargeRunId(year: number, month: number): string {
  return `scheduled_${year}_${String(month).padStart(2, '0')}`;
}

export function rentChargeGeneratedAudit(
  run: RentChargeRun,
  charge: {
    ledgerEntryId: string;
    tenantId: string;
    amount: number;
    /** monthlyRate, lessCoveredAtMoveIn and coveredAtMoveIn when reduced. */
    covered?: Record<string, unknown>;
    idempotencyKey?: string | null;
  },
): RentChargeAuditEntry {
  return {
    eventType: RENT_CHARGE_GENERATED_EVENT,
    ...actor(run),
    targetType: 'ledgerEntry',
    targetId: charge.ledgerEntryId,
    tenantId: charge.tenantId,
    after: {
      amount: charge.amount,
      chargeType: 'monthlyRent',
      month: run.month,
      year: run.year,
      ...(charge.covered ?? {}),
    },
    metadata: {
      runId: run.runId,
      source: run.source,
      ...(charge.idempotencyKey ? { idempotencyKey: charge.idempotencyKey } : {}),
    },
  };
}

export function rentChargeNeedsReviewAudit(
  run: RentChargeRun,
  review: {
    tenantId: string;
    reason: string;
    monthlyRate: number;
    coveredAtMoveIn: unknown[];
  },
): RentChargeAuditEntry {
  return {
    eventType: RENT_CHARGE_NEEDS_REVIEW_EVENT,
    ...actor(run),
    targetType: 'tenant',
    targetId: review.tenantId,
    tenantId: review.tenantId,
    metadata: {
      runId: run.runId,
      source: run.source,
      reason: review.reason,
      monthlyRate: review.monthlyRate,
      coveredAtMoveIn: review.coveredAtMoveIn,
      chargeType: 'monthlyRent',
      month: run.month,
      year: run.year,
    },
  };
}

function actor(run: RentChargeRun): { actorUid: string; actorEmail?: string } {
  return run.actorEmail
    ? { actorUid: run.actorUid, actorEmail: run.actorEmail }
    : { actorUid: run.actorUid };
}
