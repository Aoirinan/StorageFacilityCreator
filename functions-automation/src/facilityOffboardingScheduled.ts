import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  buildFacilityDisconnectUpdate,
  buildTenantPiiRedaction,
  deauthorizeConnectedAccount,
  getStripeClient,
  isOrphanedConnectedAccount,
  selectFacilitiesForOffboarding,
  type FacilityDisconnectReason,
  type OffboardingCandidate,
} from '@sfc/functions-shared';
import { STRIPE_CONNECT_CLIENT_ID, STRIPE_SECRETS_WITH_CONNECT } from './secrets';

const TENANT_SUBCOLLECTIONS = ['tenants', 'oldTenants'] as const;
const MAX_CONNECTED_ACCOUNTS_PER_SWEEP = 1000;

function toDate(value: unknown): Date | null {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof (value as { toDate?: () => Date }).toDate === 'function') {
    return (value as { toDate: () => Date }).toDate();
  }
  return null;
}

async function deauthorizeIfConfigured(accountId: string, logContext: Record<string, unknown>) {
  const clientId = STRIPE_CONNECT_CLIENT_ID.value().trim();
  if (!clientId) {
    functions.logger.error('STRIPE_CONNECT_CLIENT_ID missing; cannot deauthorize', { accountId, ...logContext });
    return 'skipped' as const;
  }
  return deauthorizeConnectedAccount(getStripeClient(), clientId, accountId);
}

/**
 * Blank tenant PII for one offboarded facility. Saved payment-method records
 * are removed too: they hold the Stripe customer and payment-method ids that
 * only make sense while the platform can still reach the connected account.
 */
async function redactFacilityTenants(facilityId: string, reason: FacilityDisconnectReason): Promise<number> {
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  let redacted = 0;
  for (const sub of TENANT_SUBCOLLECTIONS) {
    const tenants = await facilityRef.collection(sub).get();
    for (const tenantDoc of tenants.docs) {
      if (tenantDoc.data().piiRedactedAt) continue;
      const batch = db.batch();
      batch.update(
        tenantDoc.ref,
        buildTenantPiiRedaction({ reason, now: admin.firestore.FieldValue.serverTimestamp() }),
      );
      const paymentMethods = await tenantDoc.ref.collection('paymentMethods').get();
      for (const pm of paymentMethods.docs) batch.delete(pm.ref);
      const billing = await tenantDoc.ref.collection('billing').get();
      for (const b of billing.docs) {
        batch.update(b.ref, {
          autopayEnabled: false,
          stripeSubscriptionId: null,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      redacted += 1;
    }
  }
  return redacted;
}

async function offboardCancelledFacility(facilityId: string): Promise<void> {
  const db = admin.firestore();
  const facilityRef = db.collection('facilities').doc(facilityId);
  const snap = await facilityRef.get();
  if (!snap.exists) return;
  const data = snap.data() || {};
  const accountId = (data.stripeConnectAccountId as string | undefined) || null;
  const reason: FacilityDisconnectReason = 'subscription_cancelled';

  let stripeResult: 'deauthorized' | 'already_disconnected' | 'skipped' = 'skipped';
  if (accountId) {
    stripeResult = await deauthorizeIfConfigured(accountId, { facilityId });
    if (stripeResult === 'skipped') {
      // Do not redact or mark offboarded while the platform still holds access;
      // the next sweep retries once the secret is configured.
      return;
    }
  }

  await facilityRef.update({
    ...buildFacilityDisconnectUpdate({
      accountId,
      reason,
      now: admin.firestore.FieldValue.serverTimestamp(),
    }),
    offboardedAt: admin.firestore.FieldValue.serverTimestamp(),
    offboardingReason: reason,
  });
  const redacted = await redactFacilityTenants(facilityId, reason);
  functions.logger.info('Facility offboarded', { facilityId, accountId, stripe: stripeResult, tenantsRedacted: redacted });
}

/**
 * Connected accounts created by this platform carry metadata.facilityId. Any
 * whose facility document is gone (client-side deletes bypass every function)
 * get detached so the platform key can no longer act on them.
 */
async function sweepOrphanedConnectedAccounts(): Promise<{ scanned: number; detached: number }> {
  const stripe = getStripeClient();
  const db = admin.firestore();
  let scanned = 0;
  let detached = 0;
  for await (const account of stripe.accounts.list({ limit: 100 })) {
    scanned += 1;
    if (scanned > MAX_CONNECTED_ACCOUNTS_PER_SWEEP) {
      functions.logger.warn('Orphan sweep stopped at cap; raise MAX_CONNECTED_ACCOUNTS_PER_SWEEP or paginate by cursor');
      break;
    }
    const facilityId = account.metadata?.facilityId;
    if (!facilityId) continue;
    const facilitySnap = await db.collection('facilities').doc(facilityId).get();
    if (!isOrphanedConnectedAccount(account, facilitySnap.exists)) continue;
    try {
      const result = await deauthorizeIfConfigured(account.id, { facilityId, orphan: true });
      if (result !== 'skipped') detached += 1;
      functions.logger.info('Orphaned connected account detached', { accountId: account.id, facilityId, result });
    } catch (error) {
      functions.logger.error('Failed to detach orphaned connected account', {
        accountId: account.id,
        facilityId,
        error: (error as Error).message,
      });
    }
  }
  return { scanned, detached };
}

/**
 * Daily: offboard facilities whose platform subscription has been cancelled
 * for the grace period (detach Stripe, blank tenant PII, drop saved cards),
 * and detach Connect accounts whose facility no longer exists.
 */
export const processFacilityOffboarding = functions
  .runWith({ secrets: STRIPE_SECRETS_WITH_CONNECT, timeoutSeconds: 540, memory: '512MB' })
  .pubsub.schedule('0 6 * * *') // Daily at 6:00 AM UTC
  .timeZone('UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const now = new Date();

    const cancelled = await db
      .collection('facilities')
      .where('platformSubscriptionStatus', '==', 'cancelled')
      .get();

    const candidates: OffboardingCandidate[] = cancelled.docs.map((doc) => {
      const data = doc.data();
      return {
        id: doc.id,
        platformSubscriptionStatus: data.platformSubscriptionStatus,
        platformSubscriptionCancelledAt: toDate(data.platformSubscriptionCancelledAt),
        offboardedAt: toDate(data.offboardedAt),
      };
    });
    const selection = selectFacilitiesForOffboarding(candidates, now);

    // Facilities cancelled before this job existed have no timestamp; start
    // their grace period today rather than offboarding them without warning.
    for (const facilityId of selection.needsClockStart) {
      await db.collection('facilities').doc(facilityId).update({
        platformSubscriptionCancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    let offboarded = 0;
    for (const facilityId of selection.due) {
      try {
        await offboardCancelledFacility(facilityId);
        offboarded += 1;
      } catch (error) {
        functions.logger.error('Facility offboarding failed', { facilityId, error: (error as Error).message });
      }
    }

    let orphans = { scanned: 0, detached: 0 };
    try {
      orphans = await sweepOrphanedConnectedAccounts();
    } catch (error) {
      functions.logger.error('Orphaned connected account sweep failed', { error: (error as Error).message });
    }

    functions.logger.info('Facility offboarding sweep complete', {
      cancelledFacilities: cancelled.size,
      clockStarted: selection.needsClockStart.length,
      waiting: selection.waiting.length,
      due: selection.due.length,
      offboarded,
      orphanAccountsScanned: orphans.scanned,
      orphanAccountsDetached: orphans.detached,
    });
    return null;
  });
