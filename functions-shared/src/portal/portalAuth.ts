import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import * as functions from 'firebase-functions/v1';

const PORTAL_AUTH_RATE_WINDOW_MS = 60 * 1000;
const PORTAL_AUTH_RATE_MAX = 10;
const PORTAL_FAILURE_WINDOW_MS = 15 * 60 * 1000;
const PORTAL_FAILURE_LOCKOUT_THRESHOLD = 5;
const PORTAL_LOCKOUT_MS = 30 * 60 * 1000;

export type PortalTenantSession = {
  tenantDoc: admin.firestore.QueryDocumentSnapshot;
  tenantId: string;
  tenantData: Record<string, unknown>;
  facilityId: string;
  facilityRef: admin.firestore.DocumentReference;
};

/** Extract client IP from a callable HTTP request (supports x-forwarded-for). */
export function extractCallableClientIp(rawRequest?: functions.https.Request): string {
  const ip = rawRequest?.ip || rawRequest?.connection?.remoteAddress || 'unknown';
  const forwarded = rawRequest?.headers?.['x-forwarded-for'];
  return (typeof forwarded === 'string' ? forwarded.split(',')[0].trim() : null) || ip;
}

/** Require portal access codes to meet minimum entropy (aligns with tenant UI generator). */
export function validatePortalAccessCodeFormat(accessCode: string): void {
  const normalized = accessCode.trim().toUpperCase();
  if (normalized.length < 8 || !/^[A-Z2-9]+$/.test(normalized)) {
    throw new functions.https.HttpsError('invalid-argument', 'Invalid portal credentials');
  }
}

function portalDocId(key: string): string {
  return `portalAuth_${crypto.createHash('sha256').update(key).digest('hex').substring(0, 24)}`;
}

async function getRateLimitRef(suffix: string): Promise<admin.firestore.DocumentReference> {
  return admin.firestore().collection('rateLimits').doc(portalDocId(suffix));
}

/** Block brute-force attempts: per-email+IP attempt budget and progressive lockout. */
export async function enforcePortalAuthRateLimit(emailLower: string, clientIp: string): Promise<void> {
  const now = Date.now();
  const lockoutRef = await getRateLimitRef(`lockout_${emailLower}_${clientIp}`);
  const lockoutDoc = await lockoutRef.get();
  if (lockoutDoc.exists) {
    const lockedUntil = (lockoutDoc.data()?.lockedUntil as number) ?? 0;
    if (lockedUntil > now) {
      throw new functions.https.HttpsError(
        'resource-exhausted',
        'Too many failed attempts. Please wait and try again later.',
      );
    }
  }

  const attemptRef = await getRateLimitRef(`attempt_${emailLower}_${clientIp}`);
  const attemptDoc = await attemptRef.get();
  const data = attemptDoc.exists ? (attemptDoc.data() as Record<string, unknown>) : null;
  const windowStart = (data?.windowStart as number) ?? 0;

  if (now - windowStart >= PORTAL_AUTH_RATE_WINDOW_MS) {
    await attemptRef.set({ count: 1, windowStart: now });
    return;
  }

  const count = ((data?.count as number) ?? 0) + 1;
  if (count > PORTAL_AUTH_RATE_MAX) {
    throw new functions.https.HttpsError(
      'resource-exhausted',
      'Too many requests. Please wait a minute and try again.',
    );
  }

  await attemptRef.update({ count: admin.firestore.FieldValue.increment(1) });
}

/** Record a failed portal login; triggers lockout after repeated failures. */
export async function recordPortalAuthFailure(emailLower: string, clientIp: string): Promise<void> {
  const now = Date.now();
  const failureRef = await getRateLimitRef(`failure_${emailLower}_${clientIp}`);
  const failureDoc = await failureRef.get();
  const data = failureDoc.exists ? (failureDoc.data() as Record<string, unknown>) : null;
  const windowStart = (data?.windowStart as number) ?? 0;

  if (now - windowStart >= PORTAL_FAILURE_WINDOW_MS) {
    await failureRef.set({ count: 1, windowStart: now });
    return;
  }

  const count = ((data?.count as number) ?? 0) + 1;
  await failureRef.set({ count, windowStart }, { merge: true });

  if (count >= PORTAL_FAILURE_LOCKOUT_THRESHOLD) {
    const lockoutRef = await getRateLimitRef(`lockout_${emailLower}_${clientIp}`);
    await lockoutRef.set({ lockedUntil: now + PORTAL_LOCKOUT_MS, lockedAt: now });
  }
}

