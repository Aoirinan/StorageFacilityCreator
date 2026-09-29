import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  buildPublicLinkPaymentIntentMetadata,
  checkDisputeForPayment,
  completePublicLinkPayment,
  PUBLIC_LINK_PAYMENT_TYPE,
  PUBLIC_PAYMENT_LINKS_COLLECTION,
} from '@sfc/functions-shared';

/**
 * Checkout for public payment links, one open Stripe session per link.
 *
 * Before this, every "Pay Now" created a new session, none were recorded, and
 * the link stayed pending forever, so a tenant could pay the same link as many
 * times as they clicked. Now:
 *
 * - The link remembers its current session (`checkoutSessionId`, all of them in
 *   `checkoutSessionIds`) and an attempt counter (`checkoutAttempt`,
 *   `checkoutExpiresAt`), reserved in a transaction.
 * - A still-open session is handed back instead of a new one. A new one is only
 *   made once the last has expired (and never while it could still be paid).
 * - Each attempt's session is created with `idempotencyKey link_{token}_{n}`
 *   and parameters fixed by the reservation, so two requests racing for the
 *   same attempt get the same session back from Stripe.
 * - A completed session found on the way marks the link paid (the same code
 *   the webhook runs) and no new checkout is offered.
 * - A facility that reconnected a different Stripe account has the link's
 *   session looked up on its previous account too: one still open there is
 *   expired, and one paid there stops a second payment.
 * - A link sent to collect a card dispute is checked against the dispute
 *   again before any session is handed out: once the dispute is won, voided
 *   or paid another way, the link is no longer due.
 */

/** Stripe's minimum is 30 minutes; the margin absorbs clock skew. */
export const CHECKOUT_SESSION_TTL_SECONDS = 45 * 60;
/** An open session with less than this left is expired and replaced rather than handed out. */
export const REUSE_MIN_REMAINING_MS = 2 * 60 * 1000;
/**
 * A reservation whose session was never stored is joined only while this much
 * of it is left. Joining re-sends its `expires_at`, and when the first request
 * never reached Stripe that is a fresh create, which Stripe refuses unless
 * expires_at is at least 30 minutes away; the extra minute absorbs clock skew.
 */
export const JOIN_MIN_REMAINING_MS = 31 * 60 * 1000;

const MAX_PASSES = 4;

export type CheckoutSessionsApi = {
  create(
    params: Stripe.Checkout.SessionCreateParams,
    options: Stripe.RequestOptions,
  ): Promise<Stripe.Checkout.Session>;
  retrieve(
    id: string,
    params: Stripe.Checkout.SessionRetrieveParams,
    options: Stripe.RequestOptions,
  ): Promise<Stripe.Checkout.Session>;
  expire(
    id: string,
    params: Stripe.Checkout.SessionExpireParams,
    options: Stripe.RequestOptions,
  ): Promise<Stripe.Checkout.Session>;
};

export type PublicLinkCheckoutDeps = {
  db: admin.firestore.Firestore;
  sessions: CheckoutSessionsApi;
  appUrl: string;
  now?: () => Date;
};

export type PublicLinkCheckoutResult =
  | { kind: 'checkout'; checkoutUrl: string; sessionId: string; reused: boolean }
  | { kind: 'paid' };

export function publicLinkIdempotencyKey(token: string, attempt: number): string {
  return `link_${token}_${attempt}`;
}

