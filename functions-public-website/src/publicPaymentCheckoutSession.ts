import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import type Stripe from 'stripe';
import {
  buildPublicLinkPaymentIntentMetadata,
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
 */

/** Stripe's minimum is 30 minutes; the margin absorbs clock skew. */
export const CHECKOUT_SESSION_TTL_SECONDS = 45 * 60;
/** An open session with less than this left is expired and replaced rather than handed out. */
export const REUSE_MIN_REMAINING_MS = 2 * 60 * 1000;
/** A reservation whose session was never stored is joined only while this much of it is left. */
export const JOIN_MIN_REMAINING_MS = 5 * 60 * 1000;

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
      metadata: buildPublicLinkPaymentIntentMetadata(input.facilityId, input.tenantId, input.token),
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
): Promise<{ connectAccountId: string; facilityName: string }> {
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
  return {
    connectAccountId,
    facilityName: typeof facility.name === 'string' ? facility.name : 'Facility',
  };
}

/**
 * The link's stored session, or null when Stripe no longer has it on this
 * account (the facility reconnected a different Stripe account): that session
 * cannot be paid here, so a new attempt is the right answer.
 */
async function retrieveUnlessMissing(
  sessions: CheckoutSessionsApi,
  sessionId: string,
  requestOptions: Stripe.RequestOptions,
): Promise<Stripe.Checkout.Session | null> {
  try {
    return await sessions.retrieve(sessionId, {}, requestOptions);
  } catch (error) {
    const e = error as { statusCode?: number; code?: string };
    if (e?.statusCode === 404 || e?.code === 'resource_missing') {
      functions.logger.warn('Payment-link session is gone from the connected account; starting a new one', {
        sessionId,
      });
      return null;
    }
    throw error;
  }
}

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

    const { connectAccountId, facilityName } = await loadFacilityAccount(db, link.facilityId, {
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
    const current = link.checkoutSessionId
      ? await retrieveUnlessMissing(sessions, link.checkoutSessionId, requestOptions)
      : null;
    if (current) {
      if (current.status === 'complete') {
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
      if (current.status === 'open') {
        const remainingMs = (current.expires_at ?? 0) * 1000 - clock().getTime();
        if (remainingMs > REUSE_MIN_REMAINING_MS && current.url) {
          return { kind: 'checkout', checkoutUrl: current.url, sessionId: current.id, reused: true };
        }
        // About to lapse: close it first so it cannot be paid alongside its replacement.
        try {
          await sessions.expire(current.id, {}, requestOptions);
        } catch (error) {
          functions.logger.warn('Could not expire a lapsing payment-link session; re-checking', {
            sessionId: current.id,
            error: (error as Error)?.message,
          });
          continue;
        }
      }
      // Expired (or just expired above): fall through to a new attempt.
    }

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
    throw new functions.https.HttpsError('not-found', 'Checkout session not found');
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
