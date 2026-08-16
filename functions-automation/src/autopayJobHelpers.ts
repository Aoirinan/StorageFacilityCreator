/**
 * Autopay-specific job constants.
 *
 * The generic fan-out bookkeeping now lives in ./facilityJobHelpers, because
 * more than one scheduled job needs it. Re-exported here under the names the
 * autopay code and its tests already use.
 */
export {
  jobRunDate as autopayRunDate,
  facilityJobId as autopayJobId,
  canClaimFacilityJob as canClaimAutopayJob,
  chunkForBatchedWrites,
} from './facilityJobHelpers';
export type {
  FacilityJobStatus as AutopayJobStatus,
  FacilityJobData as AutopayJobData,
} from './facilityJobHelpers';

export const AUTOPAY_JOBS_COLLECTION = 'autopayJobs';