export function buildPublicLinkCheckoutSessionParams(input: {
  token: string;
  facilityId: string;
  tenantId: string;
  amount: number;
  description: string;
  facilityName: string;
  tenantEmail?: string | null;
  appUrl: string;
  expiresAtSeconds: number;
  /** The card dispute this link collects, when staff sent it for one. */
  disputeId?: string | null;
}): Stripe.Checkout.SessionCreateParams {
  const facilityName = input.facilityName || 'Facility';
  const email = typeof input.tenantEmail === 'string' ? input.tenantEmail.trim() : '';
  return {
    mode: 'payment',
    payment_method_types: ['card'],
    line_items: [
      {
        price_data: {
          currency: 'usd',
          product_data: {
            name: input.description || `Payment for ${facilityName}`,
            description: `Payment for ${facilityName}`,
          },
          unit_amount: Math.round(input.amount * 100),
        },
        quantity: 1,
      },
    ],
    // Stripe rejects an empty customer_email outright.
    ...(email ? { customer_email: email } : {}),
    // Hash route, query before the hash: a path-style /pay?token=… has no
    // route and lands the tenant on the facility-manager login after paying.
    // The payment page reads status/session_id from the query to confirm.
    success_url: `${input.appUrl}/?status=success&session_id={CHECKOUT_SESSION_ID}#/pay?token=${input.token}`,
    cancel_url: `${input.appUrl}/?status=cancel#/pay?token=${input.token}`,
    // Short-lived so a revoked link cannot be paid for long on a session
    // opened before it was revoked.
    expires_at: input.expiresAtSeconds,
    metadata: {
      facilityId: input.facilityId,
      tenantId: input.tenantId,
      type: PUBLIC_LINK_PAYMENT_TYPE,
      paymentLinkToken: input.token,
    },
    // Checkout does not copy session metadata onto the PaymentIntent, and the
    // payment_intent.succeeded handler keys on the PaymentIntent's. Without
    // this, a paid link was never recorded on the tenant ledger.
    payment_intent_data: {
      metadata: buildPublicLinkPaymentIntentMetadata(input.facilityId, input.tenantId, input.token, input.disputeId),
    },
  };
}

type LinkState = {
  status: string;
  facilityId: string;
  tenantId: string;
  amount: number;
  description: string;
  expiresAt: admin.firestore.Timestamp | null;
  checkoutSessionId: string | null;
  checkoutAttempt: number;
  checkoutExpiresAtMs: number | null;
  checkoutSessionIds: string[];
  disputeId: string | null;
};

function readLinkState(data: Record<string, unknown>): LinkState {
  const expiresAt = data.expiresAt instanceof admin.firestore.Timestamp ? data.expiresAt : null;
  const checkoutExpiresAt = data.checkoutExpiresAt instanceof admin.firestore.Timestamp
    ? data.checkoutExpiresAt
    : null;
  return {
    status: String(data.status || 'pending'),
    facilityId: typeof data.facilityId === 'string' ? data.facilityId : '',
    tenantId: typeof data.tenantId === 'string' ? data.tenantId : '',
    amount: typeof data.amount === 'number' ? data.amount : NaN,
    description: typeof data.description === 'string' ? data.description : 'Payment',
    expiresAt,
    checkoutSessionId: typeof data.checkoutSessionId === 'string' && data.checkoutSessionId
      ? data.checkoutSessionId
      : null,
    checkoutAttempt: typeof data.checkoutAttempt === 'number' ? data.checkoutAttempt : 0,
    checkoutExpiresAtMs: checkoutExpiresAt ? checkoutExpiresAt.toMillis() : null,
    checkoutSessionIds: Array.isArray(data.checkoutSessionIds)
      ? (data.checkoutSessionIds as unknown[]).filter((id): id is string => typeof id === 'string')
      : [],
    disputeId: typeof data.disputeId === 'string' && data.disputeId ? data.disputeId : null,
  };
}

function assertPayable(link: LinkState, now: Date): void {
  if (link.status !== 'pending') {
    throw new functions.https.HttpsError('failed-precondition', 'Payment link is no longer active');
  }
  if (link.expiresAt && link.expiresAt.toDate() < now) {
    throw new functions.https.HttpsError('failed-precondition', 'Payment link has expired');
  }
  if (!Number.isFinite(link.amount) || link.amount <= 0) {
    throw new functions.https.HttpsError('failed-precondition', 'Payment link has no valid amount');
  }
}

async function loadFacilityAccount(
  db: admin.firestore.Firestore,
  facilityId: string,
  options: { requireOnboarded: boolean },
): Promise<{ connectAccountId: string; previousAccountId: string | null; facilityName: string }> {
  const facilityDoc = await db.collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facility = facilityDoc.data() as Record<string, unknown>;
  const connectAccountId = facility.stripeConnectAccountId;
  if (
    typeof connectAccountId !== 'string' ||
    !connectAccountId ||
    (options.requireOnboarded && !facility.stripeConnectOnboardingComplete)
  ) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Facility owner must complete Stripe Connect onboarding before accepting payments',
    );
  }
  const previous = facility.stripeConnectPreviousAccountId;
  return {
    connectAccountId,
    previousAccountId: typeof previous === 'string' && previous && previous !== connectAccountId ? previous : null,
    facilityName: typeof facility.name === 'string' ? facility.name : 'Facility',
  };
}

