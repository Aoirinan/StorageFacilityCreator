import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getDownloadURL } from 'firebase-admin/storage';
import * as crypto from 'crypto';
import type Stripe from 'stripe';
import { defineString, defineSecret } from 'firebase-functions/params';
import {
  registerHostingConfigProvider,
  getRefereePlatformTrialDays,
  processReferralOnPlatformInvoicePaid,
  resolveReferralPendingItemForSuperAdmin,
} from '@sfc/functions-shared';
import * as Sentry from '@sentry/node';
import * as stripeTenantBilling from './stripe/tenant_billing';
import { isHelpKeyword, isStartKeyword, isStopKeyword } from './texting_onboarding_helpers';
import { emailMonthlyLimitForAccount } from './constants/emailMonthlyLimits';
// Stripe v20 types: Subscription/Invoice may have stricter Expandable types; these fields exist at runtime
type SubscriptionWithPeriod = Stripe.Subscription & { current_period_end?: number; current_period_start?: number };
function subPeriodEnd(sub: Stripe.Subscription): number | undefined {
  return (sub as SubscriptionWithPeriod).current_period_end;
}
function subPeriodStart(sub: Stripe.Subscription): number | undefined {
  return (sub as SubscriptionWithPeriod).current_period_start;
}
function invoiceSubscriptionId(inv: Stripe.Invoice): string | null {
  const sub = (inv as Stripe.Invoice & { subscription?: string | Stripe.Subscription | null }).subscription;
  return typeof sub === 'string' ? sub : (sub as Stripe.Subscription)?.id ?? null;
}

// Define environment parameters for Stripe (all from Firebase Secrets for tenant Add Card / Connect)
const STRIPE_SECRET_KEY = defineSecret('STRIPE_SECRET_KEY');
const STRIPE_WEBHOOK_SECRET = defineSecret('STRIPE_WEBHOOK_SECRET');
const STRIPE_PUBLISHABLE_KEY = defineSecret('STRIPE_PUBLISHABLE_KEY');
/** Stripe Connect OAuth client id (`ca_…`); optional — set via `firebase functions:secrets:set STRIPE_CONNECT_CLIENT_ID`. */
const STRIPE_CONNECT_CLIENT_ID = defineSecret('STRIPE_CONNECT_CLIENT_ID');

const STRIPE_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PUBLISHABLE_KEY];

/** Platform Stripe secrets + Connect client id (only for functions that need Connect logging / future OAuth). */
const STRIPE_SECRETS_WITH_CONNECT = [
  STRIPE_SECRET_KEY,
  STRIPE_WEBHOOK_SECRET,
  STRIPE_PUBLISHABLE_KEY,
  STRIPE_CONNECT_CLIENT_ID,
];

const HOSTING_PROJECT_ID = defineString('HOSTING_PROJECT_ID', { default: 'storage-facility-creator' });
const HOSTING_SITE_ID = defineString('HOSTING_SITE_ID', { default: 'storage-facility-creator' });
registerHostingConfigProvider({
  getProjectId: () => HOSTING_PROJECT_ID.value(),
  getSiteId: () => HOSTING_SITE_ID.value(),
});


/**
 * Validates that Stripe secret and publishable keys are same mode (both test or both live).
 * Never logs key values; logs only "Stripe mode: LIVE" or "Stripe mode: TEST".
 * @throws Error if modes mismatch
 */
function validateStripeKeyMode(secretKey: string, publishableKey: string): void {
  const skLive = secretKey.startsWith('sk_live_');
  const skTest = secretKey.startsWith('sk_test_');
  const pkLive = publishableKey.startsWith('pk_live_');
  const pkTest = publishableKey.startsWith('pk_test_');
  if (skLive && pkLive) {
    functions.logger.info('Stripe mode: LIVE');
    return;
  }
  if (skTest && pkTest) {
    functions.logger.info('Stripe mode: TEST');
    return;
  }
  throw new Error('Stripe key mode mismatch: platform keys must both be test or both be live. Check STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY in Firebase secrets.');
}

/** Cached platform publishable key after first successful validation (never log this value). */
let cachedPlatformPublishableKey: string | null = null;

/**
 * Reject request if client sent Stripe keys (backend must use only Firebase secrets).
 * Call at start of any callable that accepts arbitrary data.
 */
function rejectClientSuppliedStripeKeys(data: Record<string, unknown>): void {
  const forbidden = ['stripeSecretKey', 'stripePublishableKey', 'secretKey', 'apiKey', 'STRIPE_SECRET_KEY', 'STRIPE_PUBLISHABLE_KEY'];
  for (const key of forbidden) {
    if (data && typeof data[key] === 'string' && (data[key] as string).trim() !== '') {
      functions.logger.warn('Rejected client-supplied Stripe key parameter', { key });
      throw new functions.https.HttpsError('invalid-argument', 'Stripe keys must not be sent from the client. Use backend configuration only.');
    }
  }
}

/**
 * Returns the platform publishable key and validates mode against STRIPE_SECRET_KEY.
 * Use this for any response that sends pk to the client (tenant Add Card, Connect, etc.).
 */
function getPlatformPublishableKey(): string {
  if (cachedPlatformPublishableKey) return cachedPlatformPublishableKey;
  const secretKey = STRIPE_SECRET_KEY.value();
  const publishableKey = STRIPE_PUBLISHABLE_KEY.value();
  if (!secretKey) throw new Error('STRIPE_SECRET_KEY is not set');
  if (!publishableKey || !publishableKey.trim()) throw new Error('STRIPE_PUBLISHABLE_KEY is not set');
  validateStripeKeyMode(secretKey, publishableKey);
  cachedPlatformPublishableKey = publishableKey.trim();
  return cachedPlatformPublishableKey;
}

// Initialize Stripe (platform secret only; Connect uses stripeAccount option per request)
let stripeClient: Stripe | null = null;

function getStripeClient(): Stripe {
  if (!stripeClient) {
    const secretKey = STRIPE_SECRET_KEY.value();
    if (!secretKey) {
      throw new Error('STRIPE_SECRET_KEY is not set');
    }
    // Validate mode on first use (never log keys)
    try {
      const publishableKey = STRIPE_PUBLISHABLE_KEY.value();
      if (publishableKey && publishableKey.trim()) {
        validateStripeKeyMode(secretKey, publishableKey);
      }
    } catch (e) {
      // If publishable not set yet, still allow Stripe client for server-only flows
      functions.logger.warn('Stripe mode check skipped (publishable key not set)');
    }
    const StripeSdk = require('stripe').default as typeof import('stripe').default;
    stripeClient = new StripeSdk(secretKey, {
      apiVersion: '2026-02-25.clover',
    });
  }
  return stripeClient;
}

// Initialize Firebase Admin
admin.initializeApp();

// Initialize Sentry for error monitoring
const SENTRY_DSN = process.env.SENTRY_DSN;
if (SENTRY_DSN) {
  Sentry.init({
    dsn: SENTRY_DSN,
    environment: process.env.GCLOUD_PROJECT?.includes('dev') ? 'development' : 'production',
    tracesSampleRate: 0.1, // 10% of transactions
    beforeSend(event) {
      // Scrub sensitive data from events
      if (event.request) {
        // Remove request body for payment endpoints
        if (event.request.url?.includes('/payment') || 
            event.request.url?.includes('/stripe') ||
            event.request.url?.includes('/checkout')) {
          delete event.request.data;
          if ('body' in event.request) {
            delete (event.request as any).body;
          }
        }
        // Redact email addresses from URLs
        if (event.request.url) {
          event.request.url = event.request.url.replace(/email=([^&]+)/gi, 'email=[REDACTED]');
        }
      }
      // Redact sensitive fields from extra data
      if (event.extra) {
        const sensitiveKeys = ['cardNumber', 'cvv', 'cvc', 'pan', 'paymentMethodId', 'clientSecret'];
        sensitiveKeys.forEach(key => {
          if (event.extra?.[key]) {
            event.extra[key] = '[REDACTED]';
          }
        });
      }
      return event;
    },
  });
  functions.logger.info('Sentry initialized for error monitoring');
} else {
  functions.logger.warn('SENTRY_DSN not set - error monitoring disabled');
}


/**
 * Process payment via Stripe for autopay or manual payments
 */
export const processStripePayment = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.facilityId,
    key: 'processStripePayment',
    limit: 40,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { facilityId, tenantId, paymentMethodId, customerId, amount, description } = data;

  if (!facilityId || !tenantId || !paymentMethodId || !amount) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};
    const stripeConnectAccountId = facilityData?.stripeConnectAccountId;

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    // Verify tenant exists
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const stripe = getStripeClient();

    // Check if payment safety features are enabled
    const safetyConfig = await getPaymentSafetyConfig();
    const idempotencyEnabled = await isPaymentSafetyFeatureEnabled('idempotency', facilityId);
    const duplicateDetectionEnabled = await isPaymentSafetyFeatureEnabled('duplicateDetection', facilityId);

    // Generate idempotency key to prevent duplicate charges (if enabled)
    const idempotencyKey = idempotencyEnabled
      ? `payment_${facilityId}_${tenantId}_${Date.now()}_${Math.round(amount * 100)}`
      : undefined;

    // Check for duplicate payment within last 5 minutes (if enabled)
    if (duplicateDetectionEnabled) {
      const duplicateCheckWindow = 5 * 60 * 1000; // 5 minutes in milliseconds
      const recentPaymentsSnapshot = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('payments')
        .where('tenantId', '==', tenantId)
        .where('amount', '==', amount)
        .where('status', '==', 'paid')
        .where('createdAt', '>', admin.firestore.Timestamp.fromMillis(Date.now() - duplicateCheckWindow))
        .limit(1)
        .get();

      if (!recentPaymentsSnapshot.empty) {
        const recentPayment = recentPaymentsSnapshot.docs[0].data();
        functions.logger.warn(`Duplicate payment detected: ${recentPayment.externalPaymentId || 'unknown'} for tenant ${tenantId}`);
        throw new functions.https.HttpsError(
          'already-exists',
          'A payment with the same amount was processed recently. Please verify this is not a duplicate.',
        );
      }
    }

    // Create payment intent with idempotency key
    const paymentIntentParams: Stripe.PaymentIntentCreateParams = {
      amount: Math.round(amount * 100), // Convert to cents
      currency: 'usd',
      payment_method: paymentMethodId,
      customer: customerId,
      confirmation_method: 'automatic',
      confirm: true,
      description: description || `Payment for tenant ${tenantId}`,
      ...(idempotencyKey ? { idempotency_key: idempotencyKey } : {}), // Stripe idempotency key (if enabled)
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
        ...(idempotencyKey ? { idempotencyKey } : {}), // Store our idempotency key in metadata (if enabled)
      },
    };

    // If facility has Stripe Connect account, use it
    if (stripeConnectAccountId) {
      paymentIntentParams.on_behalf_of = stripeConnectAccountId;
      paymentIntentParams.transfer_data = {
        destination: stripeConnectAccountId,
      };
    }

    const paymentIntent = await stripe.paymentIntents.create(paymentIntentParams);

    if (paymentIntent.status === 'succeeded') {
      functions.logger.info(`Payment succeeded: ${paymentIntent.id} for tenant ${tenantId}`);

      // Store payment record in Firestore with idempotency key
      const paymentRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('payments')
        .doc();

      await paymentRef.set({
        tenantId,
        facilityId,
        amount,
        status: 'paid',
        method: 'stripe',
        paidAt: admin.firestore.FieldValue.serverTimestamp(),
        paidDate: admin.firestore.FieldValue.serverTimestamp(),
        transactionId: paymentIntent.id,
        externalPaymentId: paymentIntent.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: context.auth.uid,
        isActive: true,
        metadata: {
          idempotencyKey,
          stripeConnectAccountId: stripeConnectAccountId || null,
        },
      });

      // Store idempotency key to prevent duplicates (if enabled)
      if (idempotencyKey) {
        await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('idempotencyKeys')
          .doc(idempotencyKey)
          .set({
            paymentId: paymentRef.id,
            paymentIntentId: paymentIntent.id,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
            facilityId,
            tenantId,
            amount,
          });
      }

      await writeAuditLog(facilityId, {
        eventType: 'payment.charged',
        actorUid: context.auth.uid,
        targetType: 'payment',
        targetId: paymentIntent.id,
        tenantId,
        after: {
          amount,
          status: 'succeeded',
          paymentIntentId: paymentIntent.id,
          paymentId: paymentRef.id,
        },
        metadata: {
          method: 'stripe',
          stripeConnectAccountId: stripeConnectAccountId || null,
          ...(idempotencyKey ? { idempotencyKey } : {}),
        },
      });
      return {
        success: true,
        transactionId: paymentIntent.id,
        amount: amount,
        status: paymentIntent.status,
        paymentId: paymentRef.id,
      };
    } else if (paymentIntent.status === 'requires_action') {
      // Payment requires additional authentication
      return {
        success: false,
        requiresAction: true,
        clientSecret: paymentIntent.client_secret,
        transactionId: paymentIntent.id,
      };
    } else {
      throw new Error(`Payment failed with status: ${paymentIntent.status}`);
    }
  } catch (error: any) {
    // Scrub sensitive data from logs
    const safeError = error?.message || 'Failed to process payment';
    const logData = {
      facilityId,
      tenantId,
      error: safeError,
      // Explicitly exclude sensitive fields like paymentMethodId, amount
    };
    
    functions.logger.error('Error processing Stripe payment:', logData);
    
    // Capture in Sentry (with scrubbing)
    const sentryDsn = process.env.SENTRY_DSN;
    if (sentryDsn) {
      Sentry.captureException(error, {
        tags: {
          function: 'processStripePayment',
          facilityId,
        },
        extra: {
          tenantId,
          // Do not include paymentMethodId, amount, or other sensitive data
        },
      });
    }
    
    await writeAuditLog(facilityId, {
      action: 'payment_failed',
      userId: context.auth.uid,
      tenantId,
      amount,
      error: safeError,
    });
    
    // Map Stripe error codes to user-friendly messages
    const userMessage = mapStripeErrorToUserMessage(error);
    throw new functions.https.HttpsError('internal', userMessage);
  }
});

/**
 * Map Stripe error codes to user-friendly messages
 */
function mapStripeErrorToUserMessage(error: any): string {
  const errorCode = error?.code || error?.type || '';
  
  switch (errorCode) {
    case 'card_declined':
      return 'Your card was declined. Please try another card or contact your bank.';
    case 'insufficient_funds':
      return 'Insufficient funds. Please use a different payment method.';
    case 'expired_card':
      return 'Your card has expired. Please use a different card.';
    case 'incorrect_cvc':
      return 'The security code is incorrect. Please check and try again.';
    case 'incorrect_number':
      return 'The card number is incorrect. Please check and try again.';
    case 'processing_error':
      return 'An error occurred while processing your card. Please try again.';
    case 'generic_decline':
      return 'Your card was declined. Please try another card.';
    case 'lost_card':
    case 'stolen_card':
    case 'pickup_card':
    case 'restricted_card':
      return 'Your card was declined. Please contact your bank.';
    case 'security_violation':
      return 'Your card was declined due to a security violation. Please contact your bank.';
    case 'service_not_allowed':
      return 'This card type is not accepted. Please use a different card.';
    case 'do_not_honor':
      return 'Your card was declined. Please try another card or contact your bank.';
    default:
      // For non-Stripe errors, return generic message to avoid leaking details
      return 'Failed to process payment. Please try again or contact support.';
  }
}

/**
 * Create a SetupIntent for saving a payment method for autopay
 * PCI-safe: Client only receives client_secret, never card data
 */
export const createSetupIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, tenantId } = data;

  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters: facilityId, tenantId');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    // Verify tenant exists
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data();
    const stripe = getStripeClient();

    // Get or create Stripe Customer for tenant
    let customerId = tenantData?.stripeCustomerId as string | undefined;
    
    if (!customerId) {
      // Create Stripe Customer
      const customer = await stripe.customers.create({
        email: tenantData?.email as string | undefined,
        name: tenantData?.name as string | undefined,
        metadata: {
          facilityId,
          tenantId,
        },
      });
      customerId = customer.id;

      // Store customer ID in tenant document
      await tenantDoc.ref.update({
        stripeCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create SetupIntent
    const setupIntent = await stripe.setupIntents.create({
      customer: customerId,
      payment_method_types: ['card'],
      usage: 'off_session', // For autopay
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
      },
    });

    // Log (without sensitive data)
    functions.logger.info(`SetupIntent created: ${setupIntent.id} for tenant ${tenantId}`);

    return {
      clientSecret: setupIntent.client_secret,
      setupIntentId: setupIntent.id,
    };
  } catch (error: any) {
    // Scrub error messages to avoid leaking sensitive info
    const safeError = error?.message || 'Failed to create setup intent';
    functions.logger.error('Error creating SetupIntent:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to create setup intent: ${safeError}`);
  }
});

/**
 * Attach a payment method to a customer after SetupIntent confirmation
 * Called after client confirms SetupIntent with Stripe Elements
 */
export const attachPaymentMethod = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, tenantId, paymentMethodId, setupIntentId } = data;

  if (!facilityId || !tenantId || !paymentMethodId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  try {
    // Verify user has access
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
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

    const tenantData = tenantDoc.data();
    const stripe = getStripeClient();

    // Verify SetupIntent was successful
    if (setupIntentId) {
      const setupIntent = await stripe.setupIntents.retrieve(setupIntentId);
      if (setupIntent.status !== 'succeeded') {
        throw new functions.https.HttpsError('failed-precondition', 'SetupIntent not succeeded');
      }
    }

    // Get customer ID
    const customerId = tenantData?.stripeCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer');
    }

    // Retrieve payment method to get display info (safe metadata only)
    const paymentMethod = await stripe.paymentMethods.retrieve(paymentMethodId);

    // Attach payment method to customer
    await stripe.paymentMethods.attach(paymentMethodId, {
      customer: customerId,
    });

    // Extract safe display info
    const card = paymentMethod.card;
    const displayInfo = {
      last4: card?.last4 || null,
      brand: card?.brand || null,
      expMonth: card?.exp_month || null,
      expYear: card?.exp_year || null,
    };

    // Store payment method in Firestore (only safe metadata)
    const paymentMethodRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('paymentMethods')
      .doc();

    await paymentMethodRef.set({
      tenantId,
      facilityId,
      type: 'creditCard',
      stripePaymentMethodId: paymentMethodId,
      stripeCustomerId: customerId,
      last4: displayInfo.last4,
      brand: displayInfo.brand,
      expiryMonth: displayInfo.expMonth,
      expiryYear: displayInfo.expYear,
      isDefault: false,
      autopayEnabled: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: context.auth.uid,
      isActive: true,
    });

    functions.logger.info(`Payment method attached: ${paymentMethodId} for tenant ${tenantId}`);

    return {
      success: true,
      paymentMethodId: paymentMethodRef.id,
      displayInfo,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to attach payment method';
    functions.logger.error('Error attaching payment method:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to attach payment method: ${safeError}`);
  }
});

