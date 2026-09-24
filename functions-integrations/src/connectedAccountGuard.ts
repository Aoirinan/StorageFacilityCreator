import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as Sentry from '@sentry/node';
import { STRIPE_WEBHOOK_REFUSALS_COLLECTION } from '@sfc/functions-shared';

/**
 * Refused money events from connected accounts are recorded in
 * [STRIPE_WEBHOOK_REFUSALS_COLLECTION], with what to do about each
 * (`action`). One document per account and Stripe object, so a dispute's
 * created/withdrawn/closed events share one row. Server-only: no app screen
 * lists it yet, so a super admin reads it in the Firebase console (the Sentry
 * alert for each refusal is what tells them to look), and
 * functions-admin/scripts/stripe-predeploy-check.cjs reports it read-only.
 */
export { STRIPE_WEBHOOK_REFUSALS_COLLECTION };

export type StripeRefusalReason = 'previous_account' | 'unknown_account' | 'facility_has_no_account';

/** Why [connectedAccountId] is not accepted for a facility stored as [facilityData]. */
export function refusalReasonFor(
  facilityData: Record<string, unknown>,
  connectedAccountId: string,
): StripeRefusalReason {
  const facilityAccount = facilityData.stripeConnectAccountId;
  if (facilityData.stripeConnectPreviousAccountId === connectedAccountId) return 'previous_account';
  return typeof facilityAccount === 'string' && facilityAccount ? 'unknown_account' : 'facility_has_no_account';
}

/**
 * Whether this deployment takes test-mode events from connected accounts.
 *
 * Stripe sends a connected account's test-mode events to live Connect
 * endpoints too, and anyone holding that account's test key makes them for
 * free: a test PaymentIntent credited a tenant on the live books. Production
 * refuses them. The emulator accepts them, and so does any deployment that
 * sets STRIPE_ACCEPT_TEST_MODE_EVENTS=true (a test-mode project, never the
 * live one).
 */
export function testModeConnectedEventsAccepted(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.STRIPE_ACCEPT_TEST_MODE_EVENTS === 'true' || env.FUNCTIONS_EMULATOR === 'true';
}

/**
 * True when [event] is a connected account's test-mode event this deployment
 * must not act on. Checked once, before dispatch, for every connected-account
 * event: payments, refunds, disputes, saved cards, failures, link checkouts
 * and account updates alike. Logged, not recorded: test-mode events are never
 * real money, and a durable row per event would let anyone fill the
 * refusals collection for free.
 */
export function refuseTestModeConnectedEvent(event: {
  id?: string;
  type?: string;
  account?: string | null;
  livemode?: boolean;
}): boolean {
  if (!event.account || event.livemode !== false) return false;
  if (testModeConnectedEventsAccepted()) return false;
  functions.logger.warn('Stripe test-mode event from a connected account ignored', {
    eventId: event.id ?? null,
    eventType: event.type ?? null,
    eventAccount: event.account,
  });
  return true;
}

/**
 * Whether a connected-account webhook event may touch [facilityId]'s records.
 *
 * Tenant payments, refunds, disputes, saved cards and failed payments name
 * their facility in the Stripe object's `metadata.facilityId`, but on a
 * Standard account the account owner can create one with any metadata they
 * like. Trusting it let one facility's owner credit, refund, dispute-charge
 * or re-point another facility's tenants. Only an event from the facility's
 * own connected account counts.
 *
 * Events without an account are the platform's own objects, which only this
 * platform's server can create, so they pass.
 *
 * A refusal is final: the webhook marks the event processed and Stripe does
 * not resend it. So it is logged and sent to Sentry, and a money event
 * (payment, refund, dispute, link checkout) is recorded in
 * [STRIPE_WEBHOOK_REFUSALS_COLLECTION] with what a super admin needs to post
 * a genuine one by hand. A facility's previous account is refused too: after
 * a reconnect, a late refund or dispute on the old account is real, but so is
 * a former owner who still controls that account, and only a person can tell
 * them apart. Those rows say so (`reason: 'previous_account'`).
 *
 * [record] false is for events that move no money (a saved card, a failed
 * payment, an account update): there is nothing to post by hand, and a row
 * per refusal would let any connected account fill the collection for free.
 */
export async function eventAccountMatchesFacility(params: {
  facilityId: string;
  connectedAccountId: string | null | undefined;
  eventType: string;
  objectId: string;
  eventId?: string;
  tenantId?: string | null;
  /** Dollars the event would have moved on the tenant's ledger, when known. */
  amount?: number | null;
  record?: boolean;
}): Promise<boolean> {
  const { facilityId, connectedAccountId, eventType, objectId } = params;
  if (!connectedAccountId) return true;

  const facilitySnap = await admin.firestore().collection('facilities').doc(facilityId).get();
  const facilityData = facilitySnap.exists ? (facilitySnap.data() as Record<string, unknown>) : {};
  const facilityAccount = facilityData.stripeConnectAccountId;
  if (typeof facilityAccount === 'string' && facilityAccount === connectedAccountId) {
    return true;
  }

  await recordStripeEventRefusal({
    reason: refusalReasonFor(facilityData, connectedAccountId),
    facilityId,
    facilityExists: facilitySnap.exists,
    facilityAccount: typeof facilityAccount === 'string' ? facilityAccount : null,
    connectedAccountId,
    eventType,
    objectId,
    eventId: params.eventId,
    tenantId: params.tenantId,
    amount: params.amount,
    record: params.record,
  });
  return false;
}

