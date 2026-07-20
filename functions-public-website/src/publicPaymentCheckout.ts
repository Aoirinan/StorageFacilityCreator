import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import {
  enforceAppCheckOrThrow,
  enforceUserRateLimit,
  extractCallableClientIp,
  getStripeClient,
} from '@sfc/functions-shared';
import { STRIPE_SECRETS } from './secrets';

const PUBLIC_PAYMENT_TOKEN_PATTERN = /^[A-Za-z0-9_-]{24,128}$/;
const DOCUMENT_ID_PATTERN = /^[^/]{1,128}$/;
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
  });

  return { success: true, token };
});

/**
 * Create a payment checkout session for public payment links
 * No authentication required - uses token-based validation
 */
export const createPublicPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  // Note: No auth check - public access via token
  enforceAppCheckOrThrow(context);
  await enforcePublicLookupRateLimit(context);
  const token = requirePaymentToken(data);

  try {
    // Get payment link from Firestore
    const linkDoc = await admin.firestore()
      .collection('publicPaymentLinks')
      .doc(token)
      .get();

    if (!linkDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Payment link not found');
    }

    const linkData = linkDoc.data()!;
    const facilityId = linkData.facilityId as string;
    const tenantId = linkData.tenantId as string;
    const amount = linkData.amount as number;
    const description = linkData.description as string || 'Payment';
    const status = linkData.status as string;
    const expiresAt = linkData.expiresAt as admin.firestore.Timestamp;

    // Validate link is active
    if (status !== 'pending') {
      throw new functions.https.HttpsError('failed-precondition', 'Payment link is no longer active');
    }

    // Check if expired
    if (expiresAt && expiresAt.toDate() < new Date()) {
      throw new functions.https.HttpsError('failed-precondition', 'Payment link has expired');
    }

    // Get facility info
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    const onboardingComplete = facilityData.stripeConnectOnboardingComplete as boolean | undefined;

    if (!connectAccountId || !onboardingComplete) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility owner must complete Stripe Connect onboarding before accepting payments');
    }

    // Get tenant info
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data()!;
    const tenantEmail = tenantData['email'] as string | undefined;

    const stripe = getStripeClient();

    // Create checkout session directly on the connected account
    // For Standard accounts, payments go directly to the connected account (0% platform fee)
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: description || `Payment for ${facilityData['name'] || 'Facility'}`,
              description: `Payment for ${facilityData['name'] || 'Facility'}`,
            },
            unit_amount: Math.round(amount * 100), // Convert to cents
          },
          quantity: 1,
        },
      ],
      customer_email: tenantEmail,
      success_url: 'https://app.storagefacilitycreator.com/pay?token=' + token + '&status=success&session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://app.storagefacilitycreator.com/pay?token=' + token + '&status=cancel',
      metadata: {
        facilityId: facilityId,
        tenantId: tenantId,
        type: 'public_payment_link',
        paymentLinkToken: token,
      },
    }, {
      stripeAccount: connectAccountId, // Create session on connected account - all funds go to facility owner
    });

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error creating public payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});