// ========== Stripe Embedded Payments (tenant billing) ==========
/**
 * Get or create Stripe Customer for tenant (embedded payments)
 */
export const getOrCreateStripeCustomer = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.getOrCreateStripeCustomer(data, context, getStripeClient());
});

/**
 * Create SetupIntent for saving card via Payment Element (embedded)
 * App Check is optional here so card-add works even if reCAPTCHA is blocked; auth is still required.
 */
export const createEmbeddedSetupIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (context.app) {
    // App Check token present – enforce as usual
  } else {
    functions.logger.warn('createEmbeddedSetupIntent: App Check token missing (reCAPTCHA may be blocked) – allowing for auth-only');
  }
  try {
    const stripe = getStripeClient();
    const result = await stripeTenantBilling.createSetupIntent(data, context, stripe);
    // Return platform publishable key (validated TEST/LIVE match) so frontend matches SetupIntent (avoids 401)
    const publishableKey = getPlatformPublishableKey();
    return { ...result, publishableKey };
  } catch (err: any) {
    if (err?.code && typeof err.code === 'string' && err.message) {
      throw err;
    }
    functions.logger.error('createEmbeddedSetupIntent error', { message: err?.message, stack: err?.stack });
    throw new functions.https.HttpsError(
      'unavailable',
      err?.message && !err.message.includes('STRIPE_SECRET') ? err.message : 'Payment service is temporarily unavailable. Please try again.',
    );
  }
});

/**
 * Create one-time PaymentIntent for embedded Payment Element
 */
export const createOneTimePaymentIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.createOneTimePaymentIntent(data, context, getStripeClient());
});

/**
 * Toggle AutoPay for tenant (Stripe subscription for monthly rent)
 */
export const toggleAutopay = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.toggleAutopay(data, context, getStripeClient());
});

/**
 * List saved payment methods for tenant
 */
export const listSavedPaymentMethods = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.listSavedPaymentMethods(data, context, getStripeClient());
});

/**
 * Detach payment method from tenant
 */
export const detachPaymentMethod = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return stripeTenantBilling.detachPaymentMethod(data, context, getStripeClient());
});

/**
 * Create or get Stripe Customer for a facility (for SaaS billing)
 */
export const ensureFacilityStripeCustomer = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId');
  }

  try {
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;

    if (ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    // Check if customer already exists
    let customerId = facilityData?.stripeCustomerId as string | undefined;

    if (customerId) {
      // Verify customer still exists in Stripe
      const stripe = getStripeClient();
      try {
        await stripe.customers.retrieve(customerId);
        return { customerId, created: false };
      } catch {
        // Customer doesn't exist, create new one
        customerId = undefined;
      }
    }

    if (!customerId) {
      // Get owner email from auth
      const ownerDoc = await admin.firestore()
        .collection('users')
        .doc(ownerUid)
        .get();

      const ownerData = ownerDoc.data();
      const stripe = getStripeClient();

      const customer = await stripe.customers.create({
        email: ownerData?.email as string | undefined,
        name: ownerData?.displayName as string | undefined,
        metadata: {
          facilityId,
          ownerUid,
        },
      });

      customerId = customer.id;

      // Store customer ID in facility document
      await facilityDoc.ref.update({
        stripeCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

      functions.logger.info(`Stripe customer created: ${customerId} for facility ${facilityId}`);
    }

    return { customerId, created: !facilityData?.stripeCustomerId };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to ensure Stripe customer';
    functions.logger.error('Error ensuring Stripe customer:', {
      facilityId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to ensure Stripe customer: ${safeError}`);
  }
});



/**
 * Process refund via Stripe
 * Used for move-out refunds and other refund scenarios
 */
export const processRefund = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.facilityId,
    key: 'processRefund',
    limit: 20,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { facilityId, tenantId, amount, refundMethod, referenceId } = data;

  if (!facilityId || !tenantId || !amount || amount <= 0) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters or invalid amount');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};
    const stripeConnectAccountId = facilityData?.stripeConnectAccountId;

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to process refunds');
    }

    // If Stripe Connect is set up and refund method is card, process via Stripe
    if (stripeConnectAccountId && refundMethod === 'creditCard' && referenceId) {
      try {
        const stripe = getStripeClient();
        
        // Look up the original payment intent
        const paymentIntent = await stripe.paymentIntents.retrieve(referenceId, {
          expand: ['charges'],
        });

        if (paymentIntent.status !== 'succeeded') {
          throw new Error('Payment intent not succeeded, cannot refund');
        }

        // Get the charge ID - retrieve payment intent with charges expanded
        const expandedPaymentIntent = await stripe.paymentIntents.retrieve(paymentIntent.id, {
          expand: ['charges'],
        });
        const chargeId = (expandedPaymentIntent as any).charges?.data?.[0]?.id;
        if (!chargeId) {
          throw new Error('Charge ID not found in payment intent');
        }

        // Create refund on the connected account
        const refund = await stripe.refunds.create({
          charge: chargeId,
          amount: Math.round(amount * 100), // Convert to cents
        }, {
          stripeAccount: stripeConnectAccountId,
        });

        functions.logger.info(`Stripe refund processed: ${refund.id} for $${amount}`);

        // Log audit event
        await writeAuditLog(facilityId, {
          eventType: 'payment.refunded',
          actorUid: context.auth.uid,
          targetType: 'payment',
          targetId: referenceId,
          tenantId,
          after: {
            amount,
            refundId: refund.id,
            method: refundMethod,
            status: 'refunded',
          },
          metadata: {
            method: 'stripe',
            stripeRefundId: refund.id,
            stripeConnectAccountId: stripeConnectAccountId || null,
          },
        });

        return {
          success: true,
          refundId: refund.id,
          amount: amount,
          method: refundMethod,
          stripeRefundId: refund.id,
          message: 'Refund processed successfully via Stripe',
        };
      } catch (stripeError: any) {
        functions.logger.error('Stripe refund error:', stripeError);
        // Fall through to manual processing
      }
    }

    // For non-Stripe refunds or if Stripe fails, log for manual processing
    functions.logger.info(`Refund requested: $${amount} for tenant ${tenantId}, method: ${refundMethod || 'manual'}`);
    await writeAuditLog(facilityId, {
      eventType: 'payment.refundRequested',
      actorUid: context.auth.uid,
      targetType: 'payment',
      targetId: referenceId || 'manual',
      tenantId,
      after: {
        amount,
        method: refundMethod || 'manual',
        status: 'pending',
      },
      metadata: {
        requiresManualProcessing: true,
        tenantId,
        amount,
        method: refundMethod || 'manual',
      },
      referenceId: referenceId || null,
    });

    return {
      success: true,
      refundId: `refund-${Date.now()}`,
      amount: amount,
      method: refundMethod || 'manual',
      message: 'Refund logged for processing',
    };
  } catch (error: any) {
    functions.logger.error('Error processing refund:', error);
    await writeAuditLog(facilityId, {
      action: 'refund_failed',
      userId: context.auth.uid,
      tenantId,
      amount,
      error: error?.message || 'unknown',
    });
    throw new functions.https.HttpsError('internal', `Failed to process refund: ${error.message}`);
  }
});








// ============================================
// STRIPE SUBSCRIPTION FUNCTIONS
// ============================================

interface CheckoutSessionRequest {
  amount: number;
  currency?: string;
  successUrl: string;
  cancelUrl: string;
  description?: string;
  customerEmail?: string;
}

/**
 * Example: create a Stripe Checkout session for one-time payments
 */
export const createCheckoutSession = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: CheckoutSessionRequest, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const {
    amount,
    currency = 'usd',
    successUrl,
    cancelUrl,
    description = 'Storage Facility Payment',
    customerEmail,
  } = data;

  if (!amount || amount <= 0 || !successUrl || !cancelUrl) {
    throw new functions.https.HttpsError('invalid-argument', 'amount, successUrl, and cancelUrl are required');
  }

  const stripe = getStripeClient();
  const session = await stripe.checkout.sessions.create({
    mode: 'payment',
    payment_method_types: ['card'],
    line_items: [
      {
        price_data: {
          currency,
          product_data: { name: description },
          unit_amount: Math.round(amount * 100),
        },
        quantity: 1,
      },
    ],
    customer_email: customerEmail,
    success_url: successUrl,
    cancel_url: cancelUrl,
  });

  return {
    checkoutUrl: session.url,
    sessionId: session.id,
  };
});

/**
 * Create Stripe Checkout session for facility-based subscription
 * Pricing: $75/month base (first facility) + $75/month per additional facility
 */
export const createSubscriptionCheckout = functions.runWith({ timeoutSeconds: 60, memory: '256MB', secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.accountId,
    key: 'createSubscriptionCheckout',
    limit: 20,
    windowSeconds: 300,
    userId: context.auth.uid,
  });

  const { accountId, customerEmail, successUrl, cancelUrl } = data;

  if (!accountId || !customerEmail) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId and customerEmail are required');
  }

  try {
    // Verify user owns this account
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const stripe = getStripeClient();

    // Get or create Stripe customer
    let customerId = accountData.stripeCustomerId as string | undefined;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: customerEmail,
        metadata: {
          accountId: accountId,
          ownerUid: context.auth.uid,
        },
      });
      customerId = customer.id;

      // Save customer ID to account
      await admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .update({
          stripeCustomerId: customerId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    }

    // Get facility count for this account
    const facilityIds = (accountData.facilityIds as string[]) || [];
    const facilityCount = facilityIds.length;
    const additionalFacilityCount = Math.max(0, facilityCount - 1); // Additional facilities beyond first

    // Get or create prices (needed for both checkout and subscription update)
    let basePriceId: string;
    let addOnPriceId: string;
    try {
      basePriceId = process.env.STRIPE_BASE_PRICE_ID || await getOrCreateBasePriceId(stripe);
      addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || await getOrCreateAddOnPriceId(stripe);
      functions.logger.info(`Using price IDs - Base: ${basePriceId}, Add-on: ${addOnPriceId}`);
    } catch (priceError: any) {
      functions.logger.error('Error getting/creating price IDs', {
        error: priceError.message,
        stack: priceError.stack,
        accountId,
      });
      throw new functions.https.HttpsError('internal', `Failed to get pricing: ${priceError.message}`);
    }

    // If account already has a subscription (trial or active), update it to include the new facility
    // instead of creating a new checkout that would charge for all facilities again.
    const subscriptionStatus = (accountData.subscriptionStatus as string) || '';
    let subscriptionId = accountData.stripeSubscriptionId as string | undefined;

    // If we don't have subscriptionId on the account (e.g. webhook missed), try to find it by customer
    if (!subscriptionId && customerId && (subscriptionStatus === 'trialing' || subscriptionStatus === 'active')) {
      const subs = await stripe.subscriptions.list({
        customer: customerId,
        status: 'all',
        limit: 10,
      });
      const activeOrTrialing = subs.data.find(s => s.status === 'active' || s.status === 'trialing');
      if (activeOrTrialing) {
        subscriptionId = activeOrTrialing.id;
        functions.logger.info('Resolved missing stripeSubscriptionId from customer subscriptions', {
          accountId,
          subscriptionId,
        });
        await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
          stripeSubscriptionId: subscriptionId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    const hasExistingSubscription = subscriptionId && (subscriptionStatus === 'trialing' || subscriptionStatus === 'active');
    if (hasExistingSubscription && facilityCount > 0 && subscriptionId) {
      try {
        const subscription = await stripe.subscriptions.retrieve(subscriptionId, { expand: ['items.data.price'] });
        const getPriceId = (item: Stripe.SubscriptionItem): string =>
          (typeof item.price === 'string' ? item.price : (item.price as Stripe.Price).id);
        const baseItem = subscription.items.data.find(item => getPriceId(item) === basePriceId)
          ?? subscription.items.data[0]; // First item is base if no match (e.g. different price id)
        const addOnItem = subscription.items.data.find(item => getPriceId(item) === addOnPriceId);
        const updates: Stripe.SubscriptionUpdateParams = {
          items: [],
          proration_behavior: 'create_prorations',
          cancel_at_period_end: false, // Clear cancellation when user subscribes/updates
        };
        if (baseItem) {
          updates.items!.push({ id: baseItem.id, quantity: 1 });
        }
        if (additionalFacilityCount > 0) {
          if (addOnItem) {
            updates.items!.push({ id: addOnItem.id, quantity: additionalFacilityCount });
          } else {
            updates.items!.push({ price: addOnPriceId, quantity: additionalFacilityCount });
          }
        } else if (addOnItem) {
          updates.items!.push({ id: addOnItem.id, deleted: true });
        }
        await stripe.subscriptions.update(subscriptionId, updates);
        await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
          subscriptionCancelAtPeriodEnd: false,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        functions.logger.info('Subscription updated for existing account instead of new checkout', {
          accountId,
          facilityCount,
          additionalFacilityCount,
        });
        await writeAuditLog(accountId, {
          action: 'subscription_updated_instead_of_checkout',
          userId: context.auth.uid,
          facilityCount,
        });
        return {
          subscriptionUpdated: true,
          checkoutUrl: null,
          message: 'Your subscription has been updated to include your new facility. You will see a prorated charge at your next billing date.',
        };
      } catch (updateError: any) {
        functions.logger.error('Error updating existing subscription, falling back to checkout', {
          error: updateError.message,
          accountId,
          subscriptionId,
        });
        // Fall through to create checkout (e.g. if subscription was cancelled in Stripe)
      }
    }

    // Build line items: base price (always 1) + add-on price (quantity = additional facilities)
    const lineItems: Stripe.Checkout.SessionCreateParams.LineItem[] = [
      {
        price: basePriceId,
        quantity: 1, // Base plan is always quantity 1
      },
    ];

    if (additionalFacilityCount > 0) {
      lineItems.push({
        price: addOnPriceId,
        quantity: additionalFacilityCount, // Number of additional facilities
      });
    }

    // Create checkout session
    let session: Stripe.Checkout.Session;
    try {
      functions.logger.info('Creating Stripe checkout session', {
        accountId,
        customerId,
        facilityCount,
        additionalFacilityCount,
        lineItemsCount: lineItems.length,
      });
      session = await stripe.checkout.sessions.create({
        customer: customerId,
        mode: 'subscription',
        line_items: lineItems,
        success_url: successUrl || 'https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}',
        cancel_url: cancelUrl || 'https://app.storagefacilitycreator.com/subscription/cancel',
        metadata: {
          accountId: accountId,
          ownerUid: context.auth.uid,
          facilityCount: facilityCount.toString(),
        },
        subscription_data: {
          trial_period_days: 30,
          metadata: {
            accountId: accountId,
            facilityCount: facilityCount.toString(),
          },
        },
      });
      functions.logger.info('Checkout session created successfully', {
        sessionId: session.id,
        checkoutUrl: session.url,
      });
    } catch (stripeError: any) {
      functions.logger.error('Stripe API error creating checkout session', {
        error: stripeError.message,
        type: stripeError.type,
        code: stripeError.code,
        declineCode: stripeError.declineCode,
        accountId,
        customerId,
      });
      throw new functions.https.HttpsError('internal', `Stripe error: ${stripeError.message}`);
    }

    const result = {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
    await writeAuditLog(accountId, {
      action: 'subscription_checkout_created',
      userId: context.auth.uid,
      checkoutSessionId: session.id,
      facilityCount,
    });
    return result;
  } catch (error: any) {
    const errorMessage = error?.message || 'Unknown error';
    const errorStack = error?.stack || 'No stack trace';
    
    functions.logger.error('Error creating checkout session', {
      error: errorMessage,
      stack: errorStack,
      accountId: data?.accountId,
      userId: context.auth?.uid,
      errorType: error?.constructor?.name,
      errorCode: error?.code,
    });
    
    await writeAuditLog(data?.accountId, {
      action: 'subscription_checkout_failed',
      userId: context.auth?.uid,
      error: errorMessage,
      errorType: error?.constructor?.name,
    });
    
    // If it's already an HttpsError, rethrow it
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${errorMessage}`);
  }
});

/**
 * Start a 30-day trial for an account
 * Sets subscription status to trialing with 30-day trial period
 */
export const startTrial = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.accountId,
    key: 'startTrial',
    limit: 10,
    windowSeconds: 600,
    userId: context.auth.uid,
  });

  const { accountId } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    // Verify user owns this account
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    // Check if already has active subscription or trial
    const currentStatus = accountData.subscriptionStatus as string;
    if (currentStatus === 'active' || currentStatus === 'trialing') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Account already has an active subscription or trial',
      );
    }

    const now = new Date();
    const trialEnd = new Date(now);
    trialEnd.setDate(trialEnd.getDate() + 30); // 30-day trial

    // Update account to trialing status
    await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .update({
        subscriptionStatus: 'trialing',
        subscriptionTrialEnd: admin.firestore.Timestamp.fromDate(trialEnd),
        subscriptionCurrentPeriodStart: admin.firestore.Timestamp.fromDate(now),
        subscriptionCurrentPeriodEnd: admin.firestore.Timestamp.fromDate(trialEnd),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`30-day trial started for account ${accountId}`);

    const result = {
      success: true,
      trialEnd: trialEnd.toISOString(),
      message: '30-day trial started successfully',
    };
    await writeAuditLog(accountId, {
      action: 'trial_started',
      userId: context.auth.uid,
      trialEnd: trialEnd.toISOString(),
    });
    return result;
  } catch (error: any) {
    functions.logger.error('Error starting trial', error);
    
    // Provide more detailed error information
    let errorMessage: string;
    if (error instanceof functions.https.HttpsError) {
      // Re-throw HttpsErrors as-is
      throw error;
    } else if (error.message) {
      errorMessage = error.message;
    } else if (typeof error === 'string') {
      errorMessage = error;
    } else {
      errorMessage = JSON.stringify(error);
    }
    
    functions.logger.error(`Trial start error details: ${errorMessage}`, {
      accountId,
      userId: context.auth?.uid,
      errorStack: error.stack,
    });
    
    await writeAuditLog(data?.accountId, {
      action: 'trial_start_failed',
      userId: context.auth.uid,
      error: errorMessage,
    });
    throw new functions.https.HttpsError('internal', `Failed to start trial: ${errorMessage}`);
  }
});

/**
 * Create Stripe Customer Portal session for managing subscription
 */
