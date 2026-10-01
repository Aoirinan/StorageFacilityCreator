import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import {
  checkDisputeForPayment,
  enforceAppCheckOrThrow,
  enforceUserRateLimit,
  extractCallableClientIp,
  getPublicAppUrl,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';
import { confirmPublicLinkCheckout, getOrCreatePublicLinkCheckout } from './publicPaymentCheckoutSession';

const PUBLIC_PAYMENT_TOKEN_PATTERN = /^[A-Za-z0-9_-]{24,128}$/;
const DOCUMENT_ID_PATTERN = /^[^/]{1,128}$/;
const CHECKOUT_SESSION_ID_PATTERN = /^cs_(test|live)_[A-Za-z0-9]{1,250}$/;
const PUBLIC_LOOKUP_LIMIT_PER_MINUTE = 60;

async function enforcePublicLookupRateLimit(
  context: functions.https.CallableContext,
): Promise<void> {
  const ip = extractCallableClientIp(context.rawRequest);
  const ipHash = crypto.createHash('sha256').update(ip).digest('hex').slice(0, 32);
  const windowStart = Math.floor(Date.now() / 60000);
  const counterRef = admin.firestore()
    .collection('rateLimits')
    .doc(`publicPaymentLookup_${ipHash}_${windowStart}`);

  await admin.firestore().runTransaction(async (tx) => {
    const snapshot = await tx.get(counterRef);
    const count = snapshot.exists ? Number(snapshot.data()?.count || 0) : 0;
    if (count >= PUBLIC_LOOKUP_LIMIT_PER_MINUTE) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        'Too many payment-link lookups. Please try again shortly.',
      );
    }
    tx.set(counterRef, {
      count: count + 1,
      expiresAt: admin.firestore.Timestamp.fromMillis((windowStart + 2) * 60000),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

function requirePaymentToken(data: any): string {
  const token = String(data?.token || '').trim();
  if (!PUBLIC_PAYMENT_TOKEN_PATTERN.test(token)) {
    throw new functions.https.HttpsError('invalid-argument', 'Valid token is required');
  }
  return token;
}

function optionalTimestampIso(value: unknown): string | null {
  return value instanceof admin.firestore.Timestamp
    ? value.toDate().toISOString()
    : null;
}

/**
 * Token-gated public lookup. Only fields needed to render the payment page are returned.
 */
export const getPublicPaymentLink = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  await enforcePublicLookupRateLimit(context);
  const token = requirePaymentToken(data);
  const linkDoc = await admin.firestore().collection('publicPaymentLinks').doc(token).get();
  if (!linkDoc.exists) {
    return { found: false };
  }

  const link = linkDoc.data() as Record<string, unknown>;
  const expiresAt = link.expiresAt as admin.firestore.Timestamp | undefined;
  const expired = !!expiresAt && expiresAt.toDate() < new Date();

  return {
    found: true,
    paymentLink: {
      token,
      amount: typeof link.amount === 'number' ? link.amount : 0,
      description: typeof link.description === 'string' ? link.description : 'Payment',
      status: expired && link.status === 'pending' ? 'expired' : String(link.status || 'pending'),
      createdAt: optionalTimestampIso(link.createdAt),
      expiresAt: optionalTimestampIso(expiresAt),
    },
  };
});

/**
 * Staff-only creation for public payment links. Token generation stays server-side.
 */
export const createPublicPaymentLink = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const facilityId = String(data?.facilityId || '').trim();
  const tenantId = String(data?.tenantId || '').trim();
  const description = String(data?.description || 'Payment').trim();
  const amount = Number(data?.amount);
  if (
    !DOCUMENT_ID_PATTERN.test(facilityId) ||
    !DOCUMENT_ID_PATTERN.test(tenantId) ||
    !Number.isFinite(amount) ||
    amount <= 0 ||
    amount > 1000000
  ) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Valid facilityId, tenantId, and amount are required',
    );
  }
  if (description.length > 500) {
    throw new functions.https.HttpsError('invalid-argument', 'description is too long');
  }

  await enforceUserRateLimit(context.auth.uid, 'createPublicPaymentLink', 20, 60);

  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facility = facilityDoc.data() as Record<string, any>;
  const roles = (facility.roles || {}) as Record<string, string>;
  const managers = (facility.managers || {}) as Record<string, unknown>;
  const role = roles[context.auth.uid];
  let hasStaffAccess =
    facility.ownerUid === context.auth.uid ||
    managers[context.auth.uid] === true ||
    role === 'owner' ||
    role === 'manager' ||
    role === 'admin' ||
    role === 'employee';
  if (!hasStaffAccess) {
    const userRoleSnapshot = await admin.firestore()
      .collection('user_roles')
      .where('userId', '==', context.auth.uid)
      .where('facilityId', '==', facilityId)
      .where('isActive', '==', true)
      .limit(1)
      .get();
    if (!userRoleSnapshot.empty) {
      const roleType = String(userRoleSnapshot.docs[0].data().roleType || '');
      hasStaffAccess = ['owner', 'manager', 'admin', 'employee'].includes(roleType);
    }
  }
  if (!hasStaffAccess) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'You do not have access to this facility',
    );
  }

  const tenantDoc = await admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .doc(tenantId)
    .get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }

  // A link sent to collect a card dispute by hand (the Ledger's "Record
  // payment for this dispute") names it, so its payment is booked against
  // the dispute rather than as rent.
  const dispute = await checkDisputeForPayment(
    admin.firestore(),
    facilityId,
    tenantId,
    data?.disputeId,
    Math.round(amount * 100) / 100,
  );
  if (!dispute.ok) {
    throw new functions.https.HttpsError('failed-precondition', dispute.message);
  }

  const now = new Date();
  const defaultExpiration = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000);
  const requestedExpiration = data?.expiresAt ? new Date(String(data.expiresAt)) : defaultExpiration;
  const maximumExpiration = new Date(now.getTime() + 365 * 24 * 60 * 60 * 1000);
  if (
    Number.isNaN(requestedExpiration.getTime()) ||
    requestedExpiration <= now ||
    requestedExpiration > maximumExpiration
  ) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'expiresAt must be in the future and no more than one year away',
    );
  }

  const token = crypto.randomBytes(24).toString('hex');
  await admin.firestore().collection('publicPaymentLinks').doc(token).create({
    facilityId,
    tenantId,
    amount: Math.round(amount * 100) / 100,
    description: description || 'Payment',
    token,
    status: 'pending',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    expiresAt: admin.firestore.Timestamp.fromDate(requestedExpiration),
    createdBy: context.auth.uid,
    paymentIntentId: null,
    paidAt: null,
    ...(dispute.disputeId ? { disputeId: dispute.disputeId } : {}),
  });

  return { success: true, token };
});

