import * as admin from 'firebase-admin';
import type Stripe from 'stripe';

/**
 * Public payment links (`publicPaymentLinks/{token}`): marking a link paid
 * once its Stripe Checkout Session has been paid.
 *
 * Three callers reach this, in any order and any number of times: the
 * `checkout.session.completed` webhook, the tenant's success page
 * (`confirmPublicPaymentCheckout`), and `createPublicPaymentCheckout` when it
 * finds the link's last session already complete. All of them converge on one
 * transaction that moves the link from pending to paid exactly once.
 *
 * This deliberately never writes `payments` or `ledgers`. The money is
 * recorded by the `payment_intent.succeeded` handler in functions-integrations,
 * keyed on the PaymentIntent (`ledgers/payment_{pi}`), because the session's
 * PaymentIntent carries `buildPublicLinkPaymentIntentMetadata`. Recording it
 * here as well would be a second writer racing the first.
 *
 * A payment the link cannot absorb (a second payment on a paid link, a payment
 * on a revoked link, a wrong amount) becomes an exception record plus an in-app
 * notification for the facility. Nothing is ever refunded automatically.
 */

export const PUBLIC_PAYMENT_LINKS_COLLECTION = 'publicPaymentLinks';
export const PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION = 'publicPaymentLinkExceptions';
/** `metadata.type` on both the Checkout Session and its PaymentIntent. */
export const PUBLIC_LINK_PAYMENT_TYPE = 'public_payment_link';
/** `metadata.sfcKind` on the PaymentIntent: a tenant payment taken through a link. */
export const PUBLIC_LINK_SFC_KIND = 'tenant_link';

const TOKEN_PATTERN = /^[A-Za-z0-9_-]{24,128}$/;

/**
 * Metadata for `payment_intent_data.metadata`. Checkout does not copy the
 * session's metadata onto the PaymentIntent, and the payment handler keys on
 * the PaymentIntent's `facilityId`/`tenantId`: without these a paid link is
 * never recorded (the bug this module exists to fix).
 */
export function buildPublicLinkPaymentIntentMetadata(
  facilityId: string,
  tenantId: string,
  token: string,
): Record<string, string> {
  return {
    facilityId,
    tenantId,
    type: PUBLIC_LINK_PAYMENT_TYPE,
    paymentLinkToken: token,
    sfcKind: PUBLIC_LINK_SFC_KIND,
  };
}

export function isPublicLinkCheckoutSession(
  session: { metadata?: Stripe.Metadata | null } | null | undefined,
): boolean {
  return session?.metadata?.type === PUBLIC_LINK_PAYMENT_TYPE;
}

export function isPublicLinkPaymentIntent(
  paymentIntent: { metadata?: Stripe.Metadata | null } | null | undefined,
): boolean {
  return (
    paymentIntent?.metadata?.sfcKind === PUBLIC_LINK_SFC_KIND ||
    paymentIntent?.metadata?.type === PUBLIC_LINK_PAYMENT_TYPE
  );
}

/** A link's `amount` (dollars) in cents, or null when it is not a usable amount. */
export function publicLinkAmountCents(amount: unknown): number | null {
  if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0) return null;
  return Math.round(amount * 100);
}

export function publicLinkNotificationId(checkoutSessionId: string): string {
  return `publicLinkException_${checkoutSessionId}`;
}

export type PublicLinkExceptionReason =
  | 'duplicate_payment'
  | 'paid_after_revoke'
  | 'link_not_payable'
  | 'amount_mismatch'
  | 'untracked_session';

export type PublicLinkCompletionSource = 'webhook' | 'confirm' | 'checkout';

export type CompletePublicLinkPaymentResult = {
  /**
   * marked_paid: this call moved the link to paid.
   * already_paid: the link was already paid by this same PaymentIntent.
   * exception: the payment could not be applied to the link; an exception was recorded (or already existed).
   * not_paid: the session has not been paid; nothing written.
   * rejected: the session does not belong to this link/facility/account; nothing written.
   */
  outcome: 'marked_paid' | 'already_paid' | 'exception' | 'not_paid' | 'rejected';
  linkStatus: string | null;
  exceptionReason?: PublicLinkExceptionReason;
  rejectReason?: string;
};

export type PublicLinkCheckoutSessionLike = {
  id: string;
  payment_status?: Stripe.Checkout.Session.PaymentStatus | string | null;
  amount_total?: number | null;
  currency?: string | null;
  metadata?: Stripe.Metadata | null;
  payment_intent?: string | { id: string } | null;
  livemode?: boolean;
};