/** Stripe says the object does not exist (on this account), as opposed to failing to answer. */
function isStripeResourceMissing(error: unknown): boolean {
  const e = error as { statusCode?: number; code?: string } | null;
  return e?.statusCode === 404 || e?.code === 'resource_missing';
}

/**
 * The link's stored session and the account it is on: the facility's
 * account, else the one it was connected to before (a link started before a
 * reconnect has its session there). Null when neither has it: nothing can
 * pay it, so a new attempt is the right answer.
 *
 * Looked up only on the current account, a session on the old one read as
 * missing: a new checkout was opened while the old one could still be paid,
 * or had been paid with the link not yet marked, and the tenant paid twice.
 */
async function findLinkSession(
  sessions: CheckoutSessionsApi,
  sessionId: string,
  accounts: { current: string; previous: string | null },
): Promise<{ session: Stripe.Checkout.Session; account: string } | null> {
  for (const account of [accounts.current, accounts.previous]) {
    if (!account) continue;
    try {
      return { session: await sessions.retrieve(sessionId, {}, { stripeAccount: account }), account };
    } catch (error) {
      if (!isStripeResourceMissing(error)) throw error;
    }
  }
  functions.logger.warn("Payment-link session is on none of the facility's Stripe accounts; starting a new one", {
    sessionId,
  });
  return null;
}

/** What the tenant is told when a dispute link is no longer due. */
export const DISPUTE_LINK_NOT_DUE_MESSAGE =
  'This payment is no longer due. Please contact the facility if you have questions.';

/**
 * Hand the tenant a checkout for [token]: the link's open session when there
 * is one, otherwise a new one. Returns `{kind:'paid'}` when the link turns out
 * to be paid already.
 */
