import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  computeAccountRollup,
  getStripeClient,
  type FacilitySubscriptionSnapshot,
} from '@sfc/functions-shared';

/**
 * Bring an account document back in line with its facilities and its trial.
 *
 * The webhook handlers route by metadata: a subscription carrying a
 * `facilityId` updates the facility and returns, so the account document was
 * never refreshed once an operator moved to per-facility billing. That left
 * accounts asserting `trialing` while pointing at a subscription Stripe had
 * cancelled months before. Call this after any facility-scoped subscription
 * change so the account stays a truthful rollup of its sites.
 */
export type ReconcileResult = {
  accountId: string;
  status: string;
  reason: string;
  changed: boolean;
  clearedStaleSubscriptionId: boolean;
};

/** Stripe statuses that mean the account-level subscription is finished for good. */
const DEAD_STRIPE_STATUSES = new Set(['canceled', 'incomplete_expired']);

async function loadFacilitySnapshots(accountId: string): Promise<FacilitySubscriptionSnapshot[]> {
  // Query by the facility's own back-reference rather than the account's
  // `facilityIds` array: the array is maintained by a separate write and can
  // itself be stale, which is the class of bug this function exists to fix.
  const snap = await admin
    .firestore()
    .collection('facilities')
    .where('facilityCreatorAccountId', '==', accountId)
    .get();

  return snap.docs.map((d) => ({
    facilityId: d.id,
    platformSubscriptionStatus: (d.get('platformSubscriptionStatus') as string | undefined) ?? null,
  }));
}

/**
 * Verify the account-level subscription id still refers to something live.
 * Returns true when a dead pointer was cleared.
 */
async function clearStaleAccountSubscriptionId(
  accountRef: FirebaseFirestore.DocumentReference,
  subscriptionId: string,
): Promise<boolean> {
  try {
    const stripe = getStripeClient();
    const sub = await stripe.subscriptions.retrieve(subscriptionId);
    if (!DEAD_STRIPE_STATUSES.has(sub.status)) return false;
  } catch (err: unknown) {
    const code = (err as { code?: string })?.code;
    // A subscription Stripe cannot find is as dead as one it reports cancelled.
    if (code !== 'resource_missing') {
      functions.logger.warn('Could not verify account subscription; leaving the pointer alone', {
        subscriptionId,
        err,
      });
      return false;
    }
  }

  await accountRef.update({
    stripeSubscriptionId: null,
    stripeSubscriptionIdClearedAt: admin.firestore.FieldValue.serverTimestamp(),
    stripeSubscriptionIdClearedFrom: subscriptionId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  functions.logger.info('Cleared a stale account subscription pointer', { subscriptionId });
  return true;
}

export async function reconcileAccountSubscription(
  accountId: string,
  options: { verifyStripeSubscription?: boolean } = {},
): Promise<ReconcileResult | null> {
  if (!accountId) return null;

  try {
    const accountRef = admin.firestore().collection('facilityCreatorAccounts').doc(accountId);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      functions.logger.warn('Reconcile skipped: account not found', { accountId });
      return null;
    }

    const account = accountSnap.data() ?? {};
    const trialEnd = account.subscriptionTrialEnd as admin.firestore.Timestamp | undefined;
    const facilities = await loadFacilitySnapshots(accountId);

    const rollup = computeAccountRollup({
      currentStatus: (account.subscriptionStatus as string | undefined) ?? null,
      localTrialEndMs: trialEnd?.toMillis() ?? null,
      facilities,
      nowMs: Date.now(),
    });

    if (rollup.changed) {
      await accountRef.update({
        subscriptionStatus: rollup.status,
        subscriptionRollupReason: rollup.reason,
        subscriptionRollupAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info('Account subscription status reconciled', {
        accountId,
        from: account.subscriptionStatus ?? null,
        to: rollup.status,
        reason: rollup.reason,
        facilityCount: facilities.length,
      });
    }

    let clearedStaleSubscriptionId = false;
    const accountSubscriptionId = (account.stripeSubscriptionId as string | undefined)?.trim();
    if (options.verifyStripeSubscription && accountSubscriptionId) {
      clearedStaleSubscriptionId = await clearStaleAccountSubscriptionId(accountRef, accountSubscriptionId);
    }

    return {
      accountId,
      status: rollup.status,
      reason: rollup.reason,
      changed: rollup.changed,
      clearedStaleSubscriptionId,
    };
  } catch (err: unknown) {
    // Reconciliation is a correction pass, never the reason a webhook fails:
    // Stripe would retry the whole event and re-run the primary write.
    functions.logger.error('Account reconcile failed', { accountId, err });
    return null;
  }
}