function paymentIntentIdOf(session: PublicLinkCheckoutSessionLike): string | null {
  const raw = session.payment_intent;
  if (!raw) return null;
  return typeof raw === 'string' ? raw : raw.id || null;
}

function formatDollars(cents: number | null | undefined): string {
  return `$${((cents ?? 0) / 100).toFixed(2)}`;
}

function exceptionMessage(
  reason: PublicLinkExceptionReason,
  paidCents: number | null | undefined,
  linkCents: number | null,
): string {
  const paid = formatDollars(paidCents);
  switch (reason) {
    case 'duplicate_payment':
      return (
        `A second payment of ${paid} was made on a payment link that was already paid, ` +
        'so the tenant has paid twice. Both payments post to the tenant ledger; ' +
        'refund one in Stripe if it was not intended.'
      );
    case 'paid_after_revoke':
      return (
        `A payment of ${paid} was made on a payment link that had been revoked. ` +
        'It posts to the tenant ledger; refund it in Stripe if it was not intended.'
      );
    case 'amount_mismatch':
      return (
        `A payment of ${paid} was made on a payment link for ${formatDollars(linkCents)}. ` +
        'The link was not marked paid. Check the tenant ledger and Stripe.'
      );
    case 'untracked_session':
      return (
        `A payment of ${paid} was made on a payment link checkout started before payment ` +
        'links recorded payments automatically. Check the tenant ledger shows it, and record it if not.'
      );
    case 'link_not_payable':
    default:
      return (
        `A payment of ${paid} was made on a payment link that was no longer active. ` +
        'Check the tenant ledger and Stripe, and refund it if it was not intended.'
      );
  }
}

function rejected(rejectReason: string, linkStatus: string | null = null): CompletePublicLinkPaymentResult {
  return { outcome: 'rejected', linkStatus, rejectReason };
}

/**
 * Apply a paid public-link Checkout Session to its link. Idempotent and safe
 * to race: every path runs in one Firestore transaction on the link.
 *
 * [connectedAccountId] is the account the session was read from (the
 * webhook's `event.account`, or the account the confirm callable retrieved it
 * on). It must equal the facility's `stripeConnectAccountId`: a session on any
 * other account is someone else's money carrying copied metadata.
 *
 * Throws on Firestore failure so a webhook caller returns 500 and Stripe
 * retries, instead of the event being marked processed with nothing done.
 */
