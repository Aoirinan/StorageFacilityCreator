import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import {
  buildPortalAccessCodeReminderEmail,
  enforcePortalAuthRateLimit,
  extractCallableClientIp,
  generatePortalAccessCode,
  getPublicAppUrl,
  initializeSendGrid,
  maskEmail,
  recordPortalAuthFailure,
  sendFacilityEmailWithCompliance,
} from '@sfc/functions-shared';
import { SENDGRID_FROM_EMAIL, SENDGRID_FROM_NAME, SENDGRID_SECRETS } from './secrets';

/** A phone can belong to more than one unit; cap the fan-out per request. */
const MAX_RECORDS_PER_REQUEST = 3;

const GENERIC_MESSAGE =
  'If we found a tenant account for that, we sent the access code to the email on file. It can take a minute to arrive.';

function phoneVariants(raw: string): string[] {
  const digits = raw.replace(/\D/g, '');
  if (digits.length < 7) return [];
  const national = digits.length === 11 && digits.startsWith('1') ? digits.slice(1) : digits;
  return [...new Set([raw.trim(), digits, national, `1${national}`, `+1${national}`])];
}

async function findTenantsByEmail(emailLower: string): Promise<admin.firestore.QueryDocumentSnapshot[]> {
  // The only collection-group index on tenants that covers emailLower is the
  // portal login's (emailLower, portalEnabled, portalAccessCode). Firestore
  // will not serve a two-field prefix of it, but ordering by the third field
  // makes the query match the index exactly, so this works without adding
  // another index. Verified against the live database on 2026-09-15.
  const snap = await admin
    .firestore()
    .collectionGroup('tenants')
    .where('emailLower', '==', emailLower)
    .where('portalEnabled', '==', true)
    .orderBy('portalAccessCode')
    .limit(MAX_RECORDS_PER_REQUEST)
    .get();
  return snap.docs;
}

async function findTenantsByPhone(raw: string): Promise<admin.firestore.QueryDocumentSnapshot[]> {
  const found = new Map<string, admin.firestore.QueryDocumentSnapshot>();
  const db = admin.firestore();
  // (isActive, phone) is the only collection-group index covering phone, so
  // the query has to pin isActive. The portal itself lets a moved-out tenant
  // sign in (to see history and pay a balance), so look on both sides.
  for (const variant of phoneVariants(raw)) {
    for (const isActive of [true, false]) {
      const snap = await db
        .collectionGroup('tenants')
        .where('isActive', '==', isActive)
        .where('phone', '==', variant)
        .limit(MAX_RECORDS_PER_REQUEST)
        .get();
      for (const d of snap.docs) found.set(d.ref.path, d);
    }
    if (found.size >= MAX_RECORDS_PER_REQUEST) break;
  }
  return [...found.values()].filter((d) => d.get('portalEnabled') === true);
}

/**
 * "Forgot your access code?" on the tenant portal login (which every public
 * facility site links to). Unauthenticated, so it behaves like a password
 * reset: same reply whether or not anything matched, rate-limited per
 * identifier and IP with the portal login limiter, and the code goes only to
 * the email already on the tenant record, never to the address typed in.
 *
 * Delivery is email for now. When Twilio texting is live, add an SMS to the
 * phone on file here; the lookup by phone is already in place.
 */
export const requestPortalAccessCodeReminder = functions
  .runWith({ secrets: SENDGRID_SECRETS })
  .https.onCall(async (data: { identifier?: string }, context) => {
    const identifier = (data?.identifier || '').toString().trim();
    if (!identifier) {
      throw new functions.https.HttpsError('invalid-argument', 'Enter your email or phone number');
    }
    const key = identifier.toLowerCase();
    const clientIp = extractCallableClientIp(context.rawRequest);
    await enforcePortalAuthRateLimit(key, clientIp);

    const isEmail = identifier.includes('@');
    let docs: admin.firestore.QueryDocumentSnapshot[] = [];
    try {
      docs = isEmail ? await findTenantsByEmail(key) : await findTenantsByPhone(identifier);
    } catch (error) {
      functions.logger.error('Access code reminder lookup failed', {
        error: error instanceof Error ? error.message : String(error),
      });
    }
    docs = docs.filter((d) => ((d.get('email') as string | undefined) || '').trim()).slice(0, MAX_RECORDS_PER_REQUEST);

    if (docs.length === 0) {
      // Counts toward the same lockout as a bad login, so guessing is expensive.
      await recordPortalAuthFailure(key, clientIp);
      functions.logger.info('Access code reminder: no match', { byEmail: isEmail });
      return { ok: true, message: GENERIC_MESSAGE };
    }

    initializeSendGrid();
    const portalUrl = `${getPublicAppUrl()}/#/tenant-portal`;
    let deliveredTo = '';

    for (const doc of docs) {
      const t = doc.data() as Record<string, unknown>;
      const email = String(t.email).trim();
      const facilityRef = doc.ref.parent.parent;
      if (!facilityRef) continue;
      const facilitySnap = await facilityRef.get();
      const facility = (facilitySnap.data() || {}) as Record<string, unknown>;

      let accessCode = ((t.portalAccessCode as string | undefined) || '').trim();
      if (!accessCode) {
        accessCode = generatePortalAccessCode();
        await doc.ref.update({ portalAccessCode: accessCode, updatedAt: admin.firestore.FieldValue.serverTimestamp() });
      }

      const facilityName = ((facility.name as string | undefined) || 'Your storage facility').trim();
      const content = buildPortalAccessCodeReminderEmail({
        facilityName,
        tenantName: (t.name as string | undefined) || '',
        unitNumber: (t.unitNumber as string | undefined) || null,
        email,
        accessCode,
        portalUrl,
        facilityPhone: (facility.phone as string | undefined) || null,
        autopayAvailable: false,
      });

      try {
        const result = await sendFacilityEmailWithCompliance(
          {
            to: email,
            from: { email: SENDGRID_FROM_EMAIL.value(), name: facilityName || SENDGRID_FROM_NAME.value() },
            subject: content.subject,
          },
          content.html,
          content.text,
          {
            facilityId: facilityRef.id,
            tenantId: doc.id,
            facilityName,
            facilityAddress: (facility.address as string | undefined) || null,
            facilityPhone: (facility.phone as string | undefined) || null,
          },
        );
        if (result.sent) {
          deliveredTo = deliveredTo || maskEmail(email);
          await doc.ref.update({ portalCodeReminderSentAt: admin.firestore.FieldValue.serverTimestamp() });
        }
        functions.logger.info('Access code reminder processed', {
          facilityId: facilityRef.id,
          tenantId: doc.id,
          sent: result.sent,
          blocked: result.blocked ?? null,
        });
      } catch (error) {
        functions.logger.error('Access code reminder send failed', {
          facilityId: facilityRef.id,
          tenantId: doc.id,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }

    return { ok: true, message: GENERIC_MESSAGE, ...(deliveredTo ? { deliveredTo } : {}) };
  });