export const createCustomerPortalSession = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId, returnUrl } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    // Verify user owns this account
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const customerId = accountData.stripeCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'No Stripe customer found. Please subscribe first.');
    }

    const stripe = getStripeClient();

    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: returnUrl || 'https://www.storagefacilitycreator.com/subscription/manage',
    });

    return {
      portalUrl: session.url,
    };
  } catch (error: any) {
    functions.logger.error('Error creating portal session', error);
    throw new functions.https.HttpsError('internal', `Failed to create portal: ${error.message}`);
  }
});

/**
 * Cancel subscription at period end (in-app, no Stripe portal required)
 */
export const cancelSubscription = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId } = data;
  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();
    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }
    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }
    const subscriptionId = accountData.stripeSubscriptionId as string | undefined;
    if (!subscriptionId) {
      throw new functions.https.HttpsError('failed-precondition', 'No active subscription to cancel');
    }
    const stripe = getStripeClient();
    await stripe.subscriptions.update(subscriptionId, { cancel_at_period_end: true });
    await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
      subscriptionCancelAtPeriodEnd: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Subscription set to cancel at period end for account ${accountId}`);
    return { success: true, message: 'Your subscription will cancel at the end of the current billing period.' };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) throw error;
    functions.logger.error('Error cancelling subscription', error);
    throw new functions.https.HttpsError('internal', `Failed to cancel: ${error.message}`);
  }
});

/**
 * Create Stripe Checkout for ONE facility's platform subscription ($75/mo).
 * Each facility gets its own subscription and payment method (different card per facility).
 */
export const createFacilitySubscriptionCheckout = functions.runWith({ timeoutSeconds: 60, memory: '256MB', secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId, facilityId, customerEmail, successUrl, cancelUrl } = data;
  if (!accountId || !facilityId || !customerEmail) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId, facilityId, and customerEmail are required');
  }

  try {
    const db = admin.firestore();
    const [accountDoc, facilityDoc] = await Promise.all([
      db.collection('facilityCreatorAccounts').doc(accountId).get(),
      db.collection('facilities').doc(facilityId).get(),
    ]);
    if (!accountDoc.exists || !facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account or facility not found');
    }
    const accountData = accountDoc.data()!;
    const facilityData = facilityDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid || facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }
    if ((facilityData.facilityCreatorAccountId as string) !== accountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility must be linked to this account first');
    }

    const facilityPlatformSubId = facilityData.stripePlatformSubscriptionId as string | undefined;
    const platformStatus = (facilityData.platformSubscriptionStatus as string) || '';
    if (facilityPlatformSubId && (platformStatus === 'active' || platformStatus === 'trialing')) {
      return {
        subscriptionUpdated: true,
        checkoutUrl: null,
        message: 'This facility already has an active subscription.',
      };
    }

    const stripe = getStripeClient();
    let customerId = accountData.stripeCustomerId as string | undefined;
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: customerEmail,
        metadata: { accountId, ownerUid: context.auth.uid },
      });
      customerId = customer.id;
      await db.collection('facilityCreatorAccounts').doc(accountId).update({
        stripeCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    const basePriceId = process.env.STRIPE_BASE_PRICE_ID || await getOrCreateBasePriceId(stripe);
    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: 'subscription',
      line_items: [{ price: basePriceId, quantity: 1 }],
      success_url: successUrl || `https://app.storagefacilitycreator.com/subscription/success?session_id={CHECKOUT_SESSION_ID}&facility_id=${facilityId}`,
      cancel_url: cancelUrl || `https://app.storagefacilitycreator.com/subscription/cancel?facility_id=${facilityId}`,
      metadata: { accountId, facilityId, ownerUid: context.auth.uid },
      subscription_data: {
        trial_period_days: getRefereePlatformTrialDays(facilityDoc),
        metadata: { accountId, facilityId },
      },
    });

    return { checkoutUrl: session.url, sessionId: session.id };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) throw error;
    functions.logger.error('Error creating facility subscription checkout', error);
    throw new functions.https.HttpsError('internal', `Failed: ${error.message}`);
  }
});

/**
 * Cancel one facility's platform subscription at period end.
 */
export const cancelFacilitySubscription = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }
    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }
    const subscriptionId = facilityData.stripePlatformSubscriptionId as string | undefined;
    if (!subscriptionId) {
      throw new functions.https.HttpsError('failed-precondition', 'No platform subscription found for this facility');
    }

    const stripe = getStripeClient();
    await stripe.subscriptions.update(subscriptionId, { cancel_at_period_end: true });
    await admin.firestore().collection('facilities').doc(facilityId).update({
      platformSubscriptionCancelAtPeriodEnd: true,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Facility ${facilityId} platform subscription set to cancel at period end`);
    return { success: true, message: 'Subscription will cancel at end of billing period.' };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) throw error;
    functions.logger.error('Error cancelling facility subscription', error);
    throw new functions.https.HttpsError('internal', `Failed to cancel: ${error.message}`);
  }
});

/**
 * Update subscription quantity based on facility count
 * Called when facilities are added or removed
 */
export const updateSubscriptionQuantity = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    // Verify user owns this account
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const subscriptionId = accountData.stripeSubscriptionId as string | undefined;
    if (!subscriptionId) {
      // No subscription yet, nothing to update
      return { success: true, message: 'No active subscription to update' };
    }

    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);

    // Get current facility count
    const facilityIds = (accountData.facilityIds as string[]) || [];
    const facilityCount = facilityIds.length;
    const additionalFacilityCount = Math.max(0, facilityCount - 1);

    // Get price IDs
    const basePriceId = process.env.STRIPE_BASE_PRICE_ID || await getOrCreateBasePriceId(stripe);
    const addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || await getOrCreateAddOnPriceId(stripe);

    // Find base and add-on items in subscription
    const baseItem = subscription.items.data.find(item => item.price.id === basePriceId);
    const addOnItem = subscription.items.data.find(item => item.price.id === addOnPriceId);

    // Idempotency: skip update if quantity already matches (prevents duplicate charges)
    const currentAddOnQty = addOnItem ? addOnItem.quantity : 0;
    if (baseItem?.quantity === 1 && currentAddOnQty === additionalFacilityCount) {
      functions.logger.info(`Subscription quantity already correct for account ${accountId}: ${facilityCount} facilities`);
      return {
        success: true,
        facilityCount: facilityCount,
        baseQuantity: 1,
        addOnQuantity: additionalFacilityCount,
      };
    }

    const updates: Stripe.SubscriptionUpdateParams = {
      items: [],
      // Add proration to next invoice so user gets one charge per month, not multiple mid-cycle
      proration_behavior: 'create_prorations',
    };

    // Base item: always quantity 1
    if (baseItem) {
      updates.items!.push({
        id: baseItem.id,
        quantity: 1,
      });
    } else {
      // Base item missing, add it
      updates.items!.push({
        price: basePriceId,
        quantity: 1,
      });
    }

    // Add-on item: quantity = additional facilities
    if (additionalFacilityCount > 0) {
      if (addOnItem) {
        updates.items!.push({
          id: addOnItem.id,
          quantity: additionalFacilityCount,
        });
      } else {
        // Add-on item missing, add it
        updates.items!.push({
          price: addOnPriceId,
          quantity: additionalFacilityCount,
        });
      }
    } else if (addOnItem) {
      // No additional facilities, remove add-on item
      updates.items!.push({
        id: addOnItem.id,
        deleted: true,
      });
    }

    // Update subscription
    await stripe.subscriptions.update(subscriptionId, updates);

    functions.logger.info(`Subscription quantity updated for account ${accountId}: ${facilityCount} facilities (1 base + ${additionalFacilityCount} add-on)`);

    return {
      success: true,
      facilityCount: facilityCount,
      baseQuantity: 1,
      addOnQuantity: additionalFacilityCount,
    };
  } catch (error: any) {
    functions.logger.error('Error updating subscription quantity', error);
    throw new functions.https.HttpsError('internal', `Failed to update subscription: ${error.message}`);
  }
});

/**
 * Get subscription status for an account
 */
export const getSubscriptionStatus = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { accountId } = data;

  if (!accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
  }

  try {
    const accountDoc = await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .get();

    if (!accountDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountDoc.data()!;
    if (accountData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    return {
      subscriptionStatus: accountData.subscriptionStatus,
      stripeSubscriptionId: accountData.stripeSubscriptionId,
      stripeCustomerId: accountData.stripeCustomerId,
      currentPeriodEnd: accountData.subscriptionCurrentPeriodEnd,
      cancelAtPeriodEnd: accountData.subscriptionCancelAtPeriodEnd,
    };
  } catch (error: any) {
    functions.logger.error('Error getting subscription status', error);
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error.message}`);
  }
});

/**
 * Reconcile account.facilityIds with facilities linked to this account (server-side).
 * Uses facilityCreatorAccountId so intentionally-removed facilities stay removed.
 * Fixes orphaned IDs when facilities were deleted but account wasn't updated.
 * Updates Firestore (admin) and Stripe subscription quantity.
 */