/**
 * Create (or hand back) the checkout session for a public payment link.
 * No authentication required - uses token-based validation.
 *
 * Returns `{checkoutUrl, sessionId}` for a payable link, or `{alreadyPaid: true}`
 * when the link has been paid (including by a session this call just found
 * complete). The one-open-session rules live in publicPaymentCheckoutSession.ts.
 */
export const createPublicPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  // Note: No auth check - public access via token
  enforceAppCheckOrThrow(context);
  await enforcePublicLookupRateLimit(context);
  const token = requirePaymentToken(data);

  try {
    // Sessions are created on the facility's connected account (Standard,
    // direct charges): all funds go to the facility owner.
    const result = await getOrCreatePublicLinkCheckout(token, {
      db: admin.firestore(),
      sessions: getStripeClient().checkout.sessions,
      appUrl: getPublicAppUrl(),
    });
    if (result.kind === 'paid') {
      return { alreadyPaid: true, status: 'paid' };
    }
    return {
      checkoutUrl: result.checkoutUrl,
      sessionId: result.sessionId,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    // Stripe's own wording can name accounts and parameters, and the caller
    // is anonymous: it stays in the log.
    functions.logger.error('Error creating public payment checkout', error);
    throw new functions.https.HttpsError('internal', 'Failed to create checkout. Please try again.');
  }
});

/**
 * Called by the payment page when Stripe sends the tenant back
 * (`?status=success&session_id=…`). Applies the paid session to the link at
 * once rather than leaving the tenant looking at "Pay Now" until the webhook
 * lands. Safe to race the webhook and to call repeatedly.
 */
export const confirmPublicPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  await enforcePublicLookupRateLimit(context);
  const token = requirePaymentToken(data);
  const sessionId = String(data?.sessionId || '').trim();
  if (!CHECKOUT_SESSION_ID_PATTERN.test(sessionId)) {
    throw new functions.https.HttpsError('invalid-argument', 'Valid sessionId is required');
  }

  try {
    return await confirmPublicLinkCheckout(token, sessionId, {
      db: admin.firestore(),
      sessions: getStripeClient().checkout.sessions,
    });
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error confirming public payment checkout', error);
    throw new functions.https.HttpsError('internal', 'Could not confirm the payment. Please refresh in a moment.');
  }
});
