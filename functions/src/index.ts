import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getDownloadURL } from 'firebase-admin/storage';
import * as crypto from 'crypto';
import { PDFDocument } from 'pdf-lib';
import express from 'express';
import * as sgMailModule from '@sendgrid/mail';
import Stripe from 'stripe';
import { defineString, defineSecret } from 'firebase-functions/params';
import * as Sentry from '@sentry/node';
import OpenAI from 'openai';
import twilio from 'twilio';
import * as stripeTenantBilling from './stripe/tenant_billing';
import * as quickBooksAccounting from './accounting/quickbooks';
import { diagnosticFixOwnership } from './diagnostic_fix_ownership';
import {
  computeA2PStatus,
  ensureIdempotentResource,
  isHelpKeyword,
  isStartKeyword,
  isStopKeyword,
} from './texting_onboarding_helpers';
import { adminDeleteDocumentTree } from './admin_delete_document_tree';

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

// Robust module-normalization wrapper for SendGrid to handle ESM/CommonJS interop
const sgMail: any = (sgMailModule as any).default ?? sgMailModule;

interface TenantPortalRequest {
  email: string;
  accessCode: string;
}

// Define environment parameters for SendGrid
const SENDGRID_API_KEY = defineSecret('SENDGRID_API_KEY');
const SENDGRID_SENDER_EMAIL = defineString('SENDGRID_SENDER_EMAIL');
const SENDGRID_FROM_EMAIL = SENDGRID_SENDER_EMAIL;
const SENDGRID_FROM_NAME = defineString('SENDGRID_FROM_NAME', { default: 'Storage Facility Creator' });

// Define environment parameters for Stripe (all from Firebase Secrets for tenant Add Card / Connect)
const STRIPE_SECRET_KEY = defineSecret('STRIPE_SECRET_KEY');
const STRIPE_WEBHOOK_SECRET = defineSecret('STRIPE_WEBHOOK_SECRET');
const STRIPE_PUBLISHABLE_KEY = defineSecret('STRIPE_PUBLISHABLE_KEY');
// Use process.env for STRIPE_CONNECT_CLIENT_ID to avoid deployment requirement
// It's stored as a secret: ca_TWVomtZkyvI6Ie1ZLDJhjLiWHIwjtAwB

const STRIPE_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PUBLISHABLE_KEY];

// Define parameters for Twilio
const TWILIO_ACCOUNT_SID = defineString('TWILIO_ACCOUNT_SID');
const TWILIO_AUTH_TOKEN = defineSecret('TWILIO_AUTH_TOKEN');
const TWILIO_PHONE_NUMBER = defineString('TWILIO_PHONE_NUMBER');
const TWILIO_DRY_RUN = defineString('TWILIO_DRY_RUN', { default: 'false' });

// Define parameters for AI Assistant (LLM)
const OPENAI_API_KEY = defineSecret('OPENAI_API_KEY');

// Define parameters for QuickBooks Online Accounting integration
const QUICKBOOKS_CLIENT_ID = defineSecret('QUICKBOOKS_CLIENT_ID');
const QUICKBOOKS_CLIENT_SECRET = defineSecret('QUICKBOOKS_CLIENT_SECRET');
const QUICKBOOKS_REDIRECT_URI = defineString('QUICKBOOKS_REDIRECT_URI');
const QUICKBOOKS_ENV = defineString('QUICKBOOKS_ENV', { default: 'sandbox' });
const MARKETING_LEAD_CAPTURE_KEY = defineSecret('MARKETING_LEAD_CAPTURE_KEY');

const SENDGRID_SECRETS = [SENDGRID_API_KEY];
const TWILIO_SECRETS = [TWILIO_AUTH_TOKEN];
const AI_SECRETS = [OPENAI_API_KEY];
const QUICKBOOKS_SECRETS = [QUICKBOOKS_CLIENT_ID, QUICKBOOKS_CLIENT_SECRET];

let twilioClient: any = null;
function isTwilioDryRunEnabled(): boolean {
  return (TWILIO_DRY_RUN.value() || 'false').toLowerCase() === 'true';
}
function getTwilioClient(): any {
  if (!twilioClient) {
    const accountSid = TWILIO_ACCOUNT_SID.value().trim();
    const authToken = TWILIO_AUTH_TOKEN.value().trim();
    twilioClient = twilio(accountSid, authToken);
  }
  return twilioClient;
}

// Super admin email list (case-insensitive checks via helper).
// Can be overridden via SUPER_ADMIN_EMAILS env var (comma-separated).
// Must match lib/services/superadmin_service.dart and firestore.rules
const SUPER_ADMIN_EMAILS_HARDCODED = [
  'russell_forsyth_1992@outlook.com',
  'kennethgriggs03@gmail.com',
];

// Parse environment variable or use hardcoded list
// Use process.env directly to avoid Firebase params deployment requirement
function getSuperAdminEmails(): string[] {
  const envValue = process.env.SUPER_ADMIN_EMAILS;
  return envValue && envValue.trim()
    ? envValue.split(',').map((e: string) => e.trim()).filter((e: string) => e.length > 0)
    : SUPER_ADMIN_EMAILS_HARDCODED;
}

/**
 * Check if a user is a super admin
 */
function isSuperAdmin(userEmail: string | undefined): boolean {
  if (!userEmail) return false;
  const lowerEmail = userEmail.toLowerCase();
  const adminEmails = getSuperAdminEmails();
  return adminEmails.some((adminEmail: string) => 
    adminEmail.toLowerCase() === lowerEmail,
  );
}

/**
 * Public marketing lead capture endpoint.
 * Called by marketing site's /api/contact route using a shared API key.
 */
export const captureMarketingLead = functions.runWith({ secrets: [MARKETING_LEAD_CAPTURE_KEY] }).https.onRequest(async (req, res) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, x-api-key');
  res.set('Access-Control-Allow-Methods', 'POST, OPTIONS');

  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }

  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  try {
    const expectedKey = MARKETING_LEAD_CAPTURE_KEY.value().trim();
    const providedKey = String(req.headers['x-api-key'] || '').trim();
    if (!expectedKey || providedKey !== expectedKey) {
      res.status(401).json({ error: 'Unauthorized' });
      return;
    }

    const payload = (req.body || {}) as Record<string, unknown>;
    const name = String(payload.name || '').trim();
    const email = String(payload.email || '').trim();
    const facilityName = String(payload.facilityName || '').trim();
    const phone = String(payload.phone || '').trim();
    const unitCount = String(payload.unitCount || '').trim();
    const message = String(payload.message || '').trim();
    const intentRaw = String(payload.intent || 'demo').trim().toLowerCase();
    const intent = intentRaw === 'trial' ? 'trial' : 'demo';
    const smsConsent = Boolean(payload.smsConsent);
    const utmSource = String(payload.utmSource || '').trim();
    const utmMedium = String(payload.utmMedium || '').trim();
    const utmCampaign = String(payload.utmCampaign || '').trim();
    const utmTerm = String(payload.utmTerm || '').trim();
    const utmContent = String(payload.utmContent || '').trim();
    const landingPath = String(payload.landingPath || '').trim();
    const referrer = String(payload.referrer || '').trim();

    if (!name || !email || !facilityName) {
      res.status(400).json({ error: 'name, email, and facilityName are required' });
      return;
    }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      res.status(400).json({ error: 'Invalid email format' });
      return;
    }

    const now = admin.firestore.FieldValue.serverTimestamp();
    const docRef = await admin.firestore().collection('marketing_leads').add({
      source: 'website_contact',
      status: 'new',
      intent,
      name,
      email,
      facilityName,
      phone: phone || null,
      unitCount: unitCount || null,
      message: message || null,
      utmSource: utmSource || null,
      utmMedium: utmMedium || null,
      utmCampaign: utmCampaign || null,
      utmTerm: utmTerm || null,
      utmContent: utmContent || null,
      landingPath: landingPath || null,
      referrer: referrer || null,
      smsConsent,
      assignedToUid: null,
      assignedToEmail: null,
      assignedToName: null,
      lastCalledAt: null,
      saleStatus: 'pending',
      saleAmount: null,
      createdAt: now,
      updatedAt: now,
    });

    await docRef.collection('activities').add({
      type: 'lead_created',
      summary: `Lead created from website contact form (${intent}).`,
      actorUid: 'system',
      actorEmail: 'system',
      actorName: 'System',
      createdAt: now,
    });

    res.status(200).json({ success: true, id: docRef.id });
  } catch (error) {
    functions.logger.error('captureMarketingLead failed', { error });
    res.status(500).json({ error: 'Internal error' });
  }
});

/**
 * Super admin only: delete a user from Firebase Auth and Firestore users collection.
 */
export const superAdminDeleteUser = functions.https.onCall(async (data: { uid: string }, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can delete users');
  }
  const uid = (data?.uid || '').toString().trim();
  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'uid is required');
  }
  const targetUser = await admin.auth().getUser(uid);
  if (isSuperAdmin(targetUser.email)) {
    throw new functions.https.HttpsError('permission-denied', 'Cannot delete a super admin account');
  }
  await admin.auth().deleteUser(uid);
  await admin.firestore().collection('users').doc(uid).delete();
  functions.logger.info('superAdminDeleteUser', { uid, deletedBy: callerEmail });
  return { success: true };
});

interface SuperAdminDeleteFacilityCreatorAccountData {
  accountId: string;
  ownerEmailConfirmation: string;
}

/**
 * Super admin only: permanently remove a facility-creator account, all facilities
 * owned by that user (full document trees), the facilityCreatorAccounts doc (and
 * its subcollections), and the owner's Firebase Auth + users/{uid} document.
 *
 * Caller must type the account owner's email exactly (case-insensitive) as confirmation.
 */
export const superAdminDeleteFacilityCreatorAccount = functions
  .https.onCall(async (data: SuperAdminDeleteFacilityCreatorAccountData, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Only super admins can delete facility creator accounts',
      );
    }

    const accountId = (data?.accountId || '').toString().trim();
    const confirmation = (data?.ownerEmailConfirmation || '').toString().trim().toLowerCase();
    if (!accountId) {
      throw new functions.https.HttpsError('invalid-argument', 'accountId is required');
    }
    if (!confirmation) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'ownerEmailConfirmation is required',
      );
    }

    const db = admin.firestore();
    const accountRef = db.collection('facilityCreatorAccounts').doc(accountId);
    const accountSnap = await accountRef.get();
    if (!accountSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Account not found');
    }

    const accountData = accountSnap.data() as Record<string, unknown>;
    const ownerUid = (accountData.ownerUid || '').toString().trim();
    const ownerEmail = (accountData.ownerEmail || '').toString().trim();
    if (!ownerUid) {
      throw new functions.https.HttpsError('failed-precondition', 'Account has no ownerUid');
    }

    if (ownerEmail.toLowerCase() !== confirmation) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Email confirmation does not match this account owner',
      );
    }

    let ownerAuthEmail: string | undefined;
    try {
      const ownerUser = await admin.auth().getUser(ownerUid);
      ownerAuthEmail = ownerUser.email;
    } catch (e: unknown) {
      const code = (e as { code?: string })?.code;
      if (code !== 'auth/user-not-found') {
        throw e;
      }
    }

    if (isSuperAdmin(ownerAuthEmail ?? ownerEmail)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'Cannot delete an account owned by a super admin',
      );
    }

    const facilitiesSnap = await db
      .collection('facilities')
      .where('ownerUid', '==', ownerUid)
      .get();

    for (const f of facilitiesSnap.docs) {
      await adminDeleteDocumentTree(f.ref);
    }

    await adminDeleteDocumentTree(accountRef);

    try {
      await admin.auth().deleteUser(ownerUid);
    } catch (e: unknown) {
      const code = (e as { code?: string })?.code;
      if (code !== 'auth/user-not-found') {
        throw e;
      }
    }

    await db.collection('users').doc(ownerUid).delete();

    functions.logger.info('superAdminDeleteFacilityCreatorAccount', {
      accountId,
      ownerUid,
      deletedBy: callerEmail,
      facilitiesDeleted: facilitiesSnap.size,
    });

    return { success: true, facilitiesDeleted: facilitiesSnap.size };
  });

/**
 * Super admin only: disable a user in Firebase Auth (they cannot sign in).
 */
export const superAdminDisableUser = functions.https.onCall(async (data: { uid: string }, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can disable users');
  }
  const uid = (data?.uid || '').toString().trim();
  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'uid is required');
  }
  const targetUser = await admin.auth().getUser(uid);
  if (isSuperAdmin(targetUser.email)) {
    throw new functions.https.HttpsError('permission-denied', 'Cannot disable a super admin account');
  }
  await admin.auth().updateUser(uid, { disabled: true });
  await admin.firestore().collection('users').doc(uid).set(
    { authDisabled: true, authDisabledAt: admin.firestore.FieldValue.serverTimestamp() },
    { merge: true },
  );
  functions.logger.info('superAdminDisableUser', { uid, disabledBy: callerEmail });
  return { success: true };
});

/**
 * Super admin only: re-enable a disabled user in Firebase Auth.
 */
export const superAdminEnableUser = functions.https.onCall(async (data: { uid: string }, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  const callerEmail = context.auth.token?.email as string | undefined;
  if (!isSuperAdmin(callerEmail)) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can enable users');
  }
  const uid = (data?.uid || '').toString().trim();
  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'uid is required');
  }
  await admin.auth().updateUser(uid, { disabled: false });
  await admin.firestore().collection('users').doc(uid).set(
    { authDisabled: false, authDisabledAt: admin.firestore.FieldValue.delete() },
    { merge: true },
  );
  functions.logger.info('superAdminEnableUser', { uid, enabledBy: callerEmail });
  return { success: true };
});

/**
 * Super admin only: send a password reset email to the user (Firebase Auth link via SendGrid).
 */
export const superAdminSendPasswordReset = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(
  async (data: { uid: string }, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    }
    const callerEmail = context.auth.token?.email as string | undefined;
    if (!isSuperAdmin(callerEmail)) {
      throw new functions.https.HttpsError('permission-denied', 'Only super admins can send password reset');
    }
    const uid = (data?.uid || '').toString().trim();
    if (!uid) {
      throw new functions.https.HttpsError('invalid-argument', 'uid is required');
    }
    const targetUser = await admin.auth().getUser(uid);
    const userEmail = targetUser.email;
    if (!userEmail) {
      throw new functions.https.HttpsError('invalid-argument', 'User has no email address');
    }
    const resetLink = await admin.auth().generatePasswordResetLink(userEmail);
    const sendGridFromEmail = SENDGRID_FROM_EMAIL.value();
    const fromName = SENDGRID_FROM_NAME.value();
    const msg = {
      to: userEmail,
      from: { email: sendGridFromEmail, name: fromName },
      subject: 'Reset your password - Storage Facility Creator',
      html: `<p>You requested a password reset. Click the link below to set a new password:</p><p><a href="${resetLink}">Reset password</a></p><p>If you did not request this, you can ignore this email.</p>`,
      text: `Reset your password: ${resetLink}\n\nIf you did not request this, you can ignore this email.`,
    };
    await sgMail.send(msg);
    functions.logger.info('superAdminSendPasswordReset', { uid, to: userEmail, sentBy: callerEmail });
    return { success: true };
  },
);

// Generate a short numeric access code for gate access / tokens
function generateAccessCode(): string {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

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
    stripeClient = new Stripe(secretKey, {
      apiVersion: '2026-02-25.clover',
    });
  }
  return stripeClient;
}

function getQuickBooksConfig(): quickBooksAccounting.QuickBooksConfig {
  const envRaw = (QUICKBOOKS_ENV.value() || 'sandbox').trim().toLowerCase();
  return {
    clientId: QUICKBOOKS_CLIENT_ID.value(),
    clientSecret: QUICKBOOKS_CLIENT_SECRET.value(),
    redirectUri: QUICKBOOKS_REDIRECT_URI.value(),
    environment: envRaw === 'production' ? 'production' : 'sandbox',
  };
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

// Initialize SendGrid
let sendGridInitialized = false;

function initializeSendGrid(): void {
  if (!sendGridInitialized) {
    // #region agent log
    functions.logger.info('🔍 [initializeSendGrid:H10] Starting SendGrid initialization');
    // #endregion
    
    const apiKey = SENDGRID_API_KEY.value();
    
    // #region agent log
    functions.logger.info('🔍 [initializeSendGrid:H10] API key retrieved from secret', {
      keyExists: !!apiKey,
    });
    // #endregion
    
    if (!apiKey) {
      // #region agent log
      functions.logger.error('❌ [initializeSendGrid:H10] SENDGRID_API_KEY is null or empty');
      // #endregion
      throw new Error('SENDGRID_API_KEY environment variable is not set');
    }
    
    const fromEmail = SENDGRID_FROM_EMAIL.value();
    
    // #region agent log
    functions.logger.info('🔍 [initializeSendGrid:H10] From email retrieved', {
      emailExists: !!fromEmail,
      email: fromEmail || 'N/A',
    });
    // #endregion
    
    if (!fromEmail) {
      // #region agent log
      functions.logger.error('❌ [initializeSendGrid:H10] SENDGRID_FROM_EMAIL is null or empty');
      // #endregion
      throw new Error('SENDGRID_SENDER_EMAIL environment variable is not set');
    }
    
    // #region agent log
    functions.logger.info('🔍 [initializeSendGrid:H10] Setting API key on sgMail client');
    // #endregion
    
    sgMail.setApiKey(apiKey);
    sendGridInitialized = true;
    
    // #region agent log
    functions.logger.info('✅ [initializeSendGrid:H10] SendGrid initialization complete', {
      sendGridInitialized,
      fromEmail,
    });
    // #endregion
  } else {
    // #region agent log
    functions.logger.info('⚠️ [initializeSendGrid:H10] SendGrid already initialized, skipping');
    // #endregion
  }
}

/**
 * Helper function to create or update a message log in Firestore
 */
async function createOrUpdateMessageLog(
  facilityId: string,
  messageId: string,
  data: {
    tenantId?: string | null;
    tenantName?: string | null;
    tenantEmail?: string | null;
    tenantPhone?: string | null;
    channel: 'email' | 'sms';
    direction: 'outbound';
    source: 'manual' | 'bulk' | 'automation';
    templateId?: string | null;
    subject?: string | null; // Email only
    previewText?: string | null;
    bodyHtmlStored?: boolean;
    bodyTextStored?: boolean;
    status: 'queued' | 'sent' | 'failed';
    provider: 'sendgrid' | 'twilio';
    providerMessageId?: string | null;
    errorCode?: string | null;
    errorMessage?: string | null;
    sentAt?: admin.firestore.Timestamp | null;
    createdByUid: string;
    createdByEmail?: string | null;
  },
): Promise<void> {
  const messageLogRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('messageLogs')
    .doc(messageId);

  const logData: any = {
    facilityId,
    tenantId: data.tenantId || null,
    tenantName: data.tenantName || null,
    tenantEmail: data.tenantEmail || null,
    tenantPhone: data.tenantPhone || null,
    channel: data.channel,
    direction: data.direction,
    source: data.source,
    templateId: data.templateId || null,
    subject: data.subject || null,
    previewText: data.previewText || null,
    bodyHtmlStored: data.bodyHtmlStored || false,
    bodyTextStored: data.bodyTextStored || false,
    status: data.status,
    provider: data.provider,
    providerMessageId: data.providerMessageId || null,
    errorCode: data.errorCode || null,
    errorMessage: data.errorMessage || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    sentAt: data.sentAt || null,
    createdByUid: data.createdByUid,
    createdByEmail: data.createdByEmail || null,
  };

  // If status is 'queued', this is a new log; if 'sent' or 'failed', update existing
  if (data.status === 'queued') {
    await messageLogRef.set(logData);
  } else {
    // Update existing log, preserving createdAt
    const updateData: any = {
      ...logData,
      createdAt: admin.firestore.FieldValue.serverTimestamp(), // Keep server timestamp
    };
    await messageLogRef.set(updateData, { merge: true });
  }
}

/**
 * Helper function to build branded email footer for a facility
 */
function buildFacilityFooter(
  facilityName: string,
  facilityAddress?: string | null,
  facilityPhone?: string | null,
): { html: string; text: string } {
  const lines: string[] = [];
  if (facilityAddress) lines.push(facilityAddress);
  if (facilityPhone) lines.push(facilityPhone);

  // HTML footer
  let htmlFooter = '<hr style="margin:16px 0;border:none;border-top:1px solid #e0e0e0;"/>';
  htmlFooter += '<div style="font-size:14px;line-height:1.4;color:#666;margin-top:16px;">';
  htmlFooter += `<strong>${escapeHtml(facilityName)}</strong>`;
  if (lines.length > 0) {
    htmlFooter += '<br/>';
    htmlFooter += lines.map(line => escapeHtml(line)).join('<br/>');
  }
  htmlFooter += '</div>';

  // Text footer
  let textFooter = '\n--\n';
  textFooter += facilityName;
  if (lines.length > 0) {
    textFooter += '\n' + lines.join('\n');
  }

  return { html: htmlFooter, text: textFooter };
}

/**
 * Helper function to escape HTML entities
 */
function escapeHtml(text: string): string {
  const map: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    '\'': '&#039;',
  };
  return text.replace(/[&<>"']/g, (m) => map[m]);
}

/**
 * Helper function to get tenant information for message logging
 */
async function getTenantInfo(
  facilityId: string,
  tenantId?: string | null,
  email?: string | null,
  phone?: string | null,
): Promise<{
  tenantId: string | null;
  tenantName: string | null;
  tenantEmail: string | null;
  tenantPhone: string | null;
}> {
  if (!tenantId && !email && !phone) {
    return {
      tenantId: null,
      tenantName: null,
      tenantEmail: email || null,
      tenantPhone: phone || null,
    };
  }

  try {
    let tenantDoc: admin.firestore.DocumentSnapshot | null = null;

    if (tenantId) {
      tenantDoc = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .get();
    } else if (email) {
      const tenantQuery = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .where('email', '==', email)
        .limit(1)
        .get();
      if (!tenantQuery.empty) {
        tenantDoc = tenantQuery.docs[0];
      }
    } else if (phone) {
      const tenantQuery = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .where('phone', '==', phone)
        .limit(1)
        .get();
      if (!tenantQuery.empty) {
        tenantDoc = tenantQuery.docs[0];
      }
    }

    if (tenantDoc && tenantDoc.exists) {
      const tenantData = tenantDoc.data() as Record<string, any>;
      return {
        tenantId: tenantDoc.id,
        tenantName: tenantData.name || null,
        tenantEmail: tenantData.email || email || null,
        tenantPhone: tenantData.phone || phone || null,
      };
    }
  } catch (error) {
    functions.logger.warn('Failed to fetch tenant info for message log', { error, facilityId, tenantId, email, phone });
  }

  return {
    tenantId: tenantId || null,
    tenantName: null,
    tenantEmail: email || null,
    tenantPhone: phone || null,
  };
}

interface EmailRequest {
  to: string;
  subject: string;
  html?: string; // Optional: will be generated from text if not provided
  text?: string; // Optional: at least one of html or text must be provided
  facilityId: string;
  templateId?: string;
  variables?: Record<string, any>;
  fromName?: string; // Optional: override default From name (e.g., "{FacilityName} via Storage Facility Creator")
  tenantId?: string; // Optional: for message logging and tenant context
  source?: 'manual' | 'bulk' | 'automation'; // Optional: source of the message
}

interface DigestRequest {
  facilityId: string;
  digestId: string;
  to: string;
  subject: string;
  html: string;
  text?: string;
  templateId?: string;
  variables?: Record<string, any>;
}

/**
 * Send individual email via SendGrid
 */
export const sendEmail = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(async (data: EmailRequest, context) => {
  // Log payload at the very start for debugging
  functions.logger.info('📧 [sendEmail] Function invoked', {
    hasData: !!data,
    facilityId: data?.facilityId || 'missing',
    to: data?.to || 'missing',
    subject: data?.subject || 'missing',
    hasHtml: !!(data?.html),
    htmlLength: data?.html?.length || 0,
    hasText: !!(data?.text),
    textLength: data?.text?.length || 0,
    fromName: data?.fromName || 'null',
    templateId: data?.templateId || 'null',
    hasAuth: !!context.auth,
    userId: context.auth?.uid || 'null',
  });

  // Verify authentication
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated to send emails');
  }
  enforceAppCheckOrThrow(context);
  await enforceRateLimit({
    facilityId: data.facilityId,
    key: 'sendEmail',
    limit: 60, // per minute per facility
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { to, subject, html, text, facilityId, templateId, variables, fromName, tenantId, source } = data;

  // Validate required fields
  if (!to || !subject || !facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields: to, subject, facilityId');
  }

  // Validate that we have either html or text content
  if (!html && !text) {
    throw new functions.https.HttpsError('invalid-argument', 'Email must have either html or text content');
  }

  // Generate message log ID early
  const messageLogId = `email-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;

  try {
    // Get user email for super admin check and message logging
    const userRecord = await admin.auth().getUser(context.auth.uid);
    const userEmail = userRecord.email;
    const isSuperAdminUser = isSuperAdmin(userEmail);
    
    if (isSuperAdminUser) {
      functions.logger.info(`Super admin ${userEmail} sending email - bypassing permission checks`);
    }

    // Verify user has access to the facility (owner or manager)
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilityDoc = await facilityRef.get();
    const facilityData = facilityDoc.data() as Record<string, any> | undefined;

    if (!facilityDoc.exists || !facilityData) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    // Super admins bypass all permission checks
    if (!isSuperAdminUser) {
      const ownerUid = facilityData.ownerUid;
      const managersMap = (facilityData.managers ?? {}) as Record<string, any>;
      const isOwner = ownerUid === context.auth.uid;
      const isManager = managersMap[context.auth.uid ?? ''] === true;

      // Check new permission system (user_roles collection)
      let hasPermission = false;
      // Always check user_roles to support the new permission system
      const userRolesQuery = await admin.firestore()
        .collection('user_roles')
        .where('userId', '==', context.auth.uid)
        .where('facilityId', '==', facilityId)
        .where('isActive', '==', true)
        .limit(1)
        .get();

      if (!userRolesQuery.empty) {
        const userRole = userRolesQuery.docs[0].data();
        const roleType = userRole.roleType as string;
        // Allow owner, admin, and manager roles to send emails
        if (roleType === 'owner' || roleType === 'admin' || roleType === 'manager') {
          hasPermission = true;
        }
      }

      if (!isOwner && !isManager && !hasPermission) {
        throw new functions.https.HttpsError(
          'permission-denied',
          'User is not authorized to send email for this facility',
        );
      }
    }

    // Get tenant information for message logging
    const tenantInfo = await getTenantInfo(
      facilityId,
      tenantId || variables?.tenantId,
      to,
      null,
    );

    // Create message log with status "queued"
    const previewText = (text || html || '').replace(/<[^>]*>/g, '').substring(0, 200);
    await createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId: tenantInfo.tenantId,
      tenantName: tenantInfo.tenantName,
      tenantEmail: tenantInfo.tenantEmail || to,
      tenantPhone: tenantInfo.tenantPhone,
      channel: 'email',
      direction: 'outbound',
      source: source || 'manual',
      templateId: templateId || null,
      subject: subject,
      previewText: previewText,
      bodyHtmlStored: false, // Don't store full body by default
      bodyTextStored: false,
      status: 'queued',
      provider: 'sendgrid',
      providerMessageId: null,
      errorCode: null,
      errorMessage: null,
      sentAt: null,
      createdByUid: context.auth.uid,
      createdByEmail: userEmail || null,
    });

    // Check and increment email usage
    const canSend = await checkAndIncrementEmailUsage(facilityId);
    if (!canSend.success) {
      // Update message log to failed
      await createOrUpdateMessageLog(facilityId, messageLogId, {
        tenantId: tenantInfo.tenantId,
        tenantName: tenantInfo.tenantName,
        tenantEmail: tenantInfo.tenantEmail || to,
        tenantPhone: tenantInfo.tenantPhone,
        channel: 'email',
        direction: 'outbound',
        source: source || 'manual',
        templateId: templateId || null,
        subject: subject,
        previewText: previewText,
        bodyHtmlStored: false,
        bodyTextStored: false,
        status: 'failed',
        provider: 'sendgrid',
        providerMessageId: null,
        errorCode: 'resource-exhausted',
        errorMessage: canSend.message || 'Email quota exceeded',
        sentAt: null,
        createdByUid: context.auth.uid,
        createdByEmail: userEmail || null,
      });
      throw new functions.https.HttpsError('resource-exhausted', canSend.message || 'Email quota exceeded');
    }

    // Validate SendGrid configuration early
    let sendGridApiKey: string;
    let sendGridFromEmail: string;
    try {
      sendGridApiKey = SENDGRID_API_KEY.value();
      if (!sendGridApiKey || sendGridApiKey.trim().length === 0) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'SendGrid API key not configured. Please set SENDGRID_API_KEY secret in Firebase Functions.',
        );
      }
    } catch (e: any) {
      if (e instanceof functions.https.HttpsError) {
        throw e;
      }
      functions.logger.error('❌ [sendEmail] Failed to retrieve SENDGRID_API_KEY', {
        error: e.message,
        errorType: e.constructor.name,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'SendGrid API key not configured. Please set SENDGRID_API_KEY secret in Firebase Functions.',
        { originalError: e.message },
      );
    }

    try {
      sendGridFromEmail = SENDGRID_FROM_EMAIL.value();
      if (!sendGridFromEmail || sendGridFromEmail.trim().length === 0) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'SendGrid sender email not configured. Please set SENDGRID_SENDER_EMAIL in Firebase Functions environment.',
        );
      }
    } catch (e: any) {
      if (e instanceof functions.https.HttpsError) {
        throw e;
      }
      functions.logger.error('❌ [sendEmail] Failed to retrieve SENDGRID_SENDER_EMAIL', {
        error: e.message,
        errorType: e.constructor.name,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'SendGrid sender email not configured. Please set SENDGRID_SENDER_EMAIL in Firebase Functions environment.',
        { originalError: e.message },
      );
    }

    functions.logger.info('✅ [sendEmail] SendGrid configuration validated', {
      hasApiKey: !!sendGridApiKey,
      fromEmail: sendGridFromEmail,
    });

    // Initialize SendGrid with the validated API key
    // Reset initialization flag to ensure we use the current validated key
    sendGridInitialized = false;
    try {
      sgMail.setApiKey(sendGridApiKey);
      sendGridInitialized = true;
      functions.logger.info('✅ [sendEmail] SendGrid API key set successfully');
    } catch (e: any) {
      functions.logger.error('❌ [sendEmail] Failed to set SendGrid API key', {
        error: e.message,
        errorType: e.constructor.name,
        stack: e.stack,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Failed to configure SendGrid API key. Please verify SENDGRID_API_KEY secret is valid.',
        { originalError: e.message },
      );
    }

    // Extract facility branding information (already fetched above)
    const facilityName = facilityData.name || 'Storage Facility';
    const facilityAddress = facilityData.address || null;
    const facilityPhone = facilityData.phone || null;
    const facilityEmail = facilityData.email || null;

    // Build branded footer
    const footer = buildFacilityFooter(facilityName, facilityAddress, facilityPhone);

    // Prepare email content for SendGrid with branded footer
    // Ensure html is always provided (SendGrid requires it)
    let htmlContent = html ?? (text ? `<p>${text.replace(/\n/g, '<br>')}</p>` : '<p>No content provided.</p>');
    // Append branded footer to HTML
    htmlContent += footer.html;

    // Prepare text content with branded footer
    let textContent = text || htmlContent.replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').trim();
    // Append branded footer to text
    textContent += footer.text;
    
    // Use facility name as FROM display name (unless fromName is explicitly provided)
    // This allows override for special cases like invitations
    let emailFromName: string;
    
    if (fromName) {
      // Explicit fromName provided (e.g., for invitations)
      emailFromName = fromName;
    } else {
      // Use facility name as default
      emailFromName = facilityName;
    }
    
    // Build SendGrid message object
    const msg: any = {
      to: to,
      from: {
        email: sendGridFromEmail,
        name: emailFromName,
      },
      subject: subject,
      html: htmlContent,
      text: textContent,
    };

    // Optionally set Reply-To to facility email if available
    if (facilityEmail) {
      msg.replyTo = facilityEmail;
    }

    // Disable SendGrid click tracking for invitation emails so the "Accept Invitation"
    // button link is not rewritten to a tracking URL (e.g. url1827.storagefacilitycreator.com)
    // which can fail with DNS_PROBE_FINISHED_NXDOMAIN and make the button unreachable.
    if (html && html.includes('accept-invite')) {
      msg.trackingSettings = {
        clickTracking: { enable: false },
      };
    }

    // #region agent log
    functions.logger.info('🔍 [sendEmail:H7] Email message prepared', {
      to,
      fromEmail: sendGridFromEmail,
      fromName: emailFromName,
      facilityId: facilityId,
      hasReplyTo: !!facilityEmail,
      replyTo: facilityEmail || null,
    });
    // #endregion

    // Extract invite URL domain for invitation emails (diagnostic logging)
    let inviteUrlDomain: string | null = null;
    if (html && html.includes('accept-invite')) {
      const urlMatch = html.match(/https?:\/\/[^\s"']+/);
      if (urlMatch) {
        try {
          const url = new URL(urlMatch[0]);
          inviteUrlDomain = url.hostname;
        } catch (e) {
          // Invalid URL, skip domain extraction
        }
      }
    }
    
    // Send email via SendGrid
    functions.logger.info(`Attempting to send email via SendGrid`, {
      to: to,
      fromEmail: sendGridFromEmail,
      subject: subject,
    });
    
    let result;
    let messageId: string | null = null;
    try {
      // #region agent log
      functions.logger.info('🔍 [sendEmail:H7] Calling SendGrid API', {
        to,
        fromEmail: sendGridFromEmail,
        subject,
      });
      // #endregion
      
      [result] = await sgMail.send(msg);
      
      // Extract x-message-id from headers (if available)
      messageId = result.headers?.['x-message-id'] || null;
      
      // #region agent log
      functions.logger.info('🔍 [sendEmail:H7] SendGrid API response received', {
        statusCode: result.statusCode,
        to,
      });
      // #endregion
      
      functions.logger.info(`SendGrid API call successful`, {
        statusCode: result.statusCode,
        to: to,
        subject: subject,
        xMessageId: messageId,
      });
    } catch (sgError: any) {
      // #region agent log
      functions.logger.error('❌ [sendEmail:H7] SendGrid API error', {
        error: sgError?.message,
        code: sgError?.code,
        statusCode: sgError?.response?.statusCode,
        responseBody: sgError?.response?.body,
        to: to,
        from: msg.from.email,
        fromName: msg.from.name,
        fromNameSource: fromName ? 'custom' : 'default',
        subject: subject,
        facilityId: facilityId,
        inviteUrlDomain: inviteUrlDomain || null,
        errorType: sgError?.constructor?.name,
        stack: sgError?.stack,
      });
      // #endregion
      
      functions.logger.error(`SendGrid API error`, {
        error: sgError?.message,
        code: sgError?.code,
        response: sgError?.response?.body,
        to: to,
        from: msg.from.email,
        fromName: msg.from.name,
        fromNameSource: fromName ? 'custom' : 'default',
        subject: subject,
        facilityId: facilityId,
        inviteUrlDomain: inviteUrlDomain || null,
      });
      
      // Convert SendGrid errors to appropriate HttpsError
      const statusCode = sgError?.response?.statusCode || sgError?.code;
      const errorMessage = sgError?.message || 'Unknown SendGrid error';
      const responseBody = sgError?.response?.body;

      // Log full error details for debugging
      functions.logger.error('❌ [sendEmail] SendGrid error details', {
        statusCode,
        errorMessage,
        responseBody: typeof responseBody === 'string' ? responseBody.substring(0, 500) : responseBody,
        errorType: sgError?.constructor?.name,
      });

      if (statusCode === 401) {
        // 401 means the API key is invalid, expired, or revoked
        const detailMsg = responseBody?.errors?.[0]?.message || errorMessage;
        throw new functions.https.HttpsError(
          'permission-denied',
          `SendGrid unauthorized: API key is invalid, expired, or revoked. ${detailMsg}. Please verify SENDGRID_API_KEY secret in Firebase Functions is correct and active.`,
          { 
            sendGridError: detailMsg, 
            statusCode,
            hint: 'Check Firebase Functions secrets: firebase functions:secrets:access SENDGRID_API_KEY',
          },
        );
      } else if (statusCode === 403) {
        // Common causes: unverified sender, domain not authenticated, rate limit
        const detailMsg = responseBody?.errors?.[0]?.message || errorMessage;
        throw new functions.https.HttpsError(
          'permission-denied',
          `SendGrid rejected the email: ${detailMsg}. Please verify the sender email is verified in SendGrid.`,
          { sendGridError: errorMessage, statusCode, details: responseBody },
        );
      } else if (statusCode === 400) {
        // Bad request - invalid email format, missing fields, etc.
        const detailMsg = responseBody?.errors?.[0]?.message || errorMessage;
        throw new functions.https.HttpsError(
          'invalid-argument',
          `Invalid email request: ${detailMsg}`,
          { sendGridError: errorMessage, statusCode, details: responseBody },
        );
      } else if (statusCode && statusCode >= 500) {
        throw new functions.https.HttpsError(
          'internal',
          `SendGrid server error (${statusCode}): ${errorMessage}. Please try again later.`,
          { sendGridError: errorMessage, statusCode },
        );
      } else {
        // Unknown error or no status code - convert to internal error with details
        throw new functions.https.HttpsError(
          'internal',
          `SendGrid error: ${errorMessage}. Check logs for details.`,
          { sendGridError: errorMessage, statusCode, originalError: sgError?.toString() },
        );
      }
    }

    // Extract message ID from SendGrid response (already extracted above, reuse it)
    const finalMessageId = messageId || `sg-${Date.now()}`;
    functions.logger.info(`Email sent successfully`, {
      to: to,
      subject: subject,
      statusCode: result.statusCode,
      xMessageId: finalMessageId,
    });

    // Get tenant info again (in case it wasn't retrieved earlier)
    const tenantInfoForLog = await getTenantInfo(
      facilityId,
      tenantId || variables?.tenantId,
      to,
      null,
    );
    const previewTextForLog = (text || html || '').replace(/<[^>]*>/g, '').substring(0, 200);

    // Update message log to "sent"
    await createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId: tenantInfoForLog.tenantId,
      tenantName: tenantInfoForLog.tenantName,
      tenantEmail: tenantInfoForLog.tenantEmail || to,
      tenantPhone: tenantInfoForLog.tenantPhone,
      channel: 'email',
      direction: 'outbound',
      source: source || 'manual',
      templateId: templateId || null,
      subject: subject,
      previewText: previewTextForLog,
      bodyHtmlStored: false,
      bodyTextStored: false,
      status: 'sent',
      provider: 'sendgrid',
      providerMessageId: finalMessageId,
      errorCode: null,
      errorMessage: null,
      sentAt: admin.firestore.Timestamp.now(),
      createdByUid: context.auth.uid,
      createdByEmail: userEmail || null,
    });

    // Also log to legacy emailLogs collection for backward compatibility
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('emailLogs')
      .add({
        to,
        subject,
        status: 'sent',
        messageId: finalMessageId,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        templateId,
        variables,
        sentBy: context.auth.uid,
      });

    await writeAuditLog(facilityId, {
      action: 'email_sent',
      userId: context.auth.uid,
      messageId: finalMessageId,
      subject,
      to,
      templateId: templateId || null,
    });

    // Also log tracking event (for future tracking integration)
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('emailTracking')
      .add({
        messageId: finalMessageId,
        facilityId,
        tenantId: variables?.tenantId || null,
        to,
        subject,
        eventType: 'sent',
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        metadata: {
          templateId,
          sentBy: context.auth.uid,
        },
      });

    functions.logger.info(`Email sent successfully to ${to} for facility ${facilityId}`, {
      messageId: messageId,
      facilityId,
      templateId,
    });

    return {
      success: true,
      messageId: messageId,
      messageLogId: messageLogId,
      status: 'sent',
      provider: 'sendgrid',
      providerMessageId: finalMessageId,
      usageWarning: canSend.warning,
    };

  } catch (error: any) {
    // If it's already an HttpsError, re-throw it (don't wrap it)
    if (error instanceof functions.https.HttpsError) {
      functions.logger.error(
        `Failed to send email to ${to} for facility ${facilityId}`,
        { 
          errorCode: error.code,
          errorMessage: error.message,
          errorDetails: error.details,
          facilityId, 
          to, 
          templateId, 
        },
      );

      // Update message log to "failed"
      try {
        const tenantInfo = await getTenantInfo(
          facilityId,
          tenantId || variables?.tenantId,
          to,
          null,
        );
        const userRecord = await admin.auth().getUser(context.auth.uid);
        const userEmail = userRecord.email;
        const previewText = (text || html || '').replace(/<[^>]*>/g, '').substring(0, 200);

        await createOrUpdateMessageLog(facilityId, messageLogId, {
          tenantId: tenantInfo.tenantId,
          tenantName: tenantInfo.tenantName,
          tenantEmail: tenantInfo.tenantEmail || to,
          tenantPhone: tenantInfo.tenantPhone,
          channel: 'email',
          direction: 'outbound',
          source: source || 'manual',
          templateId: templateId || null,
          subject: subject,
          previewText: previewText,
          bodyHtmlStored: false,
          bodyTextStored: false,
          status: 'failed',
          provider: 'sendgrid',
          providerMessageId: null,
          errorCode: error.code,
          errorMessage: error.message || 'Unknown error',
          sentAt: null,
          createdByUid: context.auth.uid,
          createdByEmail: userEmail || null,
        });
      } catch (logError) {
        // Don't fail if logging fails
        functions.logger.warn('Failed to log email failure to messageLogs', { logError });
      }

      // Also log to legacy emailLogs collection
      try {
        await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('emailLogs')
          .add({
            to,
            subject,
            status: 'failed',
            error: error.message,
            errorCode: error.code,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
            facilityId,
            templateId,
            variables,
            sentBy: context.auth.uid,
          });
      } catch (logError) {
        // Don't fail if logging fails
        functions.logger.warn('Failed to log email failure to Firestore', { logError });
      }

      throw error;
    }

    // For non-HttpsError exceptions, wrap them
    functions.logger.error(
      `Failed to send email to ${to} for facility ${facilityId}`,
      { 
        error: error?.message, 
        errorType: error?.constructor?.name,
        stack: error?.stack, 
        facilityId, 
        to, 
        templateId, 
      },
    );

    // Update message log to "failed"
    try {
      const tenantInfo = await getTenantInfo(
        facilityId,
        tenantId || variables?.tenantId,
        to,
        null,
      );
      const userRecord = await admin.auth().getUser(context.auth.uid);
      const userEmail = userRecord.email;
      const previewText = (text || html || '').replace(/<[^>]*>/g, '').substring(0, 200);

      await createOrUpdateMessageLog(facilityId, messageLogId, {
        tenantId: tenantInfo.tenantId,
        tenantName: tenantInfo.tenantName,
        tenantEmail: tenantInfo.tenantEmail || to,
        tenantPhone: tenantInfo.tenantPhone,
        channel: 'email',
        direction: 'outbound',
        source: source || 'manual',
        templateId: templateId || null,
        subject: subject,
        previewText: previewText,
        bodyHtmlStored: false,
        bodyTextStored: false,
        status: 'failed',
        provider: 'sendgrid',
        providerMessageId: null,
        errorCode: 'internal',
        errorMessage: error?.message || 'Unknown error',
        sentAt: null,
        createdByUid: context.auth.uid,
        createdByEmail: userEmail || null,
      });
    } catch (logError) {
      // Don't fail if logging fails
      functions.logger.warn('Failed to log email failure to messageLogs', { logError });
    }

    // Also log to legacy emailLogs collection
    try {
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('emailLogs')
        .add({
          to,
          subject,
          status: 'failed',
          error: error?.message || 'Unknown error',
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          facilityId,
          templateId,
          variables,
          sentBy: context.auth.uid,
        });
    } catch (logError) {
      // Don't fail if logging fails
      functions.logger.warn('Failed to log email failure to Firestore', { logError });
    }

    // Provide a more actionable error message
    const errorMsg = error?.message || 'Unknown error occurred';
    throw new functions.https.HttpsError(
      'internal', 
      `Failed to send email: ${errorMsg}. Please check logs for details.`,
      { originalError: errorMsg, errorType: error?.constructor?.name },
    );
  }
});

/**
 * Send digest email with multiple reminders via SendGrid
 */
export const sendDigest = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(async (data: DigestRequest, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated to send digest emails');
  }
  enforceAppCheckOrThrow(context);
  await enforceRateLimit({
    facilityId: data.facilityId,
    key: 'sendDigest',
    limit: 15, // per minute per facility
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { facilityId, digestId, to, subject, html, text, templateId, variables } = data;

  try {
    // Verify user owns the facility
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilityDoc = await facilityRef.get();
    
    if (!facilityDoc.exists || facilityDoc.data()?.ownerUid !== context.auth.uid) {
      throw new functions.https.HttpsError('permission-denied', 'User does not own this facility');
    }

    // Check and increment email usage
    const canSend = await checkAndIncrementEmailUsage(facilityId);
    if (!canSend.success) {
      throw new functions.https.HttpsError('resource-exhausted', canSend.message || 'Email quota exceeded');
    }

    // Initialize SendGrid
    initializeSendGrid();

    // Prepare digest email for SendGrid
    const msg = {
      to: to,
      from: {
        email: SENDGRID_FROM_EMAIL.value(),
        name: SENDGRID_FROM_NAME.value(),
      },
      subject: subject,
      html: html,
      ...(text && { text: text }),
    };

    // Send digest email via SendGrid
    const [result] = await sgMail.send(msg);

    // Log digest send
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('emailLogs');
      // Extract message ID from SendGrid response
      const messageId = result.headers['x-message-id'] || `sg-${Date.now()}`;

      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('emailLogs')
        .add({
          to,
          subject,
          status: 'sent',
          messageId: messageId,
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          facilityId,
          templateId,
          digestId,
          variables,
          sentBy: context.auth.uid,
        });

      functions.logger.info(`Digest email sent successfully to ${to} for facility ${facilityId}`, {
        messageId: messageId,
        facilityId,
        digestId,
      });

    return {
      success: true,
      messageId: messageId,
      usageWarning: canSend.warning,
    };

  } catch (error: any) {
    functions.logger.error(`Failed to send digest email to ${to} for facility ${facilityId}`, error);
    throw new functions.https.HttpsError('internal', `Failed to send digest email: ${error.message}`);
  }
});

/**
 * Scheduled function to send daily digest emails at 8am CST
 */
export const sendDailyDigests = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 8 * * *') // 8am CST daily
  .timeZone('America/Chicago')
  .onRun(async (context) => {
    functions.logger.info('Starting daily digest email job');

    try {
      // Get all facilities that have pending digest emails
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      const digestPromises = facilitiesSnapshot.docs.map(async (facilityDoc) => {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        // Get pending digest items for this facility
        const digestSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('digests')
          .where('status', '==', 'pending')
          .where('digestKey', '==', 'daily')
          .get();

        if (digestSnapshot.empty) {
          return; // No pending digests for this facility
        }

        // Group digest items by tenant email
        const digestGroups: Record<string, any[]> = {};
        digestSnapshot.docs.forEach((doc) => {
          const data = doc.data();
          const email = data.tenantEmail;
          if (!digestGroups[email]) {
            digestGroups[email] = [];
          }
          digestGroups[email].push({ id: doc.id, ...data });
        });

        // Send digest email to each tenant
        const sendPromises = Object.entries(digestGroups).map(async ([email, items]) => {
          const digestId = `daily_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
          
          // Generate digest HTML
          const digestHtml = generateDigestHtml(facilityData.name, items);
          
          // Initialize SendGrid
          initializeSendGrid();

          // Prepare email for SendGrid
          const msg = {
            to: email,
            from: {
              email: SENDGRID_FROM_EMAIL.value(),
              name: SENDGRID_FROM_NAME.value(),
            },
            subject: `Daily Reminders - ${facilityData.name}`,
            html: digestHtml,
            text: `Daily reminders from ${facilityData.name}`,
          };

          // Send digest email via SendGrid
          const [result] = await sgMail.send(msg);

          // Extract message ID from SendGrid response
          const messageId = result.headers['x-message-id'] || `sg-${Date.now()}`;

          // Mark digest items as sent
          const batch = admin.firestore().batch();
          items.forEach((item) => {
            batch.update(
              admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('digests')
                .doc(item.id),
              {
                status: 'sent',
                sentAt: admin.firestore.FieldValue.serverTimestamp(),
                messageId: messageId,
                digestId,
              },
            );
          });
          await batch.commit();

          functions.logger.info(`Daily digest sent to ${email} for facility ${facilityId}`);
        });

        await Promise.all(sendPromises);
      });

      await Promise.all(digestPromises);
      functions.logger.info('Daily digest email job completed successfully');

    } catch (error: any) {
      functions.logger.error('Daily digest email job failed', error);
    }
  });

/**
 * Check and increment email usage for a facility
 */
async function checkAndIncrementEmailUsage(facilityId: string): Promise<{success: boolean, message?: string, warning?: string}> {
  const now = new Date();
  const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;
  
  const usageRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('emailUsage')
    .doc(monthKey);

  // First, check if we need to determine the limit
  // Limits are sized to support a fully-active 200-tenant facility:
  //   ~1,184 emails/month at max usage (payment reminders + digests + delinquency + misc)
  // Paid: 5,000/month gives comfortable headroom up to ~800-tenant facilities
  // Trial: 500/month allows meaningful testing without incurring significant cost
  let defaultLimit = 5000; // Default for active subscribers
  const usageDoc = await usageRef.get();
  
  if (!usageDoc.exists || !usageDoc.data()?.emailMonthlyLimit) {
    // Check if facility owner is on trial to set appropriate limit
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (facilityDoc.exists) {
      const ownerUid = facilityDoc.data()?.ownerUid;
      if (ownerUid) {
        const accountSnapshot = await admin.firestore()
          .collection('facilityCreatorAccounts')
          .where('ownerUid', '==', ownerUid)
          .limit(1)
          .get();
        
        if (!accountSnapshot.empty) {
          const accountData = accountSnapshot.docs[0].data();
          if (accountData.subscriptionStatus === 'trialing') {
            defaultLimit = 500; // Trial limit — enough for real testing
          }
        }
      }
    }
  }

  return admin.firestore().runTransaction(async (transaction) => {
    const usageDocSnapshot = await transaction.get(usageRef);
    const currentUsage = usageDocSnapshot.exists ? usageDocSnapshot.data() : {
      emailMonthlyCount: 0,
      emailMonthlyLimit: defaultLimit,
      emailMonth: monthKey,
      lastReset: admin.firestore.FieldValue.serverTimestamp(),
    };

    const newCount = ((currentUsage?.emailMonthlyCount) || 0) + 1;
    const limit = (currentUsage?.emailMonthlyLimit) || defaultLimit;

    // Check if limit exceeded
    if (newCount > limit) {
      return {
        success: false,
        message: `Monthly email limit of ${limit} exceeded. Current usage: ${newCount}`,
      };
    }

    // Update usage count
    transaction.set(usageRef, {
      ...currentUsage,
      emailMonthlyCount: newCount,
      emailMonth: monthKey,
      lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Check for warning threshold (80%)
    const warningThreshold = Math.floor(limit * 0.8);
    const warning = newCount >= warningThreshold ? 
      `Email usage at ${Math.round((newCount / limit) * 100)}% of monthly limit (${newCount}/${limit})` : 
      undefined;

    return {
      success: true,
      warning,
    };
  });
}

/**
 * Generate HTML for digest email
 */
function generateDigestHtml(facilityName: string, items: any[]): string {
  const itemsHtml = items.map(item => `
    <div style="border-left: 4px solid #4CAF50; padding-left: 16px; margin: 16px 0;">
      <h4 style="margin: 0 0 8px 0; color: #333;">${item.title || 'Reminder'}</h4>
      <p style="margin: 0; color: #666;">${item.message}</p>
      ${item.unitNumber ? `<p style="margin: 4px 0; font-size: 14px; color: #888;">Unit: ${item.unitNumber}</p>` : ''}
      ${item.amount ? `<p style="margin: 4px 0; font-size: 14px; color: #888;">Amount: $${item.amount}</p>` : ''}
      ${item.dueDate ? `<p style="margin: 4px 0; font-size: 14px; color: #888;">Due: ${item.dueDate}</p>` : ''}
    </div>
  `).join('');

  return `
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Daily Reminders - ${facilityName}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; background-color: #f4f4f4; margin: 0; padding: 0; }
        .container { max-width: 600px; margin: 20px auto; background-color: #ffffff; padding: 30px; border-radius: 8px; box-shadow: 0 0 10px rgba(0, 0, 0, 0.1); border-top: 5px solid #4CAF50; }
        .header { text-align: center; padding-bottom: 20px; border-bottom: 1px solid #eee; }
        .header h2 { color: #4CAF50; margin: 0; font-size: 24px; }
        .content { padding: 20px 0; }
        .footer { text-align: center; padding-top: 20px; border-top: 1px solid #eee; color: #777; font-size: 12px; }
        @media only screen and (max-width: 600px) { .container { width: 100%; margin: 0; border-radius: 0; box-shadow: none; } }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h2>Daily Reminders from ${facilityName}</h2>
        </div>
        <div class="content">
          <p>Here are your daily reminders:</p>
          ${itemsHtml}
        </div>
        <div class="footer">
          <p>Best regards,<br>${facilityName} Management Team</p>
        </div>
      </div>
    </body>
    </html>
  `;
}

// Signing token TTL in days (configurable for hardening)
const SIGNING_TOKEN_TTL_DAYS = 14;

/**
 * Rate limit helper: max 25 calls per IP per minute for getContractBySigningToken.
 * Uses Firestore for persistence. Returns true if allowed, false if rate limited.
 */
async function checkSigningTokenRateLimit(ipKey: string): Promise<boolean> {
  const RATE_LIMIT_WINDOW_MS = 60 * 1000; // 1 minute
  const RATE_LIMIT_MAX = 25;
  const docId = `signingToken_${crypto.createHash('sha256').update(ipKey).digest('hex').substring(0, 24)}`;
  const ref = admin.firestore().collection('rateLimits').doc(docId);

  const now = Date.now();
  const doc = await ref.get();
  const data = doc.exists ? (doc.data() as Record<string, any>) : null;
  const windowStart = data?.windowStart ?? 0;

  if (now - windowStart >= RATE_LIMIT_WINDOW_MS) {
    // New window
    await ref.set({ count: 1, windowStart: now });
    return true;
  }

  const count = (data?.count ?? 0) + 1;
  if (count > RATE_LIMIT_MAX) {
    return false;
  }

  await ref.update({ count: admin.firestore.FieldValue.increment(1) });
  return true;
}

/**
 * Get contract by signing token. Used when tenants open signing link from email.
 * - App Check enforced (requests must come from legitimate app)
 * - Rate limited: 25 calls per IP per minute
 * - Never returns signingToken in response
 * - Token TTL configurable via SIGNING_TOKEN_TTL_DAYS
 */
export const getContractBySigningToken = functions.https.onCall(async (data: { signingToken?: string }, context: functions.https.CallableContext) => {
  // App Check optional for signing flow - tenants arrive from email links, may lack App Check token (reCAPTCHA blocked etc.)
  if (!context.app) {
    functions.logger.warn('getContractBySigningToken: App Check token missing – allowing for signing-token flow');
  } else {
    enforceAppCheckOrThrow(context);
  }

  const signingToken = (data?.signingToken || '').toString().trim();
  if (!signingToken) {
    throw new functions.https.HttpsError('invalid-argument', 'Signing token is required');
  }

  // Rate limit by IP
  const ip = (context.rawRequest?.ip || context.rawRequest?.connection?.remoteAddress || 'unknown');
  const forwarded = context.rawRequest?.headers?.['x-forwarded-for'];
  const clientIp = (typeof forwarded === 'string' ? forwarded.split(',')[0].trim() : null) || ip;
  const allowed = await checkSigningTokenRateLimit(clientIp);
  if (!allowed) {
    throw new functions.https.HttpsError(
      'resource-exhausted',
      'Too many requests. Please wait a minute and try again.',
    );
  }

  try {
    const snapshot = await admin.firestore()
      .collectionGroup('contracts')
      .where('signingToken', '==', signingToken)
      .where('status', '==', 'sent')
      .limit(1)
      .get();

    if (snapshot.empty) {
      return null;
    }

    const doc = snapshot.docs[0];
    const d = doc.data() as Record<string, any>;

    // Check token expiry
    const expiresAt = d.signingTokenExpiresAt;
    if (expiresAt && expiresAt.toDate && expiresAt.toDate() < new Date()) {
      return null;
    }

    // Serialize for client - convert Timestamps to { seconds, nanoseconds } for Dart
    const serializeTimestamp = (t: admin.firestore.Timestamp | undefined) => {
      if (!t) return null;
      const millis = typeof t.toMillis === 'function' ? t.toMillis() : (t as any).toDate?.()?.getTime?.();
      if (millis == null) return null;
      return { seconds: Math.floor(millis / 1000), nanoseconds: ((millis % 1000) * 1e6) | 0 };
    };

    const out: Record<string, any> = { id: doc.id };
    // Copy fields explicitly, EXCLUDING signingToken and signingTokenExpiresAt (security: never echo token)
    const exclude = ['signingToken', 'signingTokenExpiresAt'];
    for (const [k, v] of Object.entries(d)) {
      if (!exclude.includes(k)) out[k] = v;
    }
    if (d.createdAt) out.createdAt = serializeTimestamp(d.createdAt);
    if (d.sentAt) out.sentAt = serializeTimestamp(d.sentAt);
    if (d.signedAt) out.signedAt = serializeTimestamp(d.signedAt);
    if (d.expiresAt) out.expiresAt = serializeTimestamp(d.expiresAt);
    if (d.moveOutDate) out.moveOutDate = serializeTimestamp(d.moveOutDate);
    if (d.lastReconfirmedAt) out.lastReconfirmedAt = serializeTimestamp(d.lastReconfirmedAt);
    if (d.uploadedAt) out.uploadedAt = serializeTimestamp(d.uploadedAt);
    if (d.disabledAt) out.disabledAt = serializeTimestamp(d.disabledAt);
    return out;
  } catch (err: any) {
    functions.logger.error('getContractBySigningToken error:', err);
    return null;
  }
});

/**
 * Upload signed contract PDF via Cloud Function (bypasses Storage CORS).
 * Validates via auth (facility staff) or signing token (tenant from email link).
 * App Check optional when signingToken present - tenants from email links may lack App Check.
 */
export const uploadSignedContract = functions.https.onCall(async (data: {
  facilityId?: string;
  contractId?: string;
  pdfBase64?: string;
  signingToken?: string;
}, context: functions.https.CallableContext) => {
  const signingToken = (data?.signingToken || '').toString().trim();
  if (signingToken) {
    // Tenant flow from email link - App Check optional (reCAPTCHA may be blocked)
    if (!context.app) {
      functions.logger.warn('uploadSignedContract: App Check token missing – allowing for signing-token flow');
    } else {
      enforceAppCheckOrThrow(context);
    }
  } else {
    // Staff flow - enforce App Check
    enforceAppCheckOrThrow(context);
  }

  const facilityId = (data?.facilityId || '').toString().trim();
  const contractId = (data?.contractId || '').toString().trim();
  const pdfBase64 = data?.pdfBase64;

  if (!facilityId || !contractId || !pdfBase64) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, contractId, and pdfBase64 are required');
  }

  let allowed = false;

  if (context.auth?.uid) {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (facilityDoc.exists) {
      const fd = facilityDoc.data() as Record<string, any>;
      const ownerUid = fd?.ownerUid;
      const managers = fd?.managers || {};
      const roles = fd?.roles || {};
      const role = roles[context.auth!.uid];
      const isOwnerOrManager = ownerUid === context.auth.uid ||
        managers[context.auth.uid] ||
        role === 'owner' ||
        role === 'manager';
      if (isOwnerOrManager) allowed = true;
    }
  }

  if (!allowed && signingToken) {
    const contractDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('contracts')
      .doc(contractId)
      .get();
    const d = contractDoc.exists ? (contractDoc.data() as Record<string, any>) : null;
    if (d?.signingToken === signingToken && d?.status === 'sent') allowed = true;
  }

  if (!allowed) {
    throw new functions.https.HttpsError('permission-denied', 'Not authorized to upload signed contract');
  }

  const buffer = Buffer.from(pdfBase64, 'base64');
  const path = `facilities/${facilityId}/contracts/${contractId}/signed_contract.pdf`;
  const bucket = admin.storage().bucket();
  const file = bucket.file(path);
  const downloadToken = crypto.randomUUID();
  await file.save(buffer, {
    contentType: 'application/pdf',
    metadata: {
      contentType: 'application/pdf',
      metadata: { firebaseStorageDownloadTokens: downloadToken },
    },
  });
  const url = await getDownloadURL(file);
  return url;
});

/**
 * HTTP endpoint for uploadSignedContract - used via Firebase Hosting rewrite.
 * Same-origin requests avoid CORS preflight 403. Accepts callable-style body: { data: {...} }.
 * Uses Express with 10MB body limit for base64 PDF payloads.
 */
const uploadSignedContractApp = express();
uploadSignedContractApp.use(express.json({ limit: '10mb' }));

uploadSignedContractApp.all('*', async (req: express.Request, res: express.Response) => {
  const corsHeaders: Record<string, string> = {
    'Access-Control-Allow-Origin': req.headers.origin || '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
  };

  Object.entries(corsHeaders).forEach(([k, v]) => res.setHeader(k, v));

  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }

  if (req.method !== 'POST') {
    res.status(405).json({ error: { status: 'INVALID_ARGUMENT', message: 'Method not allowed' } });
    return;
  }

  try {
    const body = req.body as { data?: Record<string, unknown> } | undefined;
    const data = (body?.data || body) as Record<string, unknown> | undefined;
    const facilityId = (data?.facilityId || '').toString().trim();
    const contractId = (data?.contractId || '').toString().trim();
    const pdfBase64 = data?.pdfBase64 as string | undefined;
    const signingToken = (data?.signingToken || '').toString().trim();

    if (!facilityId || !contractId || !pdfBase64) {
      res.status(400).json({ error: { status: 'INVALID_ARGUMENT', message: 'facilityId, contractId, and pdfBase64 are required' } });
      return;
    }

    let authUid: string | undefined;
    const authHeader = req.headers.authorization;
    if (authHeader?.startsWith('Bearer ')) {
      try {
        const token = authHeader.substring(7);
        const decoded = await admin.auth().verifyIdToken(token);
        authUid = decoded.uid;
      } catch {
        // Invalid or expired token - authUid stays undefined
      }
    }

    let allowed = false;
    if (authUid) {
      const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
      if (facilityDoc.exists) {
        const fd = facilityDoc.data() as Record<string, unknown>;
        const ownerUid = fd?.ownerUid;
        const managers = (fd?.managers || {}) as Record<string, unknown>;
        const roles = (fd?.roles || {}) as Record<string, string>;
        const role = roles[authUid];
        const isOwnerOrManager = ownerUid === authUid ||
          managers[authUid] ||
          role === 'owner' ||
          role === 'manager';
        if (isOwnerOrManager) allowed = true;
      }
    }

    if (!allowed && signingToken) {
      const contractDoc = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('contracts')
        .doc(contractId)
        .get();
      const d = contractDoc.exists ? (contractDoc.data() as Record<string, unknown>) : null;
      if ((d?.signingToken as string) === signingToken && d?.status === 'sent') allowed = true;
    }

    if (!allowed) {
      res.status(403).json({ error: { status: 'PERMISSION_DENIED', message: 'Not authorized to upload signed contract' } });
      return;
    }

    const buffer = Buffer.from(pdfBase64, 'base64');
    const path = `facilities/${facilityId}/contracts/${contractId}/signed_contract.pdf`;
    const bucket = admin.storage().bucket();
    const file = bucket.file(path);
    const downloadToken = crypto.randomUUID();
    await file.save(buffer, {
      contentType: 'application/pdf',
      metadata: {
        contentType: 'application/pdf',
        metadata: { firebaseStorageDownloadTokens: downloadToken },
      },
    });
    const url = await getDownloadURL(file);

    res.set('Content-Type', 'application/json');
    res.status(200).json({ result: url });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    const stack = err instanceof Error ? err.stack : undefined;
    functions.logger.error('uploadSignedContractHttp error:', msg, stack ?? '');
    res.status(500).json({ error: { status: 'INTERNAL', message: 'Internal error' } });
  }
});

export const uploadSignedContractHttp = functions.https.onRequest(uploadSignedContractApp);

/**
 * HTTP endpoint for contract PDF upload - used via Firebase Hosting rewrite.
 * Same-origin requests avoid CORS preflight 403 when uploading from custom domain.
 */
const uploadContractPdfApp = express();
uploadContractPdfApp.use(express.json({ limit: '16mb' }));

uploadContractPdfApp.all('*', async (req: express.Request, res: express.Response) => {
  const corsHeaders: Record<string, string> = {
    'Access-Control-Allow-Origin': req.headers.origin || '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
  };
  Object.entries(corsHeaders).forEach(([k, v]) => res.setHeader(k, v));
  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }
  if (req.method !== 'POST') {
    res.status(405).json({ error: { status: 'INVALID_ARGUMENT', message: 'Method not allowed' } });
    return;
  }
  try {
    const body = req.body as { data?: Record<string, unknown> } | undefined;
    const data = (body?.data || body) as Record<string, unknown> | undefined;
    const facilityId = (data?.facilityId || '').toString().trim();
    const contractId = (data?.contractId || '').toString().trim();
    const fileName = (data?.fileName || '').toString().trim();
    const pdfBase64 = data?.pdfBase64 as string | undefined;

    if (!facilityId || !contractId || !fileName || !pdfBase64) {
      res.status(400).json({ error: { status: 'INVALID_ARGUMENT', message: 'facilityId, contractId, fileName, and pdfBase64 are required' } });
      return;
    }

    let authUid: string | undefined;
    const authHeader = req.headers.authorization;
    if (authHeader?.startsWith('Bearer ')) {
      try {
        const token = authHeader.substring(7);
        const decoded = await admin.auth().verifyIdToken(token);
        authUid = decoded.uid;
      } catch {
        // Invalid or expired token
      }
    }
    if (!authUid) {
      res.status(403).json({ error: { status: 'UNAUTHENTICATED', message: 'Authentication required' } });
      return;
    }

    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      res.status(404).json({ error: { status: 'NOT_FOUND', message: 'Facility not found' } });
      return;
    }
    const fd = facilityDoc.data() as Record<string, unknown>;
    const ownerUid = fd?.ownerUid;
    const managers = (fd?.managers || {}) as Record<string, unknown>;
    const roles = (fd?.roles || {}) as Record<string, string>;
    const role = roles[authUid];
    const isOwnerOrManager = ownerUid === authUid || managers[authUid] || role === 'owner' || role === 'manager';
    if (!isOwnerOrManager) {
      res.status(403).json({ error: { status: 'PERMISSION_DENIED', message: 'Not authorized to upload contract' } });
      return;
    }

    const buffer = Buffer.from(pdfBase64, 'base64');
    const storagePath = `facilities/${facilityId}/contracts/${contractId}/${fileName}`;
    const bucket = admin.storage().bucket();
    const file = bucket.file(storagePath);
    const downloadToken = crypto.randomUUID();
    await file.save(buffer, {
      contentType: 'application/pdf',
      metadata: {
        contentType: 'application/pdf',
        metadata: { firebaseStorageDownloadTokens: downloadToken },
      },
    });
    const url = await getDownloadURL(file);
    res.set('Content-Type', 'application/json');
    res.status(200).json({ result: url });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    functions.logger.error('uploadContractPdfHttp error:', msg);
    res.status(500).json({ error: { status: 'INTERNAL', message: 'Internal error' } });
  }
});

export const uploadContractPdfHttp = functions.https.onRequest(uploadContractPdfApp);

/** Allowed Storage bucket patterns for proxy (contract PDFs only) */
const PROXY_ALLOWED_BUCKETS = [
  'storage-facility-creator.firebasestorage.app',
  'storage-facility-creator.appspot.com',
];

/**
 * HTTP proxy for contract PDFs - bypasses Storage CORS when loading PDFs from custom domain.
 * Same-origin GET to /api/proxyContractPdf avoids CORS on firebasestorage.googleapis.com.
 */
const proxyContractPdfApp = express();
proxyContractPdfApp.all('*', async (req: express.Request, res: express.Response) => {
  const corsHeaders: Record<string, string> = {
    'Access-Control-Allow-Origin': req.headers.origin || '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '86400',
  };
  Object.entries(corsHeaders).forEach(([k, v]) => res.setHeader(k, v));
  if (req.method === 'OPTIONS') {
    res.status(204).send('');
    return;
  }
  if (req.method !== 'GET') {
    res.status(405).set('Content-Type', 'application/json').json({ error: { message: 'Method not allowed' } });
    return;
  }
  try {
    const rawUrl = (req.query.url || '').toString().trim();
    if (!rawUrl) {
      res.status(400).set('Content-Type', 'application/json').json({ error: { message: 'url query param required' } });
      return;
    }
    let parsed: URL;
    try {
      parsed = new URL(rawUrl);
    } catch {
      res.status(400).set('Content-Type', 'application/json').json({ error: { message: 'Invalid url' } });
      return;
    }
    if (parsed.protocol !== 'https:') {
      res.status(400).set('Content-Type', 'application/json').json({ error: { message: 'url must be https' } });
      return;
    }
    const host = parsed.hostname || '';
    const pathname = parsed.pathname || '';
    const isGoogleStorageHost =
      host === 'firebasestorage.googleapis.com' || host === 'storage.googleapis.com';
    const bucketMatch = PROXY_ALLOWED_BUCKETS.some((b) => pathname.includes(`/b/${b}/`));
    // Storage object path is URL-encoded in /o/{object}; decode before path checks.
    const objectPathEncoded = pathname.includes('/o/') ? pathname.split('/o/')[1] : '';
    let objectPath = objectPathEncoded || '';
    try {
      objectPath = decodeURIComponent(objectPathEncoded || '');
    } catch {
      objectPath = objectPathEncoded || '';
    }
    const isContractPath = objectPath.startsWith('facilities/') && objectPath.includes('/contracts/');
    if (!isGoogleStorageHost || !bucketMatch || !isContractPath) {
      res.status(403).set('Content-Type', 'application/json').json({ error: { message: 'URL not allowed' } });
      return;
    }
    const resp = await fetch(rawUrl, { method: 'GET' });
    if (!resp.ok) {
      res.status(resp.status).set('Content-Type', 'application/json').json({ error: { message: 'Upstream fetch failed' } });
      return;
    }
    const contentType = resp.headers.get('content-type') || 'application/pdf';
    res.set('Content-Type', contentType);
    const buf = await resp.arrayBuffer();
    res.status(200).send(Buffer.from(buf));
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    functions.logger.error('proxyContractPdf error:', msg);
    res.status(500).set('Content-Type', 'application/json').json({ error: { message: 'Internal error' } });
  }
});

export const proxyContractPdfHttp = functions.https.onRequest(proxyContractPdfApp);

/**
 * Firestore trigger: Send confirmation email when a contract is signed.
 * Sends to signedByEmail if present, otherwise tries tenant email.
 */
export const onContractSigned = functions.runWith({ secrets: SENDGRID_SECRETS })
  .firestore.document('facilities/{facilityId}/contracts/{contractId}')
  .onUpdate(async (change, context) => {
    const facilityId = context.params.facilityId as string;
    const contractId = context.params.contractId as string;
    const before = change.before.data() as Record<string, any>;
    const after = change.after.data() as Record<string, any>;

    if (before?.status === 'signed' || after?.status !== 'signed') {
      return;
    }

    const signedByEmail = (after?.signedByEmail || '').toString().trim();
    const signedBy = (after?.signedBy || '').toString().trim();
    const title = (after?.title || 'Contract').toString();
    const signedFileUrl = (after?.signedFileUrl || '').toString().trim();

    let toEmail = signedByEmail;
    if (!toEmail) {
      const tenantId = (after?.tenantId || '').toString().trim();
      if (tenantId) {
        const tenantDoc = await admin.firestore()
          .collection('facilities').doc(facilityId)
          .collection('tenants').doc(tenantId)
          .get();
        if (tenantDoc.exists) {
          toEmail = (tenantDoc.data() as Record<string, any>)?.email?.toString().trim() || '';
        }
      }
    }
    if (!toEmail || !toEmail.includes('@')) {
      functions.logger.info('onContractSigned: No signer email available, skipping confirmation');
      return;
    }

    try {
      const [apiKey, fromEmail] = await Promise.all([
        SENDGRID_API_KEY.value(),
        SENDGRID_FROM_EMAIL.value(),
      ]);
      if (!apiKey?.trim() || !fromEmail?.trim()) {
        functions.logger.warn('onContractSigned: SendGrid not configured, skipping');
        return;
      }

      const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
      const facilityData = facilityDoc.exists ? (facilityDoc.data() as Record<string, any>) : {};
      const facilityName = facilityData?.name || 'Storage Facility';
      const footer = buildFacilityFooter(
        facilityName,
        facilityData?.address,
        facilityData?.phone,
      );

      const viewLink = signedFileUrl
        ? `<p><a clicktracking="off" href="${signedFileUrl}" style="color:#1E3A8A;font-weight:600;">View your signed contract</a></p>`
        : '';
      const html = `
        <h2 style="color:#1E3A8A;">Contract signed successfully</h2>
        <p>Hello${signedBy ? ` ${escapeHtml(signedBy)}` : ''},</p>
        <p>Your signature has been recorded for <strong>${escapeHtml(title)}</strong>.</p>
        ${viewLink}
        <p>Please keep this email for your records.</p>
        ${footer.html}
      `;
      const text = [
        'Contract signed successfully',
        signedBy ? `Hello ${signedBy},` : 'Hello,',
        `Your signature has been recorded for ${title}.`,
        signedFileUrl ? `View your signed contract: ${signedFileUrl}` : '',
        'Please keep this email for your records.',
        footer.text,
      ].filter(Boolean).join('\n\n');

      sgMail.setApiKey(apiKey);
      await sgMail.send({
        to: toEmail,
        from: { email: fromEmail, name: facilityName },
        subject: `Contract Signed: ${title}`,
        html,
        text,
      });
      functions.logger.info('onContractSigned: Confirmation email sent', { to: toEmail, contractId });
    } catch (err: unknown) {
      functions.logger.error('onContractSigned: Failed to send confirmation email', err);
    }
  });

/**
 * Tenant portal lookup by email + access code. No Firebase Auth required.
 * App Check is not enforced here so unauthenticated tenants can access the portal.
 */
export const tenantPortalFetch = functions.https.onCall(async (data: TenantPortalRequest) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();

  if (!email || !accessCode) {
    throw new functions.https.HttpsError('invalid-argument', 'Email and access code are required');
  }

  try {
    let tenantSnapshot: admin.firestore.QuerySnapshot;
    try {
      tenantSnapshot = await admin
        .firestore()
        .collectionGroup('tenants')
        .where('emailLower', '==', email)
        .where('portalEnabled', '==', true)
        .where('portalAccessCode', '==', accessCode)
        .limit(1)
        .get();
    } catch (indexError: any) {
      if (indexError.code === 9 || (indexError.message ?? '').includes('indexes') || (indexError.message ?? '').includes('index')) {
        functions.logger.warn('Missing composite index for tenant portal lookup. Falling back to email-only query.', indexError);
        const fallbackSnapshot = await admin
          .firestore()
          .collectionGroup('tenants')
          .where('emailLower', '==', email)
          .get();
        const matchingDocs = fallbackSnapshot.docs.filter((doc) => {
          const d = doc.data();
          return d.portalEnabled === true && d.portalAccessCode === accessCode;
        });
        tenantSnapshot = { docs: matchingDocs, empty: matchingDocs.length === 0 } as unknown as admin.firestore.QuerySnapshot;
      } else {
        throw indexError;
      }
    }

    if (tenantSnapshot.empty) {
      throw new functions.https.HttpsError('not-found', 'Portal access not found. Verify your email and access code.');
    }

    const tenantDoc = tenantSnapshot.docs[0];
    const tenantData = tenantDoc.data() as Record<string, any>;
    const facilityRef = tenantDoc.ref.parent.parent;

    if (!facilityRef) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility reference missing for tenant');
    }

    const facilityDoc = await facilityRef.get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found for tenant');
    }

    const paymentsCollection = facilityRef.collection('payments');
    let paymentsSnapshot;
    try {
      paymentsSnapshot = await paymentsCollection
        .where('tenantId', '==', tenantDoc.id)
        .orderBy('dueDate', 'desc')
        .limit(20)
        .get();
    } catch (error: any) {
      if (error.code === 9 || (error.message ?? '').includes('indexes')) {
        functions.logger.warn('Missing index for portal payment query. Falling back to unordered query.', error);
        paymentsSnapshot = await paymentsCollection
          .where('tenantId', '==', tenantDoc.id)
          .limit(20)
          .get();
      } else {
        throw error;
      }
    }

    let outstandingBalance = 0;
    let nextDueDate: admin.firestore.Timestamp | null = null;
    let nextAmountDue: number | null = null;

    const payments = paymentsSnapshot.docs.map((doc) => {
      const paymentData = doc.data() as Record<string, any>;
      const amountRaw = paymentData.amount ?? 0;
      const amount = typeof amountRaw === 'number' ? amountRaw : Number(amountRaw) || 0;
      const statusRaw = paymentData.status;
      const status = typeof statusRaw === 'string' ? statusRaw : 'pending';
      const dueDateRaw = paymentData.dueDate;
      const dueDate = dueDateRaw instanceof admin.firestore.Timestamp
        ? dueDateRaw
        : admin.firestore.Timestamp.now();
      const paidAtRaw = paymentData.paidAt;
      const paidAt = paidAtRaw instanceof admin.firestore.Timestamp ? paidAtRaw : null;
      const method = paymentData.method ? String(paymentData.method) : null;

      const isPaid = status === 'paid' || status === 'completed';
      if (!isPaid) {
        outstandingBalance += amount;
        if (!nextDueDate || dueDate.toMillis() < nextDueDate.toMillis()) {
          nextDueDate = dueDate;
          nextAmountDue = amount;
        }
      }

      return {
        id: doc.id,
        amount,
        status,
        dueDate,
        paidAt,
        method,
      };
    });

    await tenantDoc.ref.update({
      portalLastAccessAt: admin.firestore.FieldValue.serverTimestamp(),
      portalVisitCount: admin.firestore.FieldValue.increment(1),
    });

    const facilityData = facilityDoc.data() as Record<string, any> | undefined;
    const stripeStatus = facilityData?.stripeStatus as { state?: string } | undefined;
    const autopay = tenantData.autopay as Record<string, unknown> | undefined;
    const stripe = tenantData.stripe as Record<string, unknown> | undefined;

    return {
      facility: {
        id: facilityRef.id,
        name: facilityData?.name ?? 'Facility',
        phone: facilityData?.phone ?? null,
        email: facilityData?.email ?? null,
        address: facilityData?.address ?? null,
        logoUrl: facilityData?.logoUrl ?? null,
        stripeStatus: stripeStatus ?? { state: 'DISCONNECTED' },
      },
      tenant: {
        id: tenantDoc.id,
        name: tenantData.name ?? 'Tenant',
        email: tenantData.email ?? null,
        phone: tenantData.phone ?? null,
        unitNumber: tenantData.unitNumber ?? '',
        monthlyRate: tenantData.monthlyRate ?? 0,
        paidThrough: tenantData.paidThrough ?? null,
        isDelinquent: outstandingBalance > 0,
        welcomeMessage: tenantData.portalWelcomeMessage ?? null,
        contacts: tenantData.emergencyContacts ?? [],
        vehicles: tenantData.vehicles ?? [],
        autopay: autopay ?? { requested: false, enabled: false, status: 'OFF', updatedBy: 'SYSTEM', updatedAt: null },
        stripe: stripe ?? { customerId: null, defaultPaymentMethodId: null, paymentMethodSummary: null },
        overlockIsActive: tenantData.overlockIsActive === true,
      },
      payments,
      stats: {
        outstandingBalance,
        nextAmountDue,
        nextDueDate,
      },
    };
  } catch (error: any) {
    functions.logger.error('tenantPortalFetch failed', error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', error.message ?? 'Unable to load tenant portal data');
  }
});

/**
 * tenantUpdateProfile — Allows a tenant to update their own contact info via the portal.
 * Authenticated via email + accessCode (no Firebase Auth required).
 * Tenants can update: phone, emergencyContacts, vehicles.
 * All changes are written directly to the Firestore tenant document.
 */
export const tenantUpdateProfile = functions.https.onCall(async (data: any) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();

  if (!email || !accessCode) {
    throw new functions.https.HttpsError('invalid-argument', 'Email and access code are required');
  }

  try {
    // Authenticate tenant
    let tenantSnapshot: admin.firestore.QuerySnapshot;
    try {
      tenantSnapshot = await admin
        .firestore()
        .collectionGroup('tenants')
        .where('emailLower', '==', email)
        .where('portalEnabled', '==', true)
        .where('portalAccessCode', '==', accessCode)
        .limit(1)
        .get();
    } catch (indexError: any) {
      if (indexError.code === 9 || (indexError.message ?? '').includes('index')) {
        const fallback = await admin.firestore().collectionGroup('tenants').where('emailLower', '==', email).get();
        const matching = fallback.docs.filter((d) => {
          const dd = d.data();
          return dd.portalEnabled === true && dd.portalAccessCode === accessCode;
        });
        tenantSnapshot = { docs: matching, empty: matching.length === 0 } as unknown as admin.firestore.QuerySnapshot;
      } else {
        throw indexError;
      }
    }

    if (tenantSnapshot.empty) {
      throw new functions.https.HttpsError('not-found', 'Portal access not found. Verify your email and access code.');
    }

    const tenantDoc = tenantSnapshot.docs[0];
    const updateData: Record<string, any> = {
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      portalLastProfileUpdateAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    // Phone
    if (typeof data.phone === 'string') {
      updateData['phone'] = data.phone.trim();
    }

    // Emergency contacts — validate structure
    if (Array.isArray(data.emergencyContacts)) {
      const contacts = (data.emergencyContacts as any[]).map((c: any) => ({
        name: (c.name ?? '').toString().trim(),
        relationship: (c.relationship ?? '').toString().trim() || null,
        phone: (c.phone ?? '').toString().trim() || null,
        email: (c.email ?? '').toString().trim() || null,
        isPrimary: c.isPrimary === true,
        isEmergency: c.isEmergency !== false,
      }));
      updateData['emergencyContacts'] = contacts;
    }

    // Vehicles — validate structure
    if (Array.isArray(data.vehicles)) {
      const vehicles = (data.vehicles as any[]).map((v: any) => ({
        make: (v.make ?? '').toString().trim(),
        model: (v.model ?? '').toString().trim(),
        color: (v.color ?? '').toString().trim() || null,
        licensePlate: (v.licensePlate ?? '').toString().trim() || null,
        state: (v.state ?? '').toString().trim() || null,
        notes: (v.notes ?? '').toString().trim() || null,
      }));
      updateData['vehicles'] = vehicles;
    }

    await tenantDoc.ref.update(updateData);
    functions.logger.info('tenantUpdateProfile: tenant updated their profile', { tenantId: tenantDoc.id });

    return { success: true };
  } catch (error: any) {
    functions.logger.error('tenantUpdateProfile failed', error);
    if (error instanceof functions.https.HttpsError) throw error;
    throw new functions.https.HttpsError('internal', error.message ?? 'Unable to update profile');
  }
});

/**
 * Create payment checkout for tenant portal
 * Uses email + accessCode for authentication (no Firebase Auth required)
 */
/**
 * Create payment checkout from tenant portal (email + access code auth).
 * App Check not enforced so unauthenticated tenants can pay.
 */
export const createTenantPortalPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const amount = data.amount as number;

  if (!email || !accessCode || !amount || amount <= 0) {
    throw new functions.https.HttpsError('invalid-argument', 'email, accessCode, and amount are required');
  }

  try {
    // Find tenant using email + accessCode (same logic as tenantPortalFetch)
    const tenantSnapshot = await admin
      .firestore()
      .collectionGroup('tenants')
      .where('emailLower', '==', email)
      .where('portalEnabled', '==', true)
      .where('portalAccessCode', '==', accessCode)
      .limit(1)
      .get();

    if (tenantSnapshot.empty) {
      throw new functions.https.HttpsError('not-found', 'Portal access not found');
    }

    const tenantDoc = tenantSnapshot.docs[0];
    const facilityRef = tenantDoc.ref.parent.parent;

    if (!facilityRef) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility reference missing');
    }

    const facilityDoc = await facilityRef.get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityId = facilityRef.id;
    const tenantId = tenantDoc.id;
    const facilityData = facilityDoc.data()!;
    const tenantData = tenantDoc.data()!;

    // Log portal access audit event
    await writeAuditLog(facilityId, {
      eventType: 'portal.accessed',
      actorUid: 'tenant', // Portal access uses email+code, not Firebase Auth
      targetType: 'tenant',
      targetId: tenantId,
      tenantId: tenantId,
      after: {
        'action': 'portalAccess',
      },
      metadata: {
        'accessMethod': 'email+code',
        'email': email, // Redacted in production logs
      },
    });

    // Check Stripe Connect setup
    const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
    const onboardingComplete = facilityData.stripeConnectOnboardingComplete as boolean | undefined;

    if (!connectAccountId || !onboardingComplete) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility owner must complete Stripe Connect onboarding before accepting payments');
    }

    const tenantEmail = tenantData['email'] as string | undefined;
    const tenantName = tenantData['name'] as string | undefined || 'Tenant';

    const stripe = getStripeClient();

    // Create checkout session on connected account
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: `Payment - ${tenantName}`,
              description: `Payment for ${facilityData['name'] || 'Facility'}`,
            },
            unit_amount: Math.round(amount * 100), // Convert to cents
          },
          quantity: 1,
        },
      ],
      customer_email: tenantEmail,
      success_url: 'https://app.storagefacilitycreator.com/portal/payment/success?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://app.storagefacilitycreator.com/portal/payment/cancel',
      metadata: {
        facilityId: facilityId,
        tenantId: tenantId,
        type: 'tenant_portal_payment',
        portalEmail: email,
      },
    }, {
      stripeAccount: connectAccountId, // Create session on connected account
    });

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error creating tenant portal payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});

interface SMSRequest {
  to: string;
  message: string;
  facilityId: string;
  tenantId?: string; // Optional: for per-tenant tracking
  accountId?: string; // Optional: for per-account tracking
  forceSend?: boolean; // Optional: allow manual override for extreme usage
  fallbackToEmail?: boolean; // Optional: if true, send as email when SMS limit exceeded
  source?: 'manual' | 'bulk' | 'automation'; // Optional: source of the message
}

/**
 * Send SMS text message via Twilio with fair-use safeguards
 * Automatically falls back to email if SMS limits are exceeded
 */
export const sendSMS = functions.runWith({
  secrets: [...TWILIO_SECRETS, ...SENDGRID_SECRETS],
}).https.onCall(async (data: SMSRequest, context) => {
  // Verify authentication
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated to send SMS');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data.facilityId,
    key: 'sendSMS',
    limit: 120, // per minute per facility; fair-use will still gate harder
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const { to, message, facilityId, tenantId, accountId, forceSend = false, fallbackToEmail = true, source } = data;

  // Validate required fields
  if (!to || !message || !facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields: to, message, facilityId');
  }

  // Generate message log ID early
  const messageLogId = `sms-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;

  // Format phone number early (needed in error handlers)
  let phoneNumber: string | null = null;
  try {
    phoneNumber = formatPhoneNumber(to);
  } catch (e) {
    // Will be validated later
  }

  try {
    // Verify user has access to the facility (owner or manager)
    const facilityRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilityDoc = await facilityRef.get();
    const facilityData = facilityDoc.data() as Record<string, any> | undefined;

    if (!facilityDoc.exists || !facilityData) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const ownerUid = facilityData.ownerUid;
    const managersMap = (facilityData.managers ?? {}) as Record<string, any>;
    const isOwner = ownerUid === context.auth.uid;
    const isManager = managersMap[context.auth.uid ?? ''] === true;

    if (!isOwner && !isManager) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'User is not authorized to send SMS for this facility',
      );
    }

    // Get account ID from facility if not provided
    const finalAccountId = accountId || facilityData.facilityCreatorAccountId;

    // Validate phone number format
    if (!phoneNumber) {
      phoneNumber = formatPhoneNumber(to);
      if (!phoneNumber) {
        throw new functions.https.HttpsError('invalid-argument', 'Invalid phone number format');
      }
    }

    // Get tenant information for message logging
    const tenantInfo = await getTenantInfo(
      facilityId,
      tenantId,
      null,
      phoneNumber,
    );

    const textingOnboardingFlag = await isFeatureFlagEnabled('TEXTING_ONBOARDING_V1');
    const textingOnboardingEnabled = textingOnboardingFlag && facilityData.textingOnboardingEnabled === true;
    const facilityA2PStatus = ((facilityData.a2pStatus as string) || 'draft').toLowerCase();
    const textingPlatformApproved = facilityData.textingPlatformApproved === true;
    if (textingOnboardingEnabled && facilityA2PStatus !== 'approved' && !forceSend) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Texting setup is not approved yet. SMS sending is blocked until A2P 10DLC campaign approval.',
      );
    }
    if (textingOnboardingEnabled && facilityA2PStatus === 'approved' && !textingPlatformApproved && !forceSend) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Texting is awaiting platform approval. A superadmin must approve this facility before SMS can be sent.',
      );
    }

    // SMS Compliance Checks (if enabled)
    const complianceEnabled = await isSMSComplianceFeatureEnabled('enhancedOptOut', facilityId);
    
    if ((complianceEnabled || textingOnboardingEnabled) && tenantInfo.tenantId) {
      // Check if tenant is opted out
      const tenantDoc = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantInfo.tenantId)
        .get();
      
      const tenantData = tenantDoc.data() as Record<string, any> | undefined;
      if (tenantData?.smsOptOut === true || tenantData?.smsConsentStatus === 'opted_out') {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'Tenant has opted out of SMS messages. Cannot send SMS to this number.',
        );
      }
      if (textingOnboardingEnabled && tenantData?.smsConsentStatus !== 'opted_in' && !forceSend) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'Tenant SMS consent is required before sending messages.',
        );
      }

      // Check facility block list
      const smsSettings = facilityData?.smsSettings as Record<string, any> | undefined;
      const blockList = smsSettings?.blockList as string[] | undefined;
      if (blockList && blockList.includes(phoneNumber)) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'This phone number is on the facility SMS block list. Cannot send SMS.',
        );
      }
    }

    // Check quiet hours (if enabled)
    const quietHoursEnabled = await isSMSComplianceFeatureEnabled('quietHours', facilityId);
    if (quietHoursEnabled && tenantInfo.tenantId) {
      const quietHoursCheck = await checkQuietHours(facilityId, tenantInfo.tenantId);
      if (quietHoursCheck.isQuietHours && !forceSend) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          `Cannot send SMS during quiet hours. Next allowed time: ${quietHoursCheck.nextAllowedTime?.toISOString() || 'unknown'}`,
        );
      }
    }

    // Check per-tenant rate limit (if enabled)
    const rateLimitingEnabled = await isSMSComplianceFeatureEnabled('rateLimiting', facilityId);
    if (rateLimitingEnabled && tenantInfo.tenantId) {
      const rateLimitCheck = await checkPerTenantRateLimit(facilityId, tenantInfo.tenantId);
      if (!rateLimitCheck.canSend && !forceSend) {
        throw new functions.https.HttpsError(
          'resource-exhausted',
          `Tenant daily SMS limit reached (${rateLimitCheck.messagesSentToday}/${rateLimitCheck.limit}). Limit resets at ${rateLimitCheck.resetTime?.toISOString() || 'unknown'}.`,
        );
      }
    }

    // Add opt-out footer to message (if compliance enabled)
    let finalMessage = message;
    if (complianceEnabled) {
      finalMessage = await addOptOutFooter(facilityId, message);
    }

    // Get user email for message logging
    const userRecord = await admin.auth().getUser(context.auth.uid);
    const userEmail = userRecord.email;

    // Create message log with status "queued"
    const previewText = finalMessage.substring(0, 200);
    await createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId: tenantInfo.tenantId,
      tenantName: tenantInfo.tenantName,
      tenantEmail: tenantInfo.tenantEmail,
      tenantPhone: tenantInfo.tenantPhone || phoneNumber,
      channel: 'sms',
      direction: 'outbound',
      source: source || 'manual',
      templateId: null,
      subject: null,
      previewText: previewText,
      bodyHtmlStored: false,
      bodyTextStored: false,
      status: 'queued',
      provider: 'twilio',
      providerMessageId: null,
      errorCode: null,
      errorMessage: null,
      sentAt: null,
      createdByUid: context.auth.uid,
      createdByEmail: userEmail || null,
    });

    // Check and increment SMS usage (with all limits)
    const usageCheck = await checkAndIncrementSMSUsage(facilityId, tenantId, finalAccountId);
    
    // Handle different usage states
    if (usageCheck.state === SMSUsageState.EXTREME && !forceSend) {
      // Extreme usage: prevent all SMS unless explicitly forced
      if (fallbackToEmail) {
        // Fallback to email
        return await sendSMSAsEmail(to, message, facilityId, usageCheck);
      }
      throw new functions.https.HttpsError(
        'resource-exhausted',
        'SMS usage is extremely high. SMS scheduling is disabled. Please contact support if you need to increase your limit.',
      );
    }

    if (usageCheck.shouldFallbackToEmail && !forceSend) {
      // Exceeded limit: fallback to email
      if (fallbackToEmail) {
        return await sendSMSAsEmail(to, message, facilityId, usageCheck);
      }
      throw new functions.https.HttpsError(
        'resource-exhausted',
        usageCheck.warning || 'SMS fair-use limit exceeded. Messages will be sent via email instead.',
      );
    }

    if (!usageCheck.canSendSMS && !forceSend) {
      // Limit exceeded but not in fallback mode
      if (fallbackToEmail) {
        return await sendSMSAsEmail(to, message, facilityId, usageCheck);
      }
      throw new functions.https.HttpsError(
        'resource-exhausted',
        usageCheck.warning || 'SMS quota exceeded',
      );
    }

    // Phone number already formatted above

    // Send SMS via Twilio
    // Get credentials from Firebase Functions secrets
    // #region agent log
    functions.logger.info('🔍 [sendSMS:H6] Starting credential retrieval', {
      facilityId,
      toNumberMasked: `${phoneNumber.substring(0, 4)}****${phoneNumber.substring(phoneNumber.length - 4)}`,
      messageLength: message.length,
    });
    // #endregion
    
    let twilioAccountSid: string;
    let twilioAuthToken: string;
    let twilioPhoneNumber: string;
    
    try {
      // Trim whitespace (including \r\n) that may be present if secrets were set via echo/file
      twilioAccountSid = TWILIO_ACCOUNT_SID.value().trim();
      // #region agent log
      functions.logger.info('🔍 [sendSMS:H6] Account SID retrieved', {
        accountSidLength: twilioAccountSid.length,
        accountSidPrefix: twilioAccountSid.substring(0, 8),
        isEmpty: !twilioAccountSid,
      });
      // #endregion
    } catch (e: any) {
      // #region agent log
      functions.logger.error('❌ [sendSMS:H6] Failed to retrieve TWILIO_ACCOUNT_SID', {
        error: e.message,
        errorType: e.constructor.name,
      });
      // #endregion
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Twilio Account SID not configured. Please set TWILIO_ACCOUNT_SID in Firebase Functions environment.',
        { originalError: e.message },
      );
    }
    
    try {
      twilioAuthToken = TWILIO_AUTH_TOKEN.value().trim();
      // #region agent log
      functions.logger.info('🔍 [sendSMS:H6] Auth Token retrieved', {
        authTokenLength: twilioAuthToken.length,
        authTokenMasked: `****${twilioAuthToken.substring(Math.max(0, twilioAuthToken.length - 4))}`,
        isEmpty: !twilioAuthToken,
      });
      // #endregion
    } catch (e: any) {
      // #region agent log
      functions.logger.error('❌ [sendSMS:H6] Failed to retrieve TWILIO_AUTH_TOKEN', {
        error: e.message,
        errorType: e.constructor.name,
      });
      // #endregion
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Twilio Auth Token not configured. Please set TWILIO_AUTH_TOKEN secret in Firebase Functions.',
        { originalError: e.message },
      );
    }
    
    try {
      twilioPhoneNumber = TWILIO_PHONE_NUMBER.value().trim();
      // #region agent log
      functions.logger.info('🔍 [sendSMS:H6] Phone Number retrieved', {
        phoneNumber: twilioPhoneNumber,
        isEmpty: !twilioPhoneNumber,
      });
      // #endregion
    } catch (e: any) {
      // #region agent log
      functions.logger.error('❌ [sendSMS:H6] Failed to retrieve TWILIO_PHONE_NUMBER', {
        error: e.message,
        errorType: e.constructor.name,
      });
      // #endregion
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Twilio Phone Number not configured. Please set TWILIO_PHONE_NUMBER in Firebase Functions environment.',
        { originalError: e.message },
      );
    }

    if (!twilioAccountSid || !twilioAuthToken || !twilioPhoneNumber) {
      // #region agent log
      functions.logger.error('❌ [sendSMS:H6] Twilio credentials validation failed', {
        hasAccountSid: !!twilioAccountSid,
        hasAuthToken: !!twilioAuthToken,
        hasPhoneNumber: !!twilioPhoneNumber,
        accountSidLength: twilioAccountSid?.length || 0,
        authTokenLength: twilioAuthToken?.length || 0,
        phoneNumberLength: twilioPhoneNumber?.length || 0,
      });
      // #endregion
      throw new functions.https.HttpsError(
        'failed-precondition',
        'SMS service not configured. One or more Twilio credentials are missing. Please configure TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN (secret), and TWILIO_PHONE_NUMBER in Firebase Functions.',
      );
    }

    const facilityDedicatedFromNumber = (facilityData.twilioPhoneNumberE164 as string | undefined) || null;
    const resolvedFromNumber = (textingOnboardingEnabled && facilityA2PStatus === 'approved' && facilityDedicatedFromNumber)
      ? facilityDedicatedFromNumber
      : twilioPhoneNumber;

    // Safe debug logging (masked for security)
    // #region agent log
    functions.logger.info('🔍 [sendSMS:H6] Twilio Credentials Validated', {
      accountSid: twilioAccountSid, // Full SID is safe to log (it's public)
      accountSidLength: twilioAccountSid.length,
      authTokenMasked: `****${twilioAuthToken.substring(twilioAuthToken.length - 4)}`, // Last 4 chars only
      authTokenLength: twilioAuthToken.length,
      fromNumber: resolvedFromNumber,
      toNumberMasked: `${phoneNumber.substring(0, 4)}****${phoneNumber.substring(phoneNumber.length - 4)}`, // First 4 + last 4
      messageLength: message.length,
    });
    // #endregion

    // Use Twilio REST API to send SMS
    const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`;
    const auth = Buffer.from(`${twilioAccountSid}:${twilioAuthToken}`).toString('base64');

    // #region agent log
    functions.logger.info('🔍 [sendSMS:H6] Preparing Twilio API request', {
      twilioUrl: twilioUrl.substring(0, 50) + '...', // Log URL structure only
      authHeaderPrefix: `Basic ${auth.substring(0, 10)}...`, // First 10 chars of base64
      toNumber: phoneNumber,
      fromNumber: resolvedFromNumber,
      messageLength: message.length,
    });
    // #endregion

    const formData = new URLSearchParams();
    formData.append('To', phoneNumber);
    formData.append('From', resolvedFromNumber);
    formData.append('Body', finalMessage); // Use finalMessage which includes footer if compliance enabled

    let response: Response;
    let errorResponse: any = null;

    try {
      // #region agent log
      functions.logger.info('🔍 [sendSMS:H6] Calling Twilio API', {
        url: twilioUrl,
        method: 'POST',
        hasAuthHeader: !!auth,
        authHeaderLength: auth.length,
      });
      // #endregion
      
      response = await fetch(twilioUrl, {
        method: 'POST',
        headers: {
          'Authorization': `Basic ${auth}`,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: formData.toString(),
      });

      // #region agent log
      functions.logger.info('🔍 [sendSMS:H6] Twilio API response received', {
        status: response.status,
        statusText: response.statusText,
        ok: response.ok,
      });
      // #endregion

      if (!response.ok) {
        const errorText = await response.text();
        try {
          errorResponse = JSON.parse(errorText);
        } catch {
          errorResponse = { message: errorText };
        }

        // Log structured Twilio error
        // #region agent log
        functions.logger.error('❌ [sendSMS:H6] Twilio API Error:', {
          status: response.status,
          statusText: response.statusText,
          errorCode: errorResponse.code,
          errorMessage: errorResponse.message,
          moreInfo: errorResponse.more_info,
          accountSidUsed: twilioAccountSid, // For debugging
          accountSidPrefix: twilioAccountSid.substring(0, 8),
          authTokenLength: twilioAuthToken.length,
          phoneNumber: twilioPhoneNumber,
          toNumber: phoneNumber,
        });
        // #endregion

        // Map Twilio errors to proper HttpsError
        if (response.status === 401) {
          // Authentication error - credentials are wrong
          throw new functions.https.HttpsError(
            'unauthenticated',
            `Twilio authentication failed: ${errorResponse.message || 'Invalid Account SID or Auth Token'}. Please verify credentials in Firebase Secrets.`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
              accountSidUsed: twilioAccountSid.substring(0, 8) + '...', // First 8 chars for debugging
            },
          );
        } else if (response.status === 400) {
          // Bad request - might be A2P, invalid number, etc.
          throw new functions.https.HttpsError(
            'invalid-argument',
            `Twilio request failed: ${errorResponse.message || 'Invalid request parameters'}`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
            },
          );
        } else if (response.status === 403) {
          // Forbidden - A2P or permission issue
          // Check for specific A2P 10DLC error codes
          const errorCode = errorResponse.code?.toString() || '';
          const errorMessage = errorResponse.message || '';
          let userMessage = errorMessage || 'A2P registration may be required or account lacks permissions';
          
          if (errorCode === '30034' || errorCode === '30008' || errorMessage.toLowerCase().includes('a2p') || errorMessage.toLowerCase().includes('unregistered')) {
            userMessage = 'A2P 10DLC registration is not complete. Your message was accepted by Twilio but cannot be delivered until A2P 10DLC brand and campaign registration is approved (typically takes 24-48 hours). Please check your A2P 10DLC registration status in Twilio Console > Messaging > Regulatory Compliance.';
          }
          
          throw new functions.https.HttpsError(
            'permission-denied',
            `Twilio request forbidden: ${userMessage}`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
              a2pRegistrationRequired: errorCode === '30034' || errorCode === '30008',
            },
          );
        } else {
          // Other errors
          throw new functions.https.HttpsError(
            'internal',
            `Twilio API error (${response.status}): ${errorResponse.message || 'Unknown error'}`,
            {
              twilioErrorCode: errorResponse.code,
              twilioMoreInfo: errorResponse.more_info,
            },
          );
        }
      }
    } catch (e) {
      // If it's already an HttpsError, rethrow it
      if (e instanceof functions.https.HttpsError) {
        throw e;
      }
      // Network or other errors
      functions.logger.error('❌ [sendSMS] Unexpected error calling Twilio:', e);
      throw new functions.https.HttpsError(
        'internal',
        `Failed to communicate with Twilio: ${e instanceof Error ? e.message : 'Unknown error'}`,
        { originalError: e instanceof Error ? e.toString() : String(e) },
      );
    }

    const result = await response.json();

    // Log full Twilio response for debugging delivery status
    functions.logger.info(`✅ [sendSMS] Twilio API Response:`, {
      messageId: result.sid,
      status: result.status, // 'queued', 'sent', 'delivered', 'failed', 'undelivered'
      to: result.to,
      from: result.from,
      dateCreated: result.date_created,
      dateSent: result.date_sent,
      errorCode: result.error_code,
      errorMessage: result.error_message,
      price: result.price,
      priceUnit: result.price_unit,
      uri: result.uri,
    });

    // Check for A2P 10DLC errors even with 200 status (message accepted but not deliverable)
    const errorCode = result.error_code?.toString() || '';
    const errorMessage = result.error_message || '';
    const messageStatus = result.status || '';

    // A2P 10DLC errors: 30034 (unregistered number), 30008 (A2P registration required)
    if (errorCode === '30034' || errorCode === '30008' || 
        errorMessage.toLowerCase().includes('a2p') || 
        errorMessage.toLowerCase().includes('unregistered') ||
        (messageStatus === 'undelivered' && (errorCode === '30034' || errorCode === '30008'))) {
      
      functions.logger.warn(`⚠️ [sendSMS] A2P 10DLC Registration Required:`, {
        messageId: result.sid,
        status: messageStatus,
        errorCode: errorCode,
        errorMessage: errorMessage,
        to: result.to,
      });

      // Update message log to "failed"
      await createOrUpdateMessageLog(facilityId, messageLogId, {
        tenantId: tenantInfo.tenantId,
        tenantName: tenantInfo.tenantName,
        tenantEmail: tenantInfo.tenantEmail,
        tenantPhone: tenantInfo.tenantPhone || phoneNumber,
        channel: 'sms',
        direction: 'outbound',
        source: source || 'manual',
        templateId: null,
        subject: null,
        previewText: previewText,
        bodyHtmlStored: false,
        bodyTextStored: false,
        status: 'failed',
        provider: 'twilio',
        providerMessageId: result.sid,
        errorCode: errorCode,
        errorMessage: errorMessage,
        sentAt: null,
        createdByUid: context.auth.uid,
        createdByEmail: userEmail || null,
      });

      // Also log to legacy smsLogs collection
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('smsLogs')
        .add({
          to: phoneNumber,
          message,
          status: 'failed',
          messageId: result.sid,
          twilioStatus: messageStatus,
          errorCode: errorCode,
          errorMessage: errorMessage,
          a2pRegistrationRequired: true,
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          facilityId,
          sentBy: context.auth.uid,
        });

      // Return error to user with helpful message
      throw new functions.https.HttpsError(
        'failed-precondition',
        'A2P 10DLC registration is not complete. Your message was accepted by Twilio but cannot be delivered until A2P 10DLC brand and campaign registration is approved (typically takes 24-48 hours). Please check your A2P 10DLC registration status in Twilio Console > Messaging > Regulatory Compliance.',
        {
          twilioErrorCode: errorCode,
          twilioErrorMessage: errorMessage,
          messageId: result.sid,
          a2pRegistrationRequired: true,
        },
      );
    }

    // Check for "queued" status - message accepted but waiting for delivery (often A2P campaign pending)
    if (messageStatus === 'queued') {
      functions.logger.warn(`⚠️ [sendSMS] Message queued (may be waiting for A2P campaign approval):`, {
        messageId: result.sid,
        status: messageStatus,
        to: result.to,
        dateCreated: result.date_created,
      });
      
      // Still log as success since Twilio accepted it, but note the queued status
      // The message will deliver once A2P campaign is approved
    }

    // Update message log to "sent"
    const finalStatus = (messageStatus === 'failed' || messageStatus === 'undelivered') ? 'failed' : 'sent';
    await createOrUpdateMessageLog(facilityId, messageLogId, {
      tenantId: tenantInfo.tenantId,
      tenantName: tenantInfo.tenantName,
      tenantEmail: tenantInfo.tenantEmail,
      tenantPhone: tenantInfo.tenantPhone || phoneNumber,
      channel: 'sms',
      direction: 'outbound',
      source: source || 'manual',
      templateId: null,
      subject: null,
      previewText: previewText,
      bodyHtmlStored: false,
      bodyTextStored: false,
      status: finalStatus,
      provider: 'twilio',
      providerMessageId: result.sid,
      errorCode: errorCode || null,
      errorMessage: errorMessage || null,
      sentAt: admin.firestore.Timestamp.now(),
      createdByUid: context.auth.uid,
      createdByEmail: userEmail || null,
    });

    // Also log to legacy smsLogs collection
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsLogs')
      .add({
        to: phoneNumber,
        message: finalMessage, // Use finalMessage which includes footer if compliance enabled
        status: messageStatus || 'sent', // Use Twilio's status
        messageId: result.sid,
        twilioStatus: messageStatus,
        errorCode: errorCode || null,
        errorMessage: errorMessage || null,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        sentBy: context.auth.uid,
      });

    // Warn if status indicates potential issues
    if (messageStatus === 'failed' || messageStatus === 'undelivered' || errorCode) {
      functions.logger.warn(`⚠️ [sendSMS] Twilio message may have delivery issues:`, {
        messageId: result.sid,
        status: messageStatus,
        errorCode: errorCode,
        errorMessage: errorMessage,
        to: result.to,
      });
    }

    functions.logger.info(`SMS sent successfully to ${phoneNumber} for facility ${facilityId}`, {
      messageId: result.sid,
      twilioStatus: messageStatus,
      facilityId,
    });

    // Prepare status message based on Twilio response status
    let statusMessage: string | undefined;
    if (messageStatus === 'queued') {
      statusMessage = 'Message accepted and queued. It will be delivered once your A2P 10DLC campaign is approved (typically 1-7 business days). Check Twilio Console for campaign status.';
    } else if (messageStatus === 'sent') {
      statusMessage = 'Message sent to carrier. Delivery confirmation pending.';
    } else if (messageStatus === 'delivered') {
      statusMessage = 'Message delivered successfully.';
    }

    return {
      success: true,
      messageId: result.sid,
      messageLogId: messageLogId,
      status: finalStatus,
      provider: 'twilio',
      providerMessageId: result.sid,
      twilioStatus: messageStatus,
      statusMessage: statusMessage,
      usageWarning: usageCheck.warning,
      usageState: usageCheck.state,
      fallbackUsed: false,
      usage: usageCheck.usage,
    };

  } catch (error: any) {
    // If it's already an HttpsError (from Twilio auth, invalid args, etc.), rethrow it
    if (error instanceof functions.https.HttpsError) {
      // Update message log to "failed"
      try {
        const tenantInfo = await getTenantInfo(facilityId, tenantId, null, phoneNumber || to);
        const userRecord = await admin.auth().getUser(context.auth.uid);
        const userEmail = userRecord.email;
        const previewText = message.substring(0, 200);

        await createOrUpdateMessageLog(facilityId, messageLogId, {
          tenantId: tenantInfo.tenantId,
          tenantName: tenantInfo.tenantName,
          tenantEmail: tenantInfo.tenantEmail,
          tenantPhone: tenantInfo.tenantPhone || phoneNumber || to,
          channel: 'sms',
          direction: 'outbound',
          source: source || 'manual',
          templateId: null,
          subject: null,
          previewText: previewText,
          bodyHtmlStored: false,
          bodyTextStored: false,
          status: 'failed',
          provider: 'twilio',
          providerMessageId: null,
          errorCode: error.code,
          errorMessage: error.message || 'Unknown error',
          sentAt: null,
          createdByUid: context.auth.uid,
          createdByEmail: userEmail || null,
        });
      } catch (logError) {
        // Don't fail if logging fails
        functions.logger.warn('Failed to log SMS failure to messageLogs:', logError);
      }

      // Also log to legacy smsLogs collection
      try {
        await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('smsLogs')
          .add({
            to: phoneNumber || to,
            message,
            status: 'failed',
            error: error.message,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
            facilityId,
            sentBy: context.auth.uid,
          });
      } catch (logError) {
        // Don't fail if logging fails
        functions.logger.warn('Failed to log SMS failure to Firestore:', logError);
      }
      throw error; // Rethrow the original HttpsError with proper code
    }

    // For unexpected errors, convert to internal error
    functions.logger.error(
      `Failed to send SMS to ${to} for facility ${facilityId}`,
      { error: error?.message, stack: error?.stack, facilityId, to },
    );

    // Update message log to "failed"
    try {
      const phoneNumber = formatPhoneNumber(to);
      const tenantInfo = await getTenantInfo(facilityId, tenantId, null, phoneNumber || to);
      const userRecord = await admin.auth().getUser(context.auth.uid);
      const userEmail = userRecord.email;
      const previewText = message.substring(0, 200);

      await createOrUpdateMessageLog(facilityId, messageLogId, {
        tenantId: tenantInfo.tenantId,
        tenantName: tenantInfo.tenantName,
        tenantEmail: tenantInfo.tenantEmail,
        tenantPhone: tenantInfo.tenantPhone || phoneNumber || to,
        channel: 'sms',
        direction: 'outbound',
        source: source || 'manual',
        templateId: null,
        subject: null,
        previewText: previewText,
        bodyHtmlStored: false,
        bodyTextStored: false,
        status: 'failed',
        provider: 'twilio',
        providerMessageId: null,
        errorCode: 'internal',
        errorMessage: error?.message || 'Unknown error',
        sentAt: null,
        createdByUid: context.auth.uid,
        createdByEmail: userEmail || null,
      });
    } catch (logError) {
      // Don't fail if logging fails
      functions.logger.warn('Failed to log SMS failure to messageLogs:', logError);
    }

    // Also log to legacy smsLogs collection
    try {
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('smsLogs')
        .add({
          to,
          message,
          status: 'failed',
          error: error.message,
          timestamp: admin.firestore.FieldValue.serverTimestamp(),
          facilityId,
          sentBy: context.auth.uid,
        });
    } catch (logError) {
      // Don't fail if logging fails
      functions.logger.warn('Failed to log SMS failure to Firestore:', logError);
    }

    throw new functions.https.HttpsError('internal', `Failed to send SMS: ${error.message}`);
  }
});

/**
 * Fallback function: Send SMS message as email when SMS limits are exceeded
 */
async function sendSMSAsEmail(
  to: string,
  message: string,
  facilityId: string,
  usageCheck: any,
): Promise<{
  success: boolean;
  fallbackUsed: boolean;
  messageId?: string;
  usageWarning?: string;
  usageState: string;
}> {
  try {
    // Get tenant email if 'to' is a phone number, or use 'to' if it's already an email
    let emailAddress = to;
    
    // If 'to' looks like a phone number, try to find tenant email
    const phoneDigits = to.replace(/\D/g, '');
    if (/^\+?[1-9]\d{1,14}$/.test(phoneDigits)) {
      // It's a phone number - try to find tenant by phone (normalize formats)
      const phoneVariations = [
        to, // Original
        phoneDigits, // Digits only
        `+1${phoneDigits}`, // US format
        phoneDigits.startsWith('1') ? phoneDigits : `1${phoneDigits}`, // With country code
      ];

      let tenantFound = false;
      for (const phoneVar of phoneVariations) {
        const tenantsQuery = await admin.firestore()
          .collection('tenants')
          .where('phone', '==', phoneVar)
          .limit(1)
          .get();
        
        if (!tenantsQuery.empty) {
          const tenantData = tenantsQuery.docs[0].data();
          emailAddress = tenantData.email;
          if (emailAddress) {
            tenantFound = true;
            break;
          }
        }
      }

      if (!tenantFound || !emailAddress) {
        // No tenant found or no email - can't send email fallback
        functions.logger.warn(`Cannot send email fallback: no tenant email found for phone ${to}`);
        return {
          success: false,
          fallbackUsed: true,
          usageState: usageCheck.state,
          usageWarning: 'SMS limit exceeded and no email address found for fallback',
        };
      }
    }

    // Format message as email with SMS-style template
    const emailSubject = 'Message from Storage Facility';
    const emailHtml = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h2 style="color: #333;">Message from Your Storage Facility</h2>
        <div style="background-color: #f5f5f5; padding: 20px; border-radius: 5px; margin: 20px 0;">
          <p style="margin: 0; white-space: pre-wrap;">${message}</p>
        </div>
        <p style="color: #666; font-size: 12px; margin-top: 20px;">
          This message was sent via email because SMS fair-use limits have been reached.
          All features remain available - messages are automatically converted to email when needed.
        </p>
      </div>
    `;
    const emailText = message + '\n\n---\nThis message was sent via email because SMS fair-use limits have been reached.';

    // Send email via SendGrid
    initializeSendGrid();
    const msg = {
      to: emailAddress,
      from: {
        email: SENDGRID_FROM_EMAIL.value(),
        name: SENDGRID_FROM_NAME.value(),
      },
      subject: emailSubject,
      html: emailHtml,
      text: emailText,
    };

    const [result] = await sgMail.send(msg);
    const messageId = result.headers['x-message-id'] || `email-${Date.now()}`;

    // Log fallback email send
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsLogs')
      .add({
        to: emailAddress,
        originalTo: to,
        message,
        status: 'sent_via_email_fallback',
        messageId: messageId,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        facilityId,
        usageState: usageCheck.state,
        reason: 'SMS limit exceeded - automatic email fallback',
      });

    functions.logger.info(`SMS fallback: Sent as email to ${emailAddress} for facility ${facilityId}`, {
      messageId,
      facilityId,
      usageState: usageCheck.state,
    });

    return {
      success: true,
      fallbackUsed: true,
      messageId: messageId,
      usageWarning: usageCheck.warning,
      usageState: usageCheck.state,
    };
  } catch (error: any) {
    functions.logger.error(`Failed to send SMS fallback email: ${error.message}`, error);
    return {
      success: false,
      fallbackUsed: true,
      usageState: usageCheck.state,
      usageWarning: 'SMS limit exceeded and email fallback failed',
    };
  }
}

type A2PStatus = 'draft' | 'submitted' | 'pending' | 'approved' | 'rejected';

interface TextingBusinessData {
  legalBusinessName: string;
  dba?: string;
  businessType: 'LLC' | 'Corp' | 'Nonprofit' | 'Sole Prop';
  ein?: string;
  soleProprietorTaxIdLast4?: string;
  addressLine1: string;
  city: string;
  state: string;
  postalCode: string;
  country?: string;
  website: string;
  supportEmail: string;
  supportPhone: string;
}

interface CampaignData {
  useCases: string[];
  sampleMessages: string[];
  consentConfirmed: boolean;
}

interface TextingOnboardingState {
  a2pStatus: A2PStatus;
  a2pLastError?: string;
  textingPlatformApproved?: boolean;
  textingPlatformApprovedAt?: FirebaseFirestore.Timestamp;
  twilioMessagingServiceSid?: string;
  twilioTrustProfileSid?: string;
  twilioTrustProductSid?: string;
  twilioBrandSid?: string;
  twilioCampaignSid?: string;
  twilioPhoneNumberSid?: string;
  twilioPhoneNumberE164?: string;
}

async function assertTextingOnboardingEnabled(facilityId: string): Promise<void> {
  const enabled = await isFeatureFlagEnabled('TEXTING_ONBOARDING_V1');
  if (!enabled) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Texting onboarding is disabled. Enable TEXTING_ONBOARDING_V1 first.',
    );
  }
}

async function getFacilityForTextingMutation(
  facilityId: string,
  uid: string,
): Promise<{ ref: FirebaseFirestore.DocumentReference; data: Record<string, any> }> {
  const ref = admin.firestore().collection('facilities').doc(facilityId);
  const doc = await ref.get();
  const data = doc.data() as Record<string, any> | undefined;
  if (!doc.exists || !data) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }

  const ownerUid = data.ownerUid;
  const managersMap = (data.managers ?? {}) as Record<string, any>;
  const rolesMap = (data.roles ?? {}) as Record<string, any>;
  const isOwner = ownerUid === uid;
  const isManager = managersMap[uid] === true || rolesMap[uid] === 'manager' || rolesMap[uid] === 'owner';
  if (!isOwner && !isManager) {
    throw new functions.https.HttpsError('permission-denied', 'Not authorized for this facility');
  }

  return { ref, data };
}

function buildTwilioDryRunSid(prefix: string, facilityId: string): string {
  const normalized = facilityId.replace(/[^a-zA-Z0-9]/g, '').slice(0, 24).padEnd(24, '0');
  return `${prefix}${normalized}`;
}

async function ensureMessagingServiceForFacility(
  facilityRef: FirebaseFirestore.DocumentReference,
  facilityData: Record<string, any>,
  requestId: string,
): Promise<{ messagingServiceSid: string; created: boolean }> {
  const existing = facilityData.twilioMessagingServiceSid as string | undefined;
  const idempotent = await ensureIdempotentResource(
    existing,
    async () => {
      if (isTwilioDryRunEnabled()) {
        return { sid: buildTwilioDryRunSid('MG', facilityRef.id) };
      }
      const twilio = getTwilioClient() as any;
      return await twilio.messaging.v1.services.create({
        friendlyName: `SFC-${facilityRef.id}-Messaging`,
      });
    },
    (resource: any) => resource.sid as string,
  );

  if (idempotent.created) {
    await facilityRef.set({
      twilioMessagingServiceSid: idempotent.sid,
      a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    functions.logger.info('Created messaging service', { requestId, facilityId: facilityRef.id });
  }
  return { messagingServiceSid: idempotent.sid, created: idempotent.created };
}

async function provisionFacilityPhoneNumber(
  facilityRef: FirebaseFirestore.DocumentReference,
  facilityData: Record<string, any>,
  areaCode: string | undefined,
  requestId: string,
): Promise<{ phoneNumberSid: string; phoneNumberE164: string; created: boolean }> {
  const existingSid = facilityData.twilioPhoneNumberSid as string | undefined;
  const existingE164 = facilityData.twilioPhoneNumberE164 as string | undefined;
  if (existingSid && existingE164) {
    return { phoneNumberSid: existingSid, phoneNumberE164: existingE164, created: false };
  }

  if (isTwilioDryRunEnabled()) {
    const sid = buildTwilioDryRunSid('PN', facilityRef.id);
    const e164 = `+1555${Math.floor(Math.random() * 9000000 + 1000000)}`;
    await facilityRef.set({
      twilioPhoneNumberSid: sid,
      twilioPhoneNumberE164: e164,
      a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { phoneNumberSid: sid, phoneNumberE164: e164, created: true };
  }

  const twilio = getTwilioClient() as any;
  const numbers = await twilio.availablePhoneNumbers('US').local.list({
    smsEnabled: true,
    limit: 1,
    ...(areaCode ? { areaCode } : {}),
  });
  if (!numbers?.length) {
    throw new functions.https.HttpsError('resource-exhausted', 'No local Twilio number available for requested area');
  }

  const purchased = await twilio.incomingPhoneNumbers.create({
    phoneNumber: numbers[0].phoneNumber,
  });

  await facilityRef.set({
    twilioPhoneNumberSid: purchased.sid,
    twilioPhoneNumberE164: purchased.phoneNumber,
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  functions.logger.info('Provisioned Twilio number', { requestId, facilityId: facilityRef.id, phoneSid: purchased.sid });
  return { phoneNumberSid: purchased.sid, phoneNumberE164: purchased.phoneNumber, created: true };
}

async function attachPhoneNumberToMessagingService(
  messagingServiceSid: string,
  phoneNumberSid: string,
): Promise<void> {
  if (isTwilioDryRunEnabled()) return;
  const twilio = getTwilioClient() as any;
  const existing = await twilio.messaging.v1.services(messagingServiceSid).phoneNumbers.list({ limit: 200 });
  const exists = (existing || []).some((p: any) => p.phoneNumberSid === phoneNumberSid);
  if (!exists) {
    await twilio.messaging.v1.services(messagingServiceSid).phoneNumbers.create({
      phoneNumberSid,
    });
  }
}

async function createOrUpdateA2PProfileInternal(
  facilityRef: FirebaseFirestore.DocumentReference,
  facilityData: Record<string, any>,
  businessData: TextingBusinessData,
): Promise<{ trustProfileSid: string; trustProductSid: string }> {
  if (facilityData.twilioTrustProfileSid && facilityData.twilioTrustProductSid) {
    return {
      trustProfileSid: facilityData.twilioTrustProfileSid as string,
      trustProductSid: facilityData.twilioTrustProductSid as string,
    };
  }

  let trustProfileSid = '';
  let trustProductSid = '';
  if (isTwilioDryRunEnabled()) {
    trustProfileSid = buildTwilioDryRunSid('BU', facilityRef.id);
    trustProductSid = buildTwilioDryRunSid('TP', facilityRef.id);
  } else {
    const twilio = getTwilioClient() as any;
    const profile = await twilio.trusthub.v1.customerProfiles.create({
      friendlyName: `SFC ${facilityRef.id} ${businessData.legalBusinessName}`.slice(0, 60),
      email: businessData.supportEmail,
      status: 'draft',
    });
    trustProfileSid = profile.sid;
    const trustProduct = await twilio.trusthub.v1.trustProducts.create({
      friendlyName: `SFC ${facilityRef.id} A2P`,
      customerProfileSid: trustProfileSid,
    });
    trustProductSid = trustProduct.sid;
  }

  await facilityRef.set({
    twilioTrustProfileSid: trustProfileSid,
    twilioTrustProductSid: trustProductSid,
    textingBusinessData: {
      legalBusinessName: businessData.legalBusinessName,
      dba: businessData.dba || null,
      businessType: businessData.businessType,
      // Never store full tax IDs in Firestore
      einLast4: businessData.ein ? businessData.ein.slice(-4) : null,
      soleProprietorTaxIdLast4: businessData.soleProprietorTaxIdLast4 || null,
      addressLine1: businessData.addressLine1,
      city: businessData.city,
      state: businessData.state,
      postalCode: businessData.postalCode,
      country: businessData.country || 'US',
      website: businessData.website,
      supportEmail: businessData.supportEmail,
      supportPhone: businessData.supportPhone,
    },
    a2pStatus: 'draft',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });

  return { trustProfileSid, trustProductSid };
}

async function submitBrandRegistrationInternal(
  facilityRef: FirebaseFirestore.DocumentReference,
  facilityData: Record<string, any>,
): Promise<string> {
  if (facilityData.twilioBrandSid) return facilityData.twilioBrandSid as string;

  let sid = '';
  if (isTwilioDryRunEnabled()) {
    sid = buildTwilioDryRunSid('BN', facilityRef.id);
  } else {
    const twilio = getTwilioClient() as any;
    const brand = await twilio.messaging.v1.brandRegistrations.create({
      customerProfileBundleSid: facilityData.twilioTrustProfileSid,
      a2pProfileBundleSid: facilityData.twilioTrustProductSid,
      brandType: 'STANDARD',
    });
    sid = brand.sid;
  }

  await facilityRef.set({
    twilioBrandSid: sid,
    a2pStatus: 'submitted',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pSubmittedAt: admin.firestore.FieldValue.serverTimestamp(),
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  return sid;
}

async function submitCampaignInternal(
  facilityRef: FirebaseFirestore.DocumentReference,
  facilityData: Record<string, any>,
  campaignData: CampaignData,
): Promise<string> {
  if (facilityData.twilioCampaignSid) return facilityData.twilioCampaignSid as string;
  if (!facilityData.twilioBrandSid || !facilityData.twilioMessagingServiceSid || !facilityData.twilioPhoneNumberSid) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Missing Twilio brand, messaging service, or phone number. Complete previous steps first.',
    );
  }

  let sid = '';
  if (isTwilioDryRunEnabled()) {
    sid = buildTwilioDryRunSid('CP', facilityRef.id);
  } else {
    const twilio = getTwilioClient() as any;
    const campaign = await twilio.messaging.v1.campaigns.create({
      brandRegistrationSid: facilityData.twilioBrandSid,
      usecase: 'ACCOUNT_NOTIFICATION',
      description: 'Account notifications, collections reminders, and operational notices',
      messageFlow: 'Two-way interactions with opted-in tenants',
      sampleMessages: campaignData.sampleMessages,
      hasEmbeddedLinks: false,
      hasEmbeddedPhone: true,
    });
    sid = campaign.sid;
  }

  await facilityRef.set({
    twilioCampaignSid: sid,
    textingUseCases: campaignData.useCases,
    textingSampleMessages: campaignData.sampleMessages,
    textingConsentConfirmedAt: campaignData.consentConfirmed ? admin.firestore.FieldValue.serverTimestamp() : null,
    a2pStatus: isTwilioDryRunEnabled() ? 'approved' : 'pending',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    ...(isTwilioDryRunEnabled() ? { a2pApprovedAt: admin.firestore.FieldValue.serverTimestamp() } : {}),
  }, { merge: true });

  if (!isTwilioDryRunEnabled()) {
    await attachPhoneNumberToMessagingService(
      facilityData.twilioMessagingServiceSid as string,
      facilityData.twilioPhoneNumberSid as string,
    );
  }

  return sid;
}

function getTextingOnboardingState(facilityData: Record<string, any>): TextingOnboardingState {
  return {
    a2pStatus: ((facilityData.a2pStatus as string) || 'draft') as A2PStatus,
    a2pLastError: facilityData.a2pLastError as string | undefined,
    textingPlatformApproved: facilityData.textingPlatformApproved === true,
    textingPlatformApprovedAt: facilityData.textingPlatformApprovedAt as FirebaseFirestore.Timestamp | undefined,
    twilioMessagingServiceSid: facilityData.twilioMessagingServiceSid as string | undefined,
    twilioTrustProfileSid: facilityData.twilioTrustProfileSid as string | undefined,
    twilioTrustProductSid: facilityData.twilioTrustProductSid as string | undefined,
    twilioBrandSid: facilityData.twilioBrandSid as string | undefined,
    twilioCampaignSid: facilityData.twilioCampaignSid as string | undefined,
    twilioPhoneNumberSid: facilityData.twilioPhoneNumberSid as string | undefined,
    twilioPhoneNumberE164: facilityData.twilioPhoneNumberE164 as string | undefined,
  };
}

export const getTextingOnboardingStatus = functions.https.onCall(async (data: { facilityId: string }, context) => {
  if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  const { facilityId } = data || {};
  if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  await assertTextingOnboardingEnabled(facilityId);
  const { data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
  return {
    ...getTextingOnboardingState(facilityData),
    submittedAt: facilityData.a2pSubmittedAt || null,
    approvedAt: facilityData.a2pApprovedAt || null,
    rejectedAt: facilityData.a2pRejectedAt || null,
    rejectionReason: facilityData.a2pRejectionReason || null,
  };
});

export const saveTextingBusinessInfo = functions.https.onCall(async (data: { facilityId: string; businessData: TextingBusinessData }, context) => {
  if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  const { facilityId, businessData } = data || {};
  if (!facilityId || !businessData?.legalBusinessName) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and businessData are required');
  }
  await assertTextingOnboardingEnabled(facilityId);
  const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
  await createOrUpdateA2PProfileInternal(ref, facilityData, businessData);
  await ref.set({
    textingOnboardingEnabled: true,
    a2pStatus: 'draft',
    textingPlatformApproved: false,
    textingPlatformApprovedAt: null,
    textingPlatformApprovedBy: null,
    a2pLastError: null,
    a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
  }, { merge: true });
  return { success: true };
});

export const ensureMessagingService = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId } = data || {};
    if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    await assertTextingOnboardingEnabled(facilityId);
    const requestId = crypto.randomUUID();
    const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
    const result = await ensureMessagingServiceForFacility(ref, facilityData, requestId);
    return { success: true, requestId, ...result };
  },
);

export const createOrUpdateA2PProfile = functions.https.onCall(
  async (data: { facilityId: string; businessData: TextingBusinessData }, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId, businessData } = data || {};
    if (!facilityId || !businessData?.legalBusinessName) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId and businessData are required');
    }
    await assertTextingOnboardingEnabled(facilityId);
    const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
    const result = await createOrUpdateA2PProfileInternal(ref, facilityData, businessData);
    return { success: true, ...result };
  },
);

export const provisionPhoneNumber = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string; areaCode?: string }, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId, areaCode } = data || {};
    if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    await assertTextingOnboardingEnabled(facilityId);
    const requestId = crypto.randomUUID();
    const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
    const ms = await ensureMessagingServiceForFacility(ref, facilityData, requestId);
    const phone = await provisionFacilityPhoneNumber(ref, facilityData, areaCode, requestId);
    await attachPhoneNumberToMessagingService(ms.messagingServiceSid, phone.phoneNumberSid);
    return {
      success: true,
      requestId,
      messagingServiceSid: ms.messagingServiceSid,
      phoneNumberSid: phone.phoneNumberSid,
      phoneNumberE164: phone.phoneNumberE164,
      reusedExisting: !phone.created,
    };
  },
);

export const submitTextingOnboarding = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string; campaignData: CampaignData }, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId, campaignData } = data || {};
    if (!facilityId || !campaignData?.consentConfirmed) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId and consent confirmation are required');
    }
    await assertTextingOnboardingEnabled(facilityId);
    const requestId = crypto.randomUUID();
    const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
    const baseState = getTextingOnboardingState(facilityData);
    if (!baseState.twilioTrustProfileSid || !baseState.twilioTrustProductSid) {
      throw new functions.https.HttpsError('failed-precondition', 'Business profile is incomplete. Save business info first.');
    }
    const ms = await ensureMessagingServiceForFacility(ref, facilityData, requestId);
    const pn = await provisionFacilityPhoneNumber(ref, facilityData, undefined, requestId);
    await attachPhoneNumberToMessagingService(ms.messagingServiceSid, pn.phoneNumberSid);

    const latest = (await ref.get()).data() as Record<string, any>;
    const brandSid = await submitBrandRegistrationInternal(ref, latest);
    const latestAfterBrand = (await ref.get()).data() as Record<string, any>;
    const campaignSid = await submitCampaignInternal(ref, {
      ...latestAfterBrand,
      twilioBrandSid: brandSid,
      twilioMessagingServiceSid: latestAfterBrand.twilioMessagingServiceSid || ms.messagingServiceSid,
      twilioPhoneNumberSid: latestAfterBrand.twilioPhoneNumberSid || pn.phoneNumberSid,
    }, campaignData);

    return {
      success: true,
      requestId,
      a2pStatus: isTwilioDryRunEnabled() ? 'approved' : 'pending',
      twilioBrandSid: brandSid,
      twilioCampaignSid: campaignSid,
      twilioMessagingServiceSid: ms.messagingServiceSid,
      twilioPhoneNumberSid: pn.phoneNumberSid,
      twilioPhoneNumberE164: pn.phoneNumberE164,
    };
  },
);

export const submitBrandRegistration = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId } = data || {};
    if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    await assertTextingOnboardingEnabled(facilityId);
    const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
    const sid = await submitBrandRegistrationInternal(ref, facilityData);
    return { success: true, brandSid: sid };
  },
);

export const submitCampaign = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string; campaignData: CampaignData }, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId, campaignData } = data || {};
    if (!facilityId || !campaignData?.consentConfirmed) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId and campaignData are required');
    }
    await assertTextingOnboardingEnabled(facilityId);
    const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
    const sid = await submitCampaignInternal(ref, facilityData, campaignData);
    return { success: true, campaignSid: sid };
  },
);

export const refreshTextingOnboardingStatus = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId } = data || {};
    if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    await assertTextingOnboardingEnabled(facilityId);
    const { ref, data: facilityData } = await getFacilityForTextingMutation(facilityId, context.auth.uid);

    if (isTwilioDryRunEnabled()) {
      const current = (facilityData.a2pStatus as A2PStatus | undefined) || 'draft';
      const next = current === 'submitted' || current === 'pending' ? 'approved' : current;
      await ref.set({
        a2pStatus: next,
        textingPlatformApproved: false,
        textingPlatformApprovedAt: null,
        textingPlatformApprovedBy: null,
        a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
        ...(next === 'approved' ? { a2pApprovedAt: admin.firestore.FieldValue.serverTimestamp() } : {}),
      }, { merge: true });
      return { success: true, a2pStatus: next };
    }

    const twilio = getTwilioClient() as any;
    let brandStatus: string | undefined;
    let campaignStatus: string | undefined;
    if (facilityData.twilioBrandSid) {
      const brand = await twilio.messaging.v1.brandRegistrations(facilityData.twilioBrandSid).fetch();
      brandStatus = brand.status;
    }
    if (facilityData.twilioCampaignSid) {
      const campaign = await twilio.messaging.v1.campaigns(facilityData.twilioCampaignSid).fetch();
      campaignStatus = campaign.status;
    }
    const current = ((facilityData.a2pStatus as string) || 'draft') as A2PStatus;
    const next = computeA2PStatus(current, brandStatus, campaignStatus);
    const update: Record<string, any> = {
      a2pStatus: next,
      a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      a2pLastError: null,
      a2pRejectionReason: next === 'rejected' ? (campaignStatus || brandStatus || 'Rejected by Twilio') : null,
      ...(next !== 'approved' ? {
        textingPlatformApproved: false,
        textingPlatformApprovedAt: null,
        textingPlatformApprovedBy: null,
      } : {}),
    };
    if (next === 'approved') update.a2pApprovedAt = admin.firestore.FieldValue.serverTimestamp();
    if (next === 'rejected') update.a2pRejectedAt = admin.firestore.FieldValue.serverTimestamp();
    await ref.set(update, { merge: true });
    return { success: true, a2pStatus: next, brandStatus, campaignStatus };
  },
);

export const resubmitTextingOnboarding = functions.runWith({ secrets: TWILIO_SECRETS }).https.onCall(
  async (data: { facilityId: string }, context) => {
    if (!context.auth) throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
    const { facilityId } = data || {};
    if (!facilityId) throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    await assertTextingOnboardingEnabled(facilityId);
    const { ref } = await getFacilityForTextingMutation(facilityId, context.auth.uid);
    await ref.set({
      twilioBrandSid: admin.firestore.FieldValue.delete(),
      twilioCampaignSid: admin.firestore.FieldValue.delete(),
      a2pStatus: 'draft',
      textingPlatformApproved: false,
      textingPlatformApprovedAt: null,
      textingPlatformApprovedBy: null,
      a2pLastError: null,
      a2pRejectionReason: null,
      a2pLastUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });
    return { success: true };
  },
);

/**
 * Format phone number for Twilio (E.164 format)
 */
function formatPhoneNumber(phone: string): string | null {
  // Remove all non-digit characters
  const digits = phone.replace(/\D/g, '');
  
  // If it starts with 1 and has 11 digits, it's already formatted
  if (digits.length === 11 && digits.startsWith('1')) {
    return `+${digits}`;
  }
  
  // If it has 10 digits, assume US number and add +1
  if (digits.length === 10) {
    return `+1${digits}`;
  }
  
  // If it already starts with +, return as is
  if (phone.startsWith('+')) {
    return phone;
  }
  
  // Invalid format
  return null;
}

/**
 * SMS Usage Limits (configurable via environment variables)
 */
const SMS_LIMIT_PER_TENANT = parseInt(process.env.SMS_LIMIT_PER_TENANT || '4', 10);
const SMS_LIMIT_PER_FACILITY = parseInt(process.env.SMS_LIMIT_PER_FACILITY || '1000', 10);
const SMS_LIMIT_PER_ACCOUNT = parseInt(process.env.SMS_LIMIT_PER_ACCOUNT || '3000', 10);
const SMS_COST_PER_MESSAGE = parseFloat(process.env.SMS_COST_PER_MESSAGE || '0.01'); // conservative high estimate
const SMS_MAX_COST_PER_FACILITY = parseFloat(process.env.SMS_MAX_COST_PER_FACILITY || '40'); // cap spend per facility
const SMS_EXTREME_MULTIPLIER = 3; // Extreme usage = 3x account limit

function capSmsLimit(limit: number): number {
  if (limit <= 0) return 0;
  const maxMessages = Math.floor(SMS_MAX_COST_PER_FACILITY / SMS_COST_PER_MESSAGE);
  return Math.min(limit, maxMessages);
}

/**
 * SMS Usage State
 */
enum SMSUsageState {
  NORMAL = 'normal',
  APPROACHING = 'approaching', // 80-100% of limit
  EXCEEDED = 'exceeded', // Over 100% of limit
  EXTREME = 'extreme', // 3x limit
}

/**
 * Get SMS usage status for a facility (without incrementing)
 */
export const getSMSUsageStatus = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, tenantId, accountId } = data;

  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    const now = new Date();
    const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    // Get facility to find account ID if not provided
    let finalAccountId = accountId;
    if (!finalAccountId) {
      const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
      if (facilityDoc.exists) {
        finalAccountId = facilityDoc.data()?.facilityCreatorAccountId;
      }
    }

    // Get tenant usage
    let tenantUsage = { count: 0, limit: SMS_LIMIT_PER_TENANT };
    if (tenantId) {
      const tenantUsageDoc = await admin.firestore()
        .collection('tenants')
        .doc(tenantId)
        .collection('smsUsage')
        .doc(monthKey)
        .get();
      
      if (tenantUsageDoc.exists) {
        const data = tenantUsageDoc.data()!;
        tenantUsage = {
          count: data.smsMonthlyCount || 0,
          limit: SMS_LIMIT_PER_TENANT,
        };
      }
    }

    // Get facility usage
    const facilityUsageDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsUsage')
      .doc(monthKey)
      .get();
    
    const facilityData = facilityUsageDoc.exists ? facilityUsageDoc.data()! : {};
    const facilityUsage = {
      count: facilityData.smsMonthlyCount || 0,
      limit: capSmsLimit(facilityData.smsMonthlyLimit || SMS_LIMIT_PER_FACILITY),
    };

    // Get account usage
    let accountUsage = { count: 0, limit: SMS_LIMIT_PER_ACCOUNT };
    if (finalAccountId) {
      const accountUsageDoc = await admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(finalAccountId)
        .collection('smsUsage')
        .doc(monthKey)
        .get();
      
      if (accountUsageDoc.exists) {
        const data = accountUsageDoc.data()!;
        accountUsage = {
          count: data.smsMonthlyCount || 0,
          limit: capSmsLimit(data.smsMonthlyLimit || SMS_LIMIT_PER_ACCOUNT),
        };
      }
    }

    // Determine usage state
    const accountPercentage = finalAccountId ? (accountUsage.count / accountUsage.limit) * 100 : 0;
    const facilityPercentage = (facilityUsage.count / facilityUsage.limit) * 100;
    const tenantPercentage = tenantId ? (tenantUsage.count / tenantUsage.limit) * 100 : 0;

    let state: SMSUsageState = SMSUsageState.NORMAL;
    if (accountUsage.count >= (accountUsage.limit * SMS_EXTREME_MULTIPLIER)) {
      state = SMSUsageState.EXTREME;
    } else if (tenantUsage.count > tenantUsage.limit || facilityUsage.count > facilityUsage.limit || accountUsage.count > accountUsage.limit) {
      state = SMSUsageState.EXCEEDED;
    } else if (accountPercentage >= 80 || facilityPercentage >= 80 || tenantPercentage >= 80) {
      state = SMSUsageState.APPROACHING;
    }

    return {
      state,
      usage: {
        tenant: tenantId ? tenantUsage : undefined,
        facility: facilityUsage,
        account: finalAccountId ? accountUsage : undefined,
      },
      canSendSMS: state === SMSUsageState.NORMAL || state === SMSUsageState.APPROACHING,
      shouldFallbackToEmail: state === SMSUsageState.EXCEEDED || state === SMSUsageState.EXTREME,
    };
  } catch (error: any) {
    functions.logger.error('Error getting SMS usage status', error);
    throw new functions.https.HttpsError('internal', `Failed to get SMS usage status: ${error.message}`);
  }
});

/**
 * Admin function: Override SMS limits for a facility/account
 */
export const overrideSMSLimit = functions.https.onCall(async (data: any, context) => {
  // TODO: Add admin authentication check
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, accountId, newLimit, limitType } = data; // limitType: 'facility' | 'account'

  if (!facilityId && !accountId) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId or accountId is required');
  }

  if (!newLimit || !limitType) {
    throw new functions.https.HttpsError('invalid-argument', 'newLimit and limitType are required');
  }

  try {
    const now = new Date();
    const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    if (limitType === 'facility' && facilityId) {
      const usageRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('smsUsage')
        .doc(monthKey);
      
      await usageRef.set({
        smsMonthlyLimit: capSmsLimit(newLimit),
        smsMonth: monthKey,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        overriddenBy: context.auth.uid,
        overriddenAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, message: `Facility SMS limit updated to ${newLimit}` };
    }

    if (limitType === 'account' && accountId) {
      const usageRef = admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .collection('smsUsage')
        .doc(monthKey);
      
      await usageRef.set({
        smsMonthlyLimit: capSmsLimit(newLimit),
        smsMonth: monthKey,
        lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        overriddenBy: context.auth.uid,
        overriddenAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

      return { success: true, message: `Account SMS limit updated to ${newLimit}` };
    }

    throw new functions.https.HttpsError('invalid-argument', 'Invalid limitType or missing ID');
  } catch (error: any) {
    functions.logger.error('Error overriding SMS limit', error);
    throw new functions.https.HttpsError('internal', `Failed to override SMS limit: ${error.message}`);
  }
});

/**
 * Callable function to generate monthly rent charges for a facility
 * Can be called manually or by scheduled function
 */
export const generateMonthlyRentCharges = functions.https.onCall(async (data, context) => {
  try {
    // Verify authentication
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }

    const { facilityId, forDate, dryRun } = data;
    const isDryRun = dryRun === true;

    if (!facilityId) {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
    }

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
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to generate charges for this facility');
    }

    // Parse target date or use first of current month
    let targetDate: Date;
    if (forDate) {
      targetDate = new Date(forDate);
    } else {
      const now = new Date();
      targetDate = new Date(now.getFullYear(), now.getMonth(), 1);
    }

    // Get all active tenants for the facility
    const tenantsSnapshot = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .where('isActive', '==', true)
      .get();

    // Filter tenants with safety checks
    const activeTenants = tenantsSnapshot.docs.filter(doc => {
      const data = doc.data();
      // Must have unit number
      if (!data.unitNumber || data.unitNumber.trim() === '') {
        return false;
      }
      // Must be active
      if (data.isActive !== true) {
        return false;
      }
      // Skip if moved out (has moveOutDate)
      if (data.moveOutDate) {
        return false;
      }
      return true;
    });

    functions.logger.info(`Generating charges for ${activeTenants.length} active tenants in facility ${facilityId}`);

    let successCount = 0;
    let skippedCount = 0;
    let errorCount = 0;
    const errors: string[] = [];

    const targetMonth = targetDate.getMonth() + 1; // JavaScript months are 0-indexed
    const targetYear = targetDate.getFullYear();

    for (const tenantDoc of activeTenants) {
      try {
        const tenantData = tenantDoc.data();
        const tenantId = tenantDoc.id;
        const monthlyRate = tenantData.monthlyRate || 0;

        if (monthlyRate <= 0) {
          skippedCount++;
          continue;
        }

        // Check if idempotency is enabled
        const idempotencyEnabled = await isPaymentSafetyFeatureEnabled('idempotency', facilityId);

        // Generate idempotency key for this charge (if enabled)
        // Format: charge_{facilityId}_{tenantId}_{year}_{month}
        const chargeIdempotencyKey = idempotencyEnabled
          ? `charge_${facilityId}_${tenantId}_${targetYear}_${targetMonth}`
          : null;

        // Check idempotency collection first (faster than querying all ledger entries) - if enabled
        if (idempotencyEnabled && chargeIdempotencyKey) {
          const idempotencyRef = admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('idempotencyKeys')
            .doc(chargeIdempotencyKey);

          const idempotencyDoc = await idempotencyRef.get();

          if (idempotencyDoc.exists) {
            const idempotencyData = idempotencyDoc.data();
            const existingEntryId = idempotencyData?.ledgerEntryId as string | undefined;
            
            if (existingEntryId) {
              // Verify the entry still exists
              const existingEntryRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('ledger')
                .doc(existingEntryId);
              
              const existingEntryDoc = await existingEntryRef.get();
              
              if (existingEntryDoc.exists) {
                functions.logger.info(`Charge already exists (idempotency): ${chargeIdempotencyKey} -> ${existingEntryId}`);
                skippedCount++;
                continue;
              } else {
                // Entry was deleted, remove idempotency key and continue
                await idempotencyRef.delete();
              }
            } else {
              skippedCount++;
              continue;
            }
          }
        }

        // Also check ledger entries as fallback (for backward compatibility)
        const ledgerSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('ledger')
          .where('type', '==', 'rentCharge')
          .where('status', '==', 'posted')
          .get();

        const existingCharge = ledgerSnapshot.docs.some(doc => {
          const entryData = doc.data();
          const entryDate = entryData.entryDate?.toDate();
          if (!entryDate) return false;

          const entryMonth = entryDate.getMonth() + 1;
          const entryYear = entryDate.getFullYear();

          if (entryMonth !== targetMonth || entryYear !== targetYear) return false;

          const metadata = entryData.metadata || {};
          return metadata.recurringCharge === true &&
                 metadata.chargeType === 'monthlyRent' &&
                 metadata.month === targetMonth &&
                 metadata.year === targetYear;
        });

        if (existingCharge) {
          // Store idempotency key for future checks (if enabled)
          if (idempotencyEnabled && chargeIdempotencyKey) {
            const idempotencyRef = admin.firestore()
              .collection('facilities')
              .doc(facilityId)
              .collection('idempotencyKeys')
              .doc(chargeIdempotencyKey);
            
            await idempotencyRef.set({
              ledgerEntryId: ledgerSnapshot.docs[0].id,
              createdAt: admin.firestore.FieldValue.serverTimestamp(),
              facilityId,
              tenantId,
              month: targetMonth,
              year: targetYear,
            });
          }
          skippedCount++;
          continue;
        }

        // Generate rent charge
        const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
          'July', 'August', 'September', 'October', 'November', 'December'];
        const description = `Monthly Rent - ${monthNames[targetDate.getMonth()]} ${targetYear}`;

        // In dry-run mode, skip actual creation
        if (isDryRun) {
          successCount++;
          continue;
        }

        // Use transaction to ensure atomicity (if idempotency enabled)
        const ledgerEntryId = idempotencyEnabled && chargeIdempotencyKey
          ? await admin.firestore().runTransaction(async (tx) => {
              // Double-check idempotency within transaction
              const idempotencyRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('idempotencyKeys')
                .doc(chargeIdempotencyKey);
              
              const idempotencyCheck = await tx.get(idempotencyRef);
              if (idempotencyCheck.exists) {
                const existingEntryId = idempotencyCheck.data()?.ledgerEntryId as string | undefined;
                if (existingEntryId) {
                  throw new Error('DUPLICATE_CHARGE'); // Will be caught and skipped
                }
              }

          // Create ledger entry
          const ledgerEntryRef = admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(tenantId)
            .collection('ledger')
            .doc();

          const ledgerEntryData = {
            type: 'rentCharge',
            amount: monthlyRate,
            description,
            entryDate: admin.firestore.Timestamp.fromDate(targetDate),
            dueDate: admin.firestore.Timestamp.fromDate(targetDate),
            status: 'posted',
            facilityId,
            tenantId,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
          metadata: {
            recurringCharge: true,
            chargeType: 'monthlyRent',
            month: targetMonth,
            year: targetYear,
            ...(chargeIdempotencyKey ? { idempotencyKey: chargeIdempotencyKey } : {}),
            generatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          };

          tx.set(ledgerEntryRef, ledgerEntryData);

              // Store idempotency key
              tx.set(idempotencyRef, {
                ledgerEntryId: ledgerEntryRef.id,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                facilityId,
                tenantId,
                month: targetMonth,
                year: targetYear,
              });

              return ledgerEntryRef.id;
            }).catch(async (error: any) => {
              if (error.message === 'DUPLICATE_CHARGE') {
                // This is expected - charge already exists
                return null;
              }
              throw error;
            })
          : (async () => {
              // Create ledger entry without transaction (idempotency disabled)
              const ledgerEntryRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('ledger')
                .doc();

              await ledgerEntryRef.set({
                type: 'rentCharge',
                amount: monthlyRate,
                description,
                entryDate: admin.firestore.Timestamp.fromDate(targetDate),
                dueDate: admin.firestore.Timestamp.fromDate(targetDate),
                status: 'posted',
                facilityId,
                tenantId,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                metadata: {
                  recurringCharge: true,
                  chargeType: 'monthlyRent',
                  month: targetMonth,
                  year: targetYear,
                  generatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
              });

              return ledgerEntryRef.id;
            })();

        const ledgerEntryIdResolved = await ledgerEntryId;
        if (ledgerEntryIdResolved === null) {
          skippedCount++;
          continue;
        }

        // Audit log
        await writeAuditLog(facilityId, {
          eventType: 'recurringCharge.generated',
          actorUid: context.auth.uid,
          targetType: 'ledgerEntry',
          targetId: ledgerEntryIdResolved,
          tenantId,
          after: {
            amount: monthlyRate,
            chargeType: 'monthlyRent',
            month: targetMonth,
            year: targetYear,
          },
          metadata: {
            ...(chargeIdempotencyKey ? { idempotencyKey: chargeIdempotencyKey } : {}),
          },
        });

        successCount++;
      } catch (error: any) {
        errorCount++;
        const tenantData = tenantDoc.data();
        const errorMsg = `Tenant ${tenantData.name || tenantDoc.id}: ${error.message}`;
        errors.push(errorMsg);
        functions.logger.error(`Error generating charge for tenant ${tenantDoc.id}:`, error);
      }
    }

    functions.logger.info(`Charge generation completed: ${successCount} success, ${skippedCount} skipped, ${errorCount} errors`);

    return {
      success: true,
      totalTenants: activeTenants.length,
      successCount,
      skippedCount,
      errorCount,
      errors,
      dryRun: isDryRun,
      ...(isDryRun ? {
        preview: {
          totalCharges: successCount,
          totalAmount: activeTenants.reduce((sum, doc) => {
            const data = doc.data();
            return sum + (data.monthlyRate || 0);
          }, 0),
        },
      } : {}),
    };
  } catch (error: any) {
    functions.logger.error('Error generating monthly rent charges:', error);
    throw new functions.https.HttpsError('internal', `Failed to generate charges: ${error.message}`);
  }
});

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

// ========== QuickBooks Accounting ==========
/**
 * Returns connection status for facility QuickBooks integration.
 */
export const getQuickBooksConnectionStatus = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.getQuickBooksConnectionStatus(data, context);
});

/**
 * Creates an OAuth URL to connect facility QuickBooks account.
 */
export const getQuickBooksConnectUrl = functions.runWith({ secrets: QUICKBOOKS_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.getQuickBooksConnectUrl(data, context, getQuickBooksConfig());
});

/**
 * Completes QuickBooks OAuth token exchange and stores connection.
 */
export const completeQuickBooksConnect = functions.runWith({ secrets: QUICKBOOKS_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.completeQuickBooksConnect(data, context, getQuickBooksConfig());
});

/**
 * Disconnects QuickBooks integration and clears stored tokens.
 */
export const disconnectQuickBooks = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.disconnectQuickBooks(data, context);
});

/**
 * Manually syncs a facility invoice into QuickBooks.
 */
export const syncInvoiceToQuickBooks = functions.runWith({ secrets: QUICKBOOKS_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.syncInvoiceToQuickBooks(data, context, getQuickBooksConfig());
});

/**
 * Manually syncs a facility payment into QuickBooks.
 */
export const syncPaymentToQuickBooks = functions.runWith({ secrets: QUICKBOOKS_SECRETS }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.syncPaymentToQuickBooks(data, context, getQuickBooksConfig());
});

/**
 * Enables/disables facility QuickBooks auto-sync.
 */
export const setQuickBooksAutoSync = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  return quickBooksAccounting.setQuickBooksAutoSync(data, context);
});

/**
 * Auto-sync invoice changes into QuickBooks when integration is connected.
 */
export const autoSyncInvoiceToQuickBooks = functions
  .runWith({ secrets: QUICKBOOKS_SECRETS, timeoutSeconds: 120, memory: '256MB' })
  .firestore
  .document('facilities/{facilityId}/invoices/{invoiceId}')
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;

    const afterData = (change.after.data() || {}) as Record<string, any>;
    const beforeData = (change.before.data() || {}) as Record<string, any>;
    const afterQuickbooks = (afterData.quickbooks || {}) as Record<string, any>;

    // Already synced; skip to avoid loops.
    if (typeof afterQuickbooks.invoiceId === 'string' && afterQuickbooks.invoiceId.trim() !== '') return;

    const status = String(afterData.status || '').toLowerCase();
    // Sync non-draft invoices only.
    if (status === '' || status === 'draft' || status === 'voided') return;

    const beforeStatus = String(beforeData.status || '').toLowerCase();
    const beforeQuickbooks = (beforeData.quickbooks || {}) as Record<string, any>;
    const hadQboInvoiceId = typeof beforeQuickbooks.invoiceId === 'string' && beforeQuickbooks.invoiceId.trim() !== '';
    const statusChanged = beforeStatus !== status;
    const createdNow = !change.before.exists;
    const lineItemsChanged = JSON.stringify(beforeData.lineItems || []) !== JSON.stringify(afterData.lineItems || []);
    const totalChanged = Number(beforeData.total || 0) !== Number(afterData.total || 0);

    if (!createdNow && !statusChanged && !lineItemsChanged && !totalChanged && !hadQboInvoiceId) return;

    const facilityId = context.params.facilityId as string;
    const invoiceId = context.params.invoiceId as string;
    await quickBooksAccounting.autoSyncInvoiceIfEligible(facilityId, invoiceId, getQuickBooksConfig());
  });

/**
 * Auto-sync completed payments into QuickBooks when integration is connected.
 */
export const autoSyncPaymentToQuickBooks = functions
  .runWith({ secrets: QUICKBOOKS_SECRETS, timeoutSeconds: 120, memory: '256MB' })
  .firestore
  .document('facilities/{facilityId}/payments/{paymentId}')
  .onWrite(async (change, context) => {
    if (!change.after.exists) return;

    const afterData = (change.after.data() || {}) as Record<string, any>;
    const beforeData = (change.before.data() || {}) as Record<string, any>;
    const afterQuickbooks = (afterData.quickbooks || {}) as Record<string, any>;

    // Already synced; skip to avoid loops.
    if (typeof afterQuickbooks.paymentId === 'string' && afterQuickbooks.paymentId.trim() !== '') return;

    const status = String(afterData.status || '').toLowerCase();
    const isPaidStatus = status === 'paid' || status === 'completed';
    if (!isPaidStatus) return;

    const beforeStatus = String(beforeData.status || '').toLowerCase();
    const becamePaid = beforeStatus !== 'paid' && beforeStatus !== 'completed';
    if (!change.before.exists || becamePaid) {
      const facilityId = context.params.facilityId as string;
      const paymentId = context.params.paymentId as string;
      await quickBooksAccounting.autoSyncPaymentIfEligible(facilityId, paymentId, getQuickBooksConfig());
    }
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
 * Scheduled function: Generate monthly rent charges on the 1st of each month at 12:00 AM UTC
 * This function runs for all facilities
 */
export const scheduledGenerateMonthlyRentCharges = functions.pubsub
  .schedule('0 0 1 * *') // 1st of each month at 12:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    try {
      functions.logger.info('Starting scheduled monthly rent charge generation');

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      functions.logger.info(`Found ${facilitiesSnapshot.size} active facilities`);

      const results = [];
      const targetDate = new Date();
      targetDate.setDate(1); // First day of current month

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        try {
          const facilityData = facilityDoc.data();
          // ownerUid available if needed for future permission checks

          // Get all active tenants
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .get();

          const activeTenants = tenantsSnapshot.docs.filter(doc => {
            const data = doc.data();
            return data.unitNumber && data.unitNumber.trim() !== '';
          });

          let successCount = 0;
          let skippedCount = 0;
          let errorCount = 0;

          const targetMonth = targetDate.getMonth() + 1;
          const targetYear = targetDate.getFullYear();

          for (const tenantDoc of activeTenants) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;
              const monthlyRate = tenantData.monthlyRate || 0;

              if (monthlyRate <= 0) {
                skippedCount++;
                continue;
              }

              // Check if charge already exists
              const ledgerSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .where('tenantId', '==', tenantId)
                .where('type', '==', 'rentCharge')
                .where('status', '==', 'posted')
                .get();

              const existingCharge = ledgerSnapshot.docs.some(doc => {
                const entryData = doc.data();
                const entryDate = entryData.entryDate?.toDate();
                if (!entryDate) return false;

                const entryMonth = entryDate.getMonth() + 1;
                const entryYear = entryDate.getFullYear();

                if (entryMonth !== targetMonth || entryYear !== targetYear) return false;

                const metadata = entryData.metadata || {};
                return metadata.recurringCharge === true &&
                       metadata.chargeType === 'monthlyRent' &&
                       metadata.month === targetMonth &&
                       metadata.year === targetYear;
              });

              if (existingCharge) {
                skippedCount++;
                continue;
              }

              // Generate charge
              const monthNames = ['January', 'February', 'March', 'April', 'May', 'June',
                'July', 'August', 'September', 'October', 'November', 'December'];
              const description = `Monthly Rent - ${monthNames[targetDate.getMonth()]} ${targetYear}`;

              const ledgerEntryRef = admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .doc();

              await ledgerEntryRef.set({
                tenantId: tenantId,
                facilityId: facilityId,
                type: 'rentCharge',
                amount: monthlyRate,
                description: description,
                entryDate: admin.firestore.Timestamp.fromDate(targetDate),
                dueDate: admin.firestore.Timestamp.fromDate(targetDate),
                status: 'posted',
                metadata: {
                  recurringCharge: true,
                  chargeType: 'monthlyRent',
                  month: targetMonth,
                  year: targetYear,
                  generatedAt: admin.firestore.FieldValue.serverTimestamp(),
                },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                createdBy: 'system', // System-generated
              });

              // Audit log
              await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('auditLogs')
                .add({
                  action: 'recurringCharge.generated',
                  actorUid: 'system',
                  actorEmail: 'system@scheduled-job',
                  targetId: ledgerEntryRef.id,
                  entityType: 'ledgerEntry',
                  entityId: ledgerEntryRef.id,
                  tenantId: tenantId,
                  details: {
                    amount: monthlyRate,
                    chargeType: 'monthlyRent',
                    month: targetMonth,
                    year: targetYear,
                    scheduled: true,
                  },
                  at: admin.firestore.FieldValue.serverTimestamp(),
                });

              successCount++;
            } catch (error: any) {
              errorCount++;
              functions.logger.error(`Error generating charge for tenant ${tenantDoc.id} in facility ${facilityId}:`, error);
            }
          }

          results.push({
            facilityId,
            facilityName: facilityData.name,
            totalTenants: activeTenants.length,
            successCount,
            skippedCount,
            errorCount,
          });

          functions.logger.info(`Facility ${facilityData.name}: ${successCount} success, ${skippedCount} skipped, ${errorCount} errors`);
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
          results.push({
            facilityId,
            facilityName: facilityDoc.data()?.name || 'Unknown',
            error: error.message,
          });
        }
      }

      functions.logger.info(`Scheduled charge generation completed for ${results.length} facilities`);
      return { results };
    } catch (error: any) {
      functions.logger.error('Error in scheduled charge generation:', error);
      throw error;
    }
  });

/**
 * Scheduled function: Process autopay payments daily
 * Runs daily at 2:00 AM UTC to process autopay for due payments
 */
/**
 * Scheduled function to process delinquency automation daily
 * Runs at 3:00 AM UTC every day
 */
export const processDelinquencyAutomation = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 3 * * *')
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting delinquency automation processing...');

    try {
      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalProcessed = 0;
      let totalLateFees = 0;
      let totalNotices = 0;
      let totalLockouts = 0;
      let totalErrors = 0;

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        functions.logger.info(`Processing delinquency for facility: ${facilityId}`);

        try {
          // Call the delinquency processing function (never dry-run for scheduled)
          const result = await processDelinquencyForFacility(facilityId, false);
          
          if (result.success) {
            totalProcessed += result.processedCount || 0;
            totalLateFees += result.lateFeeAppliedCount || 0;
            totalNotices += result.noticeSentCount || 0;
            totalLockouts += result.lockoutCount || 0;
            totalErrors += result.errorCount || 0;

            functions.logger.info(`✅ Processed facility ${facilityId}:`, {
              processed: result.processedCount,
              lateFees: result.lateFeeAppliedCount,
              notices: result.noticeSentCount,
              lockouts: result.lockoutCount,
            });
          } else {
            totalErrors++;
            functions.logger.error(`❌ Error processing facility ${facilityId}:`, result.error);
          }
        } catch (error: any) {
          totalErrors++;
          functions.logger.error(`❌ Error processing facility ${facilityId}:`, {
            error: error.message,
            stack: error.stack,
          });
        }
      }

      functions.logger.info('✅ Delinquency automation complete:', {
        facilitiesProcessed: facilitiesSnapshot.size,
        totalProcessed,
        totalLateFees,
        totalNotices,
        totalLockouts,
        totalErrors,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in delinquency automation:', {
        error: error.message,
        stack: error.stack,
      });
      throw error;
    }
  });

/**
 * Process delinquency for a single facility
 * This can be called manually or by the scheduled function
 */
async function processDelinquencyForFacility(
  facilityId: string,
  dryRun: boolean = false,
): Promise<{
  success: boolean;
  processedCount?: number;
  lateFeeAppliedCount?: number;
  noticeSentCount?: number;
  lockoutCount?: number;
  errorCount?: number;
  error?: string;
  dryRun?: boolean;
  preview?: {
    tenantsToProcess: number;
    estimatedLateFees: number;
    estimatedNotices: number;
    estimatedLockouts: number;
  };
}> {
  try {
    // Get facility
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      return { success: false, error: 'Facility not found' };
    }

    const facilityData = facilityDoc.data();
    const billingSettings = facilityData?.billingSettings || {};

    // Get delinquency rules
    const rules = {
      gracePeriodDays: billingSettings.gracePeriodDays || 3,
      baseLateFee: billingSettings.baseLateFee || 25.0,
      dailyLateFee: billingSettings.dailyLateFee || 5.0,
      noticeDays: billingSettings.noticeDays || 7,
      finalNoticeDays: billingSettings.finalNoticeDays || 14,
      lienDays: billingSettings.lienDays || 30,
      lockoutDays: billingSettings.lockoutDays || 45,
      enableAutoLateFees: billingSettings.enableAutoLateFees !== false,
      enableAutoNotices: billingSettings.enableAutoNotices !== false,
      enableAutoLockout: billingSettings.enableAutoLockout === true,
    };

    // Get all active tenants (with safety checks)
    const tenantsSnapshot = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .where('isActive', '==', true)
      .get();

    // Filter out moved-out tenants
    const eligibleTenants = tenantsSnapshot.docs.filter(doc => {
      const data = doc.data();
      // Skip if moved out
      if (data.moveOutDate) {
        return false;
      }
      return true;
    });

    let processedCount = 0;
    let lateFeeAppliedCount = 0;
    let noticeSentCount = 0;
    let lockoutCount = 0;
    let errorCount = 0;
    let estimatedLateFees = 0;
    const estimatedNotices = 0;
    let estimatedLockouts = 0;

    for (const tenantDoc of tenantsSnapshot.docs) {
      try {
        const tenantData = tenantDoc.data();
        const tenantId = tenantDoc.id;

        // Check if tenant is late (simplified check - in production use full logic)
        const paidThrough = tenantData.paidThrough?.toDate();
        const now = new Date();
        const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1);
        const graceBoundary = new Date(startOfMonth);
        graceBoundary.setDate(graceBoundary.getDate() - rules.gracePeriodDays);

        const isLate = !paidThrough || paidThrough < graceBoundary;
        
        if (!isLate) {
          continue; // Skip non-delinquent tenants
        }

        // Calculate days late
        const daysLate = Math.max(0, Math.floor((now.getTime() - graceBoundary.getTime()) / (1000 * 60 * 60 * 24)));

        // Get ledger balance
        const ledgerSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .doc(tenantId)
          .collection('ledger')
          .get();

        let balance = 0;
        for (const entry of ledgerSnapshot.docs) {
          const entryData = entry.data();
          if (entryData.status === 'posted' || entryData.status === 'pending') {
            if (entryData.type === 'payment' || entryData.type === 'credit') {
              balance -= entryData.amount || 0;
            } else {
              balance += entryData.amount || 0;
            }
          }
        }

        if (balance <= 0) {
          continue; // Balance is paid
        }

        // Apply late fee if needed
        if (rules.enableAutoLateFees && daysLate > rules.gracePeriodDays) {
          const lateFee = rules.baseLateFee + ((daysLate - rules.gracePeriodDays) * rules.dailyLateFee);
          
          // Check if late fee already applied this month
          const thisMonth = new Date(now.getFullYear(), now.getMonth(), 1);
          const lateFeeSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .doc(tenantId)
            .collection('ledger')
            .where('type', '==', 'lateFee')
            .where('status', '==', 'posted')
            .where('entryDate', '>=', admin.firestore.Timestamp.fromDate(thisMonth))
            .get();

          if (lateFeeSnapshot.empty && lateFee > 0) {
            if (dryRun) {
              // In dry-run mode, just count it
              estimatedLateFees += lateFee;
            } else {
              // Create late fee ledger entry
              const ledgerEntryRef = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('ledger')
                .add({
                  type: 'lateFee',
                  amount: lateFee,
                  description: `Late Fee - ${daysLate} days overdue`,
                  entryDate: admin.firestore.FieldValue.serverTimestamp(),
                  dueDate: admin.firestore.FieldValue.serverTimestamp(),
                  status: 'posted',
                  facilityId,
                  tenantId,
                  createdAt: admin.firestore.FieldValue.serverTimestamp(),
                  metadata: {
                    daysOverdue: daysLate,
                    automated: true,
                  },
                });

              // Log audit event
              await writeAuditLog(facilityId, {
                eventType: 'delinquency.lateFeeApplied',
                actorUid: 'system',
                targetType: 'ledgerEntry',
                targetId: ledgerEntryRef.id,
                tenantId,
                after: {
                  amount: lateFee,
                  daysOverdue: daysLate,
                  automated: true,
                },
                metadata: {
                  baseLateFee: rules.baseLateFee,
                  dailyLateFee: rules.dailyLateFee,
                  gracePeriodDays: rules.gracePeriodDays,
                },
              });
            }
            lateFeeAppliedCount++;
          }
        }

        // Send notices if needed
        if (rules.enableAutoNotices) {
          let shouldSendNotice = false;
          let noticeType = '';
          
          if (daysLate >= rules.finalNoticeDays) {
            shouldSendNotice = true;
            noticeType = 'final';
          } else if (daysLate >= rules.noticeDays) {
            shouldSendNotice = true;
            noticeType = 'late';
          }

          if (shouldSendNotice) {
            try {
              // Get tenant contact info for notices
              const tenantEmail = tenantData?.email;
              const tenantPhone = tenantData?.phone;
              const tenantName = tenantData?.name || 'Tenant';
              
              // Check if notice was already sent today
              const today = new Date();
              today.setHours(0, 0, 0, 0);
              const noticesSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('tenants')
                .doc(tenantId)
                .collection('notices')
                .where('type', '==', noticeType)
                .where('sentDate', '>=', admin.firestore.Timestamp.fromDate(today))
                .limit(1)
                .get();

              if (noticesSnapshot.empty) {
                // Send email notice
                if (tenantEmail && tenantEmail.trim() !== '') {
                  try {
                    initializeSendGrid();
                    const subject = noticeType === 'final' 
                      ? `Final Notice: Payment Overdue - ${facilityData?.name || 'Storage Facility'}`
                      : `Payment Reminder: Account Past Due - ${facilityData?.name || 'Storage Facility'}`;
                    
                    const emailContent = `
Dear ${tenantName},

This is a ${noticeType === 'final' ? 'FINAL' : ''} notice regarding your overdue payment.

Your account is currently ${daysLate} days overdue with a balance of $${balance.toFixed(2)}.

${noticeType === 'final' ? 'This is your final notice before further action is taken. ' : ''}Please contact us immediately to resolve this matter.

${facilityData?.phone ? `You can reach us at ${facilityData.phone}.` : ''}
${facilityData?.email ? `Or email us at ${facilityData.email}.` : ''}

Thank you,
${facilityData?.name || 'Management Team'}
                    `.trim();

                    // Initialize SendGrid if not already initialized
                    initializeSendGrid();
                    
                    // Send email directly via SendGrid
                    const msg = {
                      to: tenantEmail,
                      from: {
                        email: SENDGRID_FROM_EMAIL.value(),
                        name: SENDGRID_FROM_NAME.value(),
                      },
                      subject: subject,
                      html: emailContent.replace(/\n/g, '<br>'),
                      text: emailContent,
                    };
                    
                    await sgMail.send(msg);

                    // Record notice in Firestore
                    await admin.firestore()
                      .collection('facilities')
                      .doc(facilityId)
                      .collection('tenants')
                      .doc(tenantId)
                      .collection('notices')
                      .add({
                        type: noticeType,
                        sentDate: admin.firestore.FieldValue.serverTimestamp(),
                        daysLate: daysLate,
                        balance: balance,
                        method: 'email',
                        recipient: tenantEmail,
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                      });
                  } catch (emailError: any) {
                    functions.logger.error(`Failed to send email notice to ${tenantEmail}:`, emailError);
                  }
                }

                // Send SMS notice if phone available
                if (tenantPhone && tenantPhone.trim() !== '') {
                  try {
                    const smsMessage = noticeType === 'final'
                      ? `FINAL NOTICE: Your account is ${daysLate} days overdue. Balance: $${balance.toFixed(2)}. Contact us immediately.`
                      : `Payment reminder: Your account is ${daysLate} days overdue. Balance: $${balance.toFixed(2)}. Please make a payment.`;
                    
                    // Note: SMS sending would require Twilio integration
                    // For now, we log it - implement actual SMS sending if needed
                    functions.logger.info(`SMS notice would be sent to ${tenantPhone}: ${smsMessage}`);
                  } catch (smsError: any) {
                    functions.logger.error(`Failed to send SMS notice to ${tenantPhone}:`, smsError);
                  }
                }

                noticeSentCount++;
              }
            } catch (noticeError: any) {
              functions.logger.error(`Error sending notice to tenant ${tenantId}:`, noticeError);
            }
          }
        }

        // Update tenant delinquency status
        let delinquencyStatus = '';
        if (daysLate >= rules.lockoutDays) {
          delinquencyStatus = 'lockout';
        } else if (daysLate >= rules.lienDays) {
          delinquencyStatus = 'lien';
        } else if (daysLate >= rules.finalNoticeDays) {
          delinquencyStatus = 'final_notice';
        } else if (daysLate >= rules.noticeDays) {
          delinquencyStatus = 'late';
        }

        if (delinquencyStatus) {
          await tenantDoc.ref.update({
            delinquencyStatus: delinquencyStatus,
            lastLateFeeDate: admin.firestore.FieldValue.serverTimestamp(),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });

          // Set lien eligible date if applicable
          if (daysLate >= rules.lienDays) {
            const lienEligibleDate = new Date(now);
            lienEligibleDate.setDate(lienEligibleDate.getDate() - rules.lienDays);
            await tenantDoc.ref.update({
              lienEligibleDate: admin.firestore.Timestamp.fromDate(lienEligibleDate),
            });
          }
        }

        // Trigger lockout if needed
        if (rules.enableAutoLockout && daysLate >= rules.lockoutDays) {
          // Disable gate access
          const gateAccessSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('gateAccess')
            .where('tenantId', '==', tenantId)
            .where('isActive', '==', true)
            .get();

          const deactivatedAccessIds: string[] = [];
          
          if (dryRun) {
            // In dry-run mode, just count it
            estimatedLockouts++;
            deactivatedAccessIds.push(...gateAccessSnapshot.docs.map(doc => doc.id));
          } else {
            // Actually disable gate access
            for (const accessDoc of gateAccessSnapshot.docs) {
              await accessDoc.ref.update({
                isActive: false,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                notes: `Gate access disabled due to delinquency (${daysLate} days overdue)`,
              });
              deactivatedAccessIds.push(accessDoc.id);
            }

            // Log audit event if lockout was triggered
            if (deactivatedAccessIds.length > 0) {
              await writeAuditLog(facilityId, {
                eventType: 'delinquency.lockoutTriggered',
                actorUid: 'system',
                targetType: 'tenant',
                targetId: tenantId,
                tenantId,
                after: {
                  lockoutStatus: 'locked',
                  daysLate,
                },
                metadata: {
                  automated: true,
                  deactivatedAccessIds,
                },
              });
            }
          }

          lockoutCount++;
        }

        processedCount++;
      } catch (error: any) {
        errorCount++;
        functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
      }
    }

    return {
      success: true,
      processedCount,
      lateFeeAppliedCount,
      noticeSentCount,
      lockoutCount,
      errorCount,
      dryRun,
      ...(dryRun ? {
        preview: {
          tenantsToProcess: processedCount,
          estimatedLateFees,
          estimatedNotices,
          estimatedLockouts,
        },
      } : {}),
    };
  } catch (error: any) {
    return {
      success: false,
      error: error.message,
    };
  }
}

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

/**
 * Process move-out workflow
 * Handles move-out in a transaction-safe way: updates contract, frees unit, calculates charges/refunds
 */
export const processMoveOut = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  await enforceRateLimit({
    facilityId: data?.facilityId,
    key: 'processMoveOut',
    limit: 30,
    windowSeconds: 60,
    userId: context.auth.uid,
  });

  const userId = context.auth.uid; // Store for use in transaction

  const {
    facilityId,
    tenantId,
    contractId,
    unitId,
    moveOutDate,
    moveOutCharges,
    moveOutRefund,
    moveOutNotes,
    processRefund = false,
    refundMethod,
  } = data;

  if (!facilityId || !tenantId || !contractId || !unitId || !moveOutDate) {
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

    // Check if user is owner or has manager role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to process move-outs');
    }

    const moveOutTimestamp = admin.firestore.Timestamp.fromDate(new Date(moveOutDate));
    const now = admin.firestore.FieldValue.serverTimestamp();

    // Use Firestore transaction to ensure consistency
    const result = await admin.firestore().runTransaction(async (transaction) => {
      // 1. Get contract
      const contractRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('contracts')
        .doc(contractId);
      const contractDoc = await transaction.get(contractRef);

      if (!contractDoc.exists) {
        throw new Error('Contract not found');
      }

      // 2. Get unit
      const unitRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('units')
        .doc(unitId);
      const unitDoc = await transaction.get(unitRef);

      if (!unitDoc.exists) {
        throw new Error('Unit not found');
      }

      // 3. Get tenant
      const tenantRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId);
      const tenantDoc = await transaction.get(tenantRef);

      if (!tenantDoc.exists) {
        throw new Error('Tenant not found');
      }

      // 4. Update contract - mark as ended
      transaction.update(contractRef, {
        moveOutStatus: 'completed',
        moveOutDate: moveOutTimestamp,
        moveOutCharges: moveOutCharges || 0,
        moveOutRefund: moveOutRefund || 0,
        moveOutNotes: moveOutNotes || null,
        status: 'cancelled', // Mark contract as cancelled/ended
        isActive: false,
        updatedAt: now,
      });

      // 5. Free the unit
      transaction.update(unitRef, {
        status: 'available',
        tenantId: null,
        tenantName: null,
        moveOutDate: moveOutTimestamp,
        updatedAt: now,
        updatedBy: userId,
      });

      // 6. Update tenant - clear unit assignment
      transaction.update(tenantRef, {
        unitNumber: '',
        isActive: false,
        updatedAt: now,
      });

    // 7. Create ledger entries for move-out charges if any
      if (moveOutCharges && moveOutCharges > 0) {
        const ledgerRef = admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .doc();
        
        transaction.set(ledgerRef, {
          tenantId: tenantId,
          facilityId: facilityId,
          type: 'moveOutFee',
          amount: moveOutCharges,
          description: 'Move-out charges',
          referenceId: contractId,
          entryDate: moveOutTimestamp,
          status: 'posted',
          createdAt: now,
          createdBy: userId,
          metadata: {
            moveOutDate: moveOutDate,
          },
        });
      }

    // 8. Create refund ledger entry if applicable
      if (moveOutRefund && moveOutRefund > 0) {
        const refundLedgerRef = admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('ledgers')
          .doc();
        
        transaction.set(refundLedgerRef, {
          tenantId: tenantId,
          facilityId: facilityId,
          type: 'refund',
          amount: -moveOutRefund, // Negative for refunds
          description: 'Move-out refund',
          referenceId: contractId,
          entryDate: moveOutTimestamp,
          status: 'posted',
          createdAt: now,
          createdBy: userId,
          metadata: {
            moveOutDate: moveOutDate,
            refundMethod: refundMethod || 'manual',
          },
        });
      }

      return {
        success: true,
        contractId,
        unitId,
        tenantId,
      };
    });

    // 9. Process refund via Stripe if requested
    const refundResult = null;
    if (processRefund && moveOutRefund && moveOutRefund > 0 && refundMethod === 'creditCard') {
      try {
        // Note: We can't directly call another Cloud Function, so we'll process it here
        // or the client can call processRefund separately after move-out completes
        functions.logger.info(`Move-out refund should be processed separately: $${moveOutRefund}`, {
          facilityId,
          tenantId,
          amount: moveOutRefund,
          refundMethod: 'creditCard',
          referenceId: data.refundReferenceId,
        });
      } catch (refundError: any) {
        functions.logger.error('Error processing move-out refund:', refundError);
        // Don't fail move-out if refund fails - it can be processed manually
      }
    }

    // 10. Send move-out confirmation email (async, don't wait)
    try {
      const tenantData = (await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .get()).data();

      if (tenantData?.email) {
        initializeSendGrid();
        await sgMail.send({
          to: tenantData.email,
          from: {
            email: SENDGRID_FROM_EMAIL.value(),
            name: SENDGRID_FROM_NAME.value(),
          },
          subject: `Move-Out Confirmation - ${facilityData?.name || 'Storage Facility'}`,
          html: `
            <h2>Move-Out Confirmation</h2>
            <p>Dear ${tenantData.name || 'Tenant'},</p>
            <p>This confirms that your move-out has been processed on ${new Date(moveOutDate).toLocaleDateString()}.</p>
            ${moveOutCharges > 0 ? `<p><strong>Final Charges:</strong> $${moveOutCharges.toFixed(2)}</p>` : ''}
            ${moveOutRefund > 0 ? `<p><strong>Refund Amount:</strong> $${moveOutRefund.toFixed(2)}</p>` : ''}
            ${moveOutNotes ? `<p><strong>Notes:</strong> ${moveOutNotes}</p>` : ''}
            <p>Thank you for your business.</p>
          `,
        });
      }
    } catch (emailError: any) {
      functions.logger.error('Error sending move-out confirmation email:', emailError);
      // Don't fail move-out if email fails
    }

    return {
      ...result,
      success: true,
      refundProcessed: (refundResult as any)?.success || false,
    };
  } catch (error: any) {
    functions.logger.error('Error processing move-out:', error);
    await writeAuditLog(data?.facilityId, {
      action: 'moveout_failed',
      userId: userId,
      tenantId: data?.tenantId,
      error: error?.message || 'unknown',
    });
    throw new functions.https.HttpsError('internal', `Failed to process move-out: ${error.message}`);
  }
});

/**
 * Creates a short-lived public reservation hold for a unit.
 * This reduces obvious double-booking races before move-in completion.
 */
export const createPublicReservationHold = functions.https.onCall(async (data: any, context) => {
  const {
    facilityId,
    unitId,
    unitNumber,
    email,
    phone,
    name,
    moveInDate,
    metadata = {},
    holdMinutes = 10,
  } = data || {};

  if (!facilityId || !unitId || !email) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, unitId, and email are required');
  }

  const now = new Date();
  const boundedMinutes = Math.max(1, Math.min(Number(holdMinutes) || 10, 60));
  const expiresAt = new Date(now.getTime() + boundedMinutes * 60 * 1000);
  const moveInToken = crypto.randomBytes(24).toString('hex');

  const unitRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('units')
    .doc(unitId);

  const holdRef = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('mapEngine')
    .doc('activeHolds')
    .collection('items')
    .doc(unitId);

  const reservationRef = admin.firestore().collection('publicReservations').doc();

  await admin.firestore().runTransaction(async (tx) => {
    const unitSnap = await tx.get(unitRef);
    if (!unitSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Unit not found');
    }
    const unitData = unitSnap.data() as Record<string, any>;
    const unitStatus = String(unitData.status || '').toLowerCase();
    if (unitStatus !== 'available' && unitStatus !== 'reserved') {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
    }

    const holdSnap = await tx.get(holdRef);
    if (holdSnap.exists) {
      const holdData = holdSnap.data() as Record<string, any>;
      const holdExpiresAt = holdData.expiresAt as admin.firestore.Timestamp | undefined;
      if (holdExpiresAt && holdExpiresAt.toDate() > now) {
        throw new functions.https.HttpsError('already-exists', 'Unit is currently in checkout');
      }
    }

    tx.set(reservationRef, {
      facilityId,
      unitId,
      unitNumber: unitNumber || unitData.unitNumber || '',
      email: String(email).trim().toLowerCase(),
      phone: phone ? String(phone).trim() : null,
      name: name ? String(name).trim() : null,
      status: 'pending',
      reservedAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
      moveInDate: moveInDate ? admin.firestore.Timestamp.fromDate(new Date(moveInDate)) : null,
      moveInToken,
      metadata: {
        ...(metadata || {}),
        holdType: 'checkout',
        holdMinutes: boundedMinutes,
        source: (metadata && metadata.source) || 'publicMap',
      },
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.set(holdRef, {
      facilityId,
      unitId,
      reservationId: reservationRef.id,
      status: 'pending',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return {
    success: true,
    reservationId: reservationRef.id,
    moveInToken,
    expiresAt: expiresAt.toISOString(),
  };
});

/**
 * Complete public move-in flow (no auth)
 * - Validates reservation token
 * - Creates tenant and contract
 * - Creates ledger entries for move-in charges
 * - Verifies payment intent (optional) and logs payment
 * - Updates unit status and reservation status
 * - Generates gate access code
 */
export const completePublicMoveIn = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any) => {
  // App Check enforced for public move-in flows
  if (!(data as any)?._appCheckToken) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'App Check token required. Please refresh and try again.',
    );
  }
  const {
    reservationId,
    token,
    name,
    email,
    phone,
    address,
    emergencyContactName,
    emergencyContactPhone,
    paymentIntentId,
    totalAmount,
    lineItems = [],
    skipPayment = false,
  } = data || {};

  if (!reservationId || !token || !name || !email || !phone) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields');
  }

  const reservationRef = admin.firestore().collection('publicReservations').doc(reservationId);
  const reservationSnap = await reservationRef.get();

  if (!reservationSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Reservation not found');
  }

  const reservation = reservationSnap.data() as Record<string, any>;

  if (reservation.moveInToken !== token) {
    throw new functions.https.HttpsError('permission-denied', 'Invalid token');
  }

  if (reservation.status !== 'pending' && reservation.status !== 'confirmed') {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
  }

  const nowTs = admin.firestore.FieldValue.serverTimestamp();
  const expiresAt = reservation.expiresAt as admin.firestore.Timestamp | undefined;
  if (expiresAt && expiresAt.toDate() < new Date()) {
    await reservationRef.update({ status: 'expired', updatedAt: nowTs });
    throw new functions.https.HttpsError('failed-precondition', 'Reservation has expired');
  }

  // Derive core context
  const facilityId = reservation.facilityId as string | undefined;
  const unitId = reservation.unitId as string | undefined;
  const unitNumber = (reservation.unitNumber as string | undefined) || 'Unassigned';
  const reservationMetadata = (reservation.metadata as Record<string, any> | undefined) || {};
  const moveInDate = (reservation.moveInDate as admin.firestore.Timestamp | undefined)?.toDate() || new Date();

  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation missing facilityId');
  }

  // Optional unit validation
  if (unitId) {
    const unitSnap = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('units')
      .doc(unitId)
      .get();

    if (!unitSnap.exists) {
      throw new functions.https.HttpsError('not-found', 'Reserved unit not found');
    }

    const unitData = unitSnap.data() as Record<string, any>;
    if (unitData.status && unitData.status !== 'available' && unitData.status !== 'reserved') {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is no longer available');
    }
  }

  // Verify payment intent if provided
  if (!skipPayment && paymentIntentId && totalAmount && totalAmount > 0) {
    try {
      const stripe = getStripeClient();
      const stripeAccount = reservationMetadata.stripeConnectAccountId as string | undefined;
      const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId, stripeAccount ? {
        stripeAccount,
      } : undefined);

      if (paymentIntent.amount_received < Math.round(totalAmount * 100)) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'Payment not completed or amount mismatch',
        );
      }

      if (paymentIntent.status !== 'succeeded' && paymentIntent.status !== 'requires_capture') {
        throw new functions.https.HttpsError(
          'failed-precondition',
          `Payment intent not successful: ${paymentIntent.status}`,
        );
      }
    } catch (err: any) {
      functions.logger.error('Payment intent validation failed', {
        error: err?.message,
        paymentIntentId,
      });
      throw err instanceof functions.https.HttpsError
        ? err
        : new functions.https.HttpsError('internal', 'Failed to validate payment intent');
    }
  }

  // Helper to derive monthly rate from reservation metadata or line items
  const deriveMonthlyRate = (): number => {
    if (reservationMetadata.monthlyRate) return Number(reservationMetadata.monthlyRate);
    const rentItem = (lineItems as any[]).find(
      (item) => item?.type === 'rent' || item?.type === 'proratedRent',
    );
    if (rentItem?.amount) return Number(rentItem.amount);
    return 0;
  };

  // Perform transactional writes for tenant/contract/unit/reservation/charges
  const transactionResult = await admin.firestore().runTransaction(async (tx) => {
    // Re-check reservation inside transaction
    const freshReservation = await tx.get(reservationRef);
    if (!freshReservation.exists) {
      throw new functions.https.HttpsError('not-found', 'Reservation not found');
    }
    const freshData = freshReservation.data() as Record<string, any>;
    if (freshData.moveInToken !== token) {
      throw new functions.https.HttpsError('permission-denied', 'Invalid token');
    }
    if (freshData.status !== 'pending' && freshData.status !== 'confirmed') {
      throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
    }

    // Create tenant
    const tenantRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc();

    const tenantData = {
      facilityId,
      name: name.trim(),
      nameLower: name.trim().toLowerCase(),
      email: email.trim(),
      emailLower: email.trim().toLowerCase(),
      phone: phone.trim(),
      phoneDigits: phone.replace(/[^\d]/g, ''),
      unitNumber,
      monthlyRate: deriveMonthlyRate(),
      notes: '',
      createdAt: nowTs,
      createdBy: 'publicMoveIn',
      isActive: true,
      isOnDNR: false,
      emergencyContacts: emergencyContactName
        ? [{
            name: emergencyContactName,
            phone: emergencyContactPhone || '',
          }]
        : [],
      addresses: address
        ? [{
            street1: address,
            street2: '',
            city: '',
            state: '',
            postalCode: '',
            country: '',
            type: 'mailing',
          }]
        : [],
      portalEnabled: false,
      portalAccessCode: null,
      portalWelcomeMessage: null,
      portalLastAccessAt: null,
      portalVisitCount: 0,
    };

    tx.set(tenantRef, tenantData);

    // Create contract (minimal signed agreement record)
    const facilitySnap = await tx.get(admin.firestore().collection('facilities').doc(facilityId));
    const facilityOwnerUid = (facilitySnap.data() as Record<string, any> | undefined)?.ownerUid || 'publicMoveIn';

    const contractRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('contracts')
      .doc();

    tx.set(contractRef, {
      facilityId,
      facilityOwnerUid,
      tenantId: tenantRef.id,
      title: 'Storage Rental Agreement',
      description: 'Online self-service move-in',
      type: 'storage',
      status: 'signed',
      templateId: null,
      fileUrl: null,
      signedFileUrl: null,
      createdAt: nowTs,
      updatedAt: nowTs,
      createdBy: 'publicMoveIn',
      sentAt: nowTs,
      signedAt: nowTs,
      expiresAt: null,
      sentBy: 'publicMoveIn',
      signedBy: 'publicMoveIn',
      customFields: null,
      notes: null,
      isActive: true,
    });

    // Ledger entries for charges
    (lineItems as any[]).forEach((item) => {
      const ledgerRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .doc();

      tx.set(ledgerRef, {
        tenantId: tenantRef.id,
        facilityId,
        type: item?.type || 'moveInCharge',
        amount: Number(item?.amount || 0),
        description: item?.description || 'Move-in charge',
        referenceId: contractRef.id,
        entryDate: moveInDate,
        dueDate: item?.dueDate ? new Date(item.dueDate) : null,
        status: 'posted',
        createdAt: nowTs,
        createdBy: 'publicMoveIn',
        metadata: {
          lineItemId: item?.id || null,
          isProrated: item?.isProrated ?? false,
        },
      });
    });

    // Update unit status
    if (unitId) {
      const unitRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('units')
        .doc(unitId);

      tx.update(unitRef, {
        status: 'occupied',
        tenantId: tenantRef.id,
        tenantName: name,
        moveInDate: moveInDate,
        updatedAt: nowTs,
        updatedBy: 'publicMoveIn',
      });
    }

    // Update reservation status
    tx.update(reservationRef, {
      status: 'completed',
      completedAt: nowTs,
      updatedAt: nowTs,
      tenantId: tenantRef.id,
      contractId: contractRef.id,
      completedBy: 'publicMoveIn',
    });

    return {
      tenantId: tenantRef.id,
      contractId: contractRef.id,
    };
  });

  const { tenantId, contractId } = transactionResult;

  // Best-effort cleanup of active checkout hold.
  if (unitId) {
    const holdRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('mapEngine')
      .doc('activeHolds')
      .collection('items')
      .doc(unitId);
    try {
      await holdRef.delete();
    } catch (e) {
      functions.logger.warn('Failed to clear map hold after move-in', { facilityId, unitId });
    }
  }

  // Create payment ledger entry (outside transaction to avoid blocking)
  if (!skipPayment && paymentIntentId && totalAmount && totalAmount > 0) {
    const ledgerRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('ledgers')
      .doc();

    await ledgerRef.set({
      tenantId,
      facilityId,
      type: 'payment',
      amount: -Number(totalAmount),
      description: 'Move-in payment',
      referenceId: paymentIntentId,
      entryDate: new Date(),
      status: 'posted',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'publicMoveIn',
      metadata: {
        paymentIntentId,
      },
    });
  }

  // Create gate access code
  let gateAccessCode: string | null = null;
  try {
    gateAccessCode = generateAccessCode();
    const gateRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('gateAccess')
      .doc();

    await gateRef.set({
      facilityId,
      tenantId,
      tenantName: name,
      accessCode: gateAccessCode,
      isActive: true,
      validFrom: null,
      validUntil: null,
      allowedDays: [],
      allowedStartTime: null,
      allowedEndTime: null,
      notes: 'Auto-generated from public move-in',
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      createdBy: 'publicMoveIn',
    });
  } catch (gateError: any) {
    functions.logger.error('Failed to create gate access', { error: gateError?.message });
  }

  functions.logger.info('Public move-in completed', {
    reservationId,
    facilityId,
    tenantId,
    contractId,
    paymentIntentId,
  });

  return {
    success: true,
    tenantId,
    contractId,
    gateAccessCode,
    reservationId,
  };
});

export const processAutopayPayments = functions.runWith({ secrets: STRIPE_SECRETS }).pubsub
  .schedule('0 2 * * *') // Daily at 2:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    try {
      functions.logger.info('Starting scheduled autopay processing');

      // Get all facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      functions.logger.info(`Found ${facilitiesSnapshot.size} active facilities`);

      const results = [];

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        try {
          // Get all tenants with autopay enabled
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .get();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;

              // Get payment methods for this tenant
              const paymentMethodsSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('paymentMethods')
                .where('tenantId', '==', tenantId)
                .where('autopayEnabled', '==', true)
                .where('isActive', '==', true)
                .get();

              for (const methodDoc of paymentMethodsSnapshot.docs) {
                try {
                  const methodData = methodDoc.data();
                  const autopaySchedule = methodData.autopaySchedule;
                  
                  if (!autopaySchedule) continue;

                  const nextRun = autopaySchedule.autopayNextRun?.toDate();
                  const now = new Date();

                  // Check if autopay is due
                  if (nextRun && now >= nextRun) {
                    // Get ledger balance
                    const ledgerSnapshot = await admin.firestore()
                      .collection('facilities')
                      .doc(facilityId)
                      .collection('ledgers')
                      .where('tenantId', '==', tenantId)
                      .where('status', '==', 'posted')
                      .get();

                    let balance = 0;
                    for (const entryDoc of ledgerSnapshot.docs) {
                      const entryData = entryDoc.data();
                      balance += entryData.amount || 0;
                    }

                    // Calculate amount to charge
                    let amount = balance;
                    if (autopaySchedule.amount && autopaySchedule.amount > 0) {
                      amount = autopaySchedule.amount;
                    }

                    // Add insurance if configured
                    if (autopaySchedule.includeInsurance) {
                      const facilityData = facilityDoc.data();
                      const defaultInsurance = facilityData?.billingSettings?.['defaultInsuranceAmount'];
                      if (defaultInsurance) {
                        amount += defaultInsurance;
                      }
                    }

                    if (amount > 0 && methodData.stripePaymentMethodId) {
                      // Process payment via Stripe
                      const stripe = getStripeClient();
                      
                      const paymentIntent = await stripe.paymentIntents.create({
                        amount: Math.round(amount * 100),
                        currency: 'usd',
                        payment_method: methodData.stripePaymentMethodId,
                        customer: methodData.stripeCustomerId,
                        confirmation_method: 'automatic',
                        confirm: true,
                        description: `Autopay - ${tenantData.name}`,
                        metadata: {
                          facilityId,
                          tenantId,
                          paymentMethodId: methodDoc.id,
                          autopay: 'true',
                        },
                      });

                      if (paymentIntent.status === 'succeeded') {
                        // Create payment ledger entry
                        const paymentEntryRef = admin.firestore()
                          .collection('facilities')
                          .doc(facilityId)
                          .collection('ledgers')
                          .doc();

                        await paymentEntryRef.set({
                          tenantId: tenantId,
                          facilityId: facilityId,
                          type: 'payment',
                          amount: -amount,
                          description: `Autopay Payment - ${paymentIntent.id}`,
                          referenceId: paymentIntent.id,
                          entryDate: admin.firestore.FieldValue.serverTimestamp(),
                          status: 'posted',
                          metadata: {
                            paymentMethod: 'stripe',
                            autopay: true,
                            paymentIntentId: paymentIntent.id,
                          },
                          createdAt: admin.firestore.FieldValue.serverTimestamp(),
                          createdBy: 'system',
                        });

                        // Update payment method last run
                        await methodDoc.ref.update({
                          'autopayLastRun': admin.firestore.FieldValue.serverTimestamp(),
                          'autopayLastResult': 'success',
                          'autopayNextRun': _calculateNextAutopayRun(autopaySchedule),
                        });

                        // Audit log
                        await admin.firestore()
                          .collection('facilities')
                          .doc(facilityId)
                          .collection('auditLogs')
                          .add({
                            action: 'autopay.processed',
                            actorUid: 'system',
                            actorEmail: 'system@scheduled-job',
                            targetId: paymentEntryRef.id,
                            entityType: 'payment',
                            entityId: paymentEntryRef.id,
                            tenantId: tenantId,
                            details: {
                              amount: amount,
                              paymentIntentId: paymentIntent.id,
                              scheduled: true,
                            },
                            at: admin.firestore.FieldValue.serverTimestamp(),
                          });

                        results.push({
                          facilityId,
                          tenantId,
                          success: true,
                          amount,
                        });

                        functions.logger.info(`Autopay processed: ${tenantData.name} - $${amount}`);
                      }
                    }
                  }
                } catch (error: any) {
                  functions.logger.error(`Error processing autopay for payment method ${methodDoc.id}:`, error);
                  // Update payment method with error
                  await methodDoc.ref.update({
                    'autopayLastRun': admin.firestore.FieldValue.serverTimestamp(),
                    'autopayLastResult': 'failed',
                    'autopayLastError': error.message,
                  });
                }
              }
            } catch (error: any) {
              functions.logger.error(`Error processing autopay for tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info(`Scheduled autopay processing completed: ${results.length} payments processed`);
      return { results };
    } catch (error: any) {
      functions.logger.error('Error in scheduled autopay processing:', error);
      throw error;
    }
  });

function _calculateNextAutopayRun(schedule: any): admin.firestore.Timestamp {
  const now = new Date();
  const frequency = schedule.frequency || 'monthly';
  const dayOfMonth = schedule.dayOfMonth || 1;

  if (frequency === 'monthly') {
    const nextMonth = new Date(now.getFullYear(), now.getMonth() + 1, dayOfMonth);
    return admin.firestore.Timestamp.fromDate(nextMonth);
  } else if (frequency === 'weekly') {
    const dayOfWeek = schedule.dayOfWeek || 1;
    const daysUntilNext = (dayOfWeek - now.getDay()) % 7;
    const nextRun = new Date(now);
    nextRun.setDate(nextRun.getDate() + (daysUntilNext === 0 ? 7 : daysUntilNext));
    return admin.firestore.Timestamp.fromDate(nextRun);
  }

  // Default to next month
  return admin.firestore.Timestamp.fromDate(new Date(now.getFullYear(), now.getMonth() + 1, 1));
}

/**
 * Scheduled function: Reset monthly SMS usage counters at UTC month rollover
 * Runs at 00:00 UTC on the 1st of each month
 */
export const resetMonthlySMSUsage = functions.pubsub.schedule('0 0 1 * *').timeZone('UTC').onRun(async (context) => {
  try {
    functions.logger.info('Starting monthly SMS usage reset...');

    const now = new Date();
    const currentMonthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;

    // Reset facility usage
    const facilitiesSnapshot = await admin.firestore().collection('facilities').get();
    const facilityResets = facilitiesSnapshot.docs.map(async (facilityDoc) => {
      const usageRef = facilityDoc.ref.collection('smsUsage').doc(currentMonthKey);
      await usageRef.set({
        smsMonthlyCount: 0,
        smsMonthlyLimit: capSmsLimit(SMS_LIMIT_PER_FACILITY),
        smsMonth: currentMonthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    // Reset account usage
    const accountsSnapshot = await admin.firestore().collection('facilityCreatorAccounts').get();
    const accountResets = accountsSnapshot.docs.map(async (accountDoc) => {
      const usageRef = accountDoc.ref.collection('smsUsage').doc(currentMonthKey);
      await usageRef.set({
        smsMonthlyCount: 0,
        smsMonthlyLimit: capSmsLimit(SMS_LIMIT_PER_ACCOUNT),
        smsMonth: currentMonthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
    });

    await Promise.all([...facilityResets, ...accountResets]);

    functions.logger.info(`Monthly SMS usage reset completed for ${facilitiesSnapshot.size} facilities and ${accountsSnapshot.size} accounts`);
    return null;
  } catch (error: any) {
    functions.logger.error('Error resetting monthly SMS usage', error);
    throw error;
  }
});

/**
 * Scheduled function: Auto-Protect Move-In
 * Runs daily to check new move-ins and auto-enroll tenants in TPP after 14 days if no insurance proof
 * Scheduled to run at 4:00 AM UTC daily
 */
export const autoProtectMoveIn = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 4 * * *') // Daily at 4:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Auto-Protect Move-In processing...');

    try {
      initializeSendGrid();

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalProcessed = 0;
      let totalEnrolled = 0;
      const fourteenDaysAgo = new Date();
      fourteenDaysAgo.setDate(fourteenDaysAgo.getDate() - 14);

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if Auto-Protect Move-In is enabled for this facility
          const autoProtectEnabled = facilityData?.insuranceSettings?.autoProtectMoveIn;
          if (!autoProtectEnabled) {
            functions.logger.info(`Auto-Protect Move-In disabled for facility ${facilityId}`);
            continue;
          }

          // Get default TPP settings
          const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
          const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
          const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;

          // Get all tenants created around 14 days ago (within a 2-day window)
          const startDate = new Date(fourteenDaysAgo);
          startDate.setHours(0, 0, 0, 0);
          const endDate = new Date(fourteenDaysAgo);
          endDate.setDate(endDate.getDate() + 1);
          endDate.setHours(23, 59, 59, 999);

          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .where('createdAt', '>=', admin.firestore.Timestamp.fromDate(startDate))
            .where('createdAt', '<=', admin.firestore.Timestamp.fromDate(endDate))
            .get();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;

              // Check insurance status - only enroll if status is 'none' or 'pendingProof'
              const insuranceStatus = tenantData.insuranceStatus;
              if (insuranceStatus !== 'none' && insuranceStatus !== 'pendingProof') {
                continue; // Tenant already has insurance or is enrolled
              }

              totalProcessed++;

              // Auto-enroll in TPP
              await tenantDoc.ref.update({
                insuranceStatus: 'autoEnrolled',
                tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
                tppCoverageLevel: defaultCoverage,
                coverageAmount: defaultCoverageAmount,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
              });

              // Create ledger entry for TPP fee (prorated for remaining days in month)
              const now = new Date();
              const daysInMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
              const remainingDays = daysInMonth - now.getDate() + 1;
              const proratedFee = (monthlyFee / daysInMonth) * remainingDays;

              await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .add({
                  tenantId: tenantId,
                  facilityId: facilityId,
                  type: 'insuranceCharge',
                  amount: proratedFee,
                  description: `Tenant Protection Plan (Auto-Enrolled) - Prorated for ${remainingDays} days`,
                  entryDate: admin.firestore.FieldValue.serverTimestamp(),
                  status: 'posted',
                  metadata: {
                    tppEnrollment: true,
                    autoEnrolled: true,
                    coverageLevel: defaultCoverage,
                    proratedDays: remainingDays,
                  },
                  createdAt: admin.firestore.FieldValue.serverTimestamp(),
                  createdBy: 'system',
                });

              totalEnrolled++;

              // Send email notification to tenant
              try {
                const emailHtml = `
                  <h2>Tenant Protection Plan Enrollment</h2>
                  <p>Dear ${tenantData.name},</p>
                  <p>You have been automatically enrolled in our Tenant Protection Plan (TPP) as you have not provided proof of your own insurance coverage within the 14-day grace period.</p>
                  <p><strong>Coverage Details:</strong></p>
                  <ul>
                    <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                    <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                    <li>Prorated Fee (this month): $${proratedFee.toFixed(2)}</li>
                  </ul>
                  <p>If you have your own insurance policy, please provide proof to our facility manager to have this enrollment removed.</p>
                  <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                `;

                await sgMail.send({
                  to: tenantData.email,
                  from: {
                    email: SENDGRID_FROM_EMAIL.value(),
                    name: SENDGRID_FROM_NAME.value(),
                  },
                  subject: 'Tenant Protection Plan Enrollment Notification',
                  html: emailHtml,
                });

                functions.logger.info(`Auto-enrollment email sent to ${tenantData.email}`);
              } catch (emailError: any) {
                functions.logger.error(`Error sending auto-enrollment email: ${emailError.message}`);
              }

              functions.logger.info(`Auto-enrolled tenant ${tenantId} in TPP`);
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info('✅ Auto-Protect Move-In complete:', {
        totalProcessed,
        totalEnrolled,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Auto-Protect Move-In:', error);
      throw error;
    }
  });

/**
 * Scheduled function: Auto-Protect Audit
 * Runs monthly to audit existing tenants and notify/enroll them in TPP if no insurance
 * Scheduled to run on the 1st of each month at 5:00 AM UTC
 */
export const autoProtectAudit = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 5 1 * *') // 1st of each month at 5:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Auto-Protect Audit processing...');

    try {
      initializeSendGrid();

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalNotified = 0;
      let totalEnrolled = 0;

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if Auto-Protect Audit is enabled
          const autoProtectAuditEnabled = facilityData?.insuranceSettings?.autoProtectAudit;
          if (!autoProtectAuditEnabled) {
            functions.logger.info(`Auto-Protect Audit disabled for facility ${facilityId}`);
            continue;
          }

          const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
          const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
          const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;
          const gracePeriodDays = facilityData?.insuranceSettings?.auditGracePeriodDays || 45;

          // Get tenants with no insurance or pending proof
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .where('insuranceStatus', 'in', ['none', 'pendingProof'])
            .get();

          const now = new Date();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;
              const insuranceNotifiedDate = tenantData.insuranceNotifiedDate?.toDate();

              if (!insuranceNotifiedDate) {
                // First notification
                await tenantDoc.ref.update({
                  insuranceNotifiedDate: admin.firestore.FieldValue.serverTimestamp(),
                  updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });

                // Send first notification email
                try {
                  const emailHtml = `
                    <h2>Insurance Requirement Notice</h2>
                    <p>Dear ${tenantData.name},</p>
                    <p>Our facility now requires all tenants to have insurance coverage for their stored items. You currently do not have proof of insurance on file.</p>
                    <p>You have ${gracePeriodDays} days to provide proof of your own insurance policy. If proof is not provided by ${new Date(now.getTime() + gracePeriodDays * 24 * 60 * 60 * 1000).toLocaleDateString()}, you will be automatically enrolled in our Tenant Protection Plan.</p>
                    <p>Please contact our facility manager to provide your insurance documentation.</p>
                    <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                  `;

                  await sgMail.send({
                    to: tenantData.email,
                    from: {
                      email: SENDGRID_FROM_EMAIL.value(),
                      name: SENDGRID_FROM_NAME.value(),
                    },
                    subject: 'Insurance Requirement Notice',
                    html: emailHtml,
                  });

                  totalNotified++;
                  functions.logger.info(`First notification sent to ${tenantData.email}`);
                } catch (emailError: any) {
                  functions.logger.error(`Error sending first notification: ${emailError.message}`);
                }
              } else {
                // Check if grace period has passed
                const daysSinceNotification = Math.floor((now.getTime() - insuranceNotifiedDate.getTime()) / (1000 * 60 * 60 * 24));

                if (daysSinceNotification >= gracePeriodDays && tenantData.insuranceStatus !== 'enrolledInTPP' && tenantData.insuranceStatus !== 'autoEnrolled') {
                  // Grace period expired - auto-enroll
                  await tenantDoc.ref.update({
                    insuranceStatus: 'autoEnrolled',
                    tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
                    tppCoverageLevel: defaultCoverage,
                    coverageAmount: defaultCoverageAmount,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                  });

                  // Create ledger entry for TPP fee
                  await admin.firestore()
                    .collection('facilities')
                    .doc(facilityId)
                    .collection('ledgers')
                    .add({
                      tenantId: tenantId,
                      facilityId: facilityId,
                      type: 'insuranceCharge',
                      amount: monthlyFee,
                      description: `Tenant Protection Plan (Auto-Enrolled)`,
                      entryDate: admin.firestore.FieldValue.serverTimestamp(),
                      status: 'posted',
                      metadata: {
                        tppEnrollment: true,
                        autoEnrolled: true,
                        coverageLevel: defaultCoverage,
                      },
                      createdAt: admin.firestore.FieldValue.serverTimestamp(),
                      createdBy: 'system',
                    });

                  totalEnrolled++;

                  // Send enrollment notification
                  try {
                    const emailHtml = `
                      <h2>Tenant Protection Plan Auto-Enrollment</h2>
                      <p>Dear ${tenantData.name},</p>
                      <p>You have been automatically enrolled in our Tenant Protection Plan as proof of insurance was not provided within the ${gracePeriodDays}-day grace period.</p>
                      <p><strong>Coverage Details:</strong></p>
                      <ul>
                        <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                        <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                      </ul>
                      <p>If you have your own insurance policy, please provide proof to have this enrollment removed.</p>
                      <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                    `;

                    await sgMail.send({
                      to: tenantData.email,
                      from: {
                        email: SENDGRID_FROM_EMAIL.value(),
                        name: SENDGRID_FROM_NAME.value(),
                      },
                      subject: 'Tenant Protection Plan Auto-Enrollment',
                      html: emailHtml,
                    });

                    functions.logger.info(`Auto-enrollment email sent to ${tenantData.email}`);
                  } catch (emailError: any) {
                    functions.logger.error(`Error sending auto-enrollment email: ${emailError.message}`);
                  }
                }
              }
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId}:`, error);
        }
      }

      functions.logger.info('✅ Auto-Protect Audit complete:', {
        totalNotified,
        totalEnrolled,
      });

      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Auto-Protect Audit:', error);
      throw error;
    }
  });

/**
 * Scheduled function: Check Insurance Compliance (daily)
 * Runs daily to check if tenants who were notified have passed the grace period
 * Scheduled to run at 4:30 AM UTC daily (after Auto-Protect Move-In)
 */
export const checkInsuranceCompliance = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('30 4 * * *') // Daily at 4:30 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Insurance Compliance check...');

    try {
      initializeSendGrid();

      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        return null;
      }

      let totalEnrolled = 0;
      const now = new Date();

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        const autoProtectAuditEnabled = facilityData?.insuranceSettings?.autoProtectAudit;
        if (!autoProtectAuditEnabled) continue;

        const gracePeriodDays = facilityData?.insuranceSettings?.auditGracePeriodDays || 45;
        const defaultCoverage = facilityData?.insuranceSettings?.defaultCoverageLevel || 'minimum';
        const defaultCoverageAmount = facilityData?.insuranceSettings?.defaultCoverageAmount || 5000;
        const monthlyFee = facilityData?.insuranceSettings?.defaultMonthlyFee || 15;

        const cutoffDate = new Date(now);
        cutoffDate.setDate(cutoffDate.getDate() - gracePeriodDays);

        const tenantsSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('isActive', '==', true)
          .where('insuranceNotifiedDate', '<=', admin.firestore.Timestamp.fromDate(cutoffDate))
          .where('insuranceStatus', 'in', ['none', 'pendingProof'])
          .get();

        for (const tenantDoc of tenantsSnapshot.docs) {
          try {
            const tenantData = tenantDoc.data();
            const tenantId = tenantDoc.id;

            // Auto-enroll
            await tenantDoc.ref.update({
              insuranceStatus: 'autoEnrolled',
              tppEnrollmentDate: admin.firestore.FieldValue.serverTimestamp(),
              tppCoverageLevel: defaultCoverage,
              coverageAmount: defaultCoverageAmount,
              updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            await admin.firestore()
              .collection('facilities')
              .doc(facilityId)
              .collection('ledgers')
              .add({
                tenantId: tenantId,
                facilityId: facilityId,
                type: 'insuranceCharge',
                amount: monthlyFee,
                description: `Tenant Protection Plan (Auto-Enrolled)`,
                entryDate: admin.firestore.FieldValue.serverTimestamp(),
                status: 'posted',
                metadata: {
                  tppEnrollment: true,
                  autoEnrolled: true,
                  coverageLevel: defaultCoverage,
                },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                createdBy: 'system',
              });

            totalEnrolled++;

            // Send enrollment email (same as in autoProtectAudit)
            try {
              const emailHtml = `
                <h2>Tenant Protection Plan Auto-Enrollment</h2>
                <p>Dear ${tenantData.name},</p>
                <p>You have been automatically enrolled in our Tenant Protection Plan as proof of insurance was not provided within the ${gracePeriodDays}-day grace period.</p>
                <p><strong>Coverage Details:</strong></p>
                <ul>
                  <li>Coverage Amount: $${defaultCoverageAmount.toFixed(2)}</li>
                  <li>Monthly Fee: $${monthlyFee.toFixed(2)}</li>
                </ul>
                <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
              `;

              await sgMail.send({
                to: tenantData.email,
                from: {
                  email: SENDGRID_FROM_EMAIL.value(),
                  name: SENDGRID_FROM_NAME.value(),
                },
                subject: 'Tenant Protection Plan Auto-Enrollment',
                html: emailHtml,
              });
            } catch (emailError: any) {
              functions.logger.error(`Error sending enrollment email: ${emailError.message}`);
            }
          } catch (error: any) {
            functions.logger.error(`Error processing tenant ${tenantDoc.id}:`, error);
          }
        }
      }

      functions.logger.info(`✅ Insurance Compliance check complete: ${totalEnrolled} tenants enrolled`);
      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Insurance Compliance check:', error);
      throw error;
    }
  });

/**
 * Callable function: Submit Insurance Claim
 * Allows facility staff to submit an insurance claim for a tenant
 */
export const submitClaim = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(async (data: any, context) => {
  // Verify authentication
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  try {
    const {
      facilityId,
      tenantId,
      leaseId,
      incidentDate,
      claimType,
      claimAmount,
      deductibleAmount,
      description,
      managerStatement,
      tenantStatement,
      documentUrls,
      adjusterEmail,
    } = data;

    // Validate required fields
    if (!facilityId || !tenantId || !incidentDate || !claimType || !description || claimAmount === undefined || deductibleAmount === undefined) {
      throw new functions.https.HttpsError('invalid-argument', 'Missing required fields');
    }

    // Verify user has access to facility
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityData = facilityDoc.data();
    const userEmail = context.auth.token.email || '';
    const userId = context.auth.uid;

    // Check if user is owner or manager
    const isOwner = facilityData?.ownerUid === userId;
    const isManager = facilityData?.managers?.[userId] === true || facilityData?.roles?.[userId] === 'manager' || facilityData?.roles?.[userId] === 'owner';
    
    if (!isOwner && !isManager) {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission to submit claims');
    }

    // Verify tenant is enrolled in TPP
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
    const insuranceStatus = tenantData?.insuranceStatus;
    
    if (insuranceStatus !== 'enrolledInTPP' && insuranceStatus !== 'autoEnrolled') {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant must be enrolled in TPP to file a claim');
    }

    // Create claim document
    const claimRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('claims')
      .doc();

    const claimData = {
      facilityId,
      tenantId,
      leaseId: leaseId || null,
      incidentDate: admin.firestore.Timestamp.fromDate(new Date(incidentDate)),
      claimType,
      status: 'pending',
      claimAmount: Number(claimAmount),
      deductibleAmount: Number(deductibleAmount),
      description,
      managerStatement: managerStatement || null,
      tenantStatement: tenantStatement || null,
      documentUrls: documentUrls || [],
      adjusterEmail: adjusterEmail || null,
      adjusterNotes: null,
      filedDate: admin.firestore.FieldValue.serverTimestamp(),
      resolvedDate: null,
      createdBy: userId,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    await claimRef.set(claimData);

    // Send email to adjuster (if email provided) or log for manual forwarding
    initializeSendGrid();
    const adjusterEmailToUse = adjusterEmail || facilityData?.insuranceSettings?.defaultAdjusterEmail;
    
    if (adjusterEmailToUse) {
      try {
        const emailHtml = `
          <h2>New Insurance Claim Filed</h2>
          <p><strong>Facility:</strong> ${facilityData?.name || facilityId}</p>
          <p><strong>Tenant:</strong> ${tenantData?.name || tenantId}</p>
          <p><strong>Unit:</strong> ${tenantData?.unitNumber || 'N/A'}</p>
          <p><strong>Incident Date:</strong> ${new Date(incidentDate).toLocaleDateString()}</p>
          <p><strong>Claim Type:</strong> ${claimType}</p>
          <p><strong>Claim Amount:</strong> $${Number(claimAmount).toFixed(2)}</p>
          <p><strong>Deductible:</strong> $${Number(deductibleAmount).toFixed(2)}</p>
          <p><strong>Description:</strong></p>
          <p>${description}</p>
          ${managerStatement ? `<p><strong>Manager Statement:</strong></p><p>${managerStatement}</p>` : ''}
          ${tenantStatement ? `<p><strong>Tenant Statement:</strong></p><p>${tenantStatement}</p>` : ''}
          ${documentUrls && documentUrls.length > 0 ? `<p><strong>Documents:</strong></p><ul>${documentUrls.map((url: string) => `<li><a href="${url}">${url}</a></li>`).join('')}</ul>` : ''}
          <p>Claim ID: ${claimRef.id}</p>
        `;

        await sgMail.send({
          to: adjusterEmailToUse,
          from: {
            email: SENDGRID_FROM_EMAIL.value(),
            name: SENDGRID_FROM_NAME.value(),
          },
          subject: `New Insurance Claim - ${facilityData?.name || 'Storage Facility'}`,
          html: emailHtml,
        });

        functions.logger.info(`Claim notification email sent to ${adjusterEmailToUse}`);
      } catch (emailError: any) {
        functions.logger.error(`Error sending claim email: ${emailError.message}`);
        // Don't fail the claim submission if email fails
      }
    }

    // Audit log
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('auditLogs')
      .add({
        action: 'claim.submitted',
        actorUid: userId,
        actorEmail: userEmail,
        targetId: claimRef.id,
        entityType: 'claim',
        entityId: claimRef.id,
        tenantId: tenantId,
        details: {
          claimType,
          claimAmount,
          incidentDate,
        },
        at: admin.firestore.FieldValue.serverTimestamp(),
      });

    return {
      success: true,
      claimId: claimRef.id,
      message: 'Claim submitted successfully',
    };
  } catch (error: any) {
    functions.logger.error('Error submitting claim:', error);
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', `Failed to submit claim: ${error.message}`);
  }
});

/**
 * Scheduled function: Payment Reminders
 * Sends payment reminders to tenants 3 days before their due date
 * Runs daily at 9:00 AM UTC
 */
export const processPaymentReminders = functions.runWith({ secrets: SENDGRID_SECRETS }).pubsub
  .schedule('0 9 * * *') // Daily at 9:00 AM UTC
  .timeZone('UTC')
  .onRun(async (context) => {
    functions.logger.info('🔄 Starting Payment Reminder processing...');

    try {
      initializeSendGrid();

      // Get all active facilities
      const facilitiesSnapshot = await admin.firestore()
        .collection('facilities')
        .where('active', '==', true)
        .get();

      if (facilitiesSnapshot.empty) {
        functions.logger.info('No active facilities found');
        return null;
      }

      let totalRemindersSent = 0;
      const now = new Date();
      const threeDaysFromNow = new Date(now);
      threeDaysFromNow.setDate(threeDaysFromNow.getDate() + 3);

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const facilityData = facilityDoc.data();

        try {
          // Check if payment reminders are enabled (default to true if not set)
          const remindersEnabled = facilityData?.billingSettings?.enablePaymentReminders !== false;

          if (!remindersEnabled) {
            functions.logger.info(`Payment reminders disabled for facility ${facilityId}`);
            continue;
          }

          // Get reminder days setting (default to 3)
          const reminderDays = facilityData?.billingSettings?.paymentReminderDays || 3;

          // Calculate target due date
          const targetDueDate = new Date(now);
          targetDueDate.setDate(targetDueDate.getDate() + reminderDays);

          // Get all active tenants
          const tenantsSnapshot = await admin.firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('tenants')
            .where('isActive', '==', true)
            .get();

          for (const tenantDoc of tenantsSnapshot.docs) {
            try {
              const tenantData = tenantDoc.data();
              const tenantId = tenantDoc.id;

              // Calculate next due date based on paidThrough
              const paidThrough = tenantData.paidThrough?.toDate();
              if (!paidThrough) continue; // Skip if never paid

              // Next due date is first day of month after paidThrough
              let nextDueDate: Date;
              if (paidThrough.getMonth() === 11) {
                nextDueDate = new Date(paidThrough.getFullYear() + 1, 0, 1);
              } else {
                nextDueDate = new Date(paidThrough.getFullYear(), paidThrough.getMonth() + 1, 1);
              }

              // Check if due date matches target (within 1 day window for safety)
              const daysUntilDue = Math.floor((nextDueDate.getTime() - now.getTime()) / (1000 * 60 * 60 * 24));
              
              if (daysUntilDue !== reminderDays) {
                continue; // Not the right day to send reminder
              }

              // Get ledger balance to check if already paid
              const ledgerSnapshot = await admin.firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('ledgers')
                .where('tenantId', '==', tenantId)
                .where('status', '==', 'posted')
                .get();

              let balance = 0;
              for (const entryDoc of ledgerSnapshot.docs) {
                const entryData = entryDoc.data();
                balance += entryData.amount || 0;
              }

              // Skip if already paid (negative or zero balance means paid)
              if (balance <= 0) {
                continue;
              }

              // Check if we already sent a reminder for this due date
              // We'll track this by storing lastReminderSentDate on the tenant
              const lastReminderDate = tenantData.lastPaymentReminderDate?.toDate();
              const shouldSendReminder = !lastReminderDate || 
                lastReminderDate.getTime() < (now.getTime() - (24 * 60 * 60 * 1000)); // At least 24 hours since last reminder

              if (!shouldSendReminder) {
                continue;
              }

              // Get monthly rate for the reminder message
              const monthlyRate = tenantData.monthlyRate || 0;

              // Send email reminder
              try {
                const emailHtml = `
                  <h2>Payment Reminder</h2>
                  <p>Dear ${tenantData.name},</p>
                  <p>This is a friendly reminder that your payment of \$${monthlyRate.toFixed(2)} is due in ${reminderDays} days (${nextDueDate.toLocaleDateString()}).</p>
                  <p><strong>Current Balance:</strong> \$${balance.toFixed(2)}</p>
                  <p>Please ensure payment is received by the due date to avoid late fees.</p>
                  <p>Thank you,<br>${facilityData.name || 'Storage Facility'}</p>
                  ${facilityData.phone ? `<p>Phone: ${facilityData.phone}</p>` : ''}
                `;

                await sgMail.send({
                  to: tenantData.email,
                  from: {
                    email: SENDGRID_FROM_EMAIL.value(),
                    name: SENDGRID_FROM_NAME.value(),
                  },
                  subject: `Payment Reminder - Due ${nextDueDate.toLocaleDateString()}`,
                  html: emailHtml,
                });

                // Update tenant with reminder sent date
                await tenantDoc.ref.update({
                  lastPaymentReminderDate: admin.firestore.FieldValue.serverTimestamp(),
                });

                totalRemindersSent++;
                functions.logger.info(`Payment reminder sent to ${tenantData.email} (tenant: ${tenantId})`);
              } catch (emailError: any) {
                functions.logger.error(`Error sending payment reminder to ${tenantData.email}: ${emailError.message}`);
              }
            } catch (error: any) {
              functions.logger.error(`Error processing tenant ${tenantDoc.id} for reminders:`, error);
            }
          }
        } catch (error: any) {
          functions.logger.error(`Error processing facility ${facilityId} for reminders:`, error);
        }
      }

      functions.logger.info(`✅ Payment Reminder processing complete: ${totalRemindersSent} reminders sent`);
      return null;
    } catch (error: any) {
      functions.logger.error('❌ Fatal error in Payment Reminder processing:', error);
      throw error;
    }
  });

/**
 * Check and increment SMS usage for tenant, facility, and account
 * Returns usage state and whether SMS can be sent
 */
async function checkAndIncrementSMSUsage(
  facilityId: string,
  tenantId?: string,
  accountId?: string,
): Promise<{
  success: boolean;
  canSendSMS: boolean;
  shouldFallbackToEmail: boolean;
  state: SMSUsageState;
  message?: string;
  warning?: string;
  usage?: {
    tenant?: { count: number; limit: number };
    facility: { count: number; limit: number };
    account?: { count: number; limit: number };
  };
}> {
  const now = new Date();
  const monthKey = `${now.getFullYear()}-${(now.getMonth() + 1).toString().padStart(2, '0')}`;
  
  // Get facility to find account ID if not provided
  if (!accountId) {
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (facilityDoc.exists) {
      accountId = facilityDoc.data()?.facilityCreatorAccountId;
    }
  }

  return admin.firestore().runTransaction(async (transaction) => {
    // Check tenant usage (if tenantId provided)
    let tenantUsage = { count: 0, limit: SMS_LIMIT_PER_TENANT };
    if (tenantId) {
      const tenantUsageRef = admin.firestore()
        .collection('tenants')
        .doc(tenantId)
        .collection('smsUsage')
        .doc(monthKey);
      
      const tenantUsageDoc = await transaction.get(tenantUsageRef);
      const tenantData = tenantUsageDoc.exists ? tenantUsageDoc.data() : {
        smsMonthlyCount: 0,
        smsMonth: monthKey,
      };
      
      tenantUsage = {
        count: (tenantData?.smsMonthlyCount || 0) + 1,
        limit: SMS_LIMIT_PER_TENANT,
      };
    }

    // Check facility usage
    const facilityUsageRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsUsage')
      .doc(monthKey);
    
    const facilityUsageDoc = await transaction.get(facilityUsageRef);
    const facilityData = facilityUsageDoc.exists ? facilityUsageDoc.data() : {
      smsMonthlyCount: 0,
      smsMonthlyLimit: SMS_LIMIT_PER_FACILITY,
      smsMonth: monthKey,
      lastReset: admin.firestore.FieldValue.serverTimestamp(),
    };
    
    const facilityUsage = {
      count: (facilityData?.smsMonthlyCount || 0) + 1,
      limit: facilityData?.smsMonthlyLimit || SMS_LIMIT_PER_FACILITY,
    };

    // Check account usage (if accountId provided)
    let accountUsage = { count: 0, limit: SMS_LIMIT_PER_ACCOUNT };
    if (accountId) {
      const accountUsageRef = admin.firestore()
        .collection('facilityCreatorAccounts')
        .doc(accountId)
        .collection('smsUsage')
        .doc(monthKey);
      
      const accountUsageDoc = await transaction.get(accountUsageRef);
      const accountData = accountUsageDoc.exists ? accountUsageDoc.data() : {
        smsMonthlyCount: 0,
        smsMonthlyLimit: SMS_LIMIT_PER_ACCOUNT,
        smsMonth: monthKey,
        lastReset: admin.firestore.FieldValue.serverTimestamp(),
      };
      
      accountUsage = {
        count: (accountData?.smsMonthlyCount || 0) + 1,
        limit: accountData?.smsMonthlyLimit || SMS_LIMIT_PER_ACCOUNT,
      };
    }

    // Determine usage state based on account limit (most restrictive)
    const accountPercentage = accountId ? (accountUsage.count / accountUsage.limit) * 100 : 0;
    const facilityPercentage = (facilityUsage.count / facilityUsage.limit) * 100;
    const tenantPercentage = tenantId ? (tenantUsage.count / tenantUsage.limit) * 100 : 0;

    let state: SMSUsageState = SMSUsageState.NORMAL;
    let canSendSMS = true;
    let shouldFallbackToEmail = false;

    // Check if any limit is exceeded
    const tenantExceeded = tenantId && tenantUsage.count > tenantUsage.limit;
    const facilityExceeded = facilityUsage.count > facilityUsage.limit;
    const accountExceeded = accountId && accountUsage.count > accountUsage.limit;
    const extremeUsage = accountId && accountUsage.count >= (accountUsage.limit * SMS_EXTREME_MULTIPLIER);

    if (extremeUsage) {
      state = SMSUsageState.EXTREME;
      canSendSMS = false; // Prevent all SMS scheduling
      shouldFallbackToEmail = true;
    } else if (tenantExceeded || facilityExceeded || accountExceeded) {
      state = SMSUsageState.EXCEEDED;
      canSendSMS = false; // Block automated SMS, but allow manual with confirmation
      shouldFallbackToEmail = true;
    } else if (accountPercentage >= 80 || facilityPercentage >= 80 || tenantPercentage >= 80) {
      state = SMSUsageState.APPROACHING;
      canSendSMS = true;
      shouldFallbackToEmail = false;
    }

    // Update usage counts if within limits or if we're tracking for reporting
    if (state !== SMSUsageState.EXTREME) {
      if (tenantId && !tenantExceeded) {
        const tenantUsageRef = admin.firestore()
          .collection('tenants')
          .doc(tenantId)
          .collection('smsUsage')
          .doc(monthKey);
        transaction.set(tenantUsageRef, {
          smsMonthlyCount: tenantUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      if (!facilityExceeded) {
        transaction.set(facilityUsageRef, {
          ...facilityData,
          smsMonthlyCount: facilityUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }

      if (accountId && !accountExceeded) {
        const accountUsageRef = admin.firestore()
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection('smsUsage')
          .doc(monthKey);
        // Get existing account data (already fetched earlier in the function)
        const existingAccountDoc = await transaction.get(accountUsageRef);
        const existingAccountData = existingAccountDoc.exists ? existingAccountDoc.data() : {
          smsMonthlyLimit: SMS_LIMIT_PER_ACCOUNT,
          smsMonth: monthKey,
          lastReset: admin.firestore.FieldValue.serverTimestamp(),
        };
        transaction.set(accountUsageRef, {
          ...existingAccountData,
          smsMonthlyCount: accountUsage.count,
          smsMonth: monthKey,
          lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
      }
    }

    // Generate warning message
    let warning: string | undefined;
    if (state === SMSUsageState.APPROACHING) {
      const maxPercentage = Math.max(accountPercentage, facilityPercentage, tenantPercentage);
      warning = `You are approaching the monthly SMS fair-use threshold (${Math.round(maxPercentage)}%). Additional messages may be converted to email.`;
    } else if (state === SMSUsageState.EXCEEDED) {
      warning = `SMS fair-use limit exceeded. Messages will be sent via email instead.`;
    } else if (state === SMSUsageState.EXTREME) {
      warning = `SMS usage is extremely high (${Math.round(accountPercentage)}% of limit). SMS scheduling is disabled. Please contact support if you need to increase your limit.`;
    }

    return {
      success: true,
      canSendSMS: canSendSMS && !tenantExceeded && !facilityExceeded && !accountExceeded,
      shouldFallbackToEmail: shouldFallbackToEmail,
      state,
      warning,
      usage: {
        tenant: tenantId ? tenantUsage : undefined,
        facility: facilityUsage,
        account: accountId ? accountUsage : undefined,
      },
    };
  });
}

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
      return_url: returnUrl || 'https://storagefacilitycreator.com/subscription/manage',
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
        trial_period_days: 30,
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
 * Reads /appConfig/featureFlags and returns a specific flag state.
 * Defaults to false when missing to keep production safe.
 */
async function isFeatureFlagEnabled(flagKey: string): Promise<boolean> {
  try {
    const doc = await admin.firestore().collection('appConfig').doc('featureFlags').get();
    if (!doc.exists) return false;
    const data = doc.data() || {};
    const flagValue = data[flagKey] as Record<string, any> | undefined;
    return flagValue?.enabled === true;
  } catch (error: any) {
    functions.logger.error('Error reading feature flag, defaulting OFF', { flagKey, error: error?.message });
    return false;
  }
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
// SMS COMPLIANCE FEATURE FLAGS
// ============================================

interface SMSComplianceConfig {
  enhancedOptOutEnabled: boolean;
  quietHoursEnabled: boolean;
  rateLimitingEnabled: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_SMS_COMPLIANCE_CONFIG: SMSComplianceConfig = {
  enhancedOptOutEnabled: false,
  quietHoursEnabled: false,
  rateLimitingEnabled: false,
  allowlistFacilityIds: [],
  killSwitch: false,
};

/**
 * Get SMS compliance feature flags/config from Firestore
 * Returns default config if document doesn't exist (all features OFF)
 */
async function getSMSComplianceConfig(): Promise<SMSComplianceConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('smsCompliance')
      .get();

    if (!configDoc.exists) {
      // Return defaults (all OFF) - preserves production behavior
      return DEFAULT_SMS_COMPLIANCE_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      enhancedOptOutEnabled: data.enhancedOptOutEnabled ?? false,
      quietHoursEnabled: data.quietHoursEnabled ?? false,
      rateLimitingEnabled: data.rateLimitingEnabled ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting SMS compliance config, using defaults:', error);
    return DEFAULT_SMS_COMPLIANCE_CONFIG;
  }
}

/**
 * Check if SMS compliance feature is enabled for a specific facility
 * Feature is enabled if:
 *   - killSwitch is false (emergency brake)
 *   - AND (global flag is true OR facilityId is in allowlist)
 */
async function isSMSComplianceFeatureEnabled(
  feature: 'enhancedOptOut' | 'quietHours' | 'rateLimiting',
  facilityId?: string,
): Promise<boolean> {
  const config = await getSMSComplianceConfig();

  // Emergency kill switch - disables ALL SMS compliance features
  if (config.killSwitch) {
    return false;
  }

  // Check if facility is in allowlist
  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;

  // Determine which global flag to check
  let globalFlag = false;
  switch (feature) {
    case 'enhancedOptOut':
      globalFlag = config.enhancedOptOutEnabled;
      break;
    case 'quietHours':
      globalFlag = config.quietHoursEnabled;
      break;
    case 'rateLimiting':
      globalFlag = config.rateLimitingEnabled;
      break;
  }

  // Feature enabled if global flag is true OR facility is in allowlist
  return globalFlag || inAllowlist;
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

// ============================================
// CSV EXPORT FEATURE FLAGS
// ============================================

interface CSVExportConfig {
  enabled: boolean;
  maxRecordsPerExport: number;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
}

const DEFAULT_CSV_EXPORT_CONFIG: CSVExportConfig = {
  enabled: false,
  maxRecordsPerExport: 50000,
  allowlistFacilityIds: [],
  killSwitch: false,
};

/**
 * Get CSV export feature flags/config from Firestore
 * Returns default config if document doesn't exist (all features OFF)
 */
async function getCSVExportConfig(): Promise<CSVExportConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('csvExport')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_CSV_EXPORT_CONFIG;
    }

    const data = configDoc.data() || {};
    return {
      enabled: data.enabled ?? false,
      maxRecordsPerExport: data.maxRecordsPerExport ?? 50000,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
    };
  } catch (error: any) {
    functions.logger.error('Error getting CSV export config, using defaults:', error);
    return DEFAULT_CSV_EXPORT_CONFIG;
  }
}

/**
 * Check if CSV export is enabled for a specific facility
 */
async function isCSVExportEnabled(facilityId?: string): Promise<boolean> {
  const config = await getCSVExportConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;
  return config.enabled || inAllowlist;
}

// ============================================
// CSV EXPORT FUNCTIONS
// ============================================

/**
 * Process export job (for large datasets)
 * Generates CSV and stores in Firebase Storage
 */
export const processExportJob = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, jobId, type, filters } = data;

  if (!facilityId || !jobId || !type) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, jobId, and type are required');
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

    // Update job status to processing
    const jobRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('exportJobs')
      .doc(jobId);

    await jobRef.update({
      status: 'processing',
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Generate CSV based on type
    let csvContent = '';
    let recordCount = 0;

    if (type === 'tenants') {
      const result = await _exportTenantsToCSV(facilityId, filters);
      csvContent = result.csv;
      recordCount = result.count;
    } else if (type === 'payments') {
      const result = await _exportPaymentsToCSV(facilityId, filters);
      csvContent = result.csv;
      recordCount = result.count;
    } else if (type === 'auditLogs') {
      const result = await _exportAuditLogsToCSV(facilityId, filters);
      csvContent = result.csv;
      recordCount = result.count;
    } else {
      throw new functions.https.HttpsError('invalid-argument', `Unsupported export type: ${type}`);
    }

    // Upload CSV to Firebase Storage
    const bucket = admin.storage().bucket();
    const fileName = `exports/${facilityId}/${jobId}_${Date.now()}.csv`;
    const file = bucket.file(fileName);

    await file.save(csvContent, {
      metadata: {
        contentType: 'text/csv',
        metadata: {
          facilityId,
          jobId,
          type,
          createdBy: context.auth.uid,
        },
      },
    });

    // Make file publicly readable (or use signed URL)
    await file.makePublic();

    const downloadUrl = `https://storage.googleapis.com/${bucket.name}/${fileName}`;

    // Update job with results
    await jobRef.update({
      status: 'completed',
      downloadUrl,
      recordCount,
      completedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {
      success: true,
      jobId,
      downloadUrl,
      recordCount,
    };
  } catch (error: any) {
    // Update job with error
    try {
      const jobRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('exportJobs')
        .doc(jobId);

      await jobRef.update({
        status: 'failed',
        errorMessage: error.message,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (updateError: any) {
      functions.logger.error('Error updating export job with error:', updateError);
    }

    functions.logger.error('Error processing export job:', error);
    throw new functions.https.HttpsError('internal', `Failed to process export: ${error.message}`);
  }
});

/**
 * Export tenants to CSV
 */
async function _exportTenantsToCSV(
  facilityId: string,
  filters?: Record<string, any>,
): Promise<{ csv: string; count: number }> {
  let query: admin.firestore.Query = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants');

  if (filters?.isActive !== undefined) {
    query = query.where('isActive', '==', filters.isActive);
  }

  if (filters?.startDate) {
    query = query.where('createdAt', '>=', admin.firestore.Timestamp.fromDate(new Date(filters.startDate)));
  }

  if (filters?.endDate) {
    query = query.where('createdAt', '<=', admin.firestore.Timestamp.fromDate(new Date(filters.endDate)));
  }

  const snapshot = await query.limit(50000).get(); // Limit to 50k records

  const csvRows: string[] = [];
  csvRows.push('ID,Name,Email,Phone,Unit Number,Monthly Rate,Status,Created At,Notes');

  for (const doc of snapshot.docs) {
    const data = doc.data();
    csvRows.push([
      doc.id,
      _escapeCsvField(data.name || ''),
      _escapeCsvField(data.email || ''),
      _escapeCsvField(data.phone || ''),
      _escapeCsvField(data.unitNumber || ''),
      (data.monthlyRate || 0).toString(),
      (data.isActive === true) ? 'Active' : 'Inactive',
      data.createdAt ? (data.createdAt as admin.firestore.Timestamp).toDate().toISOString() : '',
      _escapeCsvField(data.notes || ''),
    ].join(','));
  }

  return {
    csv: csvRows.join('\n'),
    count: snapshot.size,
  };
}

/**
 * Export payments to CSV
 */
async function _exportPaymentsToCSV(
  facilityId: string,
  filters?: Record<string, any>,
): Promise<{ csv: string; count: number }> {
  let query: admin.firestore.Query = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('payments')
    .where('isActive', '==', true);

  if (filters?.status) {
    query = query.where('status', '==', filters.status);
  }

  if (filters?.startDate) {
    query = query.where('createdAt', '>=', admin.firestore.Timestamp.fromDate(new Date(filters.startDate)));
  }

  if (filters?.endDate) {
    query = query.where('createdAt', '<=', admin.firestore.Timestamp.fromDate(new Date(filters.endDate)));
  }

  const snapshot = await query.limit(50000).get();

  const csvRows: string[] = [];
  csvRows.push('ID,Tenant ID,Amount,Status,Method,Due Date,Paid Date,Transaction ID,Created At');

  for (const doc of snapshot.docs) {
    const data = doc.data();
    csvRows.push([
      doc.id,
      _escapeCsvField(data.tenantId || ''),
      (data.amount || 0).toString(),
      _escapeCsvField(data.status || ''),
      _escapeCsvField(data.method || ''),
      data.dueDate ? (data.dueDate as admin.firestore.Timestamp).toDate().toISOString() : '',
      (data.paidDate || data.paidAt) ? ((data.paidDate || data.paidAt) as admin.firestore.Timestamp).toDate().toISOString() : '',
      _escapeCsvField(data.transactionId || data.externalPaymentId || ''),
      data.createdAt ? (data.createdAt as admin.firestore.Timestamp).toDate().toISOString() : '',
    ].join(','));
  }

  return {
    csv: csvRows.join('\n'),
    count: snapshot.size,
  };
}

/**
 * Export audit logs to CSV
 */
async function _exportAuditLogsToCSV(
  facilityId: string,
  filters?: Record<string, any>,
): Promise<{ csv: string; count: number }> {
  let query: admin.firestore.Query = admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('auditLogs')
    .orderBy('timestamp', 'desc');

  if (filters?.eventType) {
    query = query.where('eventType', '==', filters.eventType);
  }

  if (filters?.startDate) {
    query = query.where('timestamp', '>=', admin.firestore.Timestamp.fromDate(new Date(filters.startDate)));
  }

  if (filters?.endDate) {
    query = query.where('timestamp', '<=', admin.firestore.Timestamp.fromDate(new Date(filters.endDate)));
  }

  const snapshot = await query.limit(50000).get();

  const csvRows: string[] = [];
  csvRows.push('ID,Event Type,Actor Email,Actor Role,Target Type,Target ID,Tenant ID,Timestamp,Metadata');

  for (const doc of snapshot.docs) {
    const data = doc.data();
    const metadata = data.metadata || {};
    csvRows.push([
      doc.id,
      _escapeCsvField(data.eventType || ''),
      _escapeCsvField(data.actorEmail || ''),
      _escapeCsvField(data.actorRole || ''),
      _escapeCsvField(data.targetType || ''),
      _escapeCsvField(data.targetId || ''),
      _escapeCsvField(data.tenantId || ''),
      data.timestamp ? (data.timestamp as admin.firestore.Timestamp).toDate().toISOString() : '',
      _escapeCsvField(JSON.stringify(metadata)),
    ].join(','));
  }

  return {
    csv: csvRows.join('\n'),
    count: snapshot.size,
  };
}

/**
 * Escape CSV field
 */
function _escapeCsvField(field: string): string {
  if (field.includes(',') || field.includes('"') || field.includes('\n')) {
    return `"${field.replace(/"/g, '""')}"`;
  }
  return field;
}

// ============================================
// AI ASSISTANT FEATURE FLAGS
// ============================================

interface AIAssistantConfig {
  enabled: boolean;
  allowlistFacilityIds: string[];
  killSwitch: boolean;
  provider?: string; // 'openai', 'anthropic', etc. (to be configured later)
  maxTokensPerRequest?: number; // Max tokens per request (default: 1000)
  maxMessagesPerDay?: number; // Max messages per facility per day (default: 100)
  maxMessagesPerUser?: number; // Max messages per user per day (default: 50)
  maxConversationHistory?: number; // Max messages in conversation history (default: 10)
  maxMessageLength?: number; // Max user message length in characters (default: 2000)
}

const DEFAULT_AI_ASSISTANT_CONFIG: AIAssistantConfig = {
  enabled: false,
  allowlistFacilityIds: [],
  killSwitch: false,
  maxTokensPerRequest: 1000,
  maxMessagesPerDay: 30,  // Per facility (hard limit)
  maxMessagesPerUser: 20, // Per user per day (hard limit)
  maxConversationHistory: 10,
  maxMessageLength: 2000, // Characters
};

/**
 * Get AI assistant config from Firestore
 */
async function getAIAssistantConfig(): Promise<AIAssistantConfig> {
  try {
    const configDoc = await admin.firestore()
      .collection('appConfig')
      .doc('aiAssistant')
      .get();

    if (!configDoc.exists) {
      return DEFAULT_AI_ASSISTANT_CONFIG;
    }

    const data = configDoc.data() || {};
    const config = {
      enabled: data.enabled ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
      provider: data.provider as string | undefined,
      maxTokensPerRequest: data.maxTokensPerRequest ?? DEFAULT_AI_ASSISTANT_CONFIG.maxTokensPerRequest,
      maxMessagesPerDay: data.maxMessagesPerDay ?? DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerDay,
      maxMessagesPerUser: data.maxMessagesPerUser ?? DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerUser,
      maxConversationHistory: data.maxConversationHistory ?? DEFAULT_AI_ASSISTANT_CONFIG.maxConversationHistory,
      maxMessageLength: data.maxMessageLength ?? DEFAULT_AI_ASSISTANT_CONFIG.maxMessageLength,
    };
    
    // Log what we read from Firestore for debugging
    functions.logger.info('getAIAssistantConfig read from Firestore', {
      docExists: configDoc.exists,
      rawData: data,
      parsedConfig: config,
    });
    
    return config;
  } catch (error: any) {
    functions.logger.error('Error getting AI assistant config, using defaults:', error);
    return DEFAULT_AI_ASSISTANT_CONFIG;
  }
}

/**
 * Check if AI assistant is enabled for a facility
 */
async function isAIAssistantEnabled(facilityId?: string): Promise<boolean> {
  const config = await getAIAssistantConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;
  return config.enabled || inAllowlist;
}

/**
 * Check if OpenAI chat (aiAssistantChat) should be used for a facility.
 * Requires: enabled && !killSwitch && provider === 'openai' &&
 * (allowlist empty OR facilityId in allowlist).
 */
function shouldUseOpenAIChat(facilityId: string, config: AIAssistantConfig): { ok: boolean; allowlistPassed: boolean } {
  // Debug logging
  const providerCheck = config.provider === 'openai';
  const enabledCheck = config.enabled;
  const killSwitchCheck = !config.killSwitch;
  
  if (config.killSwitch || !config.enabled || !providerCheck) {
    functions.logger.warn('shouldUseOpenAIChat failed', {
      facilityId,
      killSwitch: config.killSwitch,
      enabled: config.enabled,
      provider: config.provider,
      providerMatches: providerCheck,
      killSwitchPassed: killSwitchCheck,
      enabledPassed: enabledCheck,
    });
    return { ok: false, allowlistPassed: false };
  }
  const allowlist = config.allowlistFacilityIds || [];
  const allowlistPassed = allowlist.length === 0 || allowlist.includes(facilityId);
  return { ok: allowlistPassed, allowlistPassed };
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
    roles[uid] === 'admin' ||
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

/**
 * Enforce per-user rate limit (e.g. 10 requests per user per minute).
 * Uses users/{uid}/rateLimits/{key}_{windowStart}.
 */
async function enforceUserRateLimit(
  userId: string,
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  const windowStart = Math.floor(now / windowSeconds) * windowSeconds;
  const docId = `${key}_${windowStart}`;
  const ref = admin
    .firestore()
    .collection('users')
    .doc(userId)
    .collection('rateLimits')
    .doc(docId);

  await admin.firestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? (snap.data()?.count as number) || 0 : 0;
    if (current >= limit) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Rate limit exceeded. Maximum ${limit} requests per minute. Try again shortly.`,
      );
    }
    tx.set(
      ref,
      {
        count: current + 1,
        windowStart: new Date(windowStart * 1000),
        windowSeconds,
        key,
        userId,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

function hashUserId(userId: string): string {
  return crypto.createHash('sha256').update(userId, 'utf8').digest('hex').slice(0, 16);
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
export const createStripeConnectAccount = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
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

    // Get Client ID (available for future use or Express Connect migration)
    const clientId = process.env.STRIPE_CONNECT_CLIENT_ID;
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

    const baseUrl = 'https://storagefacilitycreator.com';
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
 * Get Stripe Connect status for a facility (state machine).
 * Returns: state, connectedAccountId, chargesEnabled, payoutsEnabled, detailsSubmitted, requirements, and persisted stripeStatus.
 * Callable by any authenticated user with facility access (owner/manager for settings; staff/tenant for payment UI gating).
 */
/** Verify user has access to facility: owner, manager, or tenant (occupant) */
async function canAccessFacility(uid: string, facilityId: string): Promise<boolean> {
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) return false;
  const d = facilityDoc.data()!;
  if (d.ownerUid === uid) return true;
  const roles = (d.roles || {}) as Record<string, string>;
  if (roles[uid] === 'manager' || roles[uid] === 'owner') return true;
  const tenantsSnap = await admin.firestore().collection('facilities').doc(facilityId).collection('tenants').get();
  for (const t of tenantsSnap.docs) {
    const occupants = (t.data().occupants || []) as Array<{ userId?: string }>;
    if (occupants.some((o) => o.userId === uid)) return true;
  }
  return false;
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
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const hasAccess = await canAccessFacility(context.auth!.uid, facilityId);
    if (!hasAccess) {
      throw new functions.https.HttpsError('permission-denied', 'Access denied');
    }

    const facilityData = facilityDoc.data()!;
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
 * Returns the current status of the connected account
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
    functions.logger.error('Error getting Stripe Connect account status', error);
    throw new functions.https.HttpsError('internal', `Failed to get status: ${error.message}`);
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
      success_url: 'https://storagefacilitycreator.com/payment/success?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: 'https://storagefacilitycreator.com/payment/cancel',
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

  if (!facilityId || !tenantId || !paymentMethodId || !amount) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required parameters');
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
    const roles = facilityData?.roles || {};
    const connectAccountId = facilityData?.stripeConnectAccountId as string | undefined;

    if (!connectAccountId) {
      throw new functions.https.HttpsError('failed-precondition', 'Facility must have a connected Stripe account');
    }

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

    // Get customer ID on connected account
    const customerId = tenantData?.stripeConnectedCustomerId as string | undefined;
    if (!customerId) {
      throw new functions.https.HttpsError('failed-precondition', 'Tenant does not have a Stripe customer on connected account');
    }

    // Create PaymentIntent on CONNECTED account (off-session)
    const paymentIntent = await stripe.paymentIntents.create({
      amount: Math.round(amount * 100), // Convert to cents
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

    const amountCents = Math.round(amount * 100);
    const now = admin.firestore.FieldValue.serverTimestamp();

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
    const facilityPaymentDoc = await facilityPaymentsRef.add({
      tenantId,
      facilityId,
      contractId: '',
      amount: amount,
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
      amount: -(amount),
      description: `Payment via Stripe - ${paymentIntent.id}`,
      referenceId: facilityPaymentDoc.id,
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
      amount: amount,
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

    functions.logger.info(`Off-session charge created on connected account: ${paymentIntent.id} for tenant ${tenantId}`);

    return {
      success: true,
      paymentIntentId: paymentIntent.id,
      status: paymentIntent.status,
      amount: amount,
    };
  } catch (error: any) {
    const safeError = error?.message || 'Failed to charge tenant';
    functions.logger.error('Error charging tenant off-session on connected account:', {
      facilityId,
      tenantId,
      error: safeError,
    });
    
    // Map Stripe error codes to user-friendly messages
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
 * Create a payment checkout session for public payment links
 * No authentication required - uses token-based validation
 */
export const createPublicPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  // Note: No auth check - public access via token
  const { token } = data;

  if (!token) {
    throw new functions.https.HttpsError('invalid-argument', 'token is required');
  }

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
export const lookupUserByEmail = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }
  
  const { email } = data;
  if (!email) {
    throw new functions.https.HttpsError('invalid-argument', 'Email is required');
  }
  
  try {
    const emailLower = email.toLowerCase().trim();
    
    // Find user by emailLower field
    const usersSnapshot = await admin.firestore()
      .collection('users')
      .where('emailLower', '==', emailLower)
      .limit(1)
      .get();
    
    if (usersSnapshot.empty) {
      // Fallback to email field (case-insensitive)
      const fallbackSnapshot = await admin.firestore()
        .collection('users')
        .where('email', '==', emailLower)
        .limit(1)
        .get();
      
      if (fallbackSnapshot.empty) {
        return { found: false };
      }
      
      const userData = fallbackSnapshot.docs[0].data();
      return {
        found: true,
        uid: fallbackSnapshot.docs[0].id,
        email: userData.email || emailLower,
        name: userData.name || null,
      };
    }
    
    const userData = usersSnapshot.docs[0].data();
    
    // Return minimal data for invites (email, name, uid)
    return {
      found: true,
      uid: usersSnapshot.docs[0].id,
      email: userData.email || emailLower,
      name: userData.name || null,
    };
  } catch (error: any) {
    functions.logger.error('Error looking up user by email', { error: error.message, email });
    throw new functions.https.HttpsError('internal', 'Failed to lookup user');
  }
});

// Export migration functions (Phase 2)
import { runAllMigrations } from './migrations/phase2_migrations';
import { backfillContractCompliance } from './migrations/backfill_contract_compliance';

// Cloud Function to run migrations (for manual execution)
export const runPhase2Migrations = functions.https.onCall(async (data: any, context) => {
  // Only allow super admins to run migrations
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const userEmail = context.auth.token.email;
  const superAdminEmails = [
    'russell_forsyth_1992@outlook.com',
    'russellforsyth09091992@gmail.com',
  ];

  if (!superAdminEmails.includes(userEmail?.toLowerCase() || '')) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can run migrations');
  }

  try {
    await runAllMigrations();
    return { success: true, message: 'All migrations completed' };
  } catch (error: any) {
    functions.logger.error('Migration error:', error);
    throw new functions.https.HttpsError('internal', `Migration failed: ${error.message}`);
  }
});

// Cloud Function to backfill contract compliance fields
export const backfillContractComplianceFields = functions.https.onCall(async (data: any, context) => {
  // Only allow super admins to run migrations
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const userEmail = context.auth.token.email;
  const superAdminEmails = [
    'russell_forsyth_1992@outlook.com',
    'russellforsyth09091992@gmail.com',
  ];

  if (!superAdminEmails.includes(userEmail?.toLowerCase() || '')) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can run migrations');
  }

  try {
    const result = await backfillContractCompliance();
    functions.logger.info('Contract compliance backfill completed', result);
    return {
      success: true,
      message: 'Contract compliance backfill completed',
      ...result,
    };
  } catch (error: any) {
    functions.logger.error('Migration error:', error);
    throw new functions.https.HttpsError('internal', `Migration failed: ${error.message}`);
  }
});

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

/**
 * Phase 12: Two-Way SMS Messaging
 * Handle incoming SMS messages from tenants via Twilio webhook
 */
export const handleIncomingSMS = functions.runWith({
  secrets: [TWILIO_AUTH_TOKEN],
}).https.onRequest(async (req, res) => {
  // Set CORS headers for Twilio
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.status(200).send('');
    return;
  }

  // Only accept POST requests
  if (req.method !== 'POST') {
    res.status(405).send('Method Not Allowed');
    return;
  }

  try {
    // Note: Twilio signature verification requires twilio package or manual crypto implementation
    // For now, we'll rely on the webhook URL being secret and Firebase security rules
    // TODO: Implement proper Twilio signature verification when twilio package is added
    
    // Extract phone number and message from Twilio webhook
    const from = req.body.From as string;
    const to = req.body.To as string;
    const body = (req.body.Body as string || '').trim();
    const messageSid = req.body.MessageSid as string;
    const requestId = crypto.randomUUID();
    const inboundFacilityId = await findFacilityIdByInboundNumber(to);
    functions.logger.info('Incoming SMS webhook', {
      requestId,
      fromMasked: `${from?.substring(0, 4)}****${from?.substring(Math.max(0, from.length - 4))}`,
      toMasked: `${to?.substring(0, 4)}****${to?.substring(Math.max(0, to.length - 4))}`,
      messageSid,
      inboundFacilityId: inboundFacilityId || null,
    });

    async function sendComplianceResponse(message: string) {
      try {
        const twilioAccountSid = TWILIO_ACCOUNT_SID.value().trim();
        const twilioAuthToken = TWILIO_AUTH_TOKEN.value().trim();
        const defaultTwilioPhoneNumber = TWILIO_PHONE_NUMBER.value().trim();
        const fromNumber = to || defaultTwilioPhoneNumber;
        const twilioUrl = `https://api.twilio.com/2010-04-01/Accounts/${twilioAccountSid}/Messages.json`;
        const auth = Buffer.from(`${twilioAccountSid}:${twilioAuthToken}`).toString('base64');
        const formData = new URLSearchParams();
        formData.append('To', from);
        formData.append('From', fromNumber);
        formData.append('Body', message);
        await fetch(twilioUrl, {
          method: 'POST',
          headers: {
            'Authorization': `Basic ${auth}`,
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: formData.toString(),
        });
      } catch (twilioError: any) {
        functions.logger.error('Error sending compliance response', {
          requestId,
          error: twilioError?.message,
        });
      }
    }

    // Handle STOP/UNSTOP keywords
    if (isStopKeyword(body)) {
      // Handle opt-out
      const confirmationMessage = await handleSMSOptOut(from, inboundFacilityId);
      if (confirmationMessage) {
        await sendComplianceResponse(confirmationMessage);
      }
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    if (isStartKeyword(body)) {
      // Handle opt-in
      await handleSMSOptIn(from, inboundFacilityId);
      await sendComplianceResponse('You have been subscribed to SMS messages. Reply STOP to opt out.');
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    // Handle HELP keyword
    if (isHelpKeyword(body)) {
      const normalizedFrom = formatPhoneNumber(from);
      if (normalizedFrom) {
        const tenant = await findTenantByPhoneNumber(normalizedFrom, inboundFacilityId);
        if (tenant) {
          // Get facility SMS settings for custom help message
          const facilityDoc = await admin.firestore()
            .collection('facilities')
            .doc(tenant.facilityId)
            .get();
          const facilityData = facilityDoc.data() as Record<string, any> | undefined;
          const smsSettings = facilityData?.smsSettings as Record<string, any> | undefined;
          const helpMessage = smsSettings?.helpMessage as string | undefined;

          // Use custom help message if provided, otherwise use default
          const message = helpMessage || 
            'Reply STOP to opt out of SMS messages. Reply START to opt back in. For support, contact your facility directly.';

          await sendComplianceResponse(message);
        }
      }
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    // Normalize phone number and find tenant
    const normalizedFrom = formatPhoneNumber(from);
    if (!normalizedFrom) {
      functions.logger.warn(`Invalid phone number format: ${from}`);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    // Find tenant by phone number (try multiple formats)
    const tenant = await findTenantByPhoneNumber(normalizedFrom, inboundFacilityId);
    
    if (!tenant) {
      // No tenant found - log but don't error (could be spam)
      functions.logger.warn(`Incoming SMS from unknown number: ${from}`);
      res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
      return;
    }

    // Get or create conversation
    const conversationId = await getOrCreateSMSConversation(tenant.facilityId, tenant.id, normalizedFrom);

    // Store incoming message
    await storeIncomingSMSMessage(conversationId, tenant.facilityId, tenant.id, normalizedFrom, body, messageSid);

    // Create contact log entry
    await createContactLogForSMSReply(tenant.facilityId, tenant.id, body, normalizedFrom, messageSid);

    // Send notification to facility staff (optional - can be done via Firebase Cloud Messaging)
    functions.logger.info(`Stored incoming SMS from tenant ${tenant.id} in facility ${tenant.facilityId}`);

    res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');

  } catch (error: any) {
    functions.logger.error(`Error handling incoming SMS: ${error.message}`, error);
    // Always return 200 to Twilio to prevent retries for errors we can't recover from
    res.status(200).contentType('text/xml').send('<?xml version="1.0" encoding="UTF-8"?><Response></Response>');
  }
});

/**
 * Resolve facility from inbound "To" phone number.
 */
async function findFacilityIdByInboundNumber(toPhoneNumber: string): Promise<string | null> {
  try {
    const normalized = formatPhoneNumber(toPhoneNumber);
    if (!normalized) return null;
    const snapshot = await admin.firestore()
      .collection('facilities')
      .where('twilioPhoneNumberE164', '==', normalized)
      .limit(1)
      .get();
    if (!snapshot.empty) {
      return snapshot.docs[0].id;
    }
    return null;
  } catch (error: any) {
    functions.logger.warn('Failed to resolve inbound facility by number', { error: error?.message });
    return null;
  }
}

/**
 * Helper: Find tenant by phone number (try multiple formats)
 */
async function findTenantByPhoneNumber(phoneNumber: string, facilityIdHint?: string | null): Promise<{ facilityId: string; id: string; phone: string } | null> {
  try {
    // Try different phone number formats
    const phoneVariations = [
      phoneNumber, // Original normalized format
      phoneNumber.replace('+', ''), // Without +
      phoneNumber.replace(/^\+1/, ''), // Without +1
      phoneNumber.replace(/^\+1/, '1'), // With 1 but no +
    ];

    if (facilityIdHint) {
      for (const phoneVar of phoneVariations) {
        const scopedQuery = await admin.firestore()
          .collection('facilities')
          .doc(facilityIdHint)
          .collection('tenants')
          .where('phone', '==', phoneVar)
          .where('isActive', '==', true)
          .limit(1)
          .get();
        if (!scopedQuery.empty) {
          const tenantDoc = scopedQuery.docs[0];
          const tenantData = tenantDoc.data() as Record<string, any>;
          return {
            facilityId: facilityIdHint,
            id: tenantDoc.id,
            phone: tenantData.phone,
          };
        }
      }
    }

    for (const phoneVar of phoneVariations) {
      // Use collection group query to search across all facilities
      const tenantsQuery = await admin.firestore()
        .collectionGroup('tenants')
        .where('phone', '==', phoneVar)
        .where('isActive', '==', true)
        .limit(1)
        .get();

      if (!tenantsQuery.empty) {
        const tenantDoc = tenantsQuery.docs[0];
        const tenantData = tenantDoc.data();
        const facilityId = tenantDoc.ref.parent.parent?.id;
        
        if (facilityId) {
          return {
            facilityId,
            id: tenantDoc.id,
            phone: tenantData.phone,
          };
        }
      }
    }

    return null;
  } catch (error: any) {
    functions.logger.error(`Error finding tenant by phone: ${error.message}`, error);
    return null;
  }
}

/**
 * Helper: Get or create SMS conversation
 */
async function getOrCreateSMSConversation(
  facilityId: string,
  tenantId: string,
  phoneNumber: string,
): Promise<string> {
  try {
    // Check if conversation already exists
    const conversationsRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations');
    
    const existingQuery = await conversationsRef
      .where('tenantId', '==', tenantId)
      .where('phoneNumber', '==', phoneNumber)
      .limit(1)
      .get();

    if (!existingQuery.empty) {
      return existingQuery.docs[0].id;
    }

    // Create new conversation
    const conversationRef = await conversationsRef.add({
      tenantId,
      phoneNumber,
      lastMessage: '',
      lastMessageAt: admin.firestore.FieldValue.serverTimestamp(),
      lastMessageDirection: 'incoming',
      unreadCount: 0,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return conversationRef.id;
  } catch (error: any) {
    functions.logger.error(`Error creating SMS conversation: ${error.message}`, error);
    throw error;
  }
}

/**
 * Helper: Store incoming SMS message
 */
async function storeIncomingSMSMessage(
  conversationId: string,
  facilityId: string,
  tenantId: string,
  phoneNumber: string,
  messageBody: string,
  messageSid: string,
): Promise<void> {
  try {
    const now = admin.firestore.FieldValue.serverTimestamp();
    
    // Store message in messages subcollection
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations')
      .doc(conversationId)
      .collection('messages')
      .add({
        direction: 'incoming',
        phoneNumber,
        body: messageBody,
        status: 'received',
        messageSid,
        timestamp: now,
        read: false,
      });

    // Update conversation
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('smsConversations')
      .doc(conversationId)
      .update({
        lastMessage: messageBody.substring(0, 100), // Truncate long messages
        lastMessageAt: now,
        lastMessageDirection: 'incoming',
        unreadCount: admin.firestore.FieldValue.increment(1),
        updatedAt: now,
      });

  } catch (error: any) {
    functions.logger.error(`Error storing incoming SMS message: ${error.message}`, error);
    throw error;
  }
}

/**
 * Helper: Create contact log for SMS reply
 */
async function createContactLogForSMSReply(
  facilityId: string,
  tenantId: string,
  messageBody: string,
  phoneNumber: string,
  messageSid: string,
): Promise<void> {
  try {
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .collection('contactLogs')
      .add({
        type: 'sms_reply',
        subject: 'SMS Reply from Tenant',
        message: messageBody,
        contactMethod: phoneNumber,
        direction: 'incoming',
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
        metadata: {
          messageSid,
        },
      });
  } catch (error: any) {
    // Don't fail the webhook if contact log creation fails
    functions.logger.warn(`Failed to create contact log for SMS reply: ${error.message}`);
  }
}

/**
 * Helper: Handle SMS opt-out
 */
async function handleSMSOptOut(phoneNumber: string, facilityIdHint?: string | null): Promise<string | null> {
  try {
    const normalizedPhone = formatPhoneNumber(phoneNumber);
    if (!normalizedPhone) return null;

    const tenant = await findTenantByPhoneNumber(normalizedPhone, facilityIdHint);
    if (!tenant) return null;

    // Check if enhanced opt-out is enabled for this facility
    const complianceEnabled = await isSMSComplianceFeatureEnabled('enhancedOptOut', tenant.facilityId);

    // Update tenant's SMS opt-out status
    await admin.firestore()
      .collection('facilities')
      .doc(tenant.facilityId)
      .collection('tenants')
      .doc(tenant.id)
      .update({
        smsOptOut: true,
        smsConsentStatus: 'opted_out',
        smsConsentTimestamp: admin.firestore.FieldValue.serverTimestamp(),
        smsConsentSource: 'inbound_stop',
        smsOptOutDate: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    // If compliance enabled, add to facility block list
    if (complianceEnabled) {
      const facilityRef = admin.firestore().collection('facilities').doc(tenant.facilityId);
      const facilityDoc = await facilityRef.get();
      const facilityData = facilityDoc.data() as Record<string, any> | undefined;
      
      const smsSettings = facilityData?.smsSettings || {};
      const blockList = (smsSettings.blockList as string[]) || [];
      
      // Add to block list if not already present
      if (!blockList.includes(normalizedPhone)) {
        blockList.push(normalizedPhone);
        await facilityRef.update({
          'smsSettings.blockList': blockList,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    functions.logger.info(`Tenant ${tenant.id} opted out of SMS`);

    // Return confirmation message
    return 'You have been unsubscribed from SMS messages. Reply START to opt back in.';
  } catch (error: any) {
    functions.logger.error(`Error handling SMS opt-out: ${error.message}`, error);
    return null;
  }
}

/**
 * Helper: Handle SMS opt-in
 */
async function handleSMSOptIn(phoneNumber: string, facilityIdHint?: string | null): Promise<void> {
  try {
    const normalizedPhone = formatPhoneNumber(phoneNumber);
    if (!normalizedPhone) return;

    const tenant = await findTenantByPhoneNumber(normalizedPhone, facilityIdHint);
    if (!tenant) return;

    // Check if enhanced opt-out is enabled for this facility
    const complianceEnabled = await isSMSComplianceFeatureEnabled('enhancedOptOut', tenant.facilityId);
    
    // Update tenant's SMS opt-in status
    const updateData: Record<string, any> = {
      smsOptOut: false,
      smsConsentStatus: 'opted_in',
      smsConsentTimestamp: admin.firestore.FieldValue.serverTimestamp(),
      smsConsentSource: 'inbound_start',
      smsOptInDate: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    // If compliance enabled, also remove from facility block list
    if (complianceEnabled) {
      const facilityRef = admin.firestore().collection('facilities').doc(tenant.facilityId);
      const facilityDoc = await facilityRef.get();
      const facilityData = facilityDoc.data() as Record<string, any> | undefined;
      
      if (facilityData?.smsSettings?.blockList) {
        const blockList = facilityData.smsSettings.blockList as string[];
        const updatedBlockList = blockList.filter(phone => phone !== normalizedPhone);
        
        await facilityRef.update({
          'smsSettings.blockList': updatedBlockList,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    await admin.firestore()
      .collection('facilities')
      .doc(tenant.facilityId)
      .collection('tenants')
      .doc(tenant.id)
      .update(updateData);

    functions.logger.info(`Tenant ${tenant.id} opted in to SMS`);
  } catch (error: any) {
    functions.logger.error(`Error handling SMS opt-in: ${error.message}`, error);
  }
}

/**
 * Helper: Check if current time is within quiet hours
 * Returns true if message should be queued (within quiet hours)
 */
async function checkQuietHours(facilityId: string, tenantId?: string): Promise<{
  isQuietHours: boolean;
  canSendNow: boolean;
  nextAllowedTime?: Date;
}> {
  try {
    const complianceEnabled = await isSMSComplianceFeatureEnabled('quietHours', facilityId);
    if (!complianceEnabled) {
      return { isQuietHours: false, canSendNow: true };
    }

    // Get facility SMS settings
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    const facilityData = facilityDoc.data() as Record<string, any> | undefined;
    const smsSettings = facilityData?.smsSettings as Record<string, any> | undefined;

    // Check facility-level quiet hours
    const facilityQuietStart = smsSettings?.quietHoursStart as string | undefined;
    const facilityQuietEnd = smsSettings?.quietHoursEnd as string | undefined;

    // Check tenant-level quiet hours (if tenantId provided)
    let tenantQuietStart: string | undefined;
    let tenantQuietEnd: string | undefined;
    if (tenantId) {
      const tenantDoc = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .get();
      const tenantData = tenantDoc.data() as Record<string, any> | undefined;
      tenantQuietStart = tenantData?.smsQuietHoursStart as string | undefined;
      tenantQuietEnd = tenantData?.smsQuietHoursEnd as string | undefined;
    }

    // Use tenant settings if available, otherwise use facility settings
    const quietStart = tenantQuietStart || facilityQuietStart;
    const quietEnd = tenantQuietEnd || facilityQuietEnd;

    if (!quietStart || !quietEnd) {
      return { isQuietHours: false, canSendNow: true };
    }

    // Parse quiet hours (format: "HH:mm" in facility timezone or UTC)
    const now = new Date();
    // const _facilityTimeZone = facilityData?.timeZone || 'UTC'; // Reserved for future timezone handling
    
    // For simplicity, we'll use UTC and parse the time
    // In production, you'd want to use a timezone library like moment-timezone
    const [startHour, startMinute] = quietStart.split(':').map(Number);
    const [endHour, endMinute] = quietEnd.split(':').map(Number);

    const currentHour = now.getUTCHours();
    const currentMinute = now.getUTCMinutes();
    const currentTimeMinutes = currentHour * 60 + currentMinute;
    const startTimeMinutes = startHour * 60 + startMinute;
    const endTimeMinutes = endHour * 60 + endMinute;

    // Handle quiet hours that span midnight (e.g., 22:00 to 08:00)
    let isQuietHours = false;
    if (startTimeMinutes > endTimeMinutes) {
      // Quiet hours span midnight
      isQuietHours = currentTimeMinutes >= startTimeMinutes || currentTimeMinutes < endTimeMinutes;
    } else {
      // Quiet hours within same day
      isQuietHours = currentTimeMinutes >= startTimeMinutes && currentTimeMinutes < endTimeMinutes;
    }

    if (!isQuietHours) {
      return { isQuietHours: false, canSendNow: true };
    }

    // Calculate next allowed time
    const nextAllowedTime = new Date(now);
    if (startTimeMinutes > endTimeMinutes && currentTimeMinutes >= startTimeMinutes) {
      // We're in the first part of quiet hours (before midnight)
      // Next allowed time is end time tomorrow
      nextAllowedTime.setUTCDate(nextAllowedTime.getUTCDate() + 1);
      nextAllowedTime.setUTCHours(endHour, endMinute, 0, 0);
    } else {
      // We're in quiet hours, next allowed time is end time today
      nextAllowedTime.setUTCHours(endHour, endMinute, 0, 0);
      if (nextAllowedTime <= now) {
        // End time has passed today, it's tomorrow
        nextAllowedTime.setUTCDate(nextAllowedTime.getUTCDate() + 1);
      }
    }

    return {
      isQuietHours: true,
      canSendNow: false,
      nextAllowedTime,
    };
  } catch (error: any) {
    functions.logger.error(`Error checking quiet hours: ${error.message}`, error);
    // On error, allow sending (fail open)
    return { isQuietHours: false, canSendNow: true };
  }
}

/**
 * Helper: Check per-tenant daily rate limit
 * Returns true if tenant can send more messages today
 */
async function checkPerTenantRateLimit(
  facilityId: string,
  tenantId: string,
): Promise<{
  canSend: boolean;
  messagesSentToday: number;
  limit: number;
  resetTime?: Date;
}> {
  try {
    const complianceEnabled = await isSMSComplianceFeatureEnabled('rateLimiting', facilityId);
    if (!complianceEnabled) {
      return { canSend: true, messagesSentToday: 0, limit: 0 };
    }

    // Get tenant rate limit settings
    const tenantDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .get();
    
    const tenantData = tenantDoc.data() as Record<string, any> | undefined;
    const rateLimitPerDay = tenantData?.smsRateLimitPerDay as number | undefined || 10; // Default: 10 per day
    const lastResetDate = tenantData?.smsLastResetDate?.toDate() as Date | undefined;
    const messagesSentToday = tenantData?.smsMessagesSentToday as number | undefined || 0;

    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    
    // Check if we need to reset the counter (new day)
    let needsReset = false;
    if (!lastResetDate) {
      needsReset = true;
    } else {
      const lastReset = new Date(lastResetDate.getFullYear(), lastResetDate.getMonth(), lastResetDate.getDate());
      if (lastReset < today) {
        needsReset = true;
      }
    }

    // Reset if needed
    if (needsReset) {
      await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .update({
          smsMessagesSentToday: 0,
          smsLastResetDate: admin.firestore.FieldValue.serverTimestamp(),
        });
      
      return {
        canSend: true,
        messagesSentToday: 0,
        limit: rateLimitPerDay,
        resetTime: new Date(today.getTime() + 24 * 60 * 60 * 1000), // Tomorrow
      };
    }

    // Check if limit exceeded
    const canSend = messagesSentToday < rateLimitPerDay;
    const resetTime = new Date(today.getTime() + 24 * 60 * 60 * 1000); // Tomorrow at midnight

    return {
      canSend,
      messagesSentToday,
      limit: rateLimitPerDay,
      resetTime,
    };
  } catch (error: any) {
    functions.logger.error(`Error checking per-tenant rate limit: ${error.message}`, error);
    // On error, allow sending (fail open)
    return { canSend: true, messagesSentToday: 0, limit: 0 };
  }
}

/**
 * Helper: Increment per-tenant daily message counter
 */
// Reserved for future per-tenant rate limiting
// eslint-disable-next-line @typescript-eslint/no-unused-vars
async function _incrementPerTenantRateLimit(facilityId: string, tenantId: string): Promise<void> {
  try {
    const complianceEnabled = await isSMSComplianceFeatureEnabled('rateLimiting', facilityId);
    if (!complianceEnabled) return;

    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(tenantId)
      .update({
        smsMessagesSentToday: admin.firestore.FieldValue.increment(1),
      });
  } catch (error: any) {
    functions.logger.error(`Error incrementing per-tenant rate limit: ${error.message}`, error);
    // Don't throw - this is non-critical
  }
}

/**
 * Helper: Add opt-out footer to SMS message
 * Returns message with footer appended if compliance enabled
 */
async function addOptOutFooter(facilityId: string, message: string): Promise<string> {
  try {
    const complianceEnabled = await isSMSComplianceFeatureEnabled('enhancedOptOut', facilityId);
    if (!complianceEnabled) {
      return message; // Return original message if compliance not enabled
    }

    // Get facility SMS settings for custom footer
    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
    const facilityData = facilityDoc.data() as Record<string, any> | undefined;
    const smsSettings = facilityData?.smsSettings as Record<string, any> | undefined;
    const optOutFooter = smsSettings?.optOutFooter as string | undefined;

    // Use custom footer if provided, otherwise use default
    const footer = optOutFooter || 'Reply STOP to opt out. Reply HELP for help.';

    // Check if footer already exists in message
    if (message.includes('STOP') || message.includes('opt out')) {
      // Footer might already be there, don't duplicate
      return message;
    }

    // Append footer (SMS max length is 1600 chars, but we'll keep it reasonable)
    const maxMessageLength = 1500; // Leave room for footer
    const truncatedMessage = message.length > maxMessageLength 
      ? message.substring(0, maxMessageLength - footer.length - 3) + '...'
      : message;

    return `${truncatedMessage}\n\n${footer}`;
  } catch (error: any) {
    functions.logger.error(`Error adding opt-out footer: ${error.message}`, error);
    // On error, return original message (fail open)
    return message;
  }
}

/**
 * Redirects requests from Firebase default domains to the custom domain.
 * Only redirects if the host is a Firebase domain (web.app or firebaseapp.com).
 * 
 * IMPORTANT: This function is used as a rewrite in firebase.json, which means
 * it intercepts ALL requests. For custom domain requests, we need to serve
 * the content. However, Firebase Hosting static files take precedence over
 * rewrites for exact file matches. So static assets (JS, CSS, images) will
 * still be served directly. This function mainly handles HTML page requests.
 * 
 * For custom domains, we return a simple response that allows the request
 * to be handled by static files. However, since functions must return a
 * response, we use a workaround: return a response that won't interfere.
 * 
 * Actually, wait - if static files take precedence, then this function
 * will only be called for paths that don't match static files. So for
 * custom domains, we can return a 404 and let the next rewrite handle it.
 * But that won't work because once a function returns, the chain stops.
 * 
 * The solution: For custom domains on non-static paths, we need to serve
 * the index.html content. But we can't easily read it from the function.
 * 
 * Let me try a different approach: Return a response that tells Firebase
 * to serve the static file. But that's not possible.
 * 
 * Actually, I think the solution is simpler: Since static files take
 * precedence, this function will only be called for paths that don't
 * match files. For those paths on custom domains, we should serve
 * index.html. But we can't read it easily.
 * 
 * Let me use a meta refresh approach for custom domains as a fallback.
 */
export const redirectToCustomDomain = functions.https.onRequest((req, res) => {
  // Use x-forwarded-host as Firebase Hosting proxies requests
  const forwardedHost = req.get('x-forwarded-host') || req.get('host') || '';
  const canonicalDomain = 'storagefacilitycreator.com';
  
  // Check if the request is coming from a Firebase default domain
  const isFirebaseDomain = 
    forwardedHost.includes('.web.app') || 
    forwardedHost.includes('.firebaseapp.com');
  
  if (isFirebaseDomain) {
    // Redirect to the custom domain, preserving the path and query string
    const path = req.path;
    const query = req.url.includes('?') ? req.url.substring(req.url.indexOf('?')) : '';
    const redirectUrl = `https://${canonicalDomain}${path}${query}`;
    
    res.redirect(301, redirectUrl);
    return;
  }
  
  // For custom domain: Since static files take precedence in Firebase Hosting,
  // this function is only called for paths that don't match static files.
  // For those paths, we should serve index.html. However, we can't easily
  // read it from the function. 
  // 
  // Workaround: Return a response that will cause the client to load from
  // the static files. But actually, we can't do that.
  //
  // The real solution: We need to either:
  // 1. Include index.html in the function (not ideal)
  // 2. Use a different architecture
  //
  // For now, let's try returning a simple HTML that loads the app.
  // This is a fallback - ideally static files would be served directly.
  
  // Actually, I realize the issue: Firebase Hosting processes rewrites
  // in order, and static files are checked FIRST before rewrites.
  // So if a static file exists, it's served. If not, rewrites are tried.
  // Once a rewrite function returns a response, processing stops.
  //
  // So for custom domains, if the path doesn't match a static file,
  // this function is called. We need to serve index.html content.
  // But we can't read it from the function easily.
  //
  // Let me try returning a response that redirects to the same path
  // but that would cause a loop.
  //
  // I think the solution is to accept that we need to serve content
  // from the function for custom domains. Let me return a simple
  // HTML response that will work.
  
  // For custom domain: Serve index.html content for SPA routing
  // Static files (JS, CSS, etc.) are served directly by Firebase Hosting
  // This function is only called for paths that don't match static files
  const indexHtml = `<!DOCTYPE html>
<html>
<head>
  <base href="/">
  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes, viewport-fit=cover">
  <meta name="description" content="Storage Facility Creator - Manage your storage facilities with ease">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="default">
  <meta name="apple-mobile-web-app-title" content="SFC App">
  <meta name="apple-touch-fullscreen" content="yes">
  <meta name="format-detection" content="telephone=no">
  <meta http-equiv="Content-Security-Policy" content="upgrade-insecure-requests">
  <link rel="apple-touch-icon" href="/icons/Icon-192.png">
  <link rel="icon" type="image/png" href="/favicon.png"/>
  <title>SFC App - Storage Facility Creator</title>
  <link rel="canonical" href="https://storagefacilitycreator.com">
  <script src="https://js.stripe.com/v3/"></script>
  <meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate, max-age=0, private">
  <meta http-equiv="Pragma" content="no-cache">
  <meta http-equiv="Expires" content="0">
</head>
<body>
  <script>
    (function() {
      'use strict';
      window.addEventListener('error', function(event) {
        const errorMsg = event.error?.message || event.error?.toString() || '';
        const errorStack = event.error?.stack || '';
        if (errorMsg.includes('focus') || errorMsg.includes('Focus') || errorMsg.includes('js_helper') ||
            errorStack.includes('focus_manager') || errorStack.includes('focus_traversal') || errorStack.includes('js_helper')) {
          console.warn('⚠️ Focus error caught and suppressed:', errorMsg);
          event.preventDefault();
          return true;
        }
        if (errorMsg.includes('BloomFilter') || errorMsg.includes('BloomFilterError') ||
            errorStack.includes('BloomFilter') || errorStack.includes('BloomFilterError')) {
          event.preventDefault();
          return true;
        }
        console.error('❌ Uncaught error:', event.error);
        return false;
      });
      window.addEventListener('unhandledrejection', function(event) {
        const reason = event.reason?.toString() || '';
        if (reason.includes('BloomFilter') || reason.includes('BloomFilterError')) {
          event.preventDefault();
          return;
        }
        console.warn('⚠️ Unhandled promise rejection:', event.reason);
        event.preventDefault();
      });
    })();
  </script>
  <script src="/flutter_bootstrap.js" async></script>
</body>
</html>`;
  
  res.set('Content-Type', 'text/html');
  res.set('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.status(200).send(indexHtml);
});

/**
 * TEMPORARY ADMIN FUNCTION: Enable Stripe Connect feature flag
 * This is a one-time use function to enable Stripe Connect globally
 * TODO: Remove this function after enabling the feature flag
 */
export const enableStripeConnectAdmin = functions.https.onCall(async (data: any, context) => {
  // Only allow super admins
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const userEmail = context.auth.token.email || '';
  const isSuperAdmin = getSuperAdminEmails().includes(userEmail.toLowerCase());

  if (!isSuperAdmin) {
    throw new functions.https.HttpsError('permission-denied', 'Only super admins can enable feature flags');
  }

  try {
    const configRef = admin.firestore().collection('appConfig').doc('stripe');
    const configDoc = await configRef.get();

    if (!configDoc.exists) {
      // Create config document with Connect enabled
      await configRef.set({
        connectEnabledGlobal: true,
        tenantAutopayEnabledGlobal: false,
        storeEnabledGlobal: false,
        checkoutEnabledGlobal: false,
        allowlistFacilityIds: [],
        killSwitch: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { success: true, message: 'Stripe config document created with Connect enabled!' };
    } else {
      // Update existing config to enable Connect
      await configRef.update({
        connectEnabledGlobal: true,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return { success: true, message: 'Stripe Connect enabled in existing config!' };
    }
  } catch (error: any) {
    functions.logger.error('Error enabling Stripe Connect:', error);
    throw new functions.https.HttpsError('internal', `Failed to enable Stripe Connect: ${error.message}`);
  }
});

// ============================================================================
// AI ASSISTANT FUNCTIONS (Action-Based)
// ============================================================================

/**
 * AI Assistant callable function
 * Processes user messages and returns responses with proposed actions
 * 
 * TODO: Integrate with actual LLM API (OpenAI, Anthropic, etc.)
 * For now, returns structured responses with action proposals
 */
export const aiAssistant = functions.runWith({ secrets: AI_SECRETS }).https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, message, conversationId } = data;

  if (!facilityId || !message) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and message are required');
  }

  try {
    // Get config for limits
    const config = await getAIAssistantConfig();
    
    // Check if AI assistant is enabled
    const aiEnabled = await isAIAssistantEnabled(facilityId);
    if (!aiEnabled) {
      throw new functions.https.HttpsError('failed-precondition', 'AI assistant is not enabled for this facility');
    }

    // Validate message length
    const maxLength = config.maxMessageLength || 2000;
    if (message.length > maxLength) {
      throw new functions.https.HttpsError('invalid-argument', `Message too long. Maximum ${maxLength} characters allowed.`);
    }

    // Rate limiting: Per user per minute
    await enforceRateLimit({
      facilityId,
      userId: context.auth.uid,
      key: 'aiAssistant_user',
      limit: 10, // 10 requests per minute per user
      windowSeconds: 60,
    });

    // Rate limiting: Per facility per minute
    await enforceRateLimit({
      facilityId,
      userId: context.auth.uid,
      key: 'aiAssistant_facility',
      limit: 30, // 30 requests per minute per facility
      windowSeconds: 60,
    });

    // Daily usage limits: Per facility
    const today = new Date().toISOString().split('T')[0];
    const facilityUsageRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('aiUsage')
      .doc(today);

    const facilityUsageDoc = await facilityUsageRef.get();
    const facilityUsageCount = facilityUsageDoc.exists ? (facilityUsageDoc.data()?.count || 0) : 0;
    const maxFacilityDaily = config.maxMessagesPerDay || 100;
    
    if (facilityUsageCount >= maxFacilityDaily) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Daily limit reached for this facility (${maxFacilityDaily} messages/day). Try again tomorrow.`,
      );
    }

    // Daily usage limits: Per user
    const userUsageRef = admin.firestore()
      .collection('users')
      .doc(context.auth.uid)
      .collection('aiUsage')
      .doc(today);

    const userUsageDoc = await userUsageRef.get();
    const userUsageCount = userUsageDoc.exists ? (userUsageDoc.data()?.count || 0) : 0;
    const maxUserDaily = config.maxMessagesPerUser || 50;
    
    if (userUsageCount >= maxUserDaily) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Daily limit reached for your account (${maxUserDaily} messages/day). Try again tomorrow.`,
      );
    }

    // Increment usage counters
    await facilityUsageRef.set({
      count: facilityUsageCount + 1,
      lastUsed: admin.firestore.FieldValue.serverTimestamp(),
      facilityId,
    }, { merge: true });

    await userUsageRef.set({
      count: userUsageCount + 1,
      lastUsed: admin.firestore.FieldValue.serverTimestamp(),
      userId: context.auth.uid,
    }, { merge: true });

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

    // Check if user is owner or has manager/employee role
    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'employee') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    // Get or create conversation
    let convId = conversationId;
    let conversationMessages: any[] = [];
    
    if (convId) {
      // Get existing conversation
      const convDoc = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('aiConversations')
        .doc(convId)
        .get();
      
      if (convDoc.exists) {
        conversationMessages = convDoc.data()?.messages || [];
      } else {
        convId = null; // Create new if not found
      }
    }
    
    if (!convId) {
      const convRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('aiConversations')
        .doc();
      
      await convRef.set({
        facilityId,
        messages: [],
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      
      convId = convRef.id;
    }

    // Get facility context for better responses
    const facilityName = facilityData?.name || 'your facility';
    const totalUnits = facilityData?.totalUnits || 0;
    const occupiedUnits = facilityData?.occupiedUnits || 0;
    const occupancyRate = totalUnits > 0 ? Math.round((occupiedUnits / totalUnits) * 100) : 0;


    // Prepare system prompt for action-based AI assistant
    const systemPrompt = `You are an AI assistant for a self-storage facility management system. Your role is to:
1. Answer questions about facility operations, tenant management, payments, and best practices
2. Propose actions when users request to do something (create tenant, send message, etc.)
3. Always require user confirmation before executing any action

Available actions you can propose:
- createTenant: Create a new tenant (requires: name, email, phone, unitNumber)
- createPayment: Create a payment record (requires: tenantId, amount, dueDate)
- sendMessage: Send SMS or email to tenant (requires: tenantId, message, channel)
- createReminder: Create a payment reminder (requires: tenantId, dueDate)
- updateTenant: Update tenant information (requires: tenantId, fields to update)
- createContract: Create a lease contract (requires: tenantId, unitId, terms)

When proposing actions, return a JSON object with this exact structure:
{
  "response": "A natural language response explaining what you'll do",
  "actions": [
    {
      "type": "createTenant",
      "description": "Description of the action",
      "parameters": {},
      "estimatedImpact": "What will happen",
      "requiresConfirmation": true
    }
  ]
}

If no actions are needed, return: {"response": "your response", "actions": []}

Facility context:
- Facility: ${facilityName}
- Total units: ${totalUnits}
- Occupied units: ${occupiedUnits}
- Occupancy rate: ${occupancyRate}%

Always be helpful, professional, and safety-conscious. Never execute actions without explicit user confirmation.`;

    // Call OpenAI API
    let response = '';
    let actions: any[] = [];
    
    try {
      const apiKey = OPENAI_API_KEY.value();
      if (!apiKey) {
        throw new Error('OpenAI API key not configured');
      }

      // Initialize OpenAI client
      const openai = new OpenAI({ apiKey });

      // Prepare messages for OpenAI (convert to OpenAI format)
      const openaiMessages: any[] = [
        { role: 'system', content: systemPrompt },
      ];
      
      // Add conversation history (limited by config)
      const maxHistory = config.maxConversationHistory || 10;
      const recentMessages = conversationMessages.slice(-maxHistory);
      for (const msg of recentMessages) {
        if (msg.role === 'user' || msg.role === 'assistant') {
          openaiMessages.push({
            role: msg.role,
            content: msg.content,
          });
        }
      }
      
      // Add current user message
      openaiMessages.push({ role: 'user', content: message });

      const completion = await openai.chat.completions.create({
        model: 'gpt-4o-mini', // Cost-effective model, can upgrade to gpt-4 if needed
        messages: openaiMessages,
        temperature: 0.7,
        max_tokens: config.maxTokensPerRequest || 1000, // Configurable token limit
        response_format: { type: 'json_object' }, // Force JSON response
      });

      const aiResponse = completion.choices[0]?.message?.content || '';
      
      try {
        const parsed = JSON.parse(aiResponse);
        response = parsed.response || aiResponse;
        actions = parsed.actions || [];
      } catch (parseError) {
        // If JSON parsing fails, treat as plain text response
        response = aiResponse;
        actions = [];
      }
    } catch (apiError: any) {
      functions.logger.error('OpenAI API error:', apiError);
      
      // Fallback to keyword-based responses if API fails
      const lowerMessage = message.toLowerCase();
      
      if (lowerMessage.includes('create tenant') || lowerMessage.includes('add tenant')) {
        response = 'I can help you create a new tenant. I\'ll need some information:\n\n'
          + '• Tenant name\n'
          + '• Email address\n'
          + '• Phone number\n'
          + '• Unit number (optional)\n\n'
          + 'Would you like me to create a tenant?';
        
        actions = [{
          type: 'createTenant',
          description: 'Create a new tenant',
          parameters: {},
          estimatedImpact: 'Will create a new tenant record in the system',
          requiresConfirmation: true,
        }];
      } else if (lowerMessage.includes('send reminder') || lowerMessage.includes('remind tenant')) {
        response = 'I can help you send a payment reminder to a tenant. I\'ll need:\n\n'
          + '• Tenant name or email\n'
          + '• Message content (optional)\n\n'
          + 'Would you like me to send a reminder?';
        
        actions = [{
          type: 'sendMessage',
          description: 'Send payment reminder to tenant',
          parameters: {},
          estimatedImpact: 'Will send an SMS or email reminder to the tenant',
          requiresConfirmation: true,
        }];
      } else {
        response = 'I understand you\'re asking about storage facility management. '
          + 'I can help you with:\n\n'
          + '• Creating tenants, payments, contracts\n'
          + '• Sending messages and reminders\n'
          + '• Answering questions about facility operations\n\n'
          + 'What would you like me to do?';
      }
    }

    // Add user message and assistant response to conversation
    const conversationRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('aiConversations')
      .doc(convId);

    const userMessage = {
      role: 'user',
      content: message,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    };

    const assistantMessage = {
      role: 'assistant',
      content: response,
      actions: actions,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    };

    await conversationRef.update({
      messages: admin.firestore.FieldValue.arrayUnion(userMessage, assistantMessage),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {
      conversationId: convId,
      response,
      actions,
    };
  } catch (error: any) {
    functions.logger.error('Error in AI assistant:', error);
    throw new functions.https.HttpsError('internal', `Failed to process AI request: ${error.message}`);
  }
});

const MAX_INPUT_CHARS = 2000;
const MAX_OUTPUT_TOKENS = 380; // Shorter replies; hard guard rails
const MAX_REQUESTS_PER_USER_PER_MINUTE = 5; // Hard limit
const OPENAI_CHAT_MODEL = 'gpt-4o-mini';

// Enhanced guardrail constants
const MIN_MESSAGE_LENGTH = 3; // Minimum meaningful message length
const MAX_REPEATED_CHARS = 10; // Max repeated characters (e.g., "aaaaaaa")
const SUSPICIOUS_PATTERN_THRESHOLD = 3; // Number of suspicious patterns to trigger rejection

/** Keywords that indicate storage-facility-related questions. Broad so natural questions pass. */
const STORAGE_RELATED_KEYWORDS = [
  'storage', 'facility', 'facilities', 'tenant', 'tenants', 'unit', 'units',
  'occupancy', 'payment', 'payments', 'rent', 'lease', 'contract', 'move-in', 'move-out',
  'gate', 'access', 'auction', 'lien', 'delinquency', 'pricing', 'yield', 'insurance',
  'dnr', 'reservation', 'vacancy', 'deposit', 'billing', 'stripe', 'report', 'reports',
  'late fee', 'self-storage', 'self storage', 'management', 'app ', 'feature', 'how do i', 'how to',
  'property', 'properties', 'location', 'business', 'customer', 'rental', 'space', 'locker',
  'owner', 'operate', 'operating', 'running', 'best practice', 'setup', 'set up', 'tips', 'advice',
  'monthly', 'overdue', 'collections', 'evict', 'overlock', 'lock out', 'lockout',
  'charge', 'charges', 'fee', 'fees', 'price', 'rates', 'revenue', 'income',
];

/** Off-topic terms. Reject if present and no storage-related keyword. */
const OFF_TOPIC_KEYWORDS = [
  'star trek', 'startrek', 'star wars', 'movie', 'movies', 'film', 'recipe', 'recipes',
  'cook', 'sports', 'football', 'basketball', 'game of thrones', 'lotr', 'music', 'celebrity',
  'joke', 'jokes', 'meme', 'trivia', 'recipe for',
  ' dog ', ' cat ', ' puppy', ' kitten', ' dog named', ' cat named', 'a dog', 'a cat',
];

/** Request to generate a message/email to a specific person. We have no tenant data → refuse. */
const PERSONALIZED_MESSAGE_PATTERNS = [
  /(?:give me|write|draft|send|email)\s+(?:a\s+)?(?:message|email|reminder|notice)\s+to\s+/i,
  /(?:message|email|reminder|notice)\s+to\s+send\s+to\s+/i,
  /(?:send|write)\s+(?:a\s+)?(?:message|email)\s+to\s+/i,
  /\b(?:hi|dear|hello)\s+[a-z]+\s*[,.]\s*(?:rent|payment|due)/i,
];

/** Prompt injection patterns - attempts to override system instructions */
const PROMPT_INJECTION_PATTERNS = [
  /ignore\s+(?:previous|all|above)\s+(?:instructions?|prompts?|rules?)/i,
  /forget\s+(?:previous|all|above)\s+(?:instructions?|prompts?|rules?)/i,
  /you\s+are\s+now\s+(?:a|an)\s+/i,
  /system\s*:\s*you\s+are/i,
  /new\s+instructions?\s*:/i,
  /override\s+(?:previous|system)/i,
  /act\s+as\s+if/i,
  /pretend\s+to\s+be/i,
  /roleplay\s+as/i,
  /\[system\]/i,
  /<\|system\|>/i,
  /###\s*instructions?\s*:/i,
];

/** Suspicious patterns that may indicate abuse or malicious intent */
const SUSPICIOUS_PATTERNS = [
  /(.)\1{9,}/, // Repeated characters (e.g., "aaaaaaaaaa")
  /[^\x20-\x7E]{5,}/, // Non-printable characters
  /(?:http|https|ftp):\/\//i, // URLs (shouldn't be in storage facility questions)
  /<script|javascript:|onerror=|onclick=/i, // Script injection attempts
  /eval\(|exec\(|system\(/i, // Code execution attempts
  /password|secret|api[_\s]?key|token|credential/i, // Sensitive data requests
  /\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/, // Credit card patterns
];

function isStorageFacilityRelated(message: string): boolean {
  const m = message.toLowerCase().trim();
  if (m.length < MIN_MESSAGE_LENGTH) return false; // Reject too short messages
  const hasStorage = STORAGE_RELATED_KEYWORDS.some((kw) => m.includes(kw));
  const hasOffTopic = OFF_TOPIC_KEYWORDS.some((kw) => m.includes(kw));
  if (hasOffTopic && !hasStorage) return false;
  if (hasStorage) return true;
  if (m.length <= 35 && !hasOffTopic) return true;
  return false;
}

/**
 * Detect prompt injection attempts - users trying to override system instructions
 */
function containsPromptInjection(message: string): boolean {
  return PROMPT_INJECTION_PATTERNS.some((pattern) => pattern.test(message));
}

/**
 * Detect suspicious patterns that may indicate abuse or malicious intent
 */
function containsSuspiciousPatterns(message: string): { detected: boolean; patterns: string[] } {
  const detectedPatterns: string[] = [];
  
  for (const pattern of SUSPICIOUS_PATTERNS) {
    if (pattern.test(message)) {
      detectedPatterns.push(pattern.toString());
    }
  }
  
  // Check for repeated characters
  const repeatedCharMatch = message.match(/(.)\1{9,}/);
  if (repeatedCharMatch) {
    detectedPatterns.push('repeated_characters');
  }
  
  return {
    detected: detectedPatterns.length >= SUSPICIOUS_PATTERN_THRESHOLD,
    patterns: detectedPatterns,
  };
}

/**
 * Validate message structure and content quality
 */
function isValidMessageStructure(message: string): { valid: boolean; reason?: string } {
  const trimmed = message.trim();
  
  // Too short
  if (trimmed.length < MIN_MESSAGE_LENGTH) {
    return { valid: false, reason: 'Message too short' };
  }
  
  // Too many repeated characters (likely spam/abuse)
  const repeatedCharMatch = trimmed.match(/(.)\1{9,}/);
  if (repeatedCharMatch) {
    return { valid: false, reason: 'Invalid message format' };
  }
  
  // Check for excessive whitespace
  if (trimmed.split(/\s+/).length > 200) {
    return { valid: false, reason: 'Message too long' };
  }
  
  return { valid: true };
}

/** Reject requests to draft messages to specific people (we have no tenant data). */
function containsPersonalizedMessageRequest(message: string): boolean {
  return PERSONALIZED_MESSAGE_PATTERNS.some((re) => re.test(message));
}

/** Reject nonsense e.g. dog/cat as tenant, "message to Rambo" (dog) late on rent. */
function containsNonsenseOrPersonalizedRequest(message: string): boolean {
  const m = message.toLowerCase();
  if (containsPersonalizedMessageRequest(message)) return true;
  const hasPet = /\b(dog|cat|puppy|kitten|pet)\b/.test(m);
  const hasTenantContext = /\b(rent|tenant|late|payment|message to|send to|email to)\b/.test(m);
  if (hasPet && hasTenantContext) return true;
  return false;
}

/**
 * aiAssistantChat – OpenAI-backed chat via Firestore config.
 * Config: /appConfig/aiAssistant { enabled, killSwitch, provider, allowlistFacilityIds }.
 * Called only when client has determined OpenAI should be used; we re-validate server-side.
 * Output: replyText, providerUsed, model, requestId, tokensUsed, latencyMs.
 */
export const aiAssistantChat = functions
  .runWith({ secrets: AI_SECRETS, timeoutSeconds: 60, memory: '256MB' })
  .https.onCall(async (data: any, context) => {
    const startMs = Date.now();
    const requestId = `ai-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;

    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    const { facilityId, userId, message, conversationId, threadId, facilityName } = data as {
      facilityId?: string;
      userId?: string;
      message?: string;
      conversationId?: string;
      threadId?: string;
      facilityName?: string;
    };

    if (!facilityId || !message || typeof message !== 'string') {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId and message are required');
    }
    const uid = context.auth.uid;
    if (userId && userId !== uid) {
      throw new functions.https.HttpsError('invalid-argument', 'userId must match authenticated user');
    }

    if (message.length > MAX_INPUT_CHARS) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        `Message too long. Maximum ${MAX_INPUT_CHARS} characters allowed.`,
      );
    }

    // Enhanced validation: Message structure
    const structureCheck = isValidMessageStructure(message);
    if (!structureCheck.valid) {
      functions.logger.warn('aiAssistantChat invalid message structure', {
        facilityId,
        reason: structureCheck.reason,
        messageLength: message.length,
      });
      throw new functions.https.HttpsError(
        'invalid-argument',
        structureCheck.reason || 'Invalid message format',
      );
    }

    // Enhanced guardrail: Prompt injection detection
    if (containsPromptInjection(message)) {
      functions.logger.warn('aiAssistantChat prompt injection detected', { facilityId });
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Invalid request. Please ask a question about storage facility management.',
      );
    }

    // Enhanced guardrail: Suspicious patterns detection
    const suspiciousCheck = containsSuspiciousPatterns(message);
    if (suspiciousCheck.detected) {
      functions.logger.warn('aiAssistantChat suspicious patterns detected', {
        facilityId,
        patterns: suspiciousCheck.patterns,
      });
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Invalid request format. Please ask a question about storage facility management.',
      );
    }

    const config = await getAIAssistantConfig();
    
    // Log config for debugging
    functions.logger.info('aiAssistantChat config check', {
      enabled: config.enabled,
      killSwitch: config.killSwitch,
      provider: config.provider,
      providerType: typeof config.provider,
      allowlistLength: config.allowlistFacilityIds?.length || 0,
      facilityId,
      allowlistIncludesFacility: config.allowlistFacilityIds?.includes(facilityId) || false,
    });
    
    const { ok, allowlistPassed } = shouldUseOpenAIChat(facilityId, config);
    if (!ok) {
      functions.logger.warn('aiAssistantChat rejected', {
        facilityId,
        enabled: config.enabled,
        killSwitch: config.killSwitch,
        provider: config.provider,
        providerMatches: config.provider === 'openai',
        allowlistPassed,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'AI Assistant (OpenAI) is not enabled for this facility. Check app config or allowlist.',
      );
    }

    // Rate limiting: Per user per minute
    await enforceUserRateLimit(uid, 'aiAssistantChat', MAX_REQUESTS_PER_USER_PER_MINUTE, 60);

    // Daily usage limits: Per facility
    const today = new Date().toISOString().split('T')[0];
    const facilityUsageRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('aiUsage')
      .doc(today);

    const facilityUsageDoc = await facilityUsageRef.get();
    const facilityUsageCount = facilityUsageDoc.exists ? (facilityUsageDoc.data()?.count || 0) : 0;
    const maxFacilityDaily = config.maxMessagesPerDay ?? 30;
    
    if (facilityUsageCount >= maxFacilityDaily) {
      functions.logger.warn('aiAssistantChat daily facility limit reached', {
        facilityId,
        count: facilityUsageCount,
        limit: maxFacilityDaily,
      });
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Daily limit reached for this facility (${maxFacilityDaily} messages/day). Try again tomorrow.`,
      );
    }

    // Daily usage limits: Per user
    const userUsageRef = admin.firestore()
      .collection('users')
      .doc(uid)
      .collection('aiUsage')
      .doc(today);

    const userUsageDoc = await userUsageRef.get();
    const userUsageCount = userUsageDoc.exists ? (userUsageDoc.data()?.count || 0) : 0;
    const maxUserDaily = config.maxMessagesPerUser ?? 20;
    
    if (userUsageCount >= maxUserDaily) {
      functions.logger.warn('aiAssistantChat daily user limit reached', {
        userId: uid,
        count: userUsageCount,
        limit: maxUserDaily,
      });
      throw new functions.https.HttpsError(
        'resource-exhausted',
        `Daily limit reached for your account (${maxUserDaily} messages/day). Try again tomorrow.`,
      );
    }

    const facilityData = await getFacilityDataForUserOrThrow(uid, facilityId);

    const displayName = facilityName || facilityData?.name || 'your facility';
    const systemPrompt = `You are a helpful AI assistant for ${displayName}, a self-storage facility. You help facility owners and managers with anything related to running their business — tenant management, payments, pricing, occupancy, delinquency, best practices, marketing, legal questions about storage, and how to use this software. Be conversational, practical, and thorough. You can draft template messages, emails, or notices (e.g. late payment notices, move-out confirmations) since these are general templates, not sent to specific people. If asked something completely unrelated to the storage business or facility management, gently redirect back to how you can help. Keep responses focused and actionable.`;

    let replyText: string;
    let tokensUsed: number;
    const providerUsed = 'openai';
    const model = OPENAI_CHAT_MODEL;

    try {
      const apiKey = OPENAI_API_KEY.value();
      if (!apiKey) {
        throw new Error('OpenAI API key not configured');
      }
      const openai = new OpenAI({ apiKey });

      // Enhanced guardrail: Use OpenAI Moderation API to check for harmful content
      try {
        const moderationResult = await openai.moderations.create({ input: message });
        const flagged = moderationResult.results[0]?.flagged || false;
        const categories = moderationResult.results[0]?.categories || {};
        
        if (flagged) {
          const flaggedCategories = Object.entries(categories)
            .filter(([_, isFlagged]) => isFlagged)
            .map(([category]) => category);
          
          functions.logger.warn('aiAssistantChat content flagged by moderation API', {
            facilityId,
            categories: flaggedCategories,
          });
          
          throw new functions.https.HttpsError(
            'invalid-argument',
            'Your message contains inappropriate content. Please ask a question about storage facility management.',
          );
        }
      } catch (modErr: any) {
        // If moderation API fails, log but don't block (fail open for availability)
        functions.logger.warn('aiAssistantChat moderation API check failed', {
          facilityId,
          error: modErr?.message,
        });
        // Continue with request if moderation check fails
      }

      const completion = await openai.chat.completions.create({
        model: OPENAI_CHAT_MODEL,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: message },
        ],
        temperature: 0.4,
        max_tokens: Math.min(MAX_OUTPUT_TOKENS, config.maxTokensPerRequest ?? MAX_OUTPUT_TOKENS),
      });

      const choice = completion.choices[0];
      replyText = (choice?.message?.content || '').trim() || 'I couldn\'t generate a response. Please try again.';
      
      // Enhanced guardrail: Validate and sanitize response
      if (replyText.length > MAX_OUTPUT_TOKENS * 4) { // Rough char estimate (4 chars per token)
        replyText = replyText.substring(0, MAX_OUTPUT_TOKENS * 4) + '...';
        functions.logger.warn('aiAssistantChat response truncated', { facilityId });
      }
      
      // Check response for prompt injection attempts in output
      if (containsPromptInjection(replyText)) {
        functions.logger.warn('aiAssistantChat prompt injection in response', { facilityId });
        replyText = 'I can only help with storage facility management questions.';
      }
      
      tokensUsed =
        (completion.usage?.total_tokens ?? 0) ||
        (completion.usage?.completion_tokens ?? 0) +
        (completion.usage?.prompt_tokens ?? 0);
    } catch (apiErr: any) {
      functions.logger.error('aiAssistantChat OpenAI error', { requestId, error: apiErr?.message });
      throw new functions.https.HttpsError(
        'internal',
        apiErr?.message?.includes('rate') ? 'Service is busy. Please try again shortly.' : 'Failed to get AI response. Please try again.',
      );
    }

    // Increment usage counters (after successful OpenAI call)
    await facilityUsageRef.set({
      count: facilityUsageCount + 1,
      lastUsed: admin.firestore.FieldValue.serverTimestamp(),
      facilityId,
    }, { merge: true });

    await userUsageRef.set({
      count: userUsageCount + 1,
      lastUsed: admin.firestore.FieldValue.serverTimestamp(),
      userId: uid,
    }, { merge: true });

    const latencyMs = Date.now() - startMs;
    const userIdHashed = hashUserId(uid);

    functions.logger.info('aiAssistantChat', {
      facilityId,
      userIdHashed,
      providerUsed,
      model,
      requestId,
      tokensUsed,
      latencyMs,
      allowlistPassed,
      facilityUsageCount: facilityUsageCount + 1,
      userUsageCount: userUsageCount + 1,
    });

    return {
      replyText,
      providerUsed,
      model,
      requestId,
      tokensUsed,
      latencyMs,
    };
  });

/**
 * Execute a confirmed AI action
 * Performs the actual action after user confirmation
 */
export const aiAssistantExecuteAction = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, conversationId, action } = data;

  if (!facilityId || !conversationId || !action) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, conversationId, and action are required');
  }

  try {
    // Check if AI assistant is enabled
    const aiEnabled = await isAIAssistantEnabled(facilityId);
    if (!aiEnabled) {
      throw new functions.https.HttpsError('failed-precondition', 'AI assistant is not enabled for this facility');
    }

    // Verify user has access and permission for the action
    const facilityDoc = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    // TODO: Check specific permissions for action type
    // For now, just verify facility access

    const actionType = action.type as string;
    let result: any = { success: false, message: 'Action not implemented' };

    // TODO: Implement actual action execution based on action type
    // This is a placeholder - actual implementation will depend on the action type
    switch (actionType) {
      case 'createTenant':
        // result = await createTenantFromAIAction(facilityId, action.parameters, userId);
        result = { success: false, message: 'Action execution not yet implemented. API integration pending.' };
        break;
      case 'sendMessage':
        // result = await sendMessageFromAIAction(facilityId, action.parameters, userId);
        result = { success: false, message: 'Action execution not yet implemented. API integration pending.' };
        break;
      default:
        result = { success: false, message: `Unknown action type: ${actionType}` };
    }

    // Update conversation with confirmed action
    const conversationRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('aiConversations')
      .doc(conversationId);

    // Mark the action as confirmed and executed
    const conversation = await conversationRef.get();
    if (conversation.exists) {
      const messages = conversation.data()?.messages || [];
      const lastAssistantMessage = messages.findLast((m: any) => m.role === 'assistant');
      if (lastAssistantMessage) {
        lastAssistantMessage.confirmedAction = action;
        lastAssistantMessage.executedAt = admin.firestore.FieldValue.serverTimestamp();
        
        await conversationRef.update({
          messages: messages,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
    }

    // TODO: Log audit event for AI action execution
    // await writeAuditLog(facilityId, { ... });

    return result;
  } catch (error: any) {
    functions.logger.error('Error executing AI action:', error);
    throw new functions.https.HttpsError('internal', `Failed to execute action: ${error.message}`);
  }
});

// ============================================================================
// DOCUMENT COMPLIANCE FUNCTIONS
// ============================================================================

/**
 * Compute SHA-256 hash of a document
 * Used for document integrity verification
 */
export const computeDocumentHash = functions.https.onCall(async (data: any, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  try {
    const { fileData } = data;

    if (!fileData || !Array.isArray(fileData)) {
      throw new functions.https.HttpsError('invalid-argument', 'fileData must be a byte array');
    }

    // Convert array to Buffer
    const buffer = Buffer.from(fileData);
    
    // Compute SHA-256 hash
    const hash = crypto.createHash('sha256');
    hash.update(buffer);
    const sha256 = hash.digest('hex');

    functions.logger.info(`Computed SHA-256 hash for document (${buffer.length} bytes)`);

    return {
      sha256: sha256,
      size: buffer.length,
    };
  } catch (error: any) {
    functions.logger.error('Error computing document hash:', error);
    throw new functions.https.HttpsError('internal', `Failed to compute hash: ${error.message}`);
  }
});

/**
 * Merge signature image and optional text into the original contract PDF.
 * Returns the merged PDF as base64. Used when signing the uploaded contract (not a blank page).
 * placements: [{ type: 'image'|'text', pageIndex, x, y, width?, height?, imageBase64?, text?, fontSize? }]
 * PDF coordinates: origin bottom-left, units in points (72 per inch).
 */
export const mergeSignatureIntoPdf = functions.runWith({ timeoutSeconds: 120, memory: '512MB' })
  .https.onCall(async (data: {
    pdfBase64?: string;
    fileUrl?: string;
    signaturePngBase64?: string;
    signerName?: string;
    signerDate?: string;
    signingToken?: string;
    placements?: Array<{
      type: 'image' | 'text';
      pageIndex: number;
      x: number;
      y: number;
      width?: number;
      height?: number;
      imageBase64?: string;
      text?: string;
      fontSize?: number;
    }>;
  }, context: functions.https.CallableContext) => {
  const pdfBase64 = (data?.pdfBase64 || '').toString().trim();
  const fileUrl = (data?.fileUrl || '').toString().trim();
  const signaturePngBase64 = (data?.signaturePngBase64 || '').toString().trim();
  const signerName = (data?.signerName || '').toString().trim();
  const signerDate = (data?.signerDate || '').toString().trim();
  const placements = (data?.placements || []) as Array<{
    type: 'image' | 'text';
    pageIndex: number;
    x: number;
    y: number;
    width?: number;
    height?: number;
    imageBase64?: string;
    text?: string;
    fontSize?: number;
  }>;

  if (!pdfBase64 && !fileUrl) {
    throw new functions.https.HttpsError('invalid-argument', 'pdfBase64 or fileUrl is required');
  }

  // Require auth or valid signing token (same as uploadSignedContract)
  const signingToken = (data as any)?.signingToken?.toString?.()?.trim() || '';
  if (!context.auth?.uid && !signingToken) {
    throw new functions.https.HttpsError('unauthenticated', 'Authentication or signing token required');
  }

  try {
    let pdfBytes: Buffer;
    if (pdfBase64) {
      pdfBytes = Buffer.from(pdfBase64, 'base64');
    } else if (fileUrl) {
      const resp = await fetch(fileUrl);
      if (!resp.ok) {
        throw new functions.https.HttpsError('internal', `Failed to fetch PDF: ${resp.status} ${resp.statusText}`);
      }
      const arrayBuf = await resp.arrayBuffer();
      pdfBytes = Buffer.from(arrayBuf);
    } else {
      throw new functions.https.HttpsError('invalid-argument', 'pdfBase64 or fileUrl is required');
    }
    if (pdfBytes.length > 10 * 1024 * 1024) { // 10MB limit
      throw new functions.https.HttpsError('invalid-argument', 'PDF too large (max 10MB)');
    }

    const pdfDoc = await PDFDocument.load(pdfBytes);
    const pages = pdfDoc.getPages();

    if (pages.length === 0) {
      throw new functions.https.HttpsError('invalid-argument', 'PDF has no pages');
    }

    // Build placements: if none provided, add default signature + name + date on last page
    const finalPlacements: Array<{ type: 'image' | 'text'; pageIndex: number; x: number; y: number; width?: number; height?: number; imageBase64?: string; text?: string; fontSize?: number }> = placements.length > 0
      ? placements
      : [];

    if (finalPlacements.length === 0 && signaturePngBase64) {
      const lastPageIndex = pages.length - 1;
      const page = pages[lastPageIndex];
      const { width, height } = page.getSize();
      const defaultY = 100;
      const defaultX = 50;
      const sigW = 150;
      const sigH = 60;

      const pngBytes = Buffer.from(signaturePngBase64, 'base64');
      const pngImage = await pdfDoc.embedPng(pngBytes);
      page.drawImage(pngImage, { x: defaultX, y: defaultY, width: sigW, height: sigH });

      if (signerName) {
        page.drawText(signerName, { x: defaultX, y: defaultY + sigH + 8, size: 11 });
      }
      if (signerDate) {
        page.drawText(signerDate, { x: defaultX, y: defaultY + sigH + 20, size: 10 });
      }
    } else {
      for (const p of finalPlacements) {
        const pageIndex = Math.max(0, Math.min(p.pageIndex, pages.length - 1));
        const page = pages[pageIndex];
        if (p.type === 'image') {
          const b64 = p.imageBase64 || signaturePngBase64;
          if (b64) {
            const imgBytes = Buffer.from(b64, 'base64');
            const img = await pdfDoc.embedPng(imgBytes);
            const w = p.width ?? 150;
            const h = p.height ?? 60;
            page.drawImage(img, { x: p.x, y: p.y, width: w, height: h });
          }
        } else if (p.type === 'text' && p.text) {
          page.drawText(p.text, { x: p.x, y: p.y, size: p.fontSize ?? 11 });
        }
      }
    }

    const mergedPdfBytes = await pdfDoc.save();
    return { pdfBase64: Buffer.from(mergedPdfBytes).toString('base64') };
  } catch (err: any) {
    functions.logger.error('mergeSignatureIntoPdf error:', err?.message);
    if (err instanceof functions.https.HttpsError) throw err;
    throw new functions.https.HttpsError('internal', `Failed to merge: ${err?.message || 'Unknown error'}`);
  }
});

// ============================================================================
// STRIPE CONFIG FUNCTIONS
// ============================================================================

/**
 * Get Stripe publishable key (platform key only; safe to expose to clients).
 * Uses Firebase secrets and validates TEST/LIVE consistency.
 */
export const getStripePublishableKey = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (_data, _context) => {
  try {
    const publishableKey = getPlatformPublishableKey();
    return { publishableKey };
  } catch (error: any) {
    functions.logger.error('Error getting Stripe publishable key:', { message: error?.message });
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    throw new functions.https.HttpsError('internal', 'Stripe publishable key is not configured or key mode mismatch.');
  }
});

// ============================================================================
// 2FA - EMAIL OTP FUNCTIONS
// ============================================================================

/**
 * Generate and send OTP code via email
 * 
 * This function:
 * 1. Generates a 6-digit OTP code
 * 2. Stores it in Firestore with expiration (10 minutes)
 * 3. Sends it via SendGrid email
 * 4. Updates user's lastOTPSentAt timestamp
 * 
 * Rate limiting: Max 1 OTP per 45 seconds per user. lastOTPSentAt is updated only
 * after a successful email send, so failed sends do not rate-limit the user.
 */
export const generateOTP = functions.runWith({ secrets: SENDGRID_SECRETS }).https.onCall(
  async (data: { purpose?: string }, context) => {
    try {
      if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
      }
      enforceAppCheckOrThrow(context);

      const userId = context.auth.uid;
      const userEmail = context.auth.token.email;
      const purpose = data.purpose || 'sensitive_action';

      if (!userEmail) {
        throw new functions.https.HttpsError('invalid-argument', 'User email is required');
      }

      // Get user document
      const userDoc = await admin.firestore().collection('users').doc(userId).get();
      if (!userDoc.exists) {
        throw new functions.https.HttpsError('not-found', 'User not found');
      }

      const userData = userDoc.data()!;
      const lastOTPSentAt = userData.lastOTPSentAt as admin.firestore.Timestamp | null;

      // Rate limiting: Max 1 OTP per 45 seconds (only applies after a *successful* send)
      const COOLDOWN_SECONDS = 45;
      if (lastOTPSentAt) {
        const secondsSinceLastOTP = (Date.now() - lastOTPSentAt.toMillis()) / 1000;
        if (secondsSinceLastOTP < COOLDOWN_SECONDS) {
          const remainingSeconds = Math.ceil(COOLDOWN_SECONDS - secondsSinceLastOTP);
          throw new functions.https.HttpsError(
            'resource-exhausted',
            `Please wait ${remainingSeconds} seconds before requesting another OTP code. You can request a new code in ${remainingSeconds} second${remainingSeconds !== 1 ? 's' : ''}.`,
          );
        }
      }

      // Generate 6-digit OTP code
      const otpCode = Math.floor(100000 + Math.random() * 900000).toString();
      const expiresAt = new Date(Date.now() + 10 * 60 * 1000); // 10 minutes from now

      // Store OTP in Firestore
      const otpId = `otp-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
      await admin.firestore()
        .collection('users')
        .doc(userId)
        .collection('otpCodes')
        .doc(otpId)
        .set({
          code: otpCode,
          purpose: purpose,
          expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          used: false,
        });

      // Send OTP via email using SendGrid *before* updating lastOTPSentAt.
      // Only rate-limit when we've actually sent an email; if send fails, user can retry immediately.
      initializeSendGrid();

      const emailSubject = 'Your Verification Code';
      const emailHtml = `
        <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
          <h2 style="color: #333;">Verification Code</h2>
          <p>Your verification code is:</p>
          <div style="background-color: #f5f5f5; padding: 20px; text-align: center; margin: 20px 0; border-radius: 5px;">
            <h1 style="color: #0066cc; font-size: 32px; margin: 0; letter-spacing: 5px;">${otpCode}</h1>
          </div>
          <p>This code will expire in 10 minutes.</p>
          <p style="color: #666; font-size: 12px;">If you didn't request this code, please ignore this email.</p>
        </div>
      `;
      const emailText = `Your verification code is: ${otpCode}\n\nThis code will expire in 10 minutes.\n\nIf you didn't request this code, please ignore this email.`;

      const msg = {
        to: userEmail,
        from: {
          email: SENDGRID_FROM_EMAIL.value(),
          name: SENDGRID_FROM_NAME.value(),
        },
        subject: emailSubject,
        html: emailHtml,
        text: emailText,
      };

      await sgMail.send(msg);

      // Update lastOTPSentAt only *after* successful send so failed sends don't rate-limit the user.
      await admin.firestore()
        .collection('users')
        .doc(userId)
        .update({
          lastOTPSentAt: admin.firestore.FieldValue.serverTimestamp(),
        });

      functions.logger.info(`OTP generated and sent to user ${userId} (${userEmail})`);

      return {
        success: true,
        message: 'OTP code sent to your email',
        expiresIn: 600, // 10 minutes in seconds
      };
    } catch (error: any) {
      functions.logger.error('Error generating OTP:', error);
      if (error instanceof functions.https.HttpsError) {
        throw error;
      }
      throw new functions.https.HttpsError('internal', `Failed to generate OTP: ${error.message}`);
    }
  },
);

/**
 * Verify OTP code
 * 
 * This function:
 * 1. Finds the most recent unused OTP for the user
 * 2. Checks if it matches and hasn't expired
 * 3. Marks it as used
 * 4. Returns success if valid
 */
export const verifyOTP = functions.https.onCall(
  async (data: { code: string; purpose?: string }, context) => {
    try {
      if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
      }
      enforceAppCheckOrThrow(context);

      const userId = context.auth.uid;
      const { code, purpose } = data;

      if (!code || code.length !== 6 || !/^\d+$/.test(code)) {
        throw new functions.https.HttpsError('invalid-argument', 'OTP code must be a 6-digit number');
      }

      // Find the most recent unused OTP for this user
      // Use try-catch for the query in case index is missing
      let otpQuery;
      try {
        otpQuery = await admin.firestore()
          .collection('users')
          .doc(userId)
          .collection('otpCodes')
          .where('used', '==', false)
          .where('purpose', '==', purpose || 'sensitive_action')
          .orderBy('createdAt', 'desc')
          .limit(1)
          .get();
      } catch (queryError: any) {
        // If index is missing, try without orderBy (less efficient but works)
        if (queryError.message && queryError.message.includes('index')) {
          functions.logger.warn('Composite index missing, using fallback query');
          otpQuery = await admin.firestore()
            .collection('users')
            .doc(userId)
            .collection('otpCodes')
            .where('used', '==', false)
            .where('purpose', '==', purpose || 'sensitive_action')
            .get();
          
          // Sort in memory by createdAt
          if (!otpQuery.empty) {
            const sortedDocs = otpQuery.docs.sort((a, b) => {
              const aTime = (a.data().createdAt as admin.firestore.Timestamp)?.toMillis() || 0;
              const bTime = (b.data().createdAt as admin.firestore.Timestamp)?.toMillis() || 0;
              return bTime - aTime; // Descending
            });
            // Create a new QuerySnapshot-like object with sorted docs
            otpQuery = {
              empty: sortedDocs.length === 0,
              docs: sortedDocs.slice(0, 1), // Take only the first one
            } as any;
          }
        } else {
          throw queryError;
        }
      }

      if (otpQuery.empty) {
        throw new functions.https.HttpsError('not-found', 'No valid OTP code found. Please request a new code.');
      }

      const otpDoc = otpQuery.docs[0];
      const otpData = otpDoc.data();
      
      // Validate data exists
      if (!otpData.expiresAt) {
        functions.logger.error('OTP document missing expiresAt field', { userId, otpId: otpDoc.id });
        throw new functions.https.HttpsError('internal', 'OTP data is invalid. Please request a new code.');
      }
      
      const expiresAt = (otpData.expiresAt as admin.firestore.Timestamp).toDate();

      // Check if expired
      if (expiresAt < new Date()) {
        // Mark as used to prevent reuse
        await otpDoc.ref.update({ used: true });
        throw new functions.https.HttpsError('deadline-exceeded', 'OTP code has expired. Please request a new code.');
      }

      // Check if code matches (ensure both are strings for comparison)
      const storedCode = String(otpData.code || '');
      const providedCode = String(code || '');
      
      if (storedCode !== providedCode) {
        functions.logger.warn('OTP code mismatch', { 
          userId, 
          storedCode: storedCode.substring(0, 2) + '****', // Log partial for security
          providedCodeLength: providedCode.length, 
        });
        throw new functions.https.HttpsError('permission-denied', 'Invalid OTP code. Please try again.');
      }

      // Mark as used
      await otpDoc.ref.update({ used: true });

      // Clean up old OTP codes (older than 1 hour)
      const oneHourAgo = admin.firestore.Timestamp.fromDate(new Date(Date.now() - 60 * 60 * 1000));
      const oldOtpsQuery = await admin.firestore()
        .collection('users')
        .doc(userId)
        .collection('otpCodes')
        .where('createdAt', '<', oneHourAgo)
        .get();

      const batch = admin.firestore().batch();
      oldOtpsQuery.docs.forEach((doc) => {
        batch.delete(doc.ref);
      });
      if (!oldOtpsQuery.empty) {
        await batch.commit();
      }

      functions.logger.info(`OTP verified successfully for user ${userId}`);

      return {
        success: true,
        message: 'OTP code verified successfully',
      };
    } catch (error: any) {
      functions.logger.error('Error verifying OTP:', error);
      if (error instanceof functions.https.HttpsError) {
        throw error;
      }
      throw new functions.https.HttpsError('internal', `Failed to verify OTP: ${error.message}`);
    }
  },
);

// Export diagnostic function to fix ownership issues after subscription
export { diagnosticFixOwnership };

// Export facility stats functions for automatic dashboard updates
import * as facilityStatsModule from './facility_stats';
export const onTenantWrite = facilityStatsModule.onTenantWrite;
export const onUnitWrite = facilityStatsModule.onUnitWrite;
export const updateAllFacilityStatsNightly = facilityStatsModule.updateAllFacilityStatsNightly;
export const updateFacilityStatsManual = facilityStatsModule.updateFacilityStatsManual;

// Manager Overlock callables (manager/admin only)
import * as overlockModule from './overlock';
export const setUnitOverlockStatus = overlockModule.setUnitOverlockStatus;
export const setUnitsOverlockStatusBulk = overlockModule.setUnitsOverlockStatusBulk;
export const overlockAllDelinquent = overlockModule.overlockAllDelinquent;
export const clearOverlockByFilter = overlockModule.clearOverlockByFilter;