export const reconcileAccountFacilityIds = functions
  .runWith({ secrets: STRIPE_SECRETS })
  .https.onCall(async (_data: any, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    enforceAppCheckOrThrow(context);
    const uid = context.auth.uid;
    const db = admin.firestore();

    const accountSnap = await db
      .collection('facilityCreatorAccounts')
      .where('ownerUid', '==', uid)
      .limit(1)
      .get();
    if (accountSnap.empty) {
      throw new functions.https.HttpsError('not-found', 'No account found for user');
    }
    const accountDoc = accountSnap.docs[0];
    const accountId = accountDoc.id;
    const accountData = accountDoc.data();

    // Use facilityCreatorAccountId so "removed from subscription" facilities (unlinked) stay removed.
    // Old logic used ownerUid and re-added removed facilities on every page load.
    const facilitiesSnap = await db
      .collection('facilities')
      .where('facilityCreatorAccountId', '==', accountId)
      .where('active', '==', true)
      .get();
    const actualIds = facilitiesSnap.docs.map((d) => d.id);

    const current = (accountData.facilityIds as string[]) || [];
    const currentSet = new Set(current);
    const actualSet = new Set(actualIds);
    if (currentSet.size === actualSet.size && actualIds.every((id) => currentSet.has(id))) {
      functions.logger.info(`reconcileAccountFacilityIds: already in sync, facilityCount=${actualIds.length}`);
      return { success: true, facilityCount: actualIds.length, updated: false };
    }

    await db.collection('facilityCreatorAccounts').doc(accountId).update({
      facilityIds: actualIds,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`reconcileAccountFacilityIds: ${current.length} -> ${actualIds.length} for account ${accountId}`);

    const subscriptionId = accountData.stripeSubscriptionId as string | undefined;
    if (subscriptionId) {
      const stripe = getStripeClient();
      const subscription = await stripe.subscriptions.retrieve(subscriptionId);
      const basePriceId = process.env.STRIPE_BASE_PRICE_ID || await getOrCreateBasePriceId(stripe);
      const addOnPriceId = process.env.STRIPE_ADDON_PRICE_ID || await getOrCreateAddOnPriceId(stripe);
      const facilityCount = actualIds.length;
      const additionalFacilityCount = Math.max(0, facilityCount - 1);
      const baseItem = subscription.items.data.find((item: any) => item.price.id === basePriceId);
      const addOnItem = subscription.items.data.find((item: any) => item.price.id === addOnPriceId);
      const currentAddOnQty = addOnItem ? addOnItem.quantity : 0;
      if (baseItem?.quantity === 1 && currentAddOnQty === additionalFacilityCount) {
        functions.logger.info(`reconcileAccountFacilityIds: Stripe already in sync for account ${accountId}`);
      } else {
      const updates: any = { items: [], proration_behavior: 'create_prorations' };
      if (baseItem) {
        updates.items.push({ id: baseItem.id, quantity: 1 });
      } else {
        updates.items.push({ price: basePriceId, quantity: 1 });
      }
      if (additionalFacilityCount > 0) {
        if (addOnItem) {
          updates.items.push({ id: addOnItem.id, quantity: additionalFacilityCount });
        } else {
          updates.items.push({ price: addOnPriceId, quantity: additionalFacilityCount });
        }
      } else if (addOnItem) {
        updates.items.push({ id: addOnItem.id, deleted: true });
      }
      await stripe.subscriptions.update(subscriptionId, updates);
      functions.logger.info(`reconcileAccountFacilityIds: Stripe updated for account ${accountId}, facilityCount=${facilityCount}`);
      }
    }

    return { success: true, facilityCount: actualIds.length, updated: true };
  });

/**
 * Stripe webhook handler for subscription events
 */
export const stripeWebhook = functions.runWith({ secrets: STRIPE_SECRETS }).https.onRequest(async (req, res) => {
  const sig = req.headers['stripe-signature'] as string;

  if (!sig) {
    functions.logger.error('Missing stripe-signature header');
    res.status(400).send('Missing signature');
    return;
  }

  try {
    const webhookSecret = STRIPE_WEBHOOK_SECRET.value();
    const stripe = getStripeClient();

    let event: Stripe.Event;
    try {
      const rawBody = (req as any).rawBody as Buffer | undefined;
      const payload =
        rawBody ??
        (typeof req.body === 'string'
          ? Buffer.from(req.body)
          : Buffer.from(JSON.stringify(req.body || {})));

      event = stripe.webhooks.constructEvent(payload, sig, webhookSecret);
    } catch (err: any) {
      functions.logger.error('Webhook signature verification failed', err);
      res.status(400).send(`Webhook Error: ${err.message}`);
      return;
    }

    // Idempotency: short-circuit if we've already processed this event
    const alreadyProcessed = await isStripeEventProcessed(event.id);
    if (alreadyProcessed) {
      functions.logger.info(`Stripe webhook event ${event.id} already processed, acking`);
      res.json({ received: true, duplicate: true });
      return;
    }

    // Handle the event
    switch (event.type) {
      case 'checkout.session.completed': {
        const session = event.data.object as Stripe.Checkout.Session;
        await handleCheckoutCompleted(session);
        break;
      }
      case 'customer.subscription.created':
      case 'customer.subscription.updated': {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionUpdate(subscription);
        break;
      }
      case 'customer.subscription.deleted': {
        const subscription = event.data.object as Stripe.Subscription;
        await handleSubscriptionDeleted(subscription);
        break;
      }
      case 'invoice.payment_succeeded': {
        const invoice = event.data.object as Stripe.Invoice;
        await handleInvoicePaymentSucceeded(invoice);
        break;
      }
      case 'invoice.payment_failed': {
        const invoice = event.data.object as Stripe.Invoice;
        await handleInvoicePaymentFailed(invoice);
        break;
      }
      case 'account.updated': {
        const account = event.data.object as Stripe.Account;
        await handleConnectAccountUpdated(account);
        break;
      }
      case 'payment_intent.succeeded': {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        await handlePaymentIntentSucceeded(paymentIntent);
        break;
      }
      case 'payment_intent.payment_failed': {
        const paymentIntent = event.data.object as Stripe.PaymentIntent;
        await handlePaymentIntentFailed(paymentIntent);
        break;
      }
      case 'setup_intent.succeeded': {
        const setupIntent = event.data.object as Stripe.SetupIntent;
        const connectedAccountId = (event as any).account as string | undefined;
        await handleSetupIntentSucceeded(setupIntent, connectedAccountId);
        break;
      }
      case 'charge.refunded': {
        const charge = event.data.object as Stripe.Charge;
        await handleChargeRefunded(charge);
        break;
      }
      case 'charge.dispute.created': {
        const dispute = event.data.object as Stripe.Dispute;
        await handleDisputeCreated(dispute);
        break;
      }
      default:
        functions.logger.info(`Unhandled event type: ${event.type}`);
    }

    // Extract account, facilityId, tenantId from event for idempotency tracking
    const account = (event as any).account || null;
    let facilityId: string | undefined;
    let tenantId: string | undefined;

    // Try to extract from event data object metadata
    const eventData = event.data.object as any;
    if (eventData.metadata) {
      facilityId = eventData.metadata.facilityId;
      tenantId = eventData.metadata.tenantId;
    }

    await markStripeEventProcessed(event.id, event.type, account, facilityId, tenantId);
    res.json({ received: true });
  } catch (error: any) {
    // Scrub sensitive data from webhook error logs
    const safeError = error?.message || 'Webhook processing error';
    functions.logger.error('Webhook error', {
      error: safeError,
      // Do not log request body or sensitive headers
    });
    
    // Capture in Sentry
    const sentryDsn = process.env.SENTRY_DSN;
    if (sentryDsn) {
      Sentry.captureException(error, {
        tags: {
          function: 'stripeWebhook',
        },
        // Do not include request body or sensitive data
      });
    }
    
    res.status(500).send('Webhook Error: Internal server error');
  }
});

// Helper function to get or create the $75/month base price (first facility)
async function getOrCreateBasePriceId(stripe: Stripe): Promise<string> {
  // In production, create this price in Stripe Dashboard and store the ID
  // This is a fallback for development
  try {
    const prices = await stripe.prices.list({
      lookup_keys: ['sfc_base_monthly_75'],
      limit: 1,
    });

    if (prices.data.length > 0) {
      const price = prices.data[0];
      // Verify price is active
      if (price.active) {
        return price.id;
      } else {
        functions.logger.warn(`Base price ${price.id} exists but is inactive, creating new one`);
      }
    }

    // Create the base product and price if they don't exist
    const product = await stripe.products.create({
      name: 'SFC Base Plan - First Facility',
      description: 'Storage Facility Creator base subscription - includes first facility ($75/month)',
    });

    const price = await stripe.prices.create({
      product: product.id,
      unit_amount: 7500, // $75.00
      currency: 'usd',
      recurring: {
        interval: 'month',
      },
      lookup_key: 'sfc_base_monthly_75',
    });

    functions.logger.info(`Created base price: ${price.id} for $75/month`);
    return price.id;
  } catch (error: any) {
    functions.logger.error('Error creating base price', {
      error: error.message,
      type: error.type,
      code: error.code,
    });
    throw error;
  }
}

// Helper function to get or create the $75/month add-on price (additional facilities)
async function getOrCreateAddOnPriceId(stripe: Stripe): Promise<string> {
  // In production, create this price in Stripe Dashboard and store the ID
  // This is a fallback for development
  try {
    const prices = await stripe.prices.list({
      lookup_keys: ['sfc_addon_monthly_75'],
      limit: 1,
    });

    if (prices.data.length > 0) {
      const price = prices.data[0];
      // Verify price is active
      if (price.active) {
        return price.id;
      } else {
        functions.logger.warn(`Add-on price ${price.id} exists but is inactive, creating new one`);
      }
    }

    // Create the add-on product and price if they don't exist
    const product = await stripe.products.create({
      name: 'SFC Additional Facility',
      description: 'Additional facility add-on - $75/month per facility',
    });

    const price = await stripe.prices.create({
      product: product.id,
      unit_amount: 7500, // $75.00
      currency: 'usd',
      recurring: {
        interval: 'month',
      },
      lookup_key: 'sfc_addon_monthly_75',
    });

    functions.logger.info(`Created add-on price: ${price.id} for $75/month`);
    return price.id;
  } catch (error: any) {
    functions.logger.error('Error creating add-on price', {
      error: error.message,
      type: error.type,
      code: error.code,
    });
    throw error;
  }
}

// Webhook handlers
async function handleCheckoutCompleted(session: Stripe.Checkout.Session) {
  const accountId = session.metadata?.accountId;
  const facilityId = session.metadata?.facilityId;
  if (!accountId) {
    functions.logger.error('No accountId in checkout session metadata');
    return;
  }

  const subscriptionId = session.subscription as string;
  if (!subscriptionId) {
    functions.logger.error('No subscription ID in checkout session');
    return;
  }

  // Per-facility checkout: update facility doc
  if (facilityId) {
    await updateFacilityFromPlatformSubscription(facilityId, subscriptionId);
    // Ensure facility is in account's facilityIds
    const accountDoc = await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).get();
    if (accountDoc.exists) {
      const facilityIds = (accountDoc.data()?.facilityIds as string[]) || [];
      if (!facilityIds.includes(facilityId)) {
        await admin.firestore().collection('facilityCreatorAccounts').doc(accountId).update({
          facilityIds: admin.firestore.FieldValue.arrayUnion(facilityId),
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }
    return;
  }

  // Legacy account-level checkout
  await updateAccountFromSubscription(accountId, subscriptionId);
}

async function handleSubscriptionUpdate(subscription: Stripe.Subscription) {
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;

  // Per-facility platform subscription (facilityId set, tenantId not set)
  if (facilityId && !tenantId) {
    await updateFacilityFromPlatformSubscription(facilityId, subscription.id);
    return;
  }

  // Legacy account-level platform subscription
  if (accountId && !facilityId) {
    await updateAccountFromSubscription(accountId, subscription.id);
    return;
  }

  if (facilityId && tenantId) {
    // Tenant autopay subscription
    const billingRef = admin.firestore()
      .collection('facilities').doc(facilityId)
      .collection('tenants').doc(tenantId)
      .collection('billing').doc('default');
    const periodEnd = subPeriodEnd(subscription);
    const nextDue = periodEnd
      ? admin.firestore.Timestamp.fromDate(new Date(periodEnd * 1000))
      : null;
    await billingRef.set({
      stripeSubscriptionId: subscription.id,
      autopayEnabled: subscription.status === 'active' || subscription.status === 'trialing',
      nextDueAt: nextDue,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
  }
}

async function handleSubscriptionDeleted(subscription: Stripe.Subscription) {
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;

  // Per-facility platform subscription
  if (facilityId && !tenantId) {
    await admin.firestore().collection('facilities').doc(facilityId).update({
      platformSubscriptionStatus: 'cancelled',
      stripePlatformSubscriptionId: admin.firestore.FieldValue.delete(),
      platformSubscriptionCurrentPeriodEnd: admin.firestore.FieldValue.delete(),
      platformSubscriptionCancelAtPeriodEnd: false,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Facility ${facilityId} platform subscription cancelled`);
    return;
  }

  if (accountId) {
    await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .update({
        subscriptionStatus: 'cancelled',
        subscriptionCanceledAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    functions.logger.info(`Subscription cancelled for account: ${accountId}`);
  }

  if (facilityId && tenantId) {
    const billingRef = admin.firestore()
      .collection('facilities').doc(facilityId)
      .collection('tenants').doc(tenantId)
      .collection('billing').doc('default');
    await billingRef.update({
      autopayEnabled: false,
      stripeSubscriptionId: null,
      nextDueAt: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Tenant autopay subscription cancelled: ${subscription.id} for tenant ${tenantId}`);
  }
}

async function handleInvoicePaymentSucceeded(invoice: Stripe.Invoice) {
  const subscriptionId = invoiceSubscriptionId(invoice);
  if (!subscriptionId) {
    return;
  }

  const stripe = getStripeClient();
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;

  if (facilityId && !tenantId) {
    await updateFacilityFromPlatformSubscription(facilityId, subscriptionId);
    functions.logger.info(`Facility ${facilityId} platform payment succeeded`);
    try {
      await processReferralOnPlatformInvoicePaid(getStripeClient(), invoice, subscription, facilityId);
    } catch (referralErr: any) {
      functions.logger.error('Referral reward processing failed', referralErr);
    }
    return;
  }
  if (accountId) {
    await updateAccountFromSubscription(accountId, subscriptionId);
    functions.logger.info(`Payment succeeded for account: ${accountId}`);
  }

  if (facilityId && tenantId) {
    const billingRef = admin.firestore()
      .collection('facilities').doc(facilityId)
      .collection('tenants').doc(tenantId)
      .collection('billing').doc('default');
    const periodEnd = subPeriodEnd(subscription);
    const nextDue = periodEnd
      ? admin.firestore.Timestamp.fromDate(new Date(periodEnd * 1000))
      : null;
    await billingRef.set({
      lastPaymentStatus: 'succeeded',
      lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
      lastFailureCode: null,
      lastFailureMessage: null,
      nextDueAt: nextDue,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    await admin.firestore()
      .collection('facilities').doc(facilityId)
      .collection('tenants').doc(tenantId)
      .collection('payments').add({
      type: 'invoice',
      amountCents: invoice.amount_paid || 0,
      currency: 'usd',
      stripeObjectId: invoice.id,
      status: 'succeeded',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    functions.logger.info(`Tenant autopay invoice succeeded: ${invoice.id} for tenant ${tenantId}`);
  }
}

async function handleInvoicePaymentFailed(invoice: Stripe.Invoice) {
  const subscriptionId = invoiceSubscriptionId(invoice);
  if (!subscriptionId) {
    return;
  }

  const stripe = getStripeClient();
  const subscription = await stripe.subscriptions.retrieve(subscriptionId);
  const accountId = subscription.metadata?.accountId;
  const facilityId = subscription.metadata?.facilityId;
  const tenantId = subscription.metadata?.tenantId;
  const lastError = invoice.last_finalization_error;
  const failureCode = lastError?.code || null;
  const failureMessage = lastError?.message || null;

  if (facilityId && !tenantId) {
    await admin.firestore().collection('facilities').doc(facilityId).update({
      platformSubscriptionStatus: 'past_due',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Facility ${facilityId} platform payment failed`);
    return;
  }
  if (accountId) {
    await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .update({
        subscriptionStatus: 'past_due',
        subscriptionLastPaymentFailed: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    functions.logger.info(`Payment failed for account: ${accountId}`);
  }

  if (facilityId && tenantId) {
    const billingRef = admin.firestore()
      .collection('facilities').doc(facilityId)
      .collection('tenants').doc(tenantId)
      .collection('billing').doc('default');
    await billingRef.set({
      lastPaymentStatus: 'failed',
      lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
      lastFailureCode: failureCode,
      lastFailureMessage: failureMessage,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    await admin.firestore()
      .collection('facilities').doc(facilityId)
      .collection('tenants').doc(tenantId)
      .collection('payments').add({
        type: 'invoice',
        amountCents: invoice.amount_due || 0,
        currency: 'usd',
        stripeObjectId: invoice.id,
        status: 'failed',
        failureCode,
        failureMessage,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    functions.logger.info(`Tenant autopay invoice failed: ${invoice.id} for tenant ${tenantId}`);
  }
}

/**
 * Handle successful payment intent (for tenant payments via Stripe Connect / embedded)
 */
async function handlePaymentIntentSucceeded(paymentIntent: Stripe.PaymentIntent) {
  try {
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;
    const invoiceId = paymentIntent.metadata?.invoiceId;
    const paymentDocId = paymentIntent.metadata?.paymentDocId;

    if (!facilityId || !tenantId) {
      functions.logger.warn('Payment intent missing facilityId or tenantId metadata');
      return;
    }

    // Update tenant payments subcollection (embedded one-time payments)
    if (paymentDocId) {
      const tenantPaymentRef = admin.firestore()
        .collection('facilities').doc(facilityId)
        .collection('tenants').doc(tenantId)
        .collection('payments').doc(paymentDocId);
      await tenantPaymentRef.update({
        status: 'succeeded',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      const billingRef = admin.firestore()
        .collection('facilities').doc(facilityId)
        .collection('tenants').doc(tenantId)
        .collection('billing').doc('default');
      await billingRef.set({
        lastPaymentStatus: 'succeeded',
        lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
        lastFailureCode: null,
        lastFailureMessage: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    // Update facility-level payment record (for ledger/reconciliation)
    const paymentsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('payments');

    const existingPayments = await paymentsRef
      .where('externalPaymentId', '==', paymentIntent.id)
      .limit(1)
      .get();

    if (!existingPayments.empty) {
      const now = admin.firestore.FieldValue.serverTimestamp();
      await existingPayments.docs[0].ref.update({
        status: 'completed',
        paidAt: now,
        paidDate: now,
        updatedAt: now,
      });
    } else {
      // Create new payment record (embedded or Connect)
      const now = admin.firestore.FieldValue.serverTimestamp();
      await paymentsRef.add({
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: paymentIntent.metadata?.contractId || '',
        amount: paymentIntent.amount / 100, // Convert from cents
        status: 'completed',
        method: 'stripe',
        externalPaymentId: paymentIntent.id,
        transactionId: paymentIntent.id,
        paidAt: now,
        paidDate: now,
        createdAt: now,
        updatedAt: now,
        createdBy: 'system@stripe-webhook',
        isActive: true,
      });
    }

    // If invoiceId provided, mark invoice as paid
    if (invoiceId) {
      const invoiceRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('invoices')
        .doc(invoiceId);

      await invoiceRef.update({
        status: 'paid',
        paidDate: admin.firestore.FieldValue.serverTimestamp(),
        balance: 0,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create ledger entry for payment (skip if chargeTenantOffSession already created it)
    const chargeType = paymentIntent.metadata?.chargeType;
    if (chargeType !== 'tenant_one_time_card_on_file') {
      const ledgerRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .doc();

      await ledgerRef.set({
        tenantId: tenantId,
        facilityId: facilityId,
        type: 'payment',
        amount: -(paymentIntent.amount / 100), // Negative for payments
        description: `Payment via Stripe - ${paymentIntent.id}`,
        referenceId: existingPayments.empty ? null : existingPayments.docs[0].id,
        entryDate: admin.firestore.FieldValue.serverTimestamp(),
        status: 'posted',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: 'system@stripe-webhook',
        metadata: {
          paymentIntentId: paymentIntent.id,
          invoiceId: invoiceId || null,
        },
      });
    }

    functions.logger.info(`Payment intent succeeded: ${paymentIntent.id} for tenant ${tenantId}`);
  } catch (error: any) {
    functions.logger.error('Error handling payment intent succeeded:', error);
  }
}

/**
 * Handle failed payment intent (for tenant payments via Stripe Connect / embedded)
 */
async function handlePaymentIntentFailed(paymentIntent: Stripe.PaymentIntent) {
  try {
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;
    const paymentDocId = paymentIntent.metadata?.paymentDocId;
    const lastError = paymentIntent.last_payment_error;
    const failureCode = lastError?.code || null;
    const failureMessage = lastError?.message || null;

    if (!facilityId || !tenantId) {
      functions.logger.warn('Payment intent missing facilityId or tenantId metadata');
      return;
    }

    // Update tenant payments subcollection (embedded one-time payments)
    if (paymentDocId) {
      const tenantPaymentRef = admin.firestore()
        .collection('facilities').doc(facilityId)
        .collection('tenants').doc(tenantId)
        .collection('payments').doc(paymentDocId);
      await tenantPaymentRef.update({
        status: 'failed',
        failureCode,
        failureMessage,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      const billingRef = admin.firestore()
        .collection('facilities').doc(facilityId)
        .collection('tenants').doc(tenantId)
        .collection('billing').doc('default');
      await billingRef.set({
        lastPaymentStatus: 'failed',
        lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
        lastFailureCode: failureCode,
        lastFailureMessage: failureMessage,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    // Update facility-level payment record
    const paymentsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('payments');

    const existingPayments = await paymentsRef
      .where('externalPaymentId', '==', paymentIntent.id)
      .limit(1)
      .get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        status: 'failed',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        notes: failureMessage ? `Payment failed: ${failureMessage}` : undefined,
      });
    } else {
      // Create failed payment record
      await paymentsRef.add({
        tenantId: tenantId,
        facilityId: facilityId,
        contractId: paymentIntent.metadata?.contractId || '',
        amount: paymentIntent.amount / 100,
        status: 'failed',
        method: 'stripe',
        externalPaymentId: paymentIntent.id,
        transactionId: paymentIntent.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        createdBy: 'system@stripe-webhook',
        isActive: true,
        notes: failureMessage ? `Payment failed: ${failureMessage}` : 'Payment failed: Unknown error',
      });
    }

    // Optionally send notification to facility manager
    functions.logger.info(`Payment intent failed: ${paymentIntent.id} for tenant ${tenantId}`);
  } catch (error: any) {
    functions.logger.error('Error handling payment intent failed:', error);
  }
}

/**
 * Handle successful setup intent (for saving payment methods).
 * If connectedAccountId is set, the SetupIntent was on a Connect account; use stripeAccount for Stripe API calls.
 */
async function handleSetupIntentSucceeded(setupIntent: Stripe.SetupIntent, connectedAccountId?: string) {
  try {
    const facilityId = setupIntent.metadata?.facilityId as string | undefined;
    const tenantId = setupIntent.metadata?.tenantId as string | undefined;
    const paymentMethodId = setupIntent.payment_method as string | undefined;

    if (!facilityId || !tenantId || !paymentMethodId) {
      functions.logger.warn('Setup intent missing facilityId, tenantId, or payment_method');
      return;
    }

    functions.logger.info(`Setup intent succeeded: ${setupIntent.id} for tenant ${tenantId}` + (connectedAccountId ? ' (Connect)' : ''));

    const stripe = getStripeClient();
    const customerId = setupIntent.customer as string;
    const requestOptions = connectedAccountId ? { stripeAccount: connectedAccountId } : {};
    if (customerId) {
      await stripe.customers.update(customerId, {
        invoice_settings: { default_payment_method: paymentMethodId },
      }, requestOptions);
    }

    const billingRef = admin.firestore()
      .collection('facilities').doc(facilityId)
      .collection('tenants').doc(tenantId)
      .collection('billing').doc('default');
    await billingRef.set({
      facilityId,
      tenantId,
      stripeCustomerId: customerId || null,
      defaultPaymentMethodId: paymentMethodId,
      lastPaymentStatus: 'succeeded',
      lastPaymentAt: admin.firestore.FieldValue.serverTimestamp(),
      lastFailureCode: null,
      lastFailureMessage: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    if (connectedAccountId) {
      const stripe = getStripeClient();
      const pm = await stripe.paymentMethods.retrieve(paymentMethodId, { stripeAccount: connectedAccountId });
      const card = pm.card;
      const paymentMethodSummary = {
        brand: card?.brand ?? null,
        last4: card?.last4 ?? null,
        expMonth: card?.exp_month ?? null,
        expYear: card?.exp_year ?? null,
      };
      await admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).update({
        'stripe.defaultPaymentMethodId': paymentMethodId,
        'stripe.paymentMethodSummary': paymentMethodSummary,
        'stripe.customerId': customerId,
        stripeConnectedCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  } catch (error: any) {
    functions.logger.error('Error handling setup intent succeeded:', error);
  }
}

/**
 * Handle charge refunded event
 */
async function handleChargeRefunded(charge: Stripe.Charge) {
  try {
    const paymentIntentId = charge.payment_intent as string;
    if (!paymentIntentId) {
      functions.logger.warn('Charge refunded but no payment intent ID');
      return;
    }

    const stripe = getStripeClient();
    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
    
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;

    if (!facilityId) {
      functions.logger.warn('Charge refunded but missing facilityId metadata');
      return;
    }

    // Update payment record in Firestore
    const paymentsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('payments');

    const existingPayments = await paymentsRef
      .where('externalPaymentId', '==', paymentIntentId)
      .limit(1)
      .get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        status: 'refunded',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create ledger entry for refund
    const ledgerRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('ledgers')
      .doc();

    await ledgerRef.set({
      tenantId: tenantId || null,
      facilityId: facilityId,
      type: 'refund',
      amount: charge.amount_refunded / 100, // Positive for refunds
      description: `Refund for charge ${charge.id}`,
      referenceId: existingPayments.empty ? null : existingPayments.docs[0].id,
      entryDate: admin.firestore.FieldValue.serverTimestamp(),
      status: 'posted',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'system@stripe-webhook',
      metadata: {
        chargeId: charge.id,
        paymentIntentId: paymentIntentId,
      },
    });

    functions.logger.info(`Charge refunded: ${charge.id} for payment intent ${paymentIntentId}`);
  } catch (error: any) {
    functions.logger.error('Error handling charge refunded:', error);
  }
}

/**
 * Handle dispute created event
 */
async function handleDisputeCreated(dispute: Stripe.Dispute) {
  try {
    const chargeId = dispute.charge as string;
    if (!chargeId) {
      functions.logger.warn('Dispute created but no charge ID');
      return;
    }

    const stripe = getStripeClient();
    const charge = await stripe.charges.retrieve(chargeId);
    const paymentIntentId = charge.payment_intent as string;
    
    if (!paymentIntentId) {
      functions.logger.warn('Dispute created but no payment intent ID');
      return;
    }

    const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
    const facilityId = paymentIntent.metadata?.facilityId;
    const tenantId = paymentIntent.metadata?.tenantId;

    if (!facilityId) {
      functions.logger.warn('Dispute created but missing facilityId metadata');
      return;
    }

    // Update payment record in Firestore
    const paymentsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('payments');

    const existingPayments = await paymentsRef
      .where('externalPaymentId', '==', paymentIntentId)
      .limit(1)
      .get();

    if (!existingPayments.empty) {
      await existingPayments.docs[0].ref.update({
        status: 'disputed',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        notes: `Dispute created: ${dispute.reason || 'Unknown reason'}`,
      });
    }

    // Create ledger entry for dispute
    const ledgerRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('ledgers')
      .doc();

    await ledgerRef.set({
      tenantId: tenantId || null,
      facilityId: facilityId,
      type: 'dispute',
      amount: dispute.amount / 100, // Dispute amount
      description: `Dispute created: ${dispute.reason || 'Unknown reason'}`,
      referenceId: existingPayments.empty ? null : existingPayments.docs[0].id,
      entryDate: admin.firestore.FieldValue.serverTimestamp(),
      status: 'posted',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'system@stripe-webhook',
      metadata: {
        disputeId: dispute.id,
        chargeId: chargeId,
        paymentIntentId: paymentIntentId,
        reason: dispute.reason || null,
      },
    });

    functions.logger.info(`Dispute created: ${dispute.id} for charge ${chargeId}`);
  } catch (error: any) {
    functions.logger.error('Error handling dispute created:', error);
  }
}

type RateLimitConfig = {
  facilityId: string | undefined;
  key: string;
  limit: number;
  windowSeconds: number;
  userId?: string | null;
};

async function enforceRateLimit(config: RateLimitConfig): Promise<void> {
  const { facilityId, key, limit, windowSeconds, userId } = config;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required for rate limiting');
  }

  const now = Math.floor(Date.now() / 1000);
  const windowStart = Math.floor(now / windowSeconds) * windowSeconds;
  const docId = `${key}_${windowStart}`;
  const ref = admin
    .firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('rateLimits')
    .doc(docId);

  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? (snap.data()?.count as number) || 0 : 0;
    if (current >= limit) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Rate limit exceeded for ${key}. Try again shortly.`,
      );
    }
    tx.set(
      ref,
      {
        count: current + 1,
        windowStart: new Date(windowStart * 1000),
        windowSeconds,
        key,
        facilityId,
        lastUserId: userId || null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

/**
 * Write standardized audit log entry
 * Uses standardized schema: eventType, actorUid, actorRole, targetType, targetId, before, after, timestamp, etc.
 */
async function writeAuditLog(
  facilityId: string,
  entry: {
    eventType?: string; // e.g., "payment.charged", "tenant.edited"
    action?: string; // Legacy field, maps to eventType
    userId?: string; // Maps to actorUid
    actorUid?: string;
    actorEmail?: string;
    actorRole?: string;
    targetType?: string; // "tenant", "payment", "invoice", etc.
    targetId?: string;
    entityType?: string; // Legacy field, maps to targetType
    entityId?: string; // Legacy field, maps to targetId
    tenantId?: string;
    before?: Record<string, any>;
    after?: Record<string, any>;
    timestamp?: admin.firestore.Timestamp;
    ipAddress?: string;
    userAgent?: string;
    metadata?: Record<string, any>;
    details?: Record<string, any>; // Legacy field, maps to metadata
    [key: string]: any; // Allow other fields for backward compatibility
  },
): Promise<void> {
  try {
    // Normalize entry to standardized schema
    const eventType = entry.eventType || entry.action || 'unknown';
    const actorUid = entry.actorUid || entry.userId || 'system';
    const targetType = entry.targetType || entry.entityType || 'unknown';
    const targetId = entry.targetId || entry.entityId || 'unknown';
    const metadata = entry.metadata || entry.details || {};

    // Get user email and role if actorUid is provided and not 'system'
    let actorEmail: string | undefined;
    let actorRole: string | undefined;
    
    if (actorUid !== 'system') {
      try {
        const userRecord = await admin.auth().getUser(actorUid);
        actorEmail = userRecord.email;
        
        // Try to determine role from facility
        const facilityDoc = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .get();
        
        if (facilityDoc.exists) {
          const facilityData = facilityDoc.data();
          if (facilityData?.ownerUid === actorUid) {
            actorRole = 'owner';
          } else if (facilityData?.roles?.[actorUid]) {
            actorRole = facilityData.roles[actorUid] as string;
          } else if (facilityData?.managers?.[actorUid] === true) {
            actorRole = 'manager';
          }
        }
      } catch (e) {
        // User lookup failed, continue without email/role
        functions.logger.warn(`Could not get user info for audit log: ${actorUid}`);
      }
    }

    // Build standardized audit log entry
    const auditEntry: Record<string, any> = {
      eventType,
      actorUid,
      facilityId,
      targetType,
      targetId,
      timestamp: entry.timestamp || admin.firestore.FieldValue.serverTimestamp(),
    };

    if (actorEmail) auditEntry.actorEmail = actorEmail;
    if (actorRole) auditEntry.actorRole = actorRole;
    if (entry.tenantId) auditEntry.tenantId = entry.tenantId;
    if (entry.before) auditEntry.before = entry.before;
    if (entry.after) auditEntry.after = entry.after;
    if (entry.ipAddress) auditEntry.ipAddress = entry.ipAddress;
    if (entry.userAgent) auditEntry.userAgent = entry.userAgent;
    if (Object.keys(metadata).length > 0) auditEntry.metadata = metadata;

    // Add any other fields from entry (for backward compatibility)
    Object.keys(entry).forEach(key => {
      if (!['eventType', 'action', 'userId', 'actorUid', 'actorEmail', 'actorRole', 
            'targetType', 'targetId', 'entityType', 'entityId', 'tenantId', 
            'before', 'after', 'timestamp', 'ipAddress', 'userAgent', 
            'metadata', 'details', 'facilityId'].includes(key)) {
        if (!auditEntry.metadata) auditEntry.metadata = {};
        auditEntry.metadata[key] = entry[key];
      }
    });

    await admin
      .firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('auditLogs')
      .add(auditEntry);

    functions.logger.debug(`Audit log written: ${eventType} for ${targetType}:${targetId}`);
  } catch (error: any) {
    functions.logger.error(`Error writing audit log: ${error.message}`, error);
    // Don't throw - audit logging should not break the main flow
  }
}

function enforceAppCheckOrThrow(context: functions.https.CallableContext) {
  // App Check enforcement is now enabled - client app has been updated with App Check
  // The client app auto-enables App Check for production domain (storagefacilitycreator.com)
  // Ensure reCAPTCHA v3 Secret Key is configured in Firebase Console > App Check
  if (!context.app) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'App Check token required. Please update your app.',
    );
  }
}

async function isStripeEventProcessed(eventId: string): Promise<boolean> {
  if (!eventId) return false;
  const doc = await admin.firestore().collection('stripeWebhookEvents').doc(eventId).get();
  return doc.exists;
}

async function markStripeEventProcessed(eventId: string, eventType: string, account?: string, facilityId?: string, tenantId?: string): Promise<void> {
  if (!eventId) return;
  await admin.firestore().collection('stripeWebhookEvents').doc(eventId).set({
    eventType,
    account: account || null,
    facilityId: facilityId || null,
    tenantId: tenantId || null,
    processedAt: admin.firestore.FieldValue.serverTimestamp(),
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
}

// ============================================
// FEATURE FLAGS / CONFIG SYSTEM
// ============================================

interface StripeConfig {
  connectEnabledGlobal: boolean;
  tenantAutopayEnabledGlobal: boolean;
  storeEnabledGlobal: boolean;
  checkoutEnabledGlobal: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_STRIPE_CONFIG: StripeConfig = {
  connectEnabledGlobal: false,
  tenantAutopayEnabledGlobal: false,
  storeEnabledGlobal: false,
  checkoutEnabledGlobal: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

/**
 * Get Stripe feature flags/config from Firestore
 * Returns default config if document doesn't exist (all features OFF)
 */
async function getStripeConfig(): Promise<StripeConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('stripe')
      .get();

    if (!configDoc.exists) {
      // Return defaults (all OFF) - preserves production behavior
      return DEFAULT_STRIPE_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      connectEnabledGlobal: data.connectEnabledGlobal ?? false,
      tenantAutopayEnabledGlobal: data.tenantAutopayEnabledGlobal ?? false,
      storeEnabledGlobal: data.storeEnabledGlobal ?? false,
      checkoutEnabledGlobal: data.checkoutEnabledGlobal ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting Stripe config, using defaults:', error);
    return DEFAULT_STRIPE_CONFIG;
  }
}

/**
 * Check if a feature is enabled for a specific facility
 * Feature is enabled if:
 *   - killSwitch is false (emergency brake)
 *   - AND (global flag is true OR facilityId is in allowlist)
 */
async function isStripeFeatureEnabled(
  feature: 'connect' | 'tenantAutopay' | 'store' | 'checkout',
  facilityId?: string,
): Promise<boolean> {
  const config = await getStripeConfig();

  // Emergency kill switch - disables ALL payment actions
  if (config.killSwitch) {
    return false;
  }

  // Check if facility is in allowlist
  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;

  // Determine which global flag to check
  let globalFlag = false;
  switch (feature) {
    case 'connect':
      globalFlag = config.connectEnabledGlobal;
      break;
    case 'tenantAutopay':
      globalFlag = config.tenantAutopayEnabledGlobal;
      break;
    case 'store':
      globalFlag = config.storeEnabledGlobal;
      break;
    case 'checkout':
      globalFlag = config.checkoutEnabledGlobal;
      break;
  }

  // Feature enabled if global flag is true OR facility is in allowlist
  return globalFlag || inAllowlist;
}


/**
 * Tenant autopay / add-card is allowed if kill switch is off AND the facility has
 * Stripe Connect with charges_enabled. (No separate tenantAutopay flag required.)
 */
async function isTenantAutopayAllowedForFacility(facilityId: string): Promise<boolean> {
  const config = await getStripeConfig();
  if (config.killSwitch) return false;
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) return false;
  const connectAccountId = facilityDoc.data()?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) return false;
  try {
    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    return !!account.charges_enabled;
  } catch {
    return false;
  }
}

// ============================================
// PAYMENT SAFETY FEATURE FLAGS
// ============================================

interface PaymentSafetyConfig {
  idempotencyEnabled: boolean;
  duplicateDetectionEnabled: boolean;
  reconciliationEnabled: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_PAYMENT_SAFETY_CONFIG: PaymentSafetyConfig = {
  idempotencyEnabled: false,
  duplicateDetectionEnabled: false,
  reconciliationEnabled: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

/**
 * Get payment safety feature flags/config from Firestore
 * Returns default config if document doesn't exist (all features OFF)
 */
async function getPaymentSafetyConfig(): Promise<PaymentSafetyConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('paymentSafety')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_PAYMENT_SAFETY_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      idempotencyEnabled: data.idempotencyEnabled ?? false,
      duplicateDetectionEnabled: data.duplicateDetectionEnabled ?? false,
      reconciliationEnabled: data.reconciliationEnabled ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting payment safety config, using defaults:', error);
    return DEFAULT_PAYMENT_SAFETY_CONFIG;
  }
}

/**
 * Check if payment safety feature is enabled for a specific facility
 */
async function isPaymentSafetyFeatureEnabled(
  feature: 'idempotency' | 'duplicateDetection' | 'reconciliation',
  facilityId?: string,
): Promise<boolean> {
  const config = await getPaymentSafetyConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;

  switch (feature) {
    case 'idempotency':
      return config.idempotencyEnabled || inAllowlist;
    case 'duplicateDetection':
      return config.duplicateDetectionEnabled || inAllowlist;
    case 'reconciliation':
      return config.reconciliationEnabled || inAllowlist;
    default:
      return false;
  }
}

// ============================================
// AUDIT LOGGING FEATURE FLAGS
// ============================================

interface AuditLoggingConfig {
  enhancedLoggingEnabled: boolean;
  logIpAddress: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_AUDIT_LOGGING_CONFIG: AuditLoggingConfig = {
  enhancedLoggingEnabled: false,
  logIpAddress: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

/**
 * Get audit logging feature flags/config from Firestore
 * Returns default config if document doesn't exist (all features OFF)
 */
async function getAuditLoggingConfig(): Promise<AuditLoggingConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('auditLogging')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_AUDIT_LOGGING_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      enhancedLoggingEnabled: data.enhancedLoggingEnabled ?? false,
      logIpAddress: data.logIpAddress ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting audit logging config, using defaults:', error);
    return DEFAULT_AUDIT_LOGGING_CONFIG;
  }
}

/**
 * Check if audit logging feature is enabled for a specific facility
 */
async function isAuditLoggingEnabled(facilityId?: string): Promise<boolean> {
  const config = await getAuditLoggingConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;
  return config.enhancedLoggingEnabled || inAllowlist;
}


async function getFacilityDataForUserOrThrow(
  uid: string,
  facilityId: string,
): Promise<Record<string, any>> {
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }

  const facilityData = (facilityDoc.data() || {}) as Record<string, any>;
  const ownerUid = facilityData.ownerUid as string | undefined;
  const roles = (facilityData.roles as Record<string, string>) || {};
  const managersMap = (facilityData.managers as Record<string, any>) || {};

  let hasAccess =
    ownerUid === uid ||
    roles[uid] === 'owner' ||
    roles[uid] === 'manager' ||
    roles[uid] === 'employee' ||
    managersMap[uid] === true;

  if (!hasAccess) {
    const userRolesQuery = await admin
      .firestore()
      .collection('user_roles')
      .where('userId', '==', uid)
      .where('facilityId', '==', facilityId)
      .where('isActive', '==', true)
      .limit(1)
      .get();
    hasAccess = !userRolesQuery.empty;
  }

  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'You do not have access to this facility');
  }

  return facilityData;
}


// ============================================
// STAGE 7 NEW FEATURES FEATURE FLAGS
// ============================================

interface NewFeaturesConfig {
  twoFactorEnabled: boolean;
  leadPipelineEnabled: boolean;
  workOrdersEnabled: boolean;
  portalUpgradesEnabled: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_NEW_FEATURES_CONFIG: NewFeaturesConfig = {
  twoFactorEnabled: false,
  leadPipelineEnabled: false,
  workOrdersEnabled: false,
  portalUpgradesEnabled: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

/**
 * Get new features config from Firestore
 */
async function getNewFeaturesConfig(): Promise<NewFeaturesConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('newFeatures')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_NEW_FEATURES_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      twoFactorEnabled: data.twoFactorEnabled ?? false,
      leadPipelineEnabled: data.leadPipelineEnabled ?? false,
      workOrdersEnabled: data.workOrdersEnabled ?? false,
      portalUpgradesEnabled: data.portalUpgradesEnabled ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting new features config, using defaults:', error);
    return DEFAULT_NEW_FEATURES_CONFIG;
  }
}

/**
 * Check if a new feature is enabled for a facility
 */
async function isNewFeatureEnabled(
  feature: 'twoFactor' | 'leadPipeline' | 'workOrders' | 'portalUpgrades',
  facilityId?: string,
): Promise<boolean> {
  const config = await getNewFeaturesConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;

  switch (feature) {
    case 'twoFactor':
      return config.twoFactorEnabled || inAllowlist;
    case 'leadPipeline':
      return config.leadPipelineEnabled || inAllowlist;
    case 'workOrders':
      return config.workOrdersEnabled || inAllowlist;
    case 'portalUpgrades':
      return config.portalUpgradesEnabled || inAllowlist;
  }
}

// ============================================
// FINE-GRAINED RBAC FEATURE FLAGS
// ============================================

interface FineGrainedRBACConfig {
  enabled: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_FINE_GRAINED_RBAC_CONFIG: FineGrainedRBACConfig = {
  enabled: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

/**
 * Get fine-grained RBAC feature flags/config from Firestore
 * Returns default config if document doesn't exist (all features OFF)
 */
async function getFineGrainedRBACConfig(): Promise<FineGrainedRBACConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('fineGrainedRBAC')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_FINE_GRAINED_RBAC_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      enabled: data.enabled ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting fine-grained RBAC config, using defaults:', error);
    return DEFAULT_FINE_GRAINED_RBAC_CONFIG;
  }
}

/**
 * Check if fine-grained RBAC is enabled for a specific facility
 */
async function isFineGrainedRBACEnabled(facilityId?: string): Promise<boolean> {
  const config = await getFineGrainedRBACConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;
  return config.enabled || inAllowlist;
}

// ============================================
// AUTOMATION GUARDRAILS FEATURE FLAGS
// ============================================

interface AutomationGuardrailsConfig {
  dryRunEnabled: boolean;
  safetyChecksEnabled: boolean;
  confirmationRequired: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_AUTOMATION_GUARDRAILS_CONFIG: AutomationGuardrailsConfig = {
  dryRunEnabled: false,
  safetyChecksEnabled: false,
  confirmationRequired: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

/**
 * Get automation guardrails feature flags/config from Firestore
 * Returns default config if document doesn't exist (all features OFF)
 */
async function getAutomationGuardrailsConfig(): Promise<AutomationGuardrailsConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('automationGuardrails')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_AUTOMATION_GUARDRAILS_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      dryRunEnabled: data.dryRunEnabled ?? false,
      safetyChecksEnabled: data.safetyChecksEnabled ?? false,
      confirmationRequired: data.confirmationRequired ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting automation guardrails config, using defaults:', error);
    return DEFAULT_AUTOMATION_GUARDRAILS_CONFIG;
  }
}

/**
 * Check if automation guardrails feature is enabled for a specific facility
 */
async function isAutomationGuardrailsFeatureEnabled(
  feature: 'dryRun' | 'safetyChecks' | 'confirmationRequired',
  facilityId?: string,
): Promise<boolean> {
  const config = await getAutomationGuardrailsConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;

  switch (feature) {
    case 'dryRun':
      return config.dryRunEnabled || inAllowlist;
    case 'safetyChecks':
      return config.safetyChecksEnabled || inAllowlist;
    case 'confirmationRequired':
      return config.confirmationRequired || inAllowlist;
    default:
      return false;
  }
}

// ============================================
// PAYMENT RECONCILIATION FUNCTIONS
// ============================================

/**
 * Reconcile a Stripe payment with Firestore records
 * Used by payment reconciliation service
 */
export const reconcileStripePayment = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, paymentIntentId } = data;

  if (!facilityId || !paymentIntentId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and paymentIntentId are required');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    // Retrieve payment from Stripe
    const stripe = getStripeClient();
    let paymentIntent: Stripe.PaymentIntent;

    try {
      paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
    } catch (stripeError: any) {
      if (stripeError.code === 'resource_missing') {
        return {
          found: false,
          error: 'Payment not found in Stripe',
        };
      }
      throw stripeError;
    }

    // Return payment data
    return {
      found: true,
      payment: {
        id: paymentIntent.id,
        amount: paymentIntent.amount,
        currency: paymentIntent.currency,
        status: paymentIntent.status,
        created: paymentIntent.created,
        metadata: paymentIntent.metadata,
        customer: paymentIntent.customer,
        description: paymentIntent.description,
      },
    };
  } catch (error: any) {
    functions.logger.error('Error reconciling Stripe payment:', error);
    throw new functions.https.HttpsError('internal', `Failed to reconcile payment: ${error.message}`);
  }
});

// ============================================
// STRIPE CONNECT FUNCTIONS
// ============================================

/**
 * Create a Stripe Connect account for a facility
 * This creates a Standard Connect account that facility owners will complete onboarding for
 * Feature-flagged: Requires connectEnabledGlobal OR facilityId in allowlist
 */
export const createStripeConnectAccount = functions.runWith({ secrets: STRIPE_SECRETS_WITH_CONNECT }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  // Feature flag check (additive - does not break existing behavior if flag is OFF)
  const connectEnabled = await isStripeFeatureEnabled('connect', facilityId);
  if (!connectEnabled) {
    throw new functions.https.HttpsError('failed-precondition', 'Stripe Connect is not enabled for this facility');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    // If account already exists, return it so the client can proceed to get an onboarding/link URL (e.g. "Reconnect")
    const existingAccountId = facilityData.stripeConnectAccountId as string | undefined;
    if (existingAccountId) {
      functions.logger.info(`Stripe Connect account already exists for facility ${facilityId}, returning existing ID`);
      return { accountId: existingAccountId };
    }

    const stripe = getStripeClient();

    // Connect client id (`ca_…`) from Secret Manager (optional; omit secret or use placeholder if unused)
    const clientId = STRIPE_CONNECT_CLIENT_ID.value().trim() || undefined;
    if (clientId) {
      functions.logger.info(`Using Stripe Connect Client ID for facility ${facilityId}`);
    }

    // Create a Standard Connect account
    const account = await stripe.accounts.create({
      type: 'standard',
      country: 'US', // Default to US, can be made configurable
      email: facilityData.email || context.auth.token.email,
      metadata: {
        facilityId: facilityId,
        ownerUid: context.auth.uid,
      },
    });

    // Store the account ID on the facility
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .update({
        stripeConnectAccountId: account.id,
        stripeConnectOnboardingComplete: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Created Stripe Connect account ${account.id} for facility ${facilityId}`);

    return {
      accountId: account.id,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error creating Stripe Connect account', error);
    throw new functions.https.HttpsError('internal', error?.message ? `Failed to create account: ${error.message}` : 'An internal error occurred. Please try again.');
  }
});

/**
 * Create an account link for Stripe Connect onboarding.
 * If facility has no connectedAccountId, creates a Standard Connect account first, then returns onboarding URL.
 * Single entry point for "Connect Stripe" and "Finish onboarding".
 */
export const createStripeConnectAccountLink = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilityDoc = await facilityRef.get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const stripe = getStripeClient();
    let connectAccountId = facilityData.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      const account = await stripe.accounts.create({
        type: 'standard',
        country: 'US',
        email: (facilityData.email as string) || (context.auth.token?.email as string) || undefined,
        metadata: { facilityId, ownerUid: context.auth.uid },
      });
      connectAccountId = account.id;
      await facilityRef.update({
        stripeConnectAccountId: connectAccountId,
        stripeConnectOnboardingComplete: false,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      functions.logger.info(`Created Stripe Connect account ${connectAccountId} for facility ${facilityId}`);
    }

    const baseUrl = 'https://www.storagefacilitycreator.com';
    const accountLink = await stripe.accountLinks.create({
      account: connectAccountId,
      refresh_url: `${baseUrl}/#/stripe-connect?facilityId=${facilityId}&refresh=1`,
      return_url: `${baseUrl}/#/stripe-connect?facilityId=${facilityId}`,
      type: 'account_onboarding',
    });

    return { url: accountLink.url };
  } catch (error: any) {
    if (error?.code && typeof error.code === 'string' && error.message) {
      throw error;
    }
    functions.logger.error('Error creating Stripe Connect account link', { message: error?.message });
    throw new functions.https.HttpsError('internal', `Failed to create account link: ${error?.message || 'Unknown error'}`);
  }
});

/**
 * Stripe Connect status state: DISCONNECTED | ONBOARDING_INCOMPLETE | ENABLED | ACTION_REQUIRED
 * Used to gate tenant payment UI; only ENABLED allows Stripe Elements / card entry.
 */
export type StripeConnectState = 'DISCONNECTED' | 'ONBOARDING_INCOMPLETE' | 'ENABLED' | 'ACTION_REQUIRED';

/**
 * Same access as Firestore isFacilityStaff + tenant portal occupants (for legacy checks).
 * Prefer getFacilityDataForUserOrThrow for staff-only flows.
 */
async function canAccessFacility(uid: string, facilityId: string): Promise<boolean> {
  try {
    await getFacilityDataForUserOrThrow(uid, facilityId);
    return true;
  } catch (e: any) {
    const code = e?.code;
    if (code === 'permission-denied' || code === 'not-found') {
      // Tenant (occupant) access: not in getFacilityDataForUserOrThrow
      const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
      if (!facilityDoc.exists) return false;
      const tenantsSnap = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .get();
      for (const t of tenantsSnap.docs) {
        const occupants = (t.data().occupants || []) as Array<{ userId?: string }>;
        if (occupants.some((o) => o.userId === uid)) return true;
      }
      return false;
    }
    throw e;
  }
}

export const stripeConnectGetStatus = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const { facilityId } = data;
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const facilityData = await getFacilityDataForUserOrThrow(context.auth!.uid, facilityId);
    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      const stripeStatusFirestore = {
        state: 'DISCONNECTED' as const,
        chargesEnabled: false,
        payoutsEnabled: false,
        detailsSubmitted: false,
        currentlyDue: [] as string[],
        pastDue: [] as string[],
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      };
      await admin.firestore().collection('facilities').doc(facilityId).update({
        stripeStatus: stripeStatusFirestore,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return {
        state: 'DISCONNECTED',
        connectedAccountId: null,
        chargesEnabled: false,
        payoutsEnabled: false,
        detailsSubmitted: false,
        currentlyDue: [],
        pastDue: [],
        stripeStatus: { state: 'DISCONNECTED', chargesEnabled: false, payoutsEnabled: false, detailsSubmitted: false, currentlyDue: [], pastDue: [] },
      };
    }

    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    const chargesEnabled = !!account.charges_enabled;
    const payoutsEnabled = !!account.payouts_enabled;
    const detailsSubmitted = !!account.details_submitted;
    const currentlyDue = (account.requirements?.currently_due as string[] | undefined) || [];
    const pastDue = (account.requirements?.past_due as string[] | undefined) || [];
    const hasRequirementsDue = currentlyDue.length > 0 || pastDue.length > 0;

    let state: StripeConnectState;
    if (hasRequirementsDue) {
      state = 'ACTION_REQUIRED';
    } else if (chargesEnabled) {
      state = 'ENABLED';
    } else {
      state = 'ONBOARDING_INCOMPLETE';
    }

    const stripeStatusFirestore = {
      state,
      chargesEnabled,
      payoutsEnabled,
      detailsSubmitted,
      currentlyDue,
      pastDue,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await admin.firestore().collection('facilities').doc(facilityId).update({
      stripeStatus: stripeStatusFirestore,
      stripeConnectOnboardingComplete: chargesEnabled && detailsSubmitted,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const stripeStatusResponse = { state, chargesEnabled, payoutsEnabled, detailsSubmitted, currentlyDue, pastDue };
    return {
      state,
      connectedAccountId: connectAccountId,
      chargesEnabled,
      payoutsEnabled,
      detailsSubmitted,
      currentlyDue,
      pastDue,
      stripeStatus: stripeStatusResponse,
    };
  } catch (error: any) {
    if (error?.code && typeof error.code === 'string' && error.message) {
      throw error;
    }
    functions.logger.error('Error in stripeConnectGetStatus', { message: error?.message });
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error?.message || 'Unknown error'}`);
  }
});

/**
 * Check Stripe Connect account status (legacy shape; prefer stripeConnectGetStatus for state machine)
 * Returns the current status of the connected account.
 * Any facility staff (owner, manager, employee, user_roles) may read status; only owners should start onboarding (enforced in UI / createAccount).
 */
export const getStripeConnectAccountStatus = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);

    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    if (!connectAccountId) {
      return {
        connected: false,
        onboardingComplete: false,
      };
    }

    const stripe = getStripeClient();

    // Retrieve account details
    const account = await stripe.accounts.retrieve(connectAccountId);

    // Check if onboarding is complete
    const onboardingComplete = account.details_submitted && account.charges_enabled && account.payouts_enabled;

    // Update facility with full Connect status (persist to Firestore)
    const connectStatus = onboardingComplete ? 'active' : (account.details_submitted ? 'pending' : 'needs_action');
    
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .update({
        stripeConnectOnboardingComplete: onboardingComplete,
        stripeConnectStatus: connectStatus,
        chargesEnabled: account.charges_enabled,
        payoutsEnabled: account.payouts_enabled,
        stripeConnectUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    return {
      connected: true,
      accountId: connectAccountId,
      onboardingComplete: onboardingComplete,
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      detailsSubmitted: account.details_submitted,
      email: account.email,
      status: connectStatus,
    };
  } catch (error: any) {
    if (error?.code && typeof error.code === 'string' && error.message) {
      throw error;
    }
    functions.logger.error('Error getting Stripe Connect account status', error);
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error?.message || 'Unknown error'}`);
  }
});

/**
 * Create a Stripe Connect login link for facility owners to access their Stripe Dashboard
 * Feature-flagged: Requires connectEnabledGlobal OR facilityId in allowlist
 */
export const createStripeConnectLoginLink = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  // Feature flag check
  const connectEnabled = await isStripeFeatureEnabled('connect', facilityId);
  if (!connectEnabled) {
    throw new functions.https.HttpsError('failed-precondition', 'Stripe Connect is not enabled for this facility');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data()!;
    if (facilityData.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Stripe Connect account not created');
    }

    const stripe = getStripeClient();

    // Create login link for Stripe Dashboard access
    const loginLink = await stripe.accounts.createLoginLink(connectAccountId);

    return {
      url: loginLink.url,
    };
  } catch (error: any) {
    functions.logger.error('Error creating Stripe Connect login link', error);
    throw new functions.https.HttpsError('internal', `Failed to create login link: ${error.message}`);
  }
});

/**
 * Create a payment checkout session for tenant rent payment
 * Routes payment to the facility owner's Stripe Connect account (0% platform fee)
 */
export const createTenantPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const { facilityId, tenantId, amount, description } = data;

  if (!facilityId || !tenantId || !amount) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, tenantId, and amount are required');
  }

  try {
    // Verify user has access to this facility
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
    const tenantName = tenantData['name'] as string | undefined || 'Tenant';

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
              name: description || `Rent Payment - ${tenantName}`,
              description: `Payment for ${facilityData['name'] || 'Facility'}`,
            },
            unit_amount: Math.round(amount * 100), // Convert to cents
          },
          quantity: 1,
        },
      ],
      customer_email: tenantEmail,
      success_url: 'https://www.storagefacilitycreator.com/payment/success?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://www.storagefacilitycreator.com/payment/cancel',
      metadata: {
        facilityId: facilityId,
        tenantId: tenantId,
        type: 'tenant_rent_payment',
      },
    }, {
      stripeAccount: connectAccountId, // Create session on connected account - all funds go to facility owner
    });

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (error: any) {
    functions.logger.error('Error creating tenant payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});


/**
 * Create a one-time PaymentIntent on connected account for paying with a NEW card.
 * User enters card in Payment Element; payment is not saved to customer.
 * Returns clientSecret, publishableKey, connectedAccountId for embedded payment form.
 */
export const createOneTimePaymentIntentOnConnectedAccount = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const { facilityId, tenantId, amountCents } = data;
  if (!facilityId || !tenantId || amountCents == null || amountCents < 50) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, tenantId, and amountCents (min 50) are required');
  }
  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility.');
  }
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data();
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }
  const hasAccess = await canAccessFacility(context.auth.uid, facilityId);
  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'Access denied');
  }
  const tenantDoc = await admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data();
  const stripe = getStripeClient();

  // Create payment doc first for webhook to update
  const paymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).collection('payments');
  const paymentDocRef = paymentsRef.doc();
  await paymentDocRef.set({
    facilityId,
    tenantId,
    type: 'one_time',
    amountCents,
    currency: 'usd',
    stripeObjectId: null,
    status: 'processing',
    chargeType: 'tenant_one_time_new_card',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    failureCode: null,
    failureMessage: null,
  });

  const paymentIntent = await stripe.paymentIntents.create({
    amount: amountCents,
    currency: 'usd',
    metadata: {
      facilityId,
      tenantId,
      paymentDocId: paymentDocRef.id,
      chargeType: 'tenant_one_time_new_card',
    },
    automatic_payment_methods: { enabled: true },
  }, {
    stripeAccount: connectAccountId,
    idempotencyKey: paymentDocRef.id,
  });

  await paymentDocRef.update({
    stripeObjectId: paymentIntent.id,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return {
    clientSecret: paymentIntent.client_secret,
    publishableKey: getPlatformPublishableKey(),
    connectedAccountId: connectAccountId,
  };
});

