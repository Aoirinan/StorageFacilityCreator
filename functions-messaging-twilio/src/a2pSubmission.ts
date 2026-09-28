/**
 * The paid part of texting registration: buying the number, filing the brand
 * and filing the campaign.
 *
 * Two rules, both learned from what the code used to do:
 *
 *  1. Nothing is bought until everything a paid step needs is in place. The
 *     client used to call provisionPhoneNumber first, which bought a number
 *     unconditionally; the check that the TrustHub bundles were approved only
 *     ran later, before the brand. `assertReadyForPaidSubmission` runs first
 *     in every callable that can spend money: both bundles twilio-approved
 *     (read live, not from the facility document), 2+ valid samples, at least
 *     one consent method, consent confirmed, business details present.
 *
 *  2. One paid sequence per facility at a time. Two tabs, two devices, or a
 *     tab and the hourly poll could each read "no number yet" and each buy
 *     one. `withA2PSubmitLease` takes a lease on the facility document in a
 *     transaction (`a2pSubmitLease: { holder, expiresAtMs }`), and
 *     `runPaidSubmission` re-reads the facility before every step so a step
 *     finished by a previous holder is seen and skipped.
 */
import * as functions from 'firebase-functions/v1';
import { mapBusinessType } from '@sfc/functions-shared';
import type { A2PTwilioClient } from './a2pTwilioTypes';
import { fetchTrustBundleState } from './a2pTrustBundle';
import {
  normalizeConsentMethods,
  prepareCampaignSamples,
  type ConsentMethod,
} from './a2pCampaign';

// ---- readiness gate ----------------------------------------------------------

export interface PaidSubmissionInput {
  sampleMessages?: unknown;
  consentMethods?: unknown;
  consentConfirmed?: unknown;
}

export interface PaidSubmissionReadiness {
  samples: string[];
  consentMethods: ConsentMethod[];
}

/**
 * The campaign inputs for a paid step: from the request when it carries them,
 * otherwise what an earlier submit stored on the facility.
 */
export function resolvePaidSubmissionInput(
  request: PaidSubmissionInput | undefined,
  facilityData: Record<string, any>,
): PaidSubmissionInput {
  return {
    sampleMessages: request?.sampleMessages ?? facilityData.textingSampleMessages,
    consentMethods: request?.consentMethods ?? facilityData.textingConsentMethods,
    consentConfirmed:
      request?.consentConfirmed ?? Boolean(facilityData.textingConsentConfirmedAt),
  };
}

/**
 * Refuse any paid step unless every prerequisite holds. `twilio` is null in
 * dry-run mode, where the bundle check is skipped.
 */
export async function assertReadyForPaidSubmission(
  twilio: A2PTwilioClient | null,
  facilityData: Record<string, any>,
  input: PaidSubmissionInput,
): Promise<PaidSubmissionReadiness> {
  const business = (facilityData.textingBusinessData || {}) as Record<string, any>;
  if (!String(business.legalBusinessName || '').trim() || !mapBusinessType(business.businessType)) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Save your business details before reserving a number.',
    );
  }
  if (input.consentConfirmed !== true) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Confirm that tenants opt in before texts are sent.',
    );
  }
  const consentMethods = normalizeConsentMethods(input.consentMethods);
  if (consentMethods.length === 0) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Choose how your tenants agree to texts before reserving a number.',
    );
  }
  const samples = prepareCampaignSamples(facilityData, input.sampleMessages);

  if (twilio) {
    const { profile, product } = await fetchTrustBundleState(twilio, facilityData);
    const profileStatus = profile?.status || 'missing';
    const productStatus = product?.status || 'missing';
    if (profileStatus !== 'twilio-approved' || productStatus !== 'twilio-approved') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Twilio has not approved your business profile and A2P messaging registration yet ' +
          `(business profile: ${profileStatus}, A2P registration: ${productStatus}). Nothing has ` +
          'been bought or filed. You can reserve your number once both are approved, usually ' +
          'about a business day after they are submitted.',
      );
    }
  }
  return { samples, consentMethods };
}

// ---- lease -------------------------------------------------------------------

export interface LeaseSnapshot {
  data(): Record<string, any> | undefined;
}
export interface LeaseTransaction {
  get(ref: any): Promise<LeaseSnapshot>;
  update(ref: any, data: Record<string, unknown>): unknown;
}
/** The part of Firestore the lease needs; `admin.firestore()` satisfies it. */
export interface LeaseDb {
  runTransaction<T>(fn: (tx: LeaseTransaction) => Promise<T>): Promise<T>;
}

/** Long enough for a callable's purchase + brand + campaign, short enough to self-heal. */
export const A2P_SUBMIT_LEASE_MS = 10 * 60 * 1000;

export class A2PLeaseHeldError extends functions.https.HttpsError {
  constructor() {
    super(
      'aborted',
      'Another texting registration step for this facility is already running (another tab, ' +
        'device, or the hourly status check). Wait a minute, then refresh the page.',
    );
  }
}

export async function acquireA2PSubmitLease(
  db: LeaseDb,
  ref: any,
  holder: string,
  nowMs: number,
  ttlMs = A2P_SUBMIT_LEASE_MS,
): Promise<void> {
  await db.runTransaction(async (tx) => {
    const lease = (await tx.get(ref)).data()?.a2pSubmitLease as
      | { holder?: string; expiresAtMs?: number }
      | null
      | undefined;
    if (lease && lease.holder !== holder && Number(lease.expiresAtMs || 0) > nowMs) {
      throw new A2PLeaseHeldError();
    }
    tx.update(ref, { a2pSubmitLease: { holder, acquiredAtMs: nowMs, expiresAtMs: nowMs + ttlMs } });
  });
}

export async function releaseA2PSubmitLease(db: LeaseDb, ref: any, holder: string): Promise<void> {
  await db.runTransaction(async (tx) => {
    const lease = (await tx.get(ref)).data()?.a2pSubmitLease as { holder?: string } | null | undefined;
    if (lease?.holder === holder) tx.update(ref, { a2pSubmitLease: null });
  });
}

/** Run `fn` holding the facility's submission lease; always released afterwards. */
export async function withA2PSubmitLease<T>(
  db: LeaseDb,
  ref: any,
  holder: string,
  fn: () => Promise<T>,
  now: () => number = Date.now,
): Promise<T> {
  await acquireA2PSubmitLease(db, ref, holder, now());
  try {
    return await fn();
  } finally {
    await releaseA2PSubmitLease(db, ref, holder).catch((error) => {
      // An unreleased lease expires on its own; do not mask the real result.
      functions.logger.warn('A2P submit lease release failed', { holder, error: String(error) });
    });
  }
}

// ---- ordered paid steps --------------------------------------------------------

export type PaidStep = (facilityData: Record<string, any>) => Promise<void>;

/**
 * Run paid steps in order, re-reading the facility before each so every step
 * sees what the previous one (or a previous lease holder) recorded — a number
 * already bought, a brand already filed — and skips it. Call inside
 * `withA2PSubmitLease`.
 */
export async function runPaidSubmission(
  readFacility: () => Promise<Record<string, any>>,
  steps: PaidStep[],
): Promise<Record<string, any>> {
  for (const step of steps) {
    await step(await readFacility());
  }
  return readFacility();
}
