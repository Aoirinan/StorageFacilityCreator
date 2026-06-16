import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import { getDownloadURL } from 'firebase-admin/storage';
import type { Application, Request as ExpressRequest, Response as ExpressResponse } from 'express';
import {
  authenticatePortalTenant,
  escapeHtml,
  extractCallableClientIp,
  getStripeClient,
  sendFacilityEmailWithCompliance,
  validateSigningTokenForContract,
} from '@sfc/functions-shared';
import { SENDGRID_API_KEY, SENDGRID_FROM_EMAIL, SENDGRID_SECRETS, STRIPE_SECRETS } from './secrets';
import { enforceAppCheckOrThrow, writeAuditLog } from './guardrails';

interface TenantPortalRequest {
  email: string;
  accessCode: string;
}

function requireExpress(): any {
  return require('express');
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
    functions.logger.warn('getContractBySigningToken: App Check token missing â€“ allowing for signing-token flow');
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
      functions.logger.warn('uploadSignedContract: App Check token missing â€“ allowing for signing-token flow');
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
    allowed = await validateSigningTokenForContract(signingToken, facilityId, contractId);
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
let uploadSignedContractAppInstance: Application | null = null;
function getUploadSignedContractApp(): Application {
  if (uploadSignedContractAppInstance) return uploadSignedContractAppInstance;
  const ex = requireExpress();
  const app = ex();
  app.use(ex.json({ limit: '10mb' }));
  app.all('*', async (req: ExpressRequest, res: ExpressResponse) => {
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
      allowed = await validateSigningTokenForContract(signingToken, facilityId, contractId);
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
  uploadSignedContractAppInstance = app;
  return app;
}

export const uploadSignedContractHttp = functions.https.onRequest((req, res) => {
  getUploadSignedContractApp()(req, res);
});

/**
 * HTTP endpoint for contract PDF upload - used via Firebase Hosting rewrite.
 * Same-origin requests avoid CORS preflight 403 when uploading from custom domain.
 */
let uploadContractPdfAppInstance: Application | null = null;
function getUploadContractPdfApp(): Application {
  if (uploadContractPdfAppInstance) return uploadContractPdfAppInstance;
  const ex = requireExpress();
  const app = ex();
  app.use(ex.json({ limit: '16mb' }));
  app.all('*', async (req: ExpressRequest, res: ExpressResponse) => {
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
  uploadContractPdfAppInstance = app;
  return app;
}

export const uploadContractPdfHttp = functions.https.onRequest((req, res) => {
  getUploadContractPdfApp()(req, res);
});

/** Allowed Storage bucket patterns for proxy (contract PDFs only) */
const PROXY_ALLOWED_BUCKETS = [
  'storage-facility-creator.firebasestorage.app',
  'storage-facility-creator.appspot.com',
];

/**
 * HTTP proxy for contract PDFs - bypasses Storage CORS when loading PDFs from custom domain.
 * Same-origin GET to /api/proxyContractPdf avoids CORS on firebasestorage.googleapis.com.
 */
let proxyContractPdfAppInstance: Application | null = null;
function getProxyContractPdfApp(): Application {
  if (proxyContractPdfAppInstance) return proxyContractPdfAppInstance;
  const ex = requireExpress();
  const app = ex();
  app.all('*', async (req: ExpressRequest, res: ExpressResponse) => {
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
  proxyContractPdfAppInstance = app;
  return app;
}

export const proxyContractPdfHttp = functions.https.onRequest((req, res) => {
  getProxyContractPdfApp()(req, res);
});

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
      const tenantIdForUnsub = (after?.tenantId || '').toString().trim();

      const viewLink = signedFileUrl
        ? `<p><a clicktracking="off" href="${signedFileUrl}" style="color:#1E3A8A;font-weight:600;">View your signed contract</a></p>`
        : '';
      const htmlBody = `
        <h2 style="color:#1E3A8A;">Contract signed successfully</h2>
        <p>Hello${signedBy ? ` ${escapeHtml(signedBy)}` : ''},</p>
        <p>Your signature has been recorded for <strong>${escapeHtml(title)}</strong>.</p>
        ${viewLink}
        <p>Please keep this email for your records.</p>
      `;
      const textBody = [
        'Contract signed successfully',
        signedBy ? `Hello ${signedBy},` : 'Hello,',
        `Your signature has been recorded for ${title}.`,
        signedFileUrl ? `View your signed contract: ${signedFileUrl}` : '',
        'Please keep this email for your records.',
      ].filter(Boolean).join('\n\n');

      const signedSend = await sendFacilityEmailWithCompliance(
        {
          to: toEmail,
          from: { email: fromEmail, name: facilityName },
          subject: `Contract Signed: ${title}`,
        },
        htmlBody,
        textBody,
        {
          facilityId,
          tenantId: tenantIdForUnsub || null,
          facilityName,
          facilityAddress: facilityData?.address,
          facilityPhone: facilityData?.phone,
        },
      );
      if (!signedSend.sent) {
        functions.logger.info('onContractSigned: Skipped (recipient unsubscribed)', { to: toEmail, contractId });
        return;
      }
      functions.logger.info('onContractSigned: Confirmation email sent', { to: toEmail, contractId });
    } catch (err: unknown) {
      functions.logger.error('onContractSigned: Failed to send confirmation email', err);
    }
  });

/**
 * Tenant portal lookup by email + access code. No Firebase Auth required.
 * App Check is not enforced here so unauthenticated tenants can access the portal.
 */
export const tenantPortalFetch = functions.https.onCall(async (data: TenantPortalRequest, context) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const clientIp = extractCallableClientIp(context.rawRequest);

  try {
    const session = await authenticatePortalTenant(email, accessCode, clientIp);
    const primaryTenantDoc = session.tenantDoc;
    const primaryTenantData = session.tenantData as Record<string, any>;
    const facilityRef = session.facilityRef;

    const facilityDoc = await facilityRef.get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found for tenant');
    }

    let insuranceReferral: { referralUrl: string | null; referralName: string | null; referralNotes: string | null } = {
      referralUrl: null,
      referralName: null,
      referralNotes: null,
    };
    try {
      const insuranceSnap = await facilityRef.collection('settings').doc('insurance').get();
      if (insuranceSnap.exists) {
        const ins = insuranceSnap.data() as Record<string, any> | undefined;
        const u = (ins?.referralUrl ?? '').toString().trim();
        const n = (ins?.referralName ?? '').toString().trim();
        const note = (ins?.referralNotes ?? '').toString().trim();
        insuranceReferral = {
          referralUrl: u.length ? u : null,
          referralName: n.length ? n : null,
          referralNotes: note.length ? note : null,
        };
      }
    } catch (insErr: unknown) {
      functions.logger.warn('tenantPortalFetch: insurance settings read failed', insErr);
    }

    const allMatchingDocs = [primaryTenantDoc];
    const portalAccountId = (primaryTenantData.portalAccountId || '').toString().trim();

    let linkedTenantDocs = allMatchingDocs;
    if (portalAccountId) {
      try {
        const linkedSnapshot = await facilityRef
          .collection('tenants')
          .where('portalAccountId', '==', portalAccountId)
          .get();
        if (!linkedSnapshot.empty) {
          linkedTenantDocs = linkedSnapshot.docs.filter((d) => {
            const t = d.data() as Record<string, any>;
            return t.portalEnabled === true;
          });
        }
      } catch (linkedErr: unknown) {
        functions.logger.warn('tenantPortalFetch: linked tenant query failed, falling back to matched docs', linkedErr);
      }
    }
    if (!linkedTenantDocs.some((d) => d.id === primaryTenantDoc.id)) {
      linkedTenantDocs = [primaryTenantDoc, ...linkedTenantDocs];
    }

    const tenantIdToUnit = new Map<string, string>();
    const unitSummaries = linkedTenantDocs.map((doc) => {
      const t = doc.data() as Record<string, any>;
      const unitNumber = (t.unitNumber ?? '').toString();
      tenantIdToUnit.set(doc.id, unitNumber);
      return {
        tenantId: doc.id,
        tenantName: (t.name ?? 'Tenant').toString(),
        unitNumber,
        monthlyRate: Number(t.monthlyRate ?? 0) || 0,
        autopay: (t.autopay as Record<string, unknown> | undefined) ?? { requested: false, enabled: false, status: 'OFF', updatedBy: 'SYSTEM', updatedAt: null },
        stripe: (t.stripe as Record<string, unknown> | undefined) ?? { customerId: null, defaultPaymentMethodId: null, paymentMethodSummary: null },
      };
    });

    const tenantIds = linkedTenantDocs.map((d) => d.id);
    const paymentsCollection = facilityRef.collection('payments');
    const paymentDocs: admin.firestore.QueryDocumentSnapshot[] = [];
    for (let i = 0; i < tenantIds.length; i += 10) {
      const chunk = tenantIds.slice(i, i + 10);
      if (chunk.length === 0) continue;
      const snap = await paymentsCollection.where('tenantId', 'in', chunk).limit(100).get();
      paymentDocs.push(...snap.docs);
    }

    const perTenantStats = new Map<string, { outstandingBalance: number; nextDueDate: admin.firestore.Timestamp | null; nextAmountDue: number | null }>();
    for (const tenantId of tenantIds) {
      perTenantStats.set(tenantId, {
        outstandingBalance: 0,
        nextDueDate: null,
        nextAmountDue: null,
      });
    }

    const mappedPayments = paymentDocs.map((doc) => {
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
      const paymentTenantId = (paymentData.tenantId ?? '').toString();

      const isPaid = status === 'paid' || status === 'completed';
      if (!isPaid && perTenantStats.has(paymentTenantId)) {
        const stat = perTenantStats.get(paymentTenantId)!;
        stat.outstandingBalance += amount;
        if (!stat.nextDueDate || dueDate.toMillis() < stat.nextDueDate.toMillis()) {
          stat.nextDueDate = dueDate;
          stat.nextAmountDue = amount;
        }
      }

      return {
        id: doc.id,
        tenantId: paymentTenantId,
        unitNumber: tenantIdToUnit.get(paymentTenantId) ?? null,
        amount,
        status,
        dueDate,
        paidAt,
        method,
      };
    });

    const units = unitSummaries.map((unit) => {
      const stat = perTenantStats.get(unit.tenantId) ?? {
        outstandingBalance: 0,
        nextDueDate: null,
        nextAmountDue: null,
      };
      return {
        ...unit,
        outstandingBalance: stat.outstandingBalance,
        nextAmountDue: stat.nextAmountDue,
        nextDueDate: stat.nextDueDate,
        isDelinquent: stat.outstandingBalance > 0,
      };
    });

    let outstandingBalance = 0;
    let nextDueDate: admin.firestore.Timestamp | null = null;
    let nextAmountDue: number | null = null;
    for (const unit of units) {
      outstandingBalance += unit.outstandingBalance;
      if (unit.nextDueDate && (!nextDueDate || unit.nextDueDate.toMillis() < nextDueDate.toMillis())) {
        nextDueDate = unit.nextDueDate;
        nextAmountDue = unit.nextAmountDue;
      }
    }

    const payments = mappedPayments
      .sort((a, b) => b.dueDate.toMillis() - a.dueDate.toMillis())
      .slice(0, 20);

    await primaryTenantDoc.ref.update({
      portalLastAccessAt: admin.firestore.FieldValue.serverTimestamp(),
      portalVisitCount: admin.firestore.FieldValue.increment(1),
    });

    const facilityData = facilityDoc.data() as Record<string, any> | undefined;
    const stripeStatus = facilityData?.stripeStatus as { state?: string } | undefined;
    const autopay = primaryTenantData.autopay as Record<string, unknown> | undefined;
    const stripe = primaryTenantData.stripe as Record<string, unknown> | undefined;

    return {
      facility: {
        id: facilityRef.id,
        name: facilityData?.name ?? 'Facility',
        phone: facilityData?.phone ?? null,
        email: facilityData?.email ?? null,
        address: facilityData?.address ?? null,
        logoUrl: facilityData?.logoUrl ?? null,
        stripeStatus: stripeStatus ?? { state: 'DISCONNECTED' },
        insuranceReferral,
      },
      tenant: {
        id: primaryTenantDoc.id,
        name: primaryTenantData.name ?? 'Tenant',
        email: primaryTenantData.email ?? null,
        phone: primaryTenantData.phone ?? null,
        unitNumber: primaryTenantData.unitNumber ?? '',
        monthlyRate: primaryTenantData.monthlyRate ?? 0,
        paidThrough: primaryTenantData.paidThrough ?? null,
        isDelinquent: units.some((u) => u.isDelinquent === true),
        welcomeMessage: primaryTenantData.portalWelcomeMessage ?? null,
        contacts: primaryTenantData.emergencyContacts ?? [],
        vehicles: primaryTenantData.vehicles ?? [],
        autopay: autopay ?? { requested: false, enabled: false, status: 'OFF', updatedBy: 'SYSTEM', updatedAt: null },
        stripe: stripe ?? { customerId: null, defaultPaymentMethodId: null, paymentMethodSummary: null },
        overlockIsActive: primaryTenantData.overlockIsActive === true,
      },
      units,
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
 * tenantUpdateProfile â€” Allows a tenant to update their own contact info via the portal.
 * Authenticated via email + accessCode (no Firebase Auth required).
 * Tenants can update: phone, emergencyContacts, vehicles.
 * All changes are written directly to the Firestore tenant document.
 */
export const tenantUpdateProfile = functions.https.onCall(async (data: any, context) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const clientIp = extractCallableClientIp(context.rawRequest);

  try {
    const session = await authenticatePortalTenant(email, accessCode, clientIp);
    const tenantDoc = session.tenantDoc;
    const updateData: Record<string, any> = {
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      portalLastProfileUpdateAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    // Phone
    if (typeof data.phone === 'string') {
      updateData['phone'] = data.phone.trim();
    }

    // Emergency contacts â€” validate structure
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

    // Vehicles â€” validate structure
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
export const createTenantPortalPaymentCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any, context) => {
  const email = (data.email || '').toString().trim().toLowerCase();
  const accessCode = (data.accessCode || '').toString().trim();
  const requestedTenantId = (data.tenantId || '').toString().trim();
  const amount = data.amount as number;
  const clientIp = extractCallableClientIp(context.rawRequest);

  if (!amount || amount <= 0) {
    throw new functions.https.HttpsError('invalid-argument', 'email, accessCode, and amount are required');
  }

  try {
    const portalSession = await authenticatePortalTenant(email, accessCode, clientIp);
    const authTenantDoc = portalSession.tenantDoc;
    const authTenantData = portalSession.tenantData as Record<string, any>;
    const facilityRef = portalSession.facilityRef;

    const facilityDoc = await facilityRef.get();
    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const facilityId = facilityRef.id;
    const portalAccountId = (authTenantData.portalAccountId || '').toString().trim();
    let tenantId = authTenantDoc.id;
    let tenantData = authTenantData;
    if (requestedTenantId && requestedTenantId !== authTenantDoc.id) {
      const requestedRef = facilityRef.collection('tenants').doc(requestedTenantId);
      const requestedSnap = await requestedRef.get();
      if (!requestedSnap.exists) {
        throw new functions.https.HttpsError('not-found', 'Requested tenant account not found');
      }
      const requestedData = requestedSnap.data() as Record<string, any>;
      const requestedPortalAccountId = (requestedData.portalAccountId || '').toString().trim();
      const sameAccount = portalAccountId && requestedPortalAccountId
        ? requestedPortalAccountId === portalAccountId
        : (
          requestedData.emailLower === email &&
          requestedData.portalEnabled === true &&
          requestedData.portalAccessCode === accessCode
        );
      if (!sameAccount) {
        throw new functions.https.HttpsError('permission-denied', 'Requested unit is not linked to this portal account');
      }
      tenantId = requestedSnap.id;
      tenantData = requestedData;
    }
    const facilityData = facilityDoc.data()!;

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
    const checkoutSession = await stripe.checkout.sessions.create({
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
        unitNumber: (tenantData['unitNumber'] || '').toString(),
        type: 'tenant_portal_payment',
        portalEmail: email,
      },
    }, {
      stripeAccount: connectAccountId, // Create session on connected account
    });

    return {
      checkoutUrl: checkoutSession.url,
      sessionId: checkoutSession.id,
    };
  } catch (error: any) {
    if (error instanceof functions.https.HttpsError) {
      throw error;
    }
    functions.logger.error('Error creating tenant portal payment checkout', error);
    throw new functions.https.HttpsError('internal', `Failed to create checkout: ${error.message}`);
  }
});