/**
 * Staff POS: PaymentIntent for retail card sales on the facility's connected account.
 * Card data is collected only in Stripe.js (Payment Element), not in Flutter.
 */
export const createPosRetailPaymentIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const { facilityId, amountCents, tenantId } = data;
  if (!facilityId || amountCents == null || typeof amountCents !== 'number' || amountCents < 50) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and amountCents (min 50) are required');
  }
  const paymentsAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!paymentsAllowed) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Card payments require Stripe Connect with charges enabled. Complete Connect onboarding in Payments settings.',
    );
  }
  const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }
  const stripe = getStripeClient();
  const metadata: Record<string, string> = {
    facilityId,
    chargeType: 'pos_retail',
    staffUid: context.auth.uid,
  };
  if (tenantId && typeof tenantId === 'string' && tenantId.length > 0) {
    metadata.tenantId = tenantId;
  }
  const paymentIntent = await stripe.paymentIntents.create({
    amount: Math.round(amountCents),
    currency: 'usd',
    automatic_payment_methods: { enabled: true },
    description: 'Retail / POS purchase',
    metadata,
  }, {
    stripeAccount: connectAccountId,
  });
  return {
    clientSecret: paymentIntent.client_secret,
    publishableKey: getPlatformPublishableKey(),
    connectedAccountId: connectAccountId,
  };
});

