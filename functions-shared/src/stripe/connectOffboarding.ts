import type Stripe from 'stripe';

/**
 * Facility offboarding for Stripe Connect.
 *
 * A facility that leaves the platform (subscription cancelled, or the facility
 * document deleted) used to keep its Standard Connect account attached to the
 * platform forever, which left the platform secret key able to act on every
 * former customer's account and left tenant PII in Firestore with no purpose.
 *
 * These helpers are pure so both the integrations and automation codebases can
 * share them and test them without Firestore or Stripe.
 */

/** Days after a platform-subscription cancellation before the facility is offboarded. */
export const OFFBOARDING_GRACE_DAYS = 30;

export type FacilityDisconnectReason =
  | 'facility_deleted'
  | 'subscription_cancelled'
  | 'owner_deauthorized'
  | 'orphaned_account'
  | 'manual';

export type DeauthorizeResult = 'deauthorized' | 'already_disconnected';

/**
 * Stripe answers a deauthorize for an account that is not (or no longer)
 * connected with an invalid_request_error whose message says so. Treat that as
 * success: the goal is "not connected", and it already is.
 */
export function isNotConnectedStripeError(err: unknown): boolean {
  if (!err || typeof err !== 'object') return false;
  const message = String((err as { message?: unknown }).message ?? '').toLowerCase();
  return (
    message.includes('not connected') ||
    message.includes('no longer connected') ||
    message.includes('has not been connected')
  );
}

/** Revoke the platform's access to a connected Standard account. Idempotent. */
export async function deauthorizeConnectedAccount(
  stripe: Pick<Stripe, 'oauth'>,
  clientId: string,
  accountId: string,
): Promise<DeauthorizeResult> {
  if (!clientId) {
    throw new Error('STRIPE_CONNECT_CLIENT_ID is not configured; cannot deauthorize connected accounts');
  }
  if (!accountId) {
    throw new Error('accountId is required to deauthorize a connected account');
  }
  try {
    await stripe.oauth.deauthorize({ client_id: clientId, stripe_user_id: accountId });
    return 'deauthorized';
  } catch (err) {
    if (isNotConnectedStripeError(err)) return 'already_disconnected';
    throw err;
  }
}

/**
 * Fields to write on a facility document once its Connect account is no longer
 * attached to the platform. Uses `null` rather than a delete sentinel so the
 * result is plain data; every reader already treats a missing account id and a
 * null one the same way.
 */
export function buildFacilityDisconnectUpdate(input: {
  accountId: string | null | undefined;
  reason: FacilityDisconnectReason;
  now: unknown;
}): Record<string, unknown> {
  return {
    stripeConnectAccountId: null,
    stripeConnectPreviousAccountId: input.accountId ?? null,
    stripeConnectDisconnectedAt: input.now,
    stripeConnectDisconnectReason: input.reason,
    stripeConnectOnboardingComplete: false,
    stripeStatus: {
      state: 'DISCONNECTED',
      chargesEnabled: false,
      payoutsEnabled: false,
      detailsSubmitted: false,
      currentlyDue: [],
      pastDue: [],
      updatedAt: input.now,
    },
    updatedAt: input.now,
  };
}

/** Fields on a tenant document that identify a person and have no use after offboarding. */
export const TENANT_PII_FIELDS_TO_CLEAR = [
  'email',
  'phone',
  'notes',
  'governmentIdType',
  'governmentIdNumber',
  'governmentIdState',
  'governmentIdCountry',
  'governmentIdIssuedAt',
  'governmentIdExpiresAt',
  'portalAccessCode',
  'portalAccountId',
  'portalWelcomeMessage',
  'insuranceProvider',
  'insuranceProofUrl',
  'contractUrl',
] as const;

export const TENANT_PII_LIST_FIELDS_TO_EMPTY = [
  'emergencyContacts',
  'vehicles',
  'occupants',
  'addresses',
] as const;

export const REDACTED_TENANT_NAME = 'Redacted tenant';

/**
 * Overwrite everything on a tenant document that identifies a person, while
 * keeping the document itself (unit history and ledgers reference it by id and
 * the amounts stay meaningful for accounting).
 */
export function buildTenantPiiRedaction(input: {
  reason: FacilityDisconnectReason;
  now: unknown;
}): Record<string, unknown> {
  const update: Record<string, unknown> = {
    name: REDACTED_TENANT_NAME,
    portalEnabled: false,
    isOnDNR: false,
    piiRedactedAt: input.now,
    piiRedactedReason: input.reason,
    updatedAt: input.now,
  };
  for (const field of TENANT_PII_FIELDS_TO_CLEAR) update[field] = null;
  for (const field of TENANT_PII_LIST_FIELDS_TO_EMPTY) update[field] = [];
  return update;
}

export function offboardingDueAt(cancelledAt: Date, graceDays: number = OFFBOARDING_GRACE_DAYS): Date {
  return new Date(cancelledAt.getTime() + graceDays * 24 * 60 * 60 * 1000);
}

export function isOffboardingDue(
  cancelledAt: Date,
  now: Date,
  graceDays: number = OFFBOARDING_GRACE_DAYS,
): boolean {
  return now.getTime() >= offboardingDueAt(cancelledAt, graceDays).getTime();
}

export interface OffboardingCandidate {
  id: string;
  platformSubscriptionStatus?: unknown;
  platformSubscriptionCancelledAt?: Date | null;
  offboardedAt?: Date | null;
}

export interface OffboardingSelection {
  /** Grace period elapsed; offboard now. */
  due: string[];
  /** Cancelled but no cancellation timestamp recorded (legacy); start the clock. */
  needsClockStart: string[];
  /** Cancelled, clock running, not yet due. */
  waiting: string[];
}

/**
 * Decide which cancelled facilities to offboard on this sweep. A facility that
 * re-subscribes (status no longer 'cancelled') simply stops being a candidate;
 * one already offboarded is never touched twice.
 */
export function selectFacilitiesForOffboarding(
  candidates: OffboardingCandidate[],
  now: Date,
  graceDays: number = OFFBOARDING_GRACE_DAYS,
): OffboardingSelection {
  const selection: OffboardingSelection = { due: [], needsClockStart: [], waiting: [] };
  for (const c of candidates) {
    if (c.platformSubscriptionStatus !== 'cancelled') continue;
    if (c.offboardedAt) continue;
    if (!c.platformSubscriptionCancelledAt) {
      selection.needsClockStart.push(c.id);
      continue;
    }
    if (isOffboardingDue(c.platformSubscriptionCancelledAt, now, graceDays)) {
      selection.due.push(c.id);
    } else {
      selection.waiting.push(c.id);
    }
  }
  return selection;
}

/**
 * A connected account the platform created carries `metadata.facilityId`. When
 * that facility document no longer exists, the account is orphaned and the
 * platform should let go of it. Accounts without the metadata were not created
 * by this platform's onboarding flow and are left alone.
 */
export function isOrphanedConnectedAccount(
  account: { id: string; metadata?: Record<string, string> | null },
  facilityExists: boolean,
): boolean {
  const facilityId = account.metadata?.facilityId;
  if (!facilityId) return false;
  return !facilityExists;
}