/** Clear failure counters after successful portal authentication. */
export async function clearPortalAuthFailures(emailLower: string, clientIp: string): Promise<void> {
  const batch = admin.firestore().batch();
  for (const suffix of [
    `attempt_${emailLower}_${clientIp}`,
    `failure_${emailLower}_${clientIp}`,
    `lockout_${emailLower}_${clientIp}`,
  ]) {
    batch.delete((await getRateLimitRef(suffix)));
  }
  await batch.commit().catch(() => {
    // Non-fatal if rate-limit docs are missing
  });
}

async function queryTenantByPortalCredentials(
  emailLower: string,
  accessCode: string,
): Promise<admin.firestore.QueryDocumentSnapshot | null> {
  try {
    const snapshot = await admin
      .firestore()
      .collectionGroup('tenants')
      .where('emailLower', '==', emailLower)
      .where('portalEnabled', '==', true)
      .where('portalAccessCode', '==', accessCode)
      .limit(1)
      .get();

    if (!snapshot.empty) {
      return snapshot.docs[0];
    }
  } catch (indexError: unknown) {
    const err = indexError as { code?: number; message?: string };
    if (
      err.code === 9 ||
      (err.message ?? '').includes('indexes') ||
      (err.message ?? '').includes('index')
    ) {
      const fallbackSnapshot = await admin
        .firestore()
        .collectionGroup('tenants')
        .where('emailLower', '==', emailLower)
        .get();
      const matching = fallbackSnapshot.docs.filter((doc) => {
        const d = doc.data();
        return d.portalEnabled === true && d.portalAccessCode === accessCode;
      });
      return matching.length > 0 ? matching[0] : null;
    }
    throw indexError;
  }

  return null;
}

function toPortalSession(tenantDoc: admin.firestore.QueryDocumentSnapshot): PortalTenantSession | null {
  const facilityRef = tenantDoc.ref.parent.parent;
  if (!facilityRef) {
    return null;
  }
  return {
    tenantDoc,
    tenantId: tenantDoc.id,
    tenantData: tenantDoc.data() as Record<string, unknown>,
    facilityId: facilityRef.id,
    facilityRef,
  };
}

/**
 * Authenticate a tenant portal session by email + access code.
 * Applies rate limits and returns tenant/facility context on success.
 */
export async function authenticatePortalTenant(
  email: string,
  accessCode: string,
  clientIp: string,
): Promise<PortalTenantSession> {
  const emailLower = email.trim().toLowerCase();
  const code = accessCode.trim();

  if (!emailLower || !code) {
    throw new functions.https.HttpsError('invalid-argument', 'Email and access code are required');
  }

  validatePortalAccessCodeFormat(code);
  await enforcePortalAuthRateLimit(emailLower, clientIp);

  const tenantDoc = await queryTenantByPortalCredentials(emailLower, code);
  const session = tenantDoc ? toPortalSession(tenantDoc) : null;

  if (!session) {
    await recordPortalAuthFailure(emailLower, clientIp);
    throw new functions.https.HttpsError(
      'not-found',
      'Portal access not found. Verify your email and access code.',
    );
  }

  await clearPortalAuthFailures(emailLower, clientIp);
  return session;
}

/**
 * Same as authenticatePortalTenant but requires the tenant to belong to [facilityId].
 */
export async function authenticatePortalTenantForFacility(
  email: string,
  accessCode: string,
  facilityId: string,
  clientIp: string,
): Promise<PortalTenantSession> {
  const session = await authenticatePortalTenant(email, accessCode, clientIp);
  if (session.facilityId !== facilityId.trim()) {
    throw new functions.https.HttpsError(
      'permission-denied',
      'Facility does not match this portal account',
    );
  }
  return session;
}
