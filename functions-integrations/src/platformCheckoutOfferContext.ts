import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  decidePlatformCheckoutOffer,
  getStripeClient,
  listOwnerAccountDocs,
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
 * The rest of the owner's platform history, beyond this account and its facilities: the
 * owner's other `facilityCreatorAccounts` docs (duplicates, or an account deleted and
 * made again) and the facilities the owner owns that are linked elsewhere. The offer is
 * once per owner, so none of these may start it over.
 */
export async function loadOwnerHistoryBeyondAccount(
  db: FirebaseFirestore.Firestore,
  accountId: string,
  ownerUid: string,
): Promise<{ otherAccounts: Array<Record<string, unknown>>; otherFacilities: Array<Record<string, unknown>> }> {
  if (!ownerUid) return { otherAccounts: [], otherFacilities: [] };
  const [accounts, facilities] = await Promise.all([
    listOwnerAccountDocs(db, ownerUid),
    db.collection('facilities').where('ownerUid', '==', ownerUid).get(),
  ]);
  return {
    otherAccounts: accounts
      .filter((d) => d.id !== accountId)
      .map((d) => (d.data() ?? {}) as Record<string, unknown>),
    otherFacilities: facilities.docs
      .map((d) => (d.data() ?? {}) as Record<string, unknown>)
      .filter((f) => f.facilityCreatorAccountId !== accountId),
  };
}

/**
 * The trial (including any free month) for this owner's checkout, from the account, all
 * of its facilities, (for a facility checkout) the facility being subscribed, and the
 * owner's other accounts and facilities.
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
  const [facilities, beyond] = await Promise.all([
    loadAccountFacilities(options.db, options.accountId),
    loadOwnerHistoryBeyondAccount(options.db, options.accountId, String(options.account.ownerUid ?? '')),
  ]);
  if (options.extraFacility) facilities.push(options.extraFacility);
  return decidePlatformCheckoutOffer({
    account: options.account,
    facilities: [...facilities, ...beyond.otherFacilities],
    otherAccounts: beyond.otherAccounts,
    defaultTrialDays: options.defaultTrialDays,
    nowMs: options.nowMs,
  });
}
