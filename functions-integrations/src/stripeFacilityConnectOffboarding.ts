import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  buildFacilityDisconnectUpdate,
  deauthorizeConnectedAccount,
  getStripeClient,
  type FacilityDisconnectReason,
} from '@sfc/functions-shared';
import { STRIPE_CONNECT_CLIENT_ID, STRIPE_SECRETS_WITH_CONNECT } from './secrets';

/**
 * Turn off autopay for every tenant of a facility whose Connect account is no
 * longer reachable from the platform. Charges through the platform key would
 * fail anyway; clearing the flag keeps the scheduled autopay job from trying.
 */
export async function disableFacilityTenantAutopay(facilityId: string): Promise<number> {
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  const now = admin.firestore.FieldValue.serverTimestamp();
  let disabled = 0;
  // Autopay is recorded in two places: billing/default on the tenant, and an
  // autopayEnabled flag on the chosen payment method. Clear both.
  for (const sub of ['tenants', 'oldTenants'] as const) {
    const tenants = await facilityRef.collection(sub).get();
    for (const tenantDoc of tenants.docs) {
      const billing = await tenantDoc.ref.collection('billing').where('autopayEnabled', '==', true).get();
      for (const doc of billing.docs) {
        await doc.ref.update({ autopayEnabled: false, stripeSubscriptionId: null, updatedAt: now });
        disabled += 1;
      }
      const methods = await tenantDoc.ref.collection('paymentMethods').where('autopayEnabled', '==', true).get();
      for (const doc of methods.docs) {
        await doc.ref.update({ autopayEnabled: false, updatedAt: now });
      }
    }
  }
  return disabled;
}

/**
 * Record on the facility document that its Connect account is detached, and
 * stop autopay. Safe to call when the facility document no longer exists.
 */
export async function markFacilityStripeDisconnected(input: {
  facilityId: string;
  accountId: string | null | undefined;
  reason: FacilityDisconnectReason;
}): Promise<void> {
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(input.facilityId);
  const snap = await facilityRef.get();
  if (snap.exists) {
    await facilityRef.update(
      buildFacilityDisconnectUpdate({
        accountId: input.accountId,
        reason: input.reason,
        now: admin.firestore.FieldValue.serverTimestamp(),
      }),
    );
  }
  const disabled = await disableFacilityTenantAutopay(input.facilityId);
  functions.logger.info('Facility Stripe Connect marked disconnected', {
    facilityId: input.facilityId,
    accountId: input.accountId ?? null,
    reason: input.reason,
    autopayDisabled: disabled,
  });
}

/**
 * Revoke the platform's access to a facility's connected account, then record
 * it. Missing client id is logged, not thrown: the facility bookkeeping still
 * happens and the daily sweep retries the Stripe side.
 */
export async function offboardFacilityStripeConnection(input: {
  facilityId: string;
  accountId: string | null | undefined;
  reason: FacilityDisconnectReason;
}): Promise<{ stripe: 'deauthorized' | 'already_disconnected' | 'skipped' }> {
  let stripeResult: 'deauthorized' | 'already_disconnected' | 'skipped' = 'skipped';
  if (input.accountId) {
    const clientId = STRIPE_CONNECT_CLIENT_ID.value().trim();
    if (!clientId) {
      functions.logger.error('STRIPE_CONNECT_CLIENT_ID missing; connected account left attached', {
        facilityId: input.facilityId,
        accountId: input.accountId,
      });
    } else {
      stripeResult = await deauthorizeConnectedAccount(getStripeClient(), clientId, input.accountId);
    }
  }
  await markFacilityStripeDisconnected(input);
  return { stripe: stripeResult };
}

/**
 * The Flutter client deletes facility documents directly, so this is the only
 * place that sees a deletion. Detach the Connect account right away rather
 * than leaving it for the daily orphan sweep.
 */
export const onFacilityDeletedDisconnectStripe = functions
  .runWith({ secrets: STRIPE_SECRETS_WITH_CONNECT })
  .firestore.document('facilities/{facilityId}')
  .onDelete(async (snapshot, context) => {
    const facilityId = context.params.facilityId as string;
    const accountId = (snapshot.data()?.stripeConnectAccountId as string | undefined) || null;
    if (!accountId) return;
    try {
      const result = await offboardFacilityStripeConnection({
        facilityId,
        accountId,
        reason: 'facility_deleted',
      });
      functions.logger.info('Deleted facility detached from Stripe Connect', { facilityId, accountId, ...result });
    } catch (error) {
      // The daily sweep catches anything missed here via the orphan check.
      functions.logger.error('Failed to detach deleted facility from Stripe Connect', {
        facilityId,
        accountId,
        error: (error as Error).message,
      });
    }
  });

/**
 * Connect webhook: the facility owner revoked the platform from their own
 * Stripe dashboard. Nothing to call on Stripe; just stop treating the account
 * as attached.
 */
export async function handleConnectAccountDeauthorized(event: Stripe.Event): Promise<void> {
  const accountId = (event as { account?: string }).account;
  if (!accountId) {
    functions.logger.warn('account.application.deauthorized without an account id');
    return;
  }
  const facilities = await admin
    .firestore()
    .collection('facilities')
    .where('stripeConnectAccountId', '==', accountId)
    .get();
  if (facilities.empty) {
    functions.logger.info('Deauthorized account matched no facility', { accountId });
    return;
  }
  for (const doc of facilities.docs) {
    await markFacilityStripeDisconnected({ facilityId: doc.id, accountId, reason: 'owner_deauthorized' });
  }
}