/**
 * Staff POS: list Stripe Terminal readers for the facility's connected account.
 * Uses server-driven Terminal API to avoid client/network coupling issues.
 */
export const listPosTerminalReaders = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }

  const { facilityId } = data || {};
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  const paymentsAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!paymentsAllowed) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Card payments require Stripe Connect with charges enabled. Complete Connect onboarding in Payments settings.',
    );
  }

  const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }

  const stripe = getStripeClient();
  const readers = await stripe.terminal.readers.list(
    {
      limit: 100,
    },
    {
      stripeAccount: connectAccountId,
    },
  );

  return {
    readers: readers.data.map((reader) => ({
      id: reader.id,
      label: reader.label ?? 'Unnamed reader',
      deviceType: reader.device_type ?? null,
      serialNumber: reader.serial_number ?? null,
      status: reader.status ?? 'unknown',
      location: typeof reader.location === 'string' ? reader.location : reader.location?.id ?? null,
    })),
    connectedAccountId: connectAccountId,
  };
});

/**
 * Staff POS: process payment on a specific Stripe Terminal reader.
 * Creates a card_present PaymentIntent on connected account and triggers reader processing.
 */
export const processPosTerminalPayment = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }

  const { facilityId, amountCents, readerId, tenantId } = data || {};
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }
  if (!readerId || typeof readerId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'readerId is required');
  }
  if (amountCents == null || typeof amountCents !== 'number' || amountCents < 50) {
    throw new functions.https.HttpsError('invalid-argument', 'amountCents (min 50) is required');
  }

  const paymentsAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!paymentsAllowed) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Card payments require Stripe Connect with charges enabled. Complete Connect onboarding in Payments settings.',
    );
  }

  const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }

  const stripe = getStripeClient();
  const metadata: Record<string, string> = {
    facilityId,
    chargeType: 'pos_terminal',
    staffUid: context.auth.uid,
    readerId,
  };
  if (tenantId && typeof tenantId === 'string' && tenantId.length > 0) {
    metadata.tenantId = tenantId;
  }

  const paymentIntent = await stripe.paymentIntents.create(
    {
      amount: Math.round(amountCents),
      currency: 'usd',
      payment_method_types: ['card_present'],
      capture_method: 'automatic',
      description: 'Retail / POS purchase (Terminal reader)',
      metadata,
    },
    {
      stripeAccount: connectAccountId,
    },
  );

  await stripe.terminal.readers.processPaymentIntent(
    readerId,
    {
      payment_intent: paymentIntent.id,
    },
    {
      stripeAccount: connectAccountId,
    },
  );

  return {
    paymentIntentId: paymentIntent.id,
    status: paymentIntent.status,
    connectedAccountId: connectAccountId,
  };
});

/**
 * Staff POS: check status of a Stripe Terminal payment intent.
 * Client uses this to poll until reader flow completes.
 */
export const getPosTerminalPaymentStatus = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }

  const { facilityId, paymentIntentId } = data || {};
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }
  if (!paymentIntentId || typeof paymentIntentId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'paymentIntentId is required');
  }

  const paymentsAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!paymentsAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility');
  }

  const facilityData = await getFacilityDataForUserOrThrow(context.auth.uid, facilityId);
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }

  const stripe = getStripeClient();
  const paymentIntent = await stripe.paymentIntents.retrieve(
    paymentIntentId,
    { expand: ['latest_charge'] },
    { stripeAccount: connectAccountId },
  );

  return {
    paymentIntentId: paymentIntent.id,
    status: paymentIntent.status,
    succeeded: paymentIntent.status === 'succeeded' || paymentIntent.status === 'requires_capture',
    amount: paymentIntent.amount,
    currency: paymentIntent.currency,
  };
});

/**
 * Create a SetupIntent on a connected account for tenant payment method capture.
 * PRECONDITION: Facility Stripe Connect state must be ENABLED (charges_enabled).
 * Returns clientSecret, publishableKey, and connectedAccountId so frontend can load Stripe with stripeAccount (avoids 401).
 */
