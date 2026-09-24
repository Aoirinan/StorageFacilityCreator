import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as Sentry from '@sentry/node';

/**
 * Whether a connected-account webhook event may touch [facilityId]'s records.
 *
 * Tenant payments, refunds and disputes name their facility in the
 * PaymentIntent's `metadata.facilityId`, but on a Standard account the account
 * owner can create a PaymentIntent (or a test-mode one, which a live Connect
 * endpoint also receives) with any metadata they like. Trusting it let one
 * facility's owner credit, refund or dispute-charge another facility's
 * tenants. Only an event from the facility's own connected account counts.
 *
 * Events without an account are the platform's own objects, which only this
 * platform's server can create, so they pass.
 *
 * A refusal is final (Stripe redelivering it would be refused again), so it
 * is logged and sent to Sentry instead of thrown.
 */
export async function eventAccountMatchesFacility(params: {
  facilityId: string;
  connectedAccountId: string | null | undefined;
  eventType: string;
  objectId: string;
}): Promise<boolean> {
  const { facilityId, connectedAccountId, eventType, objectId } = params;
  if (!connectedAccountId) return true;

  const facilitySnap = await admin.firestore().collection('facilities').doc(facilityId).get();
  const facilityAccount = facilitySnap.exists
    ? (facilitySnap.data() as Record<string, unknown>).stripeConnectAccountId
    : null;
  if (typeof facilityAccount === 'string' && facilityAccount === connectedAccountId) {
    return true;
  }

  const detail = {
    eventType,
    objectId,
    facilityId,
    eventAccount: connectedAccountId,
    facilityAccount: typeof facilityAccount === 'string' ? facilityAccount : null,
    facilityExists: facilitySnap.exists,
  };
  functions.logger.error('Stripe event refused: its connected account is not the facility\'s', detail);
  if (process.env.SENTRY_DSN) {
    Sentry.captureMessage('Stripe event from a connected account that is not the facility\'s', {
      level: 'error',
      tags: { function: 'stripeWebhook', check: 'connected_account' },
      extra: detail,
    });
  }
  return false;
}