export async function getOrCreatePublicLinkCheckout(
  token: string,
  deps: PublicLinkCheckoutDeps,
): Promise<PublicLinkCheckoutResult> {
  const { db, sessions } = deps;
  const clock = deps.now ?? (() => new Date());
  const linkRef = db.collection(PUBLIC_PAYMENT_LINKS_COLLECTION).doc(token);

  for (let pass = 0; pass < MAX_PASSES; pass++) {
    const linkSnap = await linkRef.get();
    if (!linkSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Payment link not found');
    }
    const link = readLinkState(linkSnap.data() as Record<string, unknown>);
    if (link.status === 'paid') return { kind: 'paid' };
    assertPayable(link, clock());

    const { connectAccountId, previousAccountId, facilityName } = await loadFacilityAccount(db, link.facilityId, {
      requireOnboarded: true,
    });
    const requestOptions: Stripe.RequestOptions = { stripeAccount: connectAccountId };
    const tenantDoc = await db
      .collection('facilities')
      .doc(link.facilityId)
      .collection('tenants')
      .doc(link.tenantId)
      .get();
    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }
    const tenantEmail = (tenantDoc.data() as Record<string, unknown>).email;

    // 1. The link's current session, if it has one.
    const found = link.checkoutSessionId
      ? await findLinkSession(sessions, link.checkoutSessionId, { current: connectAccountId, previous: previousAccountId })
      : null;
    const current = found?.session ?? null;
    const onCurrentAccount = found?.account === connectAccountId;
    if (current?.status === 'complete') {
      if (!onCurrentAccount) {
        // Paid on the facility's old account: the webhook refuses it (a
        // super admin reviews stripeWebhookRefusals), and it must not be
        // paid again here meanwhile.
        functions.logger.error("Payment-link session was completed on the facility's previous Stripe account", {
          sessionId: current.id,
        });
        throw new functions.https.HttpsError(
          'failed-precondition',
          'A payment on this link is already being processed.',
        );
      }
      const completion = await completePublicLinkPayment({
        db,
        session: current,
        connectedAccountId: connectAccountId,
        source: 'checkout',
        now: clock(),
      });
      if (completion.linkStatus === 'paid') return { kind: 'paid' };
      // Paid but not applicable (e.g. amount mismatch, already flagged), or
      // not yet settled: either way, do not offer another payment.
      throw new functions.https.HttpsError(
        'failed-precondition',
        'A payment on this link is already being processed.',
      );
    }

    // A dispute link was checked when staff made it; the dispute may have
    // been won, voided or paid another way since. Paid again after that, the
    // tenant had paid it twice.
    if (link.disputeId) {
      const dispute = await checkDisputeForPayment(db, link.facilityId, link.tenantId, link.disputeId, link.amount);
      if (!dispute.ok) {
        if (found && found.session.status === 'open') {
          try {
            await sessions.expire(found.session.id, {}, { stripeAccount: found.account });
          } catch (error) {
            functions.logger.warn('Could not expire the session of a dispute link that is no longer due', {
              sessionId: found.session.id,
              error: (error as Error)?.message,
            });
          }
        }
        functions.logger.info('Dispute payment link is no longer due', { reason: dispute.reason });
        throw new functions.https.HttpsError('failed-precondition', DISPUTE_LINK_NOT_DUE_MESSAGE);
      }
    }

    if (found && found.session.status === 'open') {
      const open = found.session;
      const remainingMs = (open.expires_at ?? 0) * 1000 - clock().getTime();
      // Only a session on the facility's own account is handed back: one on
      // the old account would pay the old account.
      if (onCurrentAccount && remainingMs > REUSE_MIN_REMAINING_MS && open.url) {
        return { kind: 'checkout', checkoutUrl: open.url, sessionId: open.id, reused: true };
      }
      // About to lapse, or on the old account: close it first so it cannot be
      // paid alongside its replacement.
      try {
        await sessions.expire(open.id, {}, { stripeAccount: found.account });
      } catch (error) {
        functions.logger.warn('Could not expire a lapsing or superseded payment-link session; re-checking', {
          sessionId: open.id,
          error: (error as Error)?.message,
        });
        continue;
      }
    }
    // Expired (or just expired above), or none: fall through to a new attempt.

    // 2. Reserve the next attempt, or join one another request reserved.
    const now = clock();
    const reservation = await db.runTransaction(async (tx) => {
      const snap = await tx.get(linkRef);
      if (!snap.exists) return null;
      const latest = readLinkState(snap.data() as Record<string, unknown>);
      if (
        latest.status !== link.status ||
        latest.checkoutSessionId !== link.checkoutSessionId ||
        latest.checkoutAttempt !== link.checkoutAttempt
      ) {
        return null; // Moved on since we looked: start over.
      }
      if (
        !latest.checkoutSessionId &&
        latest.checkoutAttempt > 0 &&
        latest.checkoutExpiresAtMs !== null &&
        latest.checkoutExpiresAtMs - now.getTime() > JOIN_MIN_REMAINING_MS
      ) {
        return { attempt: latest.checkoutAttempt, expiresAtSeconds: Math.floor(latest.checkoutExpiresAtMs / 1000) };
      }
      const attempt = latest.checkoutAttempt + 1;
      const expiresAtSeconds = Math.floor(now.getTime() / 1000) + CHECKOUT_SESSION_TTL_SECONDS;
      tx.update(linkRef, {
        checkoutAttempt: attempt,
        checkoutExpiresAt: admin.firestore.Timestamp.fromMillis(expiresAtSeconds * 1000),
        checkoutSessionId: null,
        updatedAt: admin.firestore.Timestamp.fromDate(now),
      });
      return { attempt, expiresAtSeconds };
    });
    if (!reservation) continue;

    // 3. Create the attempt's session. Same key + same parameters = same session.
    const params = buildPublicLinkCheckoutSessionParams({
      token,
      facilityId: link.facilityId,
      tenantId: link.tenantId,
      amount: link.amount,
      description: link.description,
      facilityName,
      tenantEmail: typeof tenantEmail === 'string' ? tenantEmail : null,
      appUrl: deps.appUrl,
      expiresAtSeconds: reservation.expiresAtSeconds,
      disputeId: link.disputeId,
    });

    let created: Stripe.Checkout.Session;
    try {
      created = await sessions.create(params, {
        ...requestOptions,
        idempotencyKey: publicLinkIdempotencyKey(token, reservation.attempt),
      });
    } catch (error) {
      // Stripe remembers a failed request against its key, so this attempt
      // would fail the same way forever. Retire it; the next click starts a new one.
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(linkRef);
        const latest = snap.exists ? readLinkState(snap.data() as Record<string, unknown>) : null;
        if (latest && latest.checkoutAttempt === reservation.attempt && !latest.checkoutSessionId) {
          tx.update(linkRef, {
            checkoutExpiresAt: admin.firestore.Timestamp.fromDate(clock()),
            updatedAt: admin.firestore.Timestamp.fromDate(clock()),
          });
        }
      });
      throw error;
    }

    // 4. Record it as the link's current session.
    const stored = await db.runTransaction(async (tx) => {
      const snap = await tx.get(linkRef);
      if (!snap.exists) return false;
      const latest = readLinkState(snap.data() as Record<string, unknown>);
      const isCurrent =
        latest.checkoutAttempt === reservation.attempt &&
        (latest.checkoutSessionId === null || latest.checkoutSessionId === created.id);
      tx.update(linkRef, {
        checkoutSessionIds: latest.checkoutSessionIds.includes(created.id)
          ? latest.checkoutSessionIds
          : [...latest.checkoutSessionIds, created.id],
        ...(isCurrent ? { checkoutSessionId: created.id } : {}),
        updatedAt: admin.firestore.Timestamp.fromDate(clock()),
      });
      return isCurrent && latest.status === 'pending';
    });
    if (!stored) {
      // A newer attempt (or a payment, or a revoke) overtook this one: never
      // hand out a second payable session.
      try {
        await sessions.expire(created.id, {}, requestOptions);
      } catch (error) {
        functions.logger.warn('Could not expire a superseded payment-link session', {
          sessionId: created.id,
          error: (error as Error)?.message,
        });
      }
      continue;
    }
    if (!created.url) {
      throw new functions.https.HttpsError('internal', 'Checkout session has no URL');
    }
    return { kind: 'checkout', checkoutUrl: created.url, sessionId: created.id, reused: false };
  }

  throw new functions.https.HttpsError('aborted', 'The payment link is busy. Please try again.');
}