export const createTenantSetupIntent = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  if (!context.app) {
    functions.logger.warn('createTenantSetupIntent: App Check token missing – allowing for auth-only');
  }

  const { facilityId, tenantId } = data;

  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters: facilityId, tenantId');
  }

  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility. Connect and complete Stripe onboarding first.');
  }

  try {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = (facilityData?.roles || {}) as Record<string, string>;
    const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Payments are not set up for this facility. Connect Stripe in facility settings first.');
    }

    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    if (!account.charges_enabled) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Payments are not enabled for this facility yet. The facility owner needs to finish Stripe onboarding.',
      );
    }

    const isStaff = ownerUid === context.auth.uid || roles[context.auth.uid] === 'manager' || roles[context.auth.uid] === 'owner';
    if (!isStaff) {
      const hasAccess = await canAccessFacility(context.auth!.uid, facilityId);
      if (!hasAccess) {
        throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
      }
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

    const tenantData = tenantDoc.data();

    // Get or create Stripe Customer on CONNECTED account
    let customerId = tenantData?.stripeConnectedCustomerId as string | undefined;
    
    if (!customerId) {
      // Create Stripe Customer on connected account
      const customer = await stripe.customers.create({
        email: tenantData?.email as string | undefined,
        name: tenantData?.name as string | undefined,
        metadata: {
          facilityId,
          tenantId,
        },
      }, {
        stripeAccount: connectAccountId, // Create on connected account
      });
      customerId = customer.id;

      // Store customer ID in tenant document
      await tenantDoc.ref.update({
        stripeConnectedCustomerId: customerId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    // Create SetupIntent on CONNECTED account
    const setupIntent = await stripe.setupIntents.create({
      customer: customerId,
      payment_method_types: ['card'],
      usage: 'off_session', // For autopay
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
        chargeType: 'tenant_autopay',
      },
    }, {
      stripeAccount: connectAccountId, // Create on connected account
    });

    functions.logger.info(`SetupIntent created on connected account: ${setupIntent.id} for tenant ${tenantId}`);

    const publishableKey = getPlatformPublishableKey();
    return {
      clientSecret: setupIntent.client_secret,
      setupIntentId: setupIntent.id,
      publishableKey,
      connectedAccountId: connectAccountId,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to create setup intent';
    functions.logger.error('Error creating tenant SetupIntent on connected account:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to create setup intent: ${safeError}`);
  }
});

/**
 * Attach a payment method to a customer on a connected account after SetupIntent confirmation
 * Feature-flagged: Requires tenantAutopayEnabledGlobal OR facilityId in allowlist
 */
export const attachTenantPaymentMethod = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  if (!context.app) {
    functions.logger.warn('attachTenantPaymentMethod: App Check token missing – allowing for auth-only');
  }

  const { facilityId, tenantId, paymentMethodId, setupIntentId } = data;

  if (!facilityId || !tenantId || !paymentMethodId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility. Connect and complete Stripe onboarding first.');
  }

  try {
    // Verify user has access
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};
    const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
    }

    const hasAccess = await canAccessFacility(context.auth!.uid, facilityId);
    if (!hasAccess) {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
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

    const tenantData = tenantDoc.data();
    const stripe = getStripeClient();

    // Verify SetupIntent was successful on connected account
    if (setupIntentId) {
      const setupIntent = await stripe.setupIntents.retrieve(setupIntentId, {
        stripeAccount: connectAccountId,
      });
      if (setupIntent.status !== 'succeeded') {
        throw new functions.https.HttpsError('failed-precondition', 'SetupIntent not succeeded');
      }
    }

    // Get customer ID on connected account
    const customerId = tenantData?.stripeConnectedCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer on connected account');
    }

    // Retrieve payment method to get display info (safe metadata only)
    const paymentMethod = await stripe.paymentMethods.retrieve(paymentMethodId, {
      stripeAccount: connectAccountId,
    });

    // Attach payment method to customer on connected account
    await stripe.paymentMethods.attach(paymentMethodId, {
      customer: customerId,
    }, {
      stripeAccount: connectAccountId,
    });

    // Set as default payment method on customer
    await stripe.customers.update(customerId, {
      invoice_settings: { default_payment_method: paymentMethodId },
    }, { stripeAccount: connectAccountId });

    // Extract safe display info
    const card = paymentMethod.card;
    const displayInfo = {
      last4: card?.last4 || null,
      brand: card?.brand || null,
      expMonth: card?.exp_month || null,
      expYear: card?.exp_year || null,
    };

    const paymentMethodSummary = {
      brand: displayInfo.brand,
      last4: displayInfo.last4,
      expMonth: displayInfo.expMonth,
      expYear: displayInfo.expYear,
    };

    // Update tenant doc: stripe.defaultPaymentMethodId + paymentMethodSummary (and customerId for consistency)
    const tenantUpdate: Record<string, unknown> = {
      'stripe.customerId': customerId,
      'stripe.defaultPaymentMethodId': paymentMethodId,
      'stripe.paymentMethodSummary': paymentMethodSummary,
      stripeConnectedCustomerId: customerId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
    await tenantDoc.ref.update(tenantUpdate);

    // Store payment method in Firestore (only safe metadata)
    const paymentMethodRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('paymentMethods')
      .doc();

    await paymentMethodRef.set({
      tenantId,
      facilityId,
      type: 'creditCard',
      stripePaymentMethodId: paymentMethodId,
      stripeCustomerId: customerId,
      stripeConnectedAccountId: connectAccountId,
      last4: displayInfo.last4,
      brand: displayInfo.brand,
      expiryMonth: displayInfo.expMonth,
      expiryYear: displayInfo.expYear,
      isDefault: true,
      autopayEnabled: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: context.auth.uid,
      isActive: true,
    });

    functions.logger.info(`Payment method attached on connected account: ${paymentMethodId} for tenant ${tenantId}`);

    const tenantNameForEvent = (tenantData?.name as string) || 'Tenant';
    await writeAutopayEvent(facilityId, tenantId, tenantNameForEvent, 'CARD_ADDED', 'FACILITY', null);

    return {
      success: true,
      paymentMethodId: paymentMethodRef.id,
      displayInfo,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to attach payment method';
    functions.logger.error('Error attaching tenant payment method on connected account:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to attach payment method: ${safeError}`);
  }
});

/**
 * attachTenantPaymentMethodFromRedirect — When Stripe Link (or 3DS) redirects for verification,
 * the Payment Element iframe never gets the result. This function handles the redirect return:
 * retrieves the SetupIntent, gets the payment_method, and attaches it to the tenant.
 */
export const attachTenantPaymentMethodFromRedirect = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  rejectClientSuppliedStripeKeys(data || {});
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const { setupIntentId, facilityId, tenantId } = data;
  if (!setupIntentId || !facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'setupIntentId, facilityId, and tenantId are required');
  }
  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility.');
  }
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data();
  const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }
  const hasAccess = await canAccessFacility(context.auth!.uid, facilityId);
  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
  }
  const tenantDoc = await admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data();
  const stripe = getStripeClient();
  const setupIntent = await stripe.setupIntents.retrieve(setupIntentId, { stripeAccount: connectAccountId });
  if (setupIntent.status !== 'succeeded') {
    throw new functions.https.HttpsError('failed-precondition', `SetupIntent not succeeded (status: ${setupIntent.status})`);
  }
  const paymentMethodId = typeof setupIntent.payment_method === 'string' ? setupIntent.payment_method : setupIntent.payment_method?.id;
  if (!paymentMethodId) {
    throw new functions.https.HttpsError('failed-precondition', 'SetupIntent has no payment method');
  }
  const customerId = tenantData?.stripeConnectedCustomerId as string | undefined;
  if (!customerId) {
    throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer');
  }
  const paymentMethod = await stripe.paymentMethods.retrieve(paymentMethodId, { stripeAccount: connectAccountId });
  await stripe.paymentMethods.attach(paymentMethodId, { customer: customerId }, { stripeAccount: connectAccountId });
  await stripe.customers.update(customerId, {
    invoice_settings: { default_payment_method: paymentMethodId },
  }, { stripeAccount: connectAccountId });
  const card = paymentMethod.card;
  const displayInfo = { last4: card?.last4, brand: card?.brand, expMonth: card?.exp_month, expYear: card?.exp_year };
  const paymentMethodSummary = { last4: displayInfo.last4, brand: displayInfo.brand, expMonth: displayInfo.expMonth, expYear: displayInfo.expYear };
  await tenantDoc.ref.update({
    'stripe.customerId': customerId,
    'stripe.defaultPaymentMethodId': paymentMethodId,
    'stripe.paymentMethodSummary': paymentMethodSummary,
    stripeConnectedCustomerId: customerId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  const paymentMethodRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).collection('paymentMethods').doc();
  await paymentMethodRef.set({
    tenantId, facilityId, type: 'creditCard',
    stripePaymentMethodId: paymentMethodId, stripeCustomerId: customerId, stripeConnectedAccountId: connectAccountId,
    last4: displayInfo.last4, brand: displayInfo.brand, expiryMonth: displayInfo.expMonth, expiryYear: displayInfo.expYear,
    isDefault: true, autopayEnabled: false, createdAt: admin.firestore.FieldValue.serverTimestamp(),
    createdBy: context.auth.uid, isActive: true,
  });
  const tenantNameForEvent = (tenantData?.name as string) || 'Tenant';
  await writeAutopayEvent(facilityId, tenantId, tenantNameForEvent, 'CARD_ADDED', 'FACILITY', null);
  functions.logger.info(`Payment method attached from redirect: ${paymentMethodId} for tenant ${tenantId}`);
  return { success: true, paymentMethodId: paymentMethodRef.id };
});

/** Create a facility notification and an AutopayEvents log entry */
async function createAutopayNotificationAndEvent(
  facilityId: string,
  tenantId: string,
  tenantName: string,
  notificationType: 'AUTOPAY_DISABLED' | 'AUTOPAY_ENABLED' | 'AUTOPAY_REQUESTED' | 'STRIPE_ACTION_REQUIRED',
  eventAction: 'REQUESTED' | 'ENABLED' | 'DISABLED',
  source: 'TENANT' | 'FACILITY' | 'SYSTEM',
  message: string,
  reason: string | null,
): Promise<void> {
  const batch = admin.firestore().batch();
  const notifRef = admin.firestore().collection('facilities').doc(facilityId).collection('Notifications').doc();
  batch.set(notifRef, {
    type: notificationType,
    tenantId,
    tenantName,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    readAt: null,
    message,
    metadata: reason ? { reason } : {},
  });
  const eventRef = admin.firestore().collection('facilities').doc(facilityId).collection('AutopayEvents').doc();
  batch.set(eventRef, {
    facilityId,
    tenantId,
    tenantName,
    action: eventAction,
    source,
    reason: reason || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await batch.commit();
}

/** Write a single AutopayEvents entry (e.g. CARD_ADDED) without a notification. */
async function writeAutopayEvent(
  facilityId: string,
  tenantId: string,
  tenantName: string,
  action: 'CARD_ADDED' | 'CARD_REMOVED' | 'PAYMENT_FAILED' | 'PAYMENT_SUCCEEDED' | 'REQUESTED' | 'ENABLED' | 'DISABLED',
  source: 'TENANT' | 'FACILITY' | 'SYSTEM',
  reason: string | null,
): Promise<void> {
  await admin.firestore().collection('facilities').doc(facilityId).collection('AutopayEvents').add({
    facilityId,
    tenantId,
    tenantName,
    action,
    source,
    reason: reason || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
}

/**
 * setTenantAutopay — Enable or disable autopay for a tenant. Creates notification + AutopayEvents log.
 * source: "TENANT" | "FACILITY" | "SYSTEM"
 */
export const setTenantAutopay = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  if (!context.app) {
    functions.logger.warn('setTenantAutopay: App Check token missing – allowing for auth-only');
  }
  rejectClientSuppliedStripeKeys(data || {});

  const payload = data && typeof data === 'object' ? data : {};
  const facilityId = typeof payload.facilityId === 'string' ? payload.facilityId.trim() : '';
  const tenantId = typeof payload.tenantId === 'string' ? payload.tenantId.trim() : '';
  let enabled: boolean;
  if (typeof payload.enabled === 'boolean') {
    enabled = payload.enabled;
  } else if (typeof payload.enabled === 'string') {
    enabled = payload.enabled === 'true' || payload.enabled === '1';
  } else if (payload.enabled === 1) {
    enabled = true;
  } else if (payload.enabled === 0) {
    enabled = false;
  } else {
    functions.logger.warn('setTenantAutopay: invalid payload', {
      hasFacilityId: !!facilityId,
      hasTenantId: !!tenantId,
      enabledType: typeof payload.enabled,
      uid: context.auth?.uid?.slice(0, 8),
    });
    throw new functions.https.HttpsError(
      'invalid-argument',
      'facilityId (string), tenantId (string), and enabled (boolean or "true"/"false") are required.',
    );
  }
  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'facilityId and tenantId must be non-empty strings.',
    );
  }
  const source = payload.source;
  const src = (source === 'TENANT' || source === 'FACILITY' || source === 'SYSTEM') ? source : 'SYSTEM';

  const hasAccess = await canAccessFacility(context.auth.uid, facilityId);
  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'Access denied');
  }

  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data()!;
  const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
  let chargesEnabled = false;
  if (connectAccountId) {
    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    chargesEnabled = !!account.charges_enabled;
  }

  const tenantRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
  const tenantDoc = await tenantRef.get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data()!;
  const tenantName = (tenantData.name as string) || 'Tenant';
  const stripe = tenantData.stripe as { defaultPaymentMethodId?: string } | undefined;
  const hasPm = !!(stripe?.defaultPaymentMethodId);

  const now = admin.firestore.FieldValue.serverTimestamp();

  if (enabled) {
    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Stripe is not connected for this facility. Connect Stripe in facility settings first.', { code: 'stripe_not_connected' });
    }
    if (!chargesEnabled) {
      throw new functions.https.HttpsError('failed-precondition', 'Stripe onboarding is not complete for this facility. Complete setup in facility settings.', { code: 'stripe_not_ready' });
    }
    if (!hasPm) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant must have a saved payment method before enabling autopay. Add a card first.', { code: 'missing_payment_method' });
    }
    await tenantRef.update({
      'autopay.requested': true,
      'autopay.enabled': true,
      'autopay.status': 'ON',
      'autopay.enabledAt': now,
      'autopay.disabledAt': null,
      'autopay.disabledReason': null,
      'autopay.updatedBy': src,
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(
      facilityId, tenantId, tenantName,
      'AUTOPAY_ENABLED', 'ENABLED', src,
      `${tenantName} autopay enabled.`,
      null,
    );
    return { enabled: true, status: 'ON' };
  } else {
    const disabledReason = src === 'TENANT' ? 'Tenant disabled in portal' : src === 'FACILITY' ? 'Disabled by facility' : 'System';
    await tenantRef.update({
      'autopay.requested': false,
      'autopay.enabled': false,
      'autopay.status': 'OFF',
      'autopay.disabledAt': now,
      'autopay.disabledReason': disabledReason,
      'autopay.updatedBy': src,
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(
      facilityId, tenantId, tenantName,
      'AUTOPAY_DISABLED', 'DISABLED', src,
      `${tenantName} turned off autopay.`,
      disabledReason,
    );
    return { enabled: false, status: 'OFF' };
  }
});

/**
 * requestTenantAutopay — Set autopay requested=true, enabled=false, status=REQUESTED. Creates notification + event.
 */
export const requestTenantAutopay = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const { facilityId, tenantId, source } = data;
  if (!facilityId || !tenantId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and tenantId are required');
  }
  const src = (source === 'TENANT' || source === 'FACILITY' || source === 'SYSTEM') ? source : 'SYSTEM';

  const hasAccess = await canAccessFacility(context.auth.uid, facilityId);
  if (!hasAccess) {
    throw new functions.https.HttpsError('permission-denied', 'Access denied');
  }

  const tenantRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
  const tenantDoc = await tenantRef.get();
  if (!tenantDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenantData = tenantDoc.data()!;
  const tenantName = (tenantData.name as string) || 'Tenant';

  const now = admin.firestore.FieldValue.serverTimestamp();
  await tenantRef.update({
    'autopay.requested': true,
    'autopay.enabled': false,
    'autopay.status': 'REQUESTED',
    'autopay.updatedBy': src,
    'autopay.updatedAt': now,
    updatedAt: now,
  });
  await createAutopayNotificationAndEvent(
    facilityId, tenantId, tenantName,
    'AUTOPAY_REQUESTED', 'REQUESTED', src,
    `${tenantName} requested autopay.`,
    null,
  );
  return { status: 'REQUESTED', requested: true };
});

/**
 * setTenantAutopayFromPortal — For tenant portal (no Firebase Auth). Uses email + accessCode to identify tenant.
 */
export const setTenantAutopayFromPortal = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const enabled = data.enabled === true;

  if (!email || !accessCode) {
    throw new functions.https.HttpsError('invalid-argument', 'Email and access code are required');
  }

  const tenantSnapshot = await admin.firestore().collectionGroup('tenants')
    .where('emailLower', '==', email)
    .where('portalEnabled', '==', true)
    .where('portalAccessCode', '==', accessCode)
    .limit(1)
    .get();

  if (tenantSnapshot.empty) {
    throw new functions.https.HttpsError('not-found', 'Portal access not found.');
  }

  const tenantDoc = tenantSnapshot.docs[0];
  const facilityId = tenantDoc.ref.parent.parent?.id;
  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility not found');
  }

  const tenantId = tenantDoc.id;
  const tenantData = tenantDoc.data() as Record<string, any>;
  const tenantName = tenantData.name || 'Tenant';
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data()!;
  const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
  let chargesEnabled = false;
  if (connectAccountId) {
    const stripe = getStripeClient();
    const account = await stripe.accounts.retrieve(connectAccountId);
    chargesEnabled = !!account.charges_enabled;
  }
  const stripe = tenantData.stripe as { defaultPaymentMethodId?: string } | undefined;
  const hasPm = !!(stripe?.defaultPaymentMethodId);
  const tenantRef = admin.firestore().collection('facilities').doc(facilityId).collection('tenants').doc(tenantId);
  const now = admin.firestore.FieldValue.serverTimestamp();

  if (enabled) {
    if (!chargesEnabled || !connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility yet. The facility must complete Stripe setup first.');
    }
    if (!hasPm) {
      throw new functions.https.HttpsError('failed-precondition', 'Add a payment method first. Use "Add card" to save your card, then turn on autopay.');
    }
    await tenantRef.update({
      'autopay.requested': true,
      'autopay.enabled': true,
      'autopay.status': 'ON',
      'autopay.enabledAt': now,
      'autopay.disabledAt': null,
      'autopay.disabledReason': null,
      'autopay.updatedBy': 'TENANT',
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(facilityId, tenantId, tenantName, 'AUTOPAY_ENABLED', 'ENABLED', 'TENANT', `${tenantName} enabled autopay from portal.`, null);
    return { enabled: true, status: 'ON' };
  } else {
    const disabledReason = 'Tenant disabled in portal';
    await tenantRef.update({
      'autopay.requested': false,
      'autopay.enabled': false,
      'autopay.status': 'OFF',
      'autopay.disabledAt': now,
      'autopay.disabledReason': disabledReason,
      'autopay.updatedBy': 'TENANT',
      'autopay.updatedAt': now,
      updatedAt: now,
    });
    await createAutopayNotificationAndEvent(facilityId, tenantId, tenantName, 'AUTOPAY_DISABLED', 'DISABLED', 'TENANT', `${tenantName} turned off autopay.`, disabledReason);
    return { enabled: false, status: 'OFF' };
  }
});