export async function completePublicLinkPayment(params: {
  db: admin.firestore.Firestore;
  session: PublicLinkCheckoutSessionLike;
  connectedAccountId: string | null | undefined;
  source: PublicLinkCompletionSource;
  now?: Date;
}): Promise<CompletePublicLinkPaymentResult> {
  const { db, session, connectedAccountId, source } = params;
  const now = params.now ?? new Date();
  const metadata = session.metadata || {};
  const token = metadata.paymentLinkToken;

  if (!isPublicLinkCheckoutSession(session) || !token || !TOKEN_PATTERN.test(token) || !session.id) {
    return rejected('not_a_payment_link_session');
  }
  if (!connectedAccountId) {
    // Link sessions are only ever created on the facility's connected account.
    return rejected('no_connected_account');
  }
  if (session.payment_status !== 'paid') {
    return { outcome: 'not_paid', linkStatus: null };
  }
  const paymentIntentId = paymentIntentIdOf(session);
  if (!paymentIntentId) {
    return rejected('no_payment_intent');
  }

  const linkRef = db.collection(PUBLIC_PAYMENT_LINKS_COLLECTION).doc(token);
  const timestamp = admin.firestore.Timestamp.fromDate(now);

  return db.runTransaction(async (tx) => {
    const linkSnap = await tx.get(linkRef);
    if (!linkSnap.exists) return rejected('link_not_found');
    const link = linkSnap.data() as Record<string, unknown>;
    const facilityId = typeof link.facilityId === 'string' ? link.facilityId : '';
    const tenantId = typeof link.tenantId === 'string' ? link.tenantId : '';
    const status = String(link.status || 'pending');

    if (!facilityId || facilityId !== metadata.facilityId || tenantId !== metadata.tenantId) {
      return rejected('metadata_mismatch', status);
    }

    const facilityRef = db.collection('facilities').doc(facilityId);
    const facilitySnap = await tx.get(facilityRef);
    const facilityAccount = facilitySnap.exists
      ? (facilitySnap.data() as Record<string, unknown>).stripeConnectAccountId
      : null;
    if (typeof facilityAccount !== 'string' || facilityAccount !== connectedAccountId) {
      return rejected('account_mismatch', status);
    }

    if (status === 'paid' && link.paymentIntentId === paymentIntentId) {
      return { outcome: 'already_paid', linkStatus: 'paid' } as CompletePublicLinkPaymentResult;
    }

    const linkCents = publicLinkAmountCents(link.amount);
    const amountMatches =
      linkCents !== null &&
      session.amount_total === linkCents &&
      String(session.currency || '').toLowerCase() === 'usd';
    const sessionIds = Array.isArray(link.checkoutSessionIds)
      ? (link.checkoutSessionIds as unknown[]).filter((id): id is string => typeof id === 'string')
      : [];
    const tracked = sessionIds.includes(session.id);

    let markPaid = false;
    let reason: PublicLinkExceptionReason | undefined;
    if (status === 'paid') {
      reason = 'duplicate_payment';
    } else if (status === 'pending') {
      // A pending link past its expiresAt is still marked paid: a session can
      // only be created while the link is live, and this money was taken for it.
      if (!amountMatches) {
        reason = 'amount_mismatch';
      } else {
        markPaid = true;
        // Sessions created before the fix carry no PaymentIntent metadata, so
        // the payment handler could not post them: flag them for a check.
        if (!tracked) reason = 'untracked_session';
      }
    } else if (status === 'revoked') {
      reason = 'paid_after_revoke';
    } else {
      reason = 'link_not_payable';
    }

    // Reads first (Firestore requires every read before any write).
    const exceptionRef = db.collection(PUBLIC_PAYMENT_LINK_EXCEPTIONS_COLLECTION).doc(session.id);
    let writeException = false;
    let tenantName: string | null = null;
    if (reason) {
      const exceptionSnap = await tx.get(exceptionRef);
      writeException = !exceptionSnap.exists;
      if (writeException && tenantId) {
        const tenantSnap = await tx.get(facilityRef.collection('tenants').doc(tenantId));
        const name = tenantSnap.exists ? (tenantSnap.data() as Record<string, unknown>).name : null;
        tenantName = typeof name === 'string' && name.trim() ? name.trim() : null;
      }
    }

    if (markPaid) {
      tx.update(linkRef, {
        status: 'paid',
        paymentIntentId,
        checkoutSessionId: session.id,
        checkoutSessionIds: tracked ? sessionIds : [...sessionIds, session.id],
        paidAt: timestamp,
        paidVia: source,
        amountPaidCents: session.amount_total ?? null,
        updatedAt: timestamp,
      });
    }

    if (reason && writeException) {
      const message = exceptionMessage(reason, session.amount_total, linkCents);
      tx.create(exceptionRef, {
        facilityId,
        tenantId,
        paymentLinkToken: token,
        reason,
        message,
        checkoutSessionId: session.id,
        paymentIntentId,
        amountCents: session.amount_total ?? null,
        currency: session.currency || null,
        linkAmountCents: linkCents,
        linkStatus: status,
        linkPaymentIntentId: typeof link.paymentIntentId === 'string' ? link.paymentIntentId : null,
        connectedAccountId,
        livemode: session.livemode ?? null,
        source,
        resolution: 'open',
        createdAt: timestamp,
      });
      // Facility staff read Notifications in the app; the exception collection
      // itself is server-only. Deterministic id: redelivery does not repeat it.
      tx.set(facilityRef.collection('Notifications').doc(publicLinkNotificationId(session.id)), {
        facilityId,
        tenantId,
        tenantName,
        type: 'STRIPE_ACTION_REQUIRED',
        message,
        readAt: null,
        createdAt: timestamp,
        createdBy: 'system@public-payment-link',
        metadata: {
          reason,
          checkoutSessionId: session.id,
          paymentIntentId,
          amountCents: session.amount_total ?? null,
        },
      });
    }

    const result: CompletePublicLinkPaymentResult = {
      outcome: markPaid ? 'marked_paid' : reason ? 'exception' : 'already_paid',
      linkStatus: markPaid ? 'paid' : status,
    };
    if (reason) result.exceptionReason = reason;
    return result;
  });
}