/** Event types only the platform's own Stripe account produces for this app. */
const PLATFORM_ONLY_EVENT_TYPES = new Set([
  'customer.subscription.created',
  'customer.subscription.updated',
  'customer.subscription.deleted',
  'invoice.payment_succeeded',
  'invoice.payment_failed',
]);

/**
 * True when a platform-only event arrives from a connected account, which
 * this deployment must not act on.
 *
 * Owner subscriptions and their invoices live on the platform account, and
 * their handlers trust the subscription's metadata (accountId, facilityId).
 * The Connect endpoint does not subscribe to these types today, but nothing
 * stopped one from a connected account reaching those handlers if it ever
 * did. Logged and sent to Sentry, not recorded: no tenant money moves.
 */
export function refusePlatformOnlyEventFromConnectedAccount(event: {
  id?: string;
  type?: string;
  account?: string | null;
}): boolean {
  if (!event.account || !PLATFORM_ONLY_EVENT_TYPES.has(event.type ?? '')) return false;
  const detail = { eventId: event.id ?? null, eventType: event.type ?? null, eventAccount: event.account };
  functions.logger.error('Platform-only Stripe event from a connected account ignored', detail);
  if (process.env.SENTRY_DSN) {
    Sentry.captureMessage('Platform-only Stripe event from a connected account', {
      level: 'error',
      tags: { function: 'stripeWebhook', check: 'platform_only' },
      extra: detail,
    });
  }
  return true;
}

/** What a super admin should do about a refusal, in plain words. */
export function refusalAction(reason: StripeRefusalReason): string {
  switch (reason) {
    case 'previous_account':
      return (
        "From the facility's previous Stripe account (it has since reconnected). " +
        'If it is genuine, post it on the tenant ledger by hand; Stripe will not send it again.'
      );
    case 'facility_has_no_account':
      return (
        'The facility has no Stripe account connected now. If it was disconnected recently and ' +
        'this is genuine, post it on the tenant ledger by hand; otherwise treat it as forged.'
      );
    case 'unknown_account':
    default:
      return (
        'Not from any Stripe account this facility is known to use: likely another account ' +
        "copying this facility's ids. Nothing to post unless the owner confirms the account is theirs."
      );
  }
}

/**
 * Logs a refused event, reports it to Sentry, and (unless [record] is false)
 * records it for a super admin. Recording is best effort: a failed write must
 * not turn a refusal into a 500 that Stripe retries for days.
 */
export async function recordStripeEventRefusal(params: {
  reason: StripeRefusalReason;
  facilityId: string;
  facilityExists: boolean;
  facilityAccount: string | null;
  connectedAccountId: string;
  eventType: string;
  objectId: string;
  eventId?: string;
  tenantId?: string | null;
  amount?: number | null;
  record?: boolean;
}): Promise<void> {
  const detail = {
    reason: params.reason,
    eventType: params.eventType,
    eventId: params.eventId ?? null,
    objectId: params.objectId,
    facilityId: params.facilityId,
    tenantId: params.tenantId ?? null,
    eventAccount: params.connectedAccountId,
    facilityAccount: params.facilityAccount,
    facilityExists: params.facilityExists,
  };
  functions.logger.error("Stripe event refused: its connected account is not the facility's", detail);
  if (process.env.SENTRY_DSN) {
    Sentry.captureMessage("Stripe event from a connected account that is not the facility's", {
      level: 'error',
      tags: { function: 'stripeWebhook', check: 'connected_account', reason: params.reason },
      extra: detail,
    });
  }

  if (params.record === false) return;

  const now = admin.firestore.FieldValue.serverTimestamp();
  const docId = `${params.connectedAccountId}__${params.objectId}`;
  try {
    await admin
      .firestore()
      .collection(STRIPE_WEBHOOK_REFUSALS_COLLECTION)
      .doc(docId)
      .set(
        {
          ...detail,
          amount: typeof params.amount === 'number' && Number.isFinite(params.amount) ? params.amount : null,
          action: refusalAction(params.reason),
          eventTypes: admin.firestore.FieldValue.arrayUnion(params.eventType),
          ...(params.eventId ? { eventIds: admin.firestore.FieldValue.arrayUnion(params.eventId) } : {}),
          refusals: admin.firestore.FieldValue.increment(1),
          // A new event on a row someone closed reopens it: it is new information.
          resolved: false,
          lastRefusedAt: now,
        },
        { merge: true },
      );
  } catch (error) {
    functions.logger.error('Could not record the refused Stripe event', {
      ...detail,
      error: (error as Error)?.message ?? String(error),
    });
  }
}
