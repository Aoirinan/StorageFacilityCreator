import * as admin from 'firebase-admin';
import { chunkForBatchedWrites, facilityJobId } from './facilityJobHelpers';

/**
 * Enqueue one job document per facility, tolerating ones that already exist.
 *
 * A batched write is all-or-nothing, so enqueuing 500 facilities in one batch
 * means a single facility whose job already exists aborts the entire chunk. The
 * previous code treated that ALREADY_EXISTS as benign and moved on, so up to
 * 500 facilities silently missed the night's run.
 *
 * That was invisible with one facility and showed up immediately at a hundred:
 * a load test enqueued zero jobs across 101 facilities because one pre-existing
 * document poisoned the batch. It is exactly the partial-retry case the
 * deterministic job id was meant to survive.
 *
 * The batch is still tried first, since it is one round trip for the common
 * case. Only on failure does it fall back to per-facility creates, so a
 * duplicate skips itself and nothing else.
 *
 * Returns the number of jobs newly created.
 */
export async function enqueueFacilityJobs(params: {
  collection: string;
  runDate: string;
  facilityIds: readonly string[];
  label: string;
}): Promise<number> {
  const { collection, runDate, facilityIds, label } = params;
  const db = admin.firestore();
  let enqueued = 0;

  const payload = (facilityId: string) => ({
    facilityId,
    runDate,
    status: 'pending',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  for (const chunk of chunkForBatchedWrites([...facilityIds])) {
    const batch = db.batch();
    for (const facilityId of chunk) {
      batch.create(db.collection(collection).doc(facilityJobId(runDate, facilityId)), payload(facilityId));
    }

    try {
      await batch.commit();
      enqueued += chunk.length;
      continue;
    } catch (error: any) {
      functions_logger_warn(
        `${label} batch for ${runDate} failed (${error?.message}); retrying ${chunk.length} facilities individually`,
      );
    }

    for (const facilityId of chunk) {
      try {
        await db.collection(collection).doc(facilityJobId(runDate, facilityId)).create(payload(facilityId));
        enqueued += 1;
      } catch (individualError: any) {
        const message = String(individualError?.message ?? individualError);
        // Already enqueued is the expected outcome on a same-day re-run.
        if (!message.includes('ALREADY_EXISTS')) {
          functions_logger_error(`${label}: could not enqueue facility ${facilityId}: ${message}`);
        }
      }
    }
  }

  return enqueued;
}

// Imported lazily so this module stays cheap to load in tests.
function functions_logger_warn(message: string): void {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  require('firebase-functions/v1').logger.warn(message);
}
function functions_logger_error(message: string): void {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  require('firebase-functions/v1').logger.error(message);
}