export type PublicLinkConfirmStatus = 'paid' | 'received' | 'processing' | 'unpaid';

/**
 * The tenant's success page: look the session up on the facility's account and
 * apply it to the link, without waiting for the webhook.
 *
 * 'paid': the link is paid (by this session or, for a double payment, an
 * earlier one). 'received': money was taken but the link could not absorb it
 * (revoked, wrong amount); staff have an exception to act on. 'processing':
 * the session completed but is not paid yet. 'unpaid': the session was never
 * completed.
 */
export async function confirmPublicLinkCheckout(
  token: string,
  sessionId: string,
  deps: Omit<PublicLinkCheckoutDeps, 'appUrl'>,
): Promise<{ status: PublicLinkConfirmStatus }> {
  const { db, sessions } = deps;
  const clock = deps.now ?? (() => new Date());
  const linkSnap = await db.collection(PUBLIC_PAYMENT_LINKS_COLLECTION).doc(token).get();
  if (!linkSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Payment link not found');
  }
  const link = readLinkState(linkSnap.data() as Record<string, unknown>);
  if (link.status === 'paid' && link.checkoutSessionId === sessionId) {
    return { status: 'paid' };
  }

  // The session is looked up on the account the link's facility uses; whether
  // onboarding is still flagged complete does not change what was paid.
  const { connectAccountId } = await loadFacilityAccount(db, link.facilityId, { requireOnboarded: false });
  let session: Stripe.Checkout.Session;
  try {
    session = await sessions.retrieve(sessionId, {}, { stripeAccount: connectAccountId });
  } catch (error) {
    functions.logger.warn('confirmPublicPaymentCheckout: session lookup failed', {
      error: (error as Error)?.message,
    });
    // The page treats not-found as "not this link's session" and offers Pay
    // Now again, so only Stripe saying the session does not exist may say so.
    // A timeout or outage is "try again": the page keeps showing processing.
    if (isStripeResourceMissing(error)) {
      throw new functions.https.HttpsError('not-found', 'Checkout session not found');
    }
    throw new functions.https.HttpsError(
      'unavailable',
      'Could not reach Stripe to confirm the payment. Please try again shortly.',
    );
  }
  if (session.metadata?.paymentLinkToken !== token) {
    throw new functions.https.HttpsError('permission-denied', 'Checkout session does not match this payment link');
  }
  if (session.status !== 'complete') {
    return { status: 'unpaid' };
  }

  const result = await completePublicLinkPayment({
    db,
    session,
    connectedAccountId: connectAccountId,
    source: 'confirm',
    now: clock(),
  });
  switch (result.outcome) {
    case 'marked_paid':
    case 'already_paid':
      return { status: 'paid' };
    case 'exception':
      return { status: result.linkStatus === 'paid' ? 'paid' : 'received' };
    case 'not_paid':
      return { status: 'processing' };
    case 'rejected':
    default:
      functions.logger.error('confirmPublicPaymentCheckout: session rejected', {
        reason: result.rejectReason,
        sessionId,
      });
      throw new functions.https.HttpsError('failed-precondition', 'This payment could not be confirmed');
  }
}
