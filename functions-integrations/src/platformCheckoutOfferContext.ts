import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  decidePlatformCheckoutOffer,
  getStripeClient,
  writeAuditLog,
  type PlatformCheckoutOffer,
} from '@sfc/functions-shared';

/**
 * Collaborators the platform checkout flows use. Callables pass nothing and get the
 * real ones; tests pass a fake Firestore, a fake Stripe client and a no-op audit log.
 */
export type PlatformCheckoutDeps = {
  db: FirebaseFirestore.Firestore;
  stripe: Stripe;
  auditLog: typeof writeAuditLog;
  nowMs: () => number;
};

export function resolvePlatformCheckoutDeps(deps?: Partial<PlatformCheckoutDeps>): PlatformCheckoutDeps {
  return {
    db: deps?.db ?? admin.firestore(),
    stripe: deps?.stripe ?? getStripeClient(),
    auditLog: deps?.auditLog ?? writeAuditLog,
    nowMs: deps?.nowMs ?? (() => Date.now()),
  };
}

/** Every facility linked to the account, as plain data. */
export async function loadAccountFacilities(
  db: FirebaseFirestore.Firestore,
  accountId: string,
): Promise<Array<Record<string, unknown>>> {
  const snap = await db.collection('facilities').where('facilityCreatorAccountId', '==', accountId).get();
  return snap.docs.map((d) => (d.data() ?? {}) as Record<string, unknown>);
}

/**
 * The trial (including any free month) for this owner's checkout, from the account, all
 * of its facilities, and (for a facility checkout) the facility being subscribed.
 */
export async function decideOfferForAccount(options: {
  db: FirebaseFirestore.Firestore;
  accountId: string;
  account: Record<string, unknown>;
  /** The facility being subscribed, when it may not be linked by query yet. */
  extraFacility?: Record<string, unknown>;
  defaultTrialDays: number;
  nowMs: number;
}): Promise<PlatformCheckoutOffer> {
  const facilities = await loadAccountFacilities(options.db, options.accountId);
  if (options.extraFacility) facilities.push(options.extraFacility);
  return decidePlatformCheckoutOffer({
    account: options.account,
    facilities,
    defaultTrialDays: options.defaultTrialDays,
    nowMs: options.nowMs,
  });
}