/**
 * createTenantSetupIntentFromPortal — Portal (no Firebase Auth). Email + accessCode → SetupIntent for adding card.
 */
export const createTenantSetupIntentFromPortal = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any) => {
  rejectClientSuppliedStripeKeys(data || {});
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  if (!email || !accessCode) {
    throw new functions.https.HttpsError('invalid-argument', 'Email and access code are required');
  }
  const tenantSnapshot = await admin.firestore().collectionGroup('tenants')
    .where('emailLower', '==', email)
    .where('portalEnabled', '==', true)
    .where('portalAccessCode', '==', accessCode)
    .limit(1)
    .get();
  if (tenantSnapshot.empty) {
    throw new functions.https.HttpsError('not-found', 'Portal access not found.');
  }
  const tenantDoc = tenantSnapshot.docs[0];
  const facilityId = tenantDoc.ref.parent.parent?.id;
  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility not found');
  }
  const tenantId = tenantDoc.id;
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const connectAccountId = facilityDoc.data()?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility yet.');
  }
  const stripe = getStripeClient();
  const account = await stripe.accounts.retrieve(connectAccountId);
  if (!account.charges_enabled) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility yet.');
  }
  const tenantData = tenantDoc.data() as Record<string, any>;
  let customerId = tenantData.stripeConnectedCustomerId as string | undefined;
  if (!customerId) {
    const customer = await stripe.customers.create({
      email: tenantData.email,
      name: tenantData.name,
      metadata: { facilityId, tenantId },
    }, { stripeAccount: connectAccountId });
    customerId = customer.id;
    await tenantDoc.ref.update({
      stripeConnectedCustomerId: customerId,
      'stripe.customerId': customerId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  const setupIntent = await stripe.setupIntents.create({
    customer: customerId,
    payment_method_types: ['card'],
    usage: 'off_session',
    metadata: { facilityId, tenantId, chargeType: 'tenant_autopay', source: 'portal' },
  }, { stripeAccount: connectAccountId });
  const publishableKey = getPlatformPublishableKey();
  return {
    clientSecret: setupIntent.client_secret,
    setupIntentId: setupIntent.id,
    publishableKey,
    connectedAccountId: connectAccountId,
  };
});

/**
 * attachTenantPaymentMethodFromPortal — Portal (no Firebase Auth). Email + accessCode + paymentMethodId → attach PM.
 */
export const attachTenantPaymentMethodFromPortal = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any) => {
  rejectClientSuppliedStripeKeys(data || {});
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const paymentMethodId = data.paymentMethodId as string;
  const setupIntentId = data.setupIntentId as string | undefined;
  if (!email || !accessCode || !paymentMethodId) {
    throw new functions.https.HttpsError('invalid-argument', 'Email, access code, and paymentMethodId are required');
  }
  const tenantSnapshot = await admin.firestore().collectionGroup('tenants')
    .where('emailLower', '==', email)
    .where('portalEnabled', '==', true)
    .where('portalAccessCode', '==', accessCode)
    .limit(1)
    .get();
  if (tenantSnapshot.empty) {
    throw new functions.https.HttpsError('not-found', 'Portal access not found.');
  }
  const tenantDoc = tenantSnapshot.docs[0];
  const facilityId = tenantDoc.ref.parent.parent?.id;
  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility not found');
  }
  const tenantId = tenantDoc.id;
  const tenantData = tenantDoc.data() as Record<string, any>;
  const connectAccountId = (await admin.firestore().collection('facilities').doc(facilityId).get()).data()?.stripeConnectAccountId as string | undefined;
  if (!connectAccountId) {
    throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
  }
  const customerId = tenantData.stripeConnectedCustomerId as string | undefined;
  if (!customerId) {
    throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer');
  }
  const stripeClient = getStripeClient();
  if (setupIntentId) {
    const si = await stripeClient.setupIntents.retrieve(setupIntentId, { stripeAccount: connectAccountId });
    if (si.status !== 'succeeded') {
      throw new functions.https.HttpsError('failed-precondition', 'SetupIntent not succeeded');
    }
  }
  const paymentMethod = await stripeClient.paymentMethods.retrieve(paymentMethodId, { stripeAccount: connectAccountId });
  await stripeClient.paymentMethods.attach(paymentMethodId, { customer: customerId }, { stripeAccount: connectAccountId });
  await stripeClient.customers.update(customerId, { invoice_settings: { default_payment_method: paymentMethodId } }, { stripeAccount: connectAccountId });
  const card = paymentMethod.card;
  const paymentMethodSummary = { brand: card?.brand ?? null, last4: card?.last4 ?? null, expMonth: card?.exp_month ?? null, expYear: card?.exp_year ?? null };
  await tenantDoc.ref.update({
    'stripe.customerId': customerId,
    'stripe.defaultPaymentMethodId': paymentMethodId,
    'stripe.paymentMethodSummary': paymentMethodSummary,
    stripeConnectedCustomerId: customerId,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  const tenantName = (tenantData.name as string) || 'Tenant';
  await writeAutopayEvent(facilityId, tenantId, tenantName, 'CARD_ADDED', 'TENANT', null);
  return { success: true, displayInfo: paymentMethodSummary };
});

/** Alias for stripeConnectGetStatus — get facility Stripe status (state machine). */
export const getFacilityStripeStatus = stripeConnectGetStatus;

/**
 * Charge a tenant off-session using a stored payment method on a connected account
 * Feature-flagged: Requires tenantAutopayEnabledGlobal OR facilityId in allowlist
 */
export const chargeTenantOffSession = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  if (!context.app) {
    functions.logger.warn('chargeTenantOffSession: App Check token missing – allowing for auth-only');
  }

  const { facilityId, tenantId, paymentMethodId, amount, description } = data;

  if (!facilityId || !tenantId || !paymentMethodId || amount === undefined || amount === null) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
  }

  const amountNum = Number(amount);
  if (!Number.isFinite(amountNum) || amountNum < 0.5) {
    throw new functions.https.HttpsError('invalid-argument', 'Amount must be a number of at least 0.50 (USD).');
  }

  // Use same gate as Add Card / one-time payments: facility must have Connect + charges_enabled
  const tenantAutopayAllowed = await isTenantAutopayAllowedForFacility(facilityId);
  if (!tenantAutopayAllowed) {
    throw new functions.https.HttpsError('failed-precondition', 'Payments are not enabled for this facility. Connect and complete Stripe onboarding first.');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = (facilityData?.roles || {}) as Record<string, string>;
    const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
    }

    const isElevated =
      ownerUid === context.auth.uid ||
      roles[context.auth.uid] === 'manager' ||
      roles[context.auth.uid] === 'owner';
    if (!isElevated) {
      const staffOk = await canAccessFacility(context.auth.uid, facilityId);
      if (!staffOk) {
        throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
      }
    }

    // Verify tenant exists
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();

    if (!tenantDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Tenant not found');
    }

    const tenantData = tenantDoc.data();
    const stripe = getStripeClient();

    // Get customer ID on connected account
    const customerId = tenantData?.stripeConnectedCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer on connected account');
    }

    // Create PaymentIntent on CONNECTED account (off-session)
    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(amountNum * 100), // Convert to cents
      currency: 'usd',
      payment_method: paymentMethodId,
      customer: customerId,
      confirmation_method: 'automatic',
      confirm: true,
      off_session: true, // Off-session charge
      description: description || `Payment for tenant ${tenantId}`,
      metadata: {
        facilityId,
        tenantId,
        userId: context.auth.uid,
        chargeType: 'tenant_one_time_card_on_file',
      },
    }, {
      stripeAccount: connectAccountId, // Create on connected account
    });

    if (paymentIntent.status !== 'succeeded') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        `Payment was not completed (status: ${paymentIntent.status}). Try "Pay with new card" or ask the tenant to approve with their bank.`,
      );
    }

    const amountCents = Math.round(amountNum * 100);
    const now = admin.firestore.FieldValue.serverTimestamp();

    let recordingWarning: string | undefined;
    try {
      // Store in tenant payments subcollection (shows in Payment History)
      const tenantPaymentsRef = admin.firestore()
        .collection('facilities').doc(facilityId)
        .collection('tenants').doc(tenantId)
        .collection('payments');
      const paymentDocRef = tenantPaymentsRef.doc();
      await paymentDocRef.set({
        facilityId,
        tenantId,
        type: 'one_time',
        amountCents,
        currency: 'usd',
        stripeObjectId: paymentIntent.id,
        status: 'succeeded',
        chargeType: 'tenant_one_time_card_on_file',
        description: description || `One-time payment`,
        createdAt: now,
        updatedAt: now,
        failureCode: null,
        failureMessage: null,
      });

      // Store in facility payments (shows in main Payments screen)
      const facilityPaymentsRef = admin.firestore().collection('facilities').doc(facilityId).collection('payments');
      const facilityPaymentRef = await facilityPaymentsRef.add({
        tenantId,
        facilityId,
        contractId: '',
        amount: amountNum,
        status: 'completed',
        method: 'stripe',
        paidAt: now,
        paidDate: now,
        externalPaymentId: paymentIntent.id,
        transactionId: paymentIntent.id,
        createdAt: now,
        updatedAt: now,
        createdBy: context.auth.uid,
        isActive: true,
      });

      // Create ledger entry (shows in View Ledger)
      const ledgerRef = admin.firestore().collection('facilities').doc(facilityId).collection('ledgers').doc();
      await ledgerRef.set({
        tenantId,
        facilityId,
        type: 'payment',
        amount: -amountNum,
        description: `Payment via Stripe - ${paymentIntent.id}`,
        referenceId: facilityPaymentRef.id,
        entryDate: now,
        status: 'posted',
        createdAt: now,
        createdBy: context.auth.uid,
        metadata: { paymentIntentId: paymentIntent.id },
      });

      // Also store in tenantCharges for legacy/reconciliation
      const chargeRef = admin.firestore().collection('tenantCharges').doc();
      await chargeRef.set({
        facilityId,
        tenantId,
        stripePaymentIntentId: paymentIntent.id,
        stripeCustomerId: customerId,
        stripeConnectedAccountId: connectAccountId,
        amount: amountNum,
        currency: 'usd',
        status: paymentIntent.status,
        description: description || `One-time payment for tenant ${tenantId}`,
        metadata: {
          chargeType: 'tenant_one_time_card_on_file',
          userId: context.auth.uid,
          paymentDocId: paymentDocRef.id,
        },
        createdAt: now,
        updatedAt: now,
      });

      functions.logger.info(`Off-session charge recorded: ${paymentIntent.id} for tenant ${tenantId}`);
    } catch (persistErr: any) {
      functions.logger.error('chargeTenantOffSession: Stripe succeeded but Firestore persist failed', {
        facilityId,
        tenantId,
        paymentIntentId: paymentIntent.id,
        error: persistErr?.message,
        stack: persistErr?.stack,
      });
      recordingWarning =
        'Your card was charged successfully, but saving the receipt in the app failed. ' +
        `Give support this payment ID: ${paymentIntent.id}`;
    }

    return {
      success: true,
      paymentIntentId: paymentIntent.id,
      status: paymentIntent.status,
      amount: amountNum,
      ...(recordingWarning ? { recordingWarning } : {}),
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    const safeError = error?.message || 'Failed to charge tenant';
    functions.logger.error('Error charging tenant off-session on connected account:', {
      facilityId,
      tenantId,
      error: safeError,
      stack: error?.stack,
    });

    const userMessage = mapStripeErrorToUserMessage(error);
    throw new functions.https.HttpsError('internal', userMessage);
  }
});

/**
 * Create a one-time PaymentIntent for store checkout (locks/boxes) on connected account
 * Feature-flagged: Requires storeEnabledGlobal OR facilityId in allowlist
 */
export const createStoreCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, lineItems, customerEmail, customerName } = data;

  if (!facilityId || !lineItems || !Array.isArray(lineItems) || lineItems.length === 0) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and lineItems are required');
  }

  // Feature flag check
  const storeEnabled = await isStripeFeatureEnabled('store', facilityId);
  if (!storeEnabled) {
    throw new functions.https.HttpsError('failed-precondition', 'Store checkout is not enabled for this facility');
  }

  try {
    // Verify user has access to this facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};
    const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
    }

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'owner') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    const stripe = getStripeClient();

    // Calculate total amount from line items
    let totalAmount = 0;
    lineItems.forEach((item: any) => {
      const amount = Math.round((item.price || 0) * 100); // Convert to cents
      totalAmount += amount;
    });

    // Create PaymentIntent on CONNECTED account
    const paymentIntent = await stripe.paymentIntents.create({
      amount: totalAmount,
      currency: 'usd',
      payment_method_types: ['card'],
      description: `Store purchase - ${facilityData?.name || 'Facility'}`,
      metadata: {
        facilityId,
        chargeType: 'store_checkout',
        userId: context.auth.uid,
        lineItemCount: lineItems.length.toString(),
      },
    }, {
      stripeAccount: connectAccountId, // Create on connected account
    });

    // Store sale record in Firestore
    const saleRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('sales')
      .doc();

    await saleRef.set({
      facilityId,
      stripePaymentIntentId: paymentIntent.id,
      stripeConnectedAccountId: connectAccountId,
      lineItems: lineItems.map((item: any) => ({
        sku: item.sku || null,
        name: item.name || 'Store Item',
        description: item.description || null,
        quantity: item.quantity || 1,
        price: item.price || 0,
      })),
      totalAmount: totalAmount / 100,
      currency: 'usd',
      customerEmail: customerEmail || null,
      customerName: customerName || null,
      status: 'pending',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: context.auth.uid,
    });

    functions.logger.info(`Store checkout created on connected account: ${paymentIntent.id} for facility ${facilityId}`);

    return {
      clientSecret: paymentIntent.client_secret,
      paymentIntentId: paymentIntent.id,
      saleId: saleRef.id,
      amount: totalAmount / 100,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to create store checkout';
    functions.logger.error('Error creating store checkout:', {
      facilityId,
      error: safeError,
    });
    throw new functions.https.HttpsError('internal', `Failed to create store checkout: ${safeError}`);
  }
});


/**
 * Handle Stripe Connect account updates
 * Updates facility when connected account status changes
 */
async function handleConnectAccountUpdated(account: Stripe.Account) {
  try {
    const facilityId = account.metadata?.facilityId;
    if (!facilityId) {
      functions.logger.warn('Connect account updated but no facilityId in metadata');
      return;
    }

    const onboardingComplete = account.details_submitted && account.charges_enabled && account.payouts_enabled;

    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .update({
        stripeConnectOnboardingComplete: onboardingComplete,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Updated Connect account status for facility ${facilityId}: onboardingComplete=${onboardingComplete}`);
  } catch (error: any) {
    functions.logger.error('Error handling Connect account update', error);
  }
}

/**
 * Lookup user by email for invite purposes
 * Returns minimal user data (uid, email, name) for security
 */
async function updateFacilityFromPlatformSubscription(facilityId: string, subscriptionId: string) {
  try {
    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);

    let status: string = 'active';
    switch (subscription.status) {
      case 'active': status = 'active'; break;
      case 'past_due': status = 'pastDue'; break;
      case 'canceled': status = 'cancelled'; break;
      case 'trialing': status = 'trialing'; break;
      case 'incomplete': status = 'incomplete'; break;
      case 'incomplete_expired': status = 'incompleteExpired'; break;
      case 'unpaid': status = 'unpaid'; break;
      default: status = 'active';
    }

    await admin.firestore().collection('facilities').doc(facilityId).update({
      stripePlatformSubscriptionId: subscriptionId,
      platformSubscriptionStatus: status,
      platformSubscriptionCurrentPeriodStart: subPeriodStart(subscription)
        ? admin.firestore.Timestamp.fromMillis(subPeriodStart(subscription)! * 1000)
        : null,
      platformSubscriptionCurrentPeriodEnd: subPeriodEnd(subscription)
        ? admin.firestore.Timestamp.fromMillis(subPeriodEnd(subscription)! * 1000)
        : null,
      platformSubscriptionCancelAtPeriodEnd: subscription.cancel_at_period_end,
      platformSubscriptionTrialEnd: subscription.trial_end
        ? admin.firestore.Timestamp.fromMillis(subscription.trial_end * 1000)
        : null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    functions.logger.info(`Facility ${facilityId} updated from platform subscription ${subscriptionId}`);
  } catch (error: any) {
    functions.logger.error(`Error updating facility from subscription: ${error.message}`, error);
  }
}

async function updateAccountFromSubscription(accountId: string, subscriptionId: string) {
  try {
    const stripe = getStripeClient();
    const subscription = await stripe.subscriptions.retrieve(subscriptionId);

    let status: string = 'active';
    switch (subscription.status) {
      case 'active':
        status = 'active';
        break;
      case 'past_due':
        status = 'pastDue';
        break;
      case 'canceled':
        status = 'cancelled';
        break;
      case 'trialing':
        status = 'trialing';
        break;
      case 'incomplete':
        status = 'incomplete';
        break;
      case 'incomplete_expired':
        status = 'incompleteExpired';
        break;
      case 'unpaid':
        status = 'unpaid';
        break;
      default:
        status = 'active';
    }

    await admin.firestore()
      .collection('facilityCreatorAccounts')
      .doc(accountId)
      .update({
        subscriptionStatus: status,
        stripeSubscriptionId: subscriptionId,
        subscriptionCurrentPeriodStart: subPeriodStart(subscription)
          ? admin.firestore.Timestamp.fromMillis(subPeriodStart(subscription)! * 1000)
          : null,
        subscriptionCurrentPeriodEnd: subPeriodEnd(subscription)
          ? admin.firestore.Timestamp.fromMillis(subPeriodEnd(subscription)! * 1000)
          : null,
        subscriptionCancelAtPeriodEnd: subscription.cancel_at_period_end,
        subscriptionCanceledAt: subscription.canceled_at
          ? admin.firestore.Timestamp.fromMillis(subscription.canceled_at * 1000)
          : null,
        subscriptionTrialEnd: subscription.trial_end
          ? admin.firestore.Timestamp.fromMillis(subscription.trial_end * 1000)
          : null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    functions.logger.info(`Account ${accountId} updated from subscription ${subscriptionId}`);
  } catch (error: any) {
    functions.logger.error(`Error updating account from subscription: ${error.message}`, error);
  }
}

