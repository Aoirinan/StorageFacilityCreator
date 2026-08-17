import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import { getDownloadURL } from 'firebase-admin/storage';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
  escapeHtml,
  getStripeClient,
  sendFacilityEmailWithCompliance,
} from '@sfc/functions-shared';
import {
  amountsMatchCents,
  isPublicMoveInStripePaymentRequired,
  loadPublicMoveInChargeQuote,
} from './moveInCharges';
import { SENDGRID_API_KEY, SENDGRID_FROM_EMAIL, STRIPE_SECRETS } from './secrets';
import { optionalStripeCheckoutCustomerEmail } from './stripeHelpers';
import { generateAccessCode } from './accessCode';
import { createAutopayNotificationAndEvent } from './autopayNotification';
import { resolveSmsConsentFields } from './smsConsent';
import { assertOnlineRentalNotOnDnrList } from './dnrScreening';
import { resolveMoveInPaymentStripeAccountId } from './moveInPayment';

/** Public settings → active contract template with PDF, for online move-in. */
async function readOnlineMoveInTemplateBinding(facilityId: string): Promise<{
  templateId: string;
  title: string;
  url: string;
  description: string;
  type: string;
  complianceStatus: string;
  isLicensedForm: boolean;
  documentSha256: string | null;
  fileSize: number | null;
  contentType: string | null;
} | null> {
  try {
    const publicSnap = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('settings')
      .doc('public')
      .get();
    const templateId = String(publicSnap.data()?.onlineMoveInContractTemplateId || '').trim();
    if (!templateId) return null;
    const tSnap = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('contractTemplates')
      .doc(templateId)
      .get();
    if (!tSnap.exists) return null;
    const t = tSnap.data() as Record<string, any>;
    if (t.isActive === false) return null;
    const complianceStatus = String(t.complianceStatus || 'active');
    if (complianceStatus !== 'active') return null;
    const url = String(t.fileUrl || '').trim();
    if (!url) return null;
    return {
      templateId,
      title: (String(t.name || 'Lease agreement').trim()) || 'Lease agreement',
      url,
      description: String(t.description || 'Online self-service move-in').trim(),
      type: (String(t.type || 'storage').trim()) || 'storage',
      complianceStatus,
      isLicensedForm: !!t.isLicensedForm,
      documentSha256: t.documentSha256 != null ? String(t.documentSha256) : null,
      fileSize: typeof t.fileSize === 'number' ? t.fileSize : null,
      contentType: t.contentType != null ? String(t.contentType) : null,
    };
  } catch {
    return null;
  }
}

async function readOnlineMoveInLeaseForFacility(
  facilityId: string,
): Promise<{ title: string; url: string } | null> {
  const b = await readOnlineMoveInTemplateBinding(facilityId);
  if (!b) return null;
  return { title: b.title, url: b.url };
}

const MOVE_IN_TEMPLATE_ALLOWED_BUCKETS = [
  'storage-facility-creator.firebasestorage.app',
  'storage-facility-creator.appspot.com',
];

/** Parse Firebase Storage HTTPS URL → bucket + object path; facility-scoped templates/contracts only. */
function parseAllowedFacilityStorageObject(
  rawUrl: string,
  facilityId: string,
): { bucket: string; objectPath: string } | null {
  const trimmed = rawUrl.trim();
  if (!trimmed) return null;
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return null;
  }
  if (parsed.protocol !== 'https:') return null;
  const host = parsed.hostname || '';
  if (host !== 'firebasestorage.googleapis.com' && host !== 'storage.googleapis.com') {
    return null;
  }
  const pathname = parsed.pathname || '';
  const bucketName = MOVE_IN_TEMPLATE_ALLOWED_BUCKETS.find((b) => pathname.includes(`/b/${b}/`));
  if (!bucketName) return null;
  const objectPathEncoded = pathname.includes('/o/') ? pathname.split('/o/')[1] : '';
  let objectPath = objectPathEncoded || '';
  try {
    objectPath = decodeURIComponent(objectPathEncoded || '');
  } catch {
    objectPath = objectPathEncoded || '';
  }
  const facilityPrefix = `facilities/${facilityId}/`;
  if (!objectPath.startsWith(facilityPrefix)) return null;
  const isTemplateOrContract =
    objectPath.includes('/contractTemplates/') || objectPath.includes('/contracts/');
  if (!isTemplateOrContract) return null;
  return { bucket: bucketName, objectPath };
}

/** Download lease template PDF via Admin SDK (no arbitrary server-side fetch). */
async function downloadTemplatePdfToBuffer(
  url: string,
  facilityId: string,
  expectedSha256: string | null,
): Promise<Buffer | null> {
  try {
    const parsed = parseAllowedFacilityStorageObject(url, facilityId);
    if (!parsed) return null;
    const [buf] = await admin.storage().bucket(parsed.bucket).file(parsed.objectPath).download();
    if (expectedSha256) {
      const actual = crypto.createHash('sha256').update(buf).digest('hex');
      if (actual.toLowerCase() !== expectedSha256.trim().toLowerCase()) {
        functions.logger.warn('Public move-in: template PDF hash mismatch', {
          facilityId,
          expectedSha256,
        });
        return null;
      }
    }
    return buf;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    functions.logger.warn('Public move-in: template PDF download failed', { facilityId, msg });
    return null;
  }
}

/**
 * Public token lookup for reservation flow.
 * This keeps unauthenticated move-in working while Firestore blocks anonymous list queries.
 */
export const getPublicReservationByToken = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  const token = String(data?.token || '').trim();
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(token)) {
    throw new functions.https.HttpsError('invalid-argument', 'Valid token is required');
  }

  const snapshot = await admin.firestore()
    .collection('publicReservations')
    .where('moveInToken', '==', token)
    .where('status', 'in', ['pending', 'confirmed'])
    .limit(1)
    .get();

  if (snapshot.empty) {
    return { found: false };
  }

  const doc = snapshot.docs[0];
  const reservation = doc.data() as Record<string, any>;
  const facilityIdForRateLimit = String(reservation.facilityId || '').trim();
  if (facilityIdForRateLimit) {
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex').slice(0, 16);
    await enforceRateLimit({
      facilityId: facilityIdForRateLimit,
      key: `getPublicReservation_${tokenHash}`,
      limit: 60,
      windowSeconds: 60,
    });
  }
  const expiresAt = reservation.expiresAt as admin.firestore.Timestamp | undefined;
  if (expiresAt && expiresAt.toDate() < new Date()) {
    await doc.ref.set(
      {
        status: 'expired',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return { found: false };
  }

  const facilityIdForLease = String(reservation.facilityId || '').trim();
  const onlineMoveInLease = facilityIdForLease
    ? await readOnlineMoveInLeaseForFacility(facilityIdForLease)
    : null;

  return {
    found: true,
    reservation: {
      id: doc.id,
      facilityId: reservation.facilityId || '',
      unitId: reservation.unitId || null,
      unitNumber: reservation.unitNumber || null,
      email: reservation.email || '',
      phone: reservation.phone || null,
      name: reservation.name || null,
      status: reservation.status || 'pending',
      reservedAt: (reservation.reservedAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() || null,
      expiresAt: expiresAt?.toDate().toISOString() || null,
      moveInDate: (reservation.moveInDate as admin.firestore.Timestamp | undefined)?.toDate().toISOString() || null,
      completedAt: (reservation.completedAt as admin.firestore.Timestamp | undefined)?.toDate().toISOString() || null,
      moveInToken: reservation.moveInToken || null,
      metadata: reservation.metadata || null,
    },
    ...(onlineMoveInLease ? { onlineMoveInLease } : {}),
  };
});

/**
 * Creates a short-lived public reservation hold for a unit.
 * This reduces obvious double-booking races before move-in completion.
 */
export const createPublicReservationHold = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
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

  await enforceRateLimit({
    facilityId: String(facilityId),
    key: 'createPublicReservationHold',
    limit: 30,
    windowSeconds: 60,
    userId: context.auth?.uid || null,
  });

  await assertOnlineRentalNotOnDnrList(admin.firestore(), {
    name: name ? String(name).trim() : '',
    email: String(email).trim().toLowerCase(),
    phone: phone ? String(phone).trim() : '',
  });

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
 * Token-gated public status transition. Public clients may only cancel an
 * active reservation; confirmation and completion remain server-controlled.
 */
export const transitionPublicReservationStatus = functions.https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);

  const reservationId = String(data?.reservationId || '').trim();
  const moveInToken = String(data?.moveInToken || data?.token || '').trim();
  const targetStatus = String(data?.status || '').trim().toLowerCase();
  if (!/^[^/]{1,128}$/.test(reservationId) || !/^[A-Za-z0-9_-]{16,128}$/.test(moveInToken)) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Valid reservationId and moveInToken are required',
    );
  }
  if (targetStatus !== 'cancelled') {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Public reservations may only transition to cancelled',
    );
  }

  const reservationRef = admin.firestore().collection('publicReservations').doc(reservationId);
  const initialSnapshot = await reservationRef.get();
  if (!initialSnapshot.exists) {
    throw new functions.https.HttpsError('not-found', 'Reservation not found');
  }
  const initialReservation = initialSnapshot.data() as Record<string, any>;
  if (initialReservation.moveInToken !== moveInToken) {
    throw new functions.https.HttpsError('permission-denied', 'Invalid token');
  }

  const facilityId = String(initialReservation.facilityId || '').trim();
  if (!facilityId) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Reservation is missing facilityId',
    );
  }
  const tokenHash = crypto.createHash('sha256').update(moveInToken).digest('hex').slice(0, 16);
  await enforceRateLimit({
    facilityId,
    key: `transitionPublicReservation_${tokenHash}`,
    limit: 10,
    windowSeconds: 60,
  });

  await admin.firestore().runTransaction(async (tx) => {
    const reservationSnapshot = await tx.get(reservationRef);
    if (!reservationSnapshot.exists) {
      throw new functions.https.HttpsError('not-found', 'Reservation not found');
    }
    const reservation = reservationSnapshot.data() as Record<string, any>;
    if (reservation.moveInToken !== moveInToken) {
      throw new functions.https.HttpsError('permission-denied', 'Invalid token');
    }

    const currentStatus = String(reservation.status || '');
    if (currentStatus === 'cancelled') {
      return;
    }
    if (currentStatus !== 'pending' && currentStatus !== 'confirmed') {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Reservation can no longer be cancelled',
      );
    }

    const unitId = String(reservation.unitId || '').trim();
    let holdRef: admin.firestore.DocumentReference | null = null;
    if (unitId) {
      holdRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('mapEngine')
        .doc('activeHolds')
        .collection('items')
        .doc(unitId);
      const holdSnapshot = await tx.get(holdRef);
      if (!holdSnapshot.exists || holdSnapshot.data()?.reservationId !== reservationId) {
        holdRef = null;
      }
    }

    tx.update(reservationRef, {
      status: 'cancelled',
      cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    if (holdRef) {
      tx.delete(holdRef);
    }
  });

  return { success: true, status: 'cancelled' };
});

export const createPublicMoveInCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any) => {
  const {
    reservationId,
    token,
    amount,
    description,
  } = data || {};

  if (!reservationId || !token || amount == null) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'reservationId, token, and amount are required',
    );
  }

  const amountNumber = Number(amount);
  if (!Number.isFinite(amountNumber) || amountNumber <= 0) {
    throw new functions.https.HttpsError('invalid-argument', 'amount must be greater than 0');
  }

  const reservationRef = admin.firestore().collection('publicReservations').doc(String(reservationId));
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
  const expiresAt = reservation.expiresAt as admin.firestore.Timestamp | undefined;
  if (expiresAt && expiresAt.toDate() < new Date()) {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation has expired');
  }

  const facilityId = reservation.facilityId as string | undefined;
  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation missing facilityId');
  }

  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data() as Record<string, any>;
  const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
  const onboardingComplete = facilityData.stripeConnectOnboardingComplete as boolean | undefined;
  if (!connectAccountId || !onboardingComplete) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Facility owner must complete Stripe setup before online payments are enabled',
    );
  }

  await assertOnlineRentalNotOnDnrList(admin.firestore(), {
    name: reservation.name ? String(reservation.name).trim() : '',
    email: String(reservation.email || '').trim().toLowerCase(),
    phone: reservation.phone ? String(reservation.phone).trim() : '',
  });

  const moveInDate =
    (reservation.moveInDate as admin.firestore.Timestamp | undefined)?.toDate() || new Date();
  const chargeQuote = await loadPublicMoveInChargeQuote({
    facilityId,
    reservation,
    moveInDate,
  });

  if (!amountsMatchCents(chargeQuote.totalCents, amountNumber)) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'Payment amount does not match required move-in charges. Refresh the page and try again.',
    );
  }

  await reservationRef.set(
    {
      expectedCheckoutAmountCents: chargeQuote.totalCents,
      checkoutUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  const cents = chargeQuote.totalCents;
  if (cents < 50) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'The amount due is below the $0.50 card minimum. Contact the facility to complete payment.',
    );
  }

  const safeToken = encodeURIComponent(String(token));
  const safeReservationId = encodeURIComponent(String(reservationId));
  const successUrl =
    `https://app.storagefacilitycreator.com/#/public-move-in?token=${safeToken}` +
    `&reservationId=${safeReservationId}` +
    '&checkout=success&session_id={CHECKOUT_SESSION_ID}';
  const cancelUrl =
    `https://app.storagefacilitycreator.com/#/public-move-in?token=${safeToken}` +
    `&reservationId=${safeReservationId}` +
    '&checkout=cancel';

  const customerEmail = optionalStripeCheckoutCustomerEmail(reservation.email);
  const rawLineName =
    (description || `Move-in payment for ${facilityData.name || 'Facility'}`).toString();
  const lineItemName = rawLineName.length > 200 ? `${rawLineName.slice(0, 197)}...` : rawLineName;

  try {
    const stripe = getStripeClient();
    const session = await stripe.checkout.sessions.create(
      {
        mode: 'payment',
        payment_method_types: ['card'],
        line_items: [
          {
            price_data: {
              currency: 'usd',
              product_data: {
                name: lineItemName,
              },
              unit_amount: cents,
            },
            quantity: 1,
          },
        ],
        ...(customerEmail ? { customer_email: customerEmail } : {}),
        success_url: successUrl,
        cancel_url: cancelUrl,
        metadata: {
          type: 'public_move_in',
          reservationId: String(reservationId),
          moveInToken: String(token),
          facilityId,
        },
      },
      {
        stripeAccount: connectAccountId,
      },
    );

    if (!session.url) {
      functions.logger.error('createPublicMoveInCheckout: session missing url', {
        sessionId: session.id,
        facilityId,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Stripe did not return a checkout link. The facility owner should confirm Stripe Checkout is enabled for their account.',
      );
    }

    return {
      checkoutUrl: session.url,
      sessionId: session.id,
    };
  } catch (err: unknown) {
    if (err instanceof functions.https.HttpsError) {
      throw err;
    }
    const e = err as { type?: string; code?: string; message?: string };
    const rawMessage = typeof e.message === 'string' && e.message.trim() !== ''
      ? e.message.trim()
      : 'Payment could not be started.';
    functions.logger.error('createPublicMoveInCheckout Stripe error', {
      facilityId,
      reservationId: String(reservationId),
      stripeType: e.type,
      stripeCode: e.code,
      message: rawMessage,
    });
    const capped = rawMessage.length > 240 ? `${rawMessage.slice(0, 237)}...` : rawMessage;
    throw new functions.https.HttpsError('failed-precondition', capped);
  }
});

/**
 * Confirm Stripe Checkout payment result for public move-in.
 */
export const confirmPublicMoveInCheckout = functions.runWith({ secrets: STRIPE_SECRETS }).https.onCall(async (data: any) => {
  const {
    reservationId,
    token,
    sessionId,
  } = data || {};

  if (!reservationId || !token || !sessionId) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'reservationId, token, and sessionId are required',
    );
  }

  const reservationRef = admin.firestore().collection('publicReservations').doc(String(reservationId));
  const reservationSnap = await reservationRef.get();
  if (!reservationSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Reservation not found');
  }
  const reservation = reservationSnap.data() as Record<string, any>;
  if (reservation.moveInToken !== token) {
    throw new functions.https.HttpsError('permission-denied', 'Invalid token');
  }

  const facilityId = reservation.facilityId as string | undefined;
  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation missing facilityId');
  }
  const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data() as Record<string, any>;
  const connectAccountId = facilityData.stripeConnectAccountId as string | undefined;
  const onboardingComplete = facilityData.stripeConnectOnboardingComplete as boolean | undefined;
  if (!connectAccountId || !onboardingComplete) {
    throw new functions.https.HttpsError('failed-precondition', 'Stripe is not enabled for this facility');
  }

  const stripe = getStripeClient();
  const session = await stripe.checkout.sessions.retrieve(
    String(sessionId),
    {
      expand: ['payment_intent'],
    },
    {
      stripeAccount: connectAccountId,
    },
  );

  if (session.payment_status !== 'paid') {
    throw new functions.https.HttpsError(
      'failed-precondition',
      `Checkout is not paid (status: ${session.payment_status || 'unknown'})`,
    );
  }

  const metaReservationId = session.metadata?.reservationId;
  const metaToken = session.metadata?.moveInToken;
  if (metaReservationId !== String(reservationId) || metaToken !== String(token)) {
    throw new functions.https.HttpsError('permission-denied', 'Checkout session does not match reservation');
  }

  const paymentIntentRaw = session.payment_intent;
  const paymentIntentId = typeof paymentIntentRaw === 'string'
    ? paymentIntentRaw
    : paymentIntentRaw?.id;
  if (!paymentIntentId) {
    throw new functions.https.HttpsError('failed-precondition', 'No payment intent found on checkout session');
  }

  return {
    success: true,
    paymentIntentId,
    amountPaid: (session.amount_total || 0) / 100,
    currency: session.currency || 'usd',
    sessionId: session.id,
  };
});

function humanizeUnitType(unitTypeRaw: string): string {
  const m: Record<string, string> = {
    standard: 'Standard storage',
    climateControlled: 'Climate controlled',
    vehicle: 'Vehicle storage',
    document: 'Document storage',
    wine: 'Wine storage',
    outdoor: 'Outdoor storage',
  };
  return m[unitTypeRaw] || unitTypeRaw;
}

/** One-page PDF for online move-in (signature + summary) for facility dashboard review. */
async function buildPublicMoveInAgreementPdf(params: {
  facilityName: string;
  unitNumber: string;
  unitTypeDisplay?: string;
  facilityAddress?: string;
  facilityPhone?: string;
  tenantName: string;
  tenantEmail: string;
  signedAtLabel: string;
  signaturePngBase64: string;
  /** When set, certificate page title references this lease name. */
  headerTitle?: string | null;
}): Promise<Buffer> {
  const { PDFDocument, StandardFonts, rgb } = await import('pdf-lib');
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([612, 792]);
  const regular = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  let y = 720;
  const left = 50;
  const line = (text: string, opts?: { bold?: boolean; size?: number }) => {
    const font = opts?.bold ? bold : regular;
    const size = opts?.size ?? 11;
    page.drawText(text, { x: left, y, size, font, color: rgb(0, 0, 0) });
    y -= size + 6;
  };
  const mainTitle = (params.headerTitle && params.headerTitle.trim())
    ? `${params.headerTitle.trim()} (Online Move-In Certificate)`
    : 'Storage Rental Agreement (Online Move-In)';
  line(mainTitle, { bold: true, size: 16 });
  y -= 8;
  line('This record was completed through self-service online move-in.', { size: 10 });
  y -= 6;
  line(`Facility: ${params.facilityName}`);
  if (params.facilityAddress) {
    line(`Facility address: ${params.facilityAddress}`);
  }
  if (params.facilityPhone) {
    line(`Facility phone: ${params.facilityPhone}`);
  }
  line(`Unit number: ${params.unitNumber}`);
  if (params.unitTypeDisplay) {
    line(`Unit type: ${params.unitTypeDisplay}`);
  }
  line(`Tenant: ${params.tenantName}`);
  line(`Email: ${params.tenantEmail}`);
  line(`Signed: ${params.signedAtLabel}`);
  y -= 16;
  line('Electronic signature', { bold: true });
  y -= 4;
  const pngBytes = Buffer.from(params.signaturePngBase64, 'base64');
  const png = await pdf.embedPng(pngBytes);
  const sigW = 240;
  const sigH = 96;
  page.drawImage(png, { x: left, y: y - sigH, width: sigW, height: sigH });
  y -= sigH + 20;
  line(
    'By signing above, the tenant acknowledges the storage rental agreement associated with this move-in.',
    { size: 9 },
  );
  return Buffer.from(await pdf.save());
}

/** Prepends facility lease PDF pages (when provided), then appends the signature certificate. */
async function mergeTemplateWithCertificatePdf(
  templateBytes: Buffer | null,
  certParams: Parameters<typeof buildPublicMoveInAgreementPdf>[0],
): Promise<Buffer> {
  const { PDFDocument } = await import('pdf-lib');
  const merged = await PDFDocument.create();
  if (templateBytes && templateBytes.length > 0) {
    try {
      const tpl = await PDFDocument.load(templateBytes);
      const copied = await merged.copyPages(tpl, tpl.getPageIndices());
      for (const p of copied) merged.addPage(p);
    } catch (e: any) {
      functions.logger.warn('Public move-in: template PDF merge failed; certificate only', {
        message: e?.message,
      });
    }
  }
  const certBytes = await buildPublicMoveInAgreementPdf(certParams);
  const certDoc = await PDFDocument.load(certBytes);
  const certCopied = await merged.copyPages(certDoc, certDoc.getPageIndices());
  for (const p of certCopied) merged.addPage(p);
  return Buffer.from(await merged.save());
}

/**
 * Complete public move-in flow (no auth)
 * - Validates reservation token
 * - Creates tenant and contract
 * - Creates ledger entries for move-in charges
 * - Verifies payment intent (optional) and logs payment
 * - Updates unit status and reservation status
 * - Generates gate access code
 */
export const completePublicMoveIn = functions.runWith({ secrets: [...STRIPE_SECRETS, SENDGRID_API_KEY] }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);

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
    signaturePngBase64,
    signatureSignedAt,
    addressLine2,
    city,
    state,
    zipCode,
    country,
    governmentIdType,
    governmentIdNumber,
    governmentIdState,
    governmentIdCountry,
    emergencyContactRelationship,
    emergencyContactEmail,
    enrollAutopayInterest,
  } = data || {};

  const enrollAutopay =
    enrollAutopayInterest === true ||
    enrollAutopayInterest === 'true' ||
    (data as any)?.enrollAutopay === true;

  const normalizedSignaturePngBase64 = (signaturePngBase64 || '').toString().trim();
  const normalizedSignatureSignedAt = (signatureSignedAt || '').toString().trim();
  const normalizedEmail = String(email || '').trim().toLowerCase();
  const normalizedCountry = String(country || '').trim().toUpperCase();
  const normalizedGovernmentIdType = String(governmentIdType || '').trim();
  const normalizedGovernmentIdNumber = String(governmentIdNumber || '').trim();
  const normalizedGovernmentIdState = String(governmentIdState || '').trim();
  const normalizedGovernmentIdCountry = String(governmentIdCountry || '').trim().toUpperCase();
  const normalizedEmergencyContactRelationship = String(emergencyContactRelationship || '').trim();
  const normalizedEmergencyContactEmail = String(emergencyContactEmail || '').trim().toLowerCase();

  if (!reservationId || !token || !name || !normalizedEmail || !phone || !normalizedSignaturePngBase64) {
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
  let displayUnitNumber = (reservation.unitNumber as string | undefined) || 'Unassigned';
  const reservationMetadata = (reservation.metadata as Record<string, any> | undefined) || {};
  const reservationSource = String(reservationMetadata.source || '').trim();
  const portalSourceTenantId = String(reservationMetadata.portalTenantId || '').trim();
  const moveInDate = (reservation.moveInDate as admin.firestore.Timestamp | undefined)?.toDate() || new Date();

  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation missing facilityId');
  }

  const facilityPreSnap = await admin.firestore().collection('facilities').doc(facilityId).get();
  const facilityPre = (facilityPreSnap.data() || {}) as Record<string, any>;
  const facilityNameForContext = String(facilityPre.name || 'Storage Facility').trim();
  const facilityAddressForContext = String(facilityPre.address || '').trim();
  const facilityPhoneForContext = String(facilityPre.phone || '').trim();
  const facilityEmailForContext = String(facilityPre.email || '').trim();

  let preloadedUnitData: Record<string, any> | null = null;
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

    preloadedUnitData = unitSnap.data() as Record<string, any>;
    const unitStatus = String(preloadedUnitData.status || '').toLowerCase();
    if (unitStatus && unitStatus !== 'available' && unitStatus !== 'reserved') {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is no longer available');
    }
    const numFromUnit = String(preloadedUnitData.unitNumber || '').trim();
    if (numFromUnit) {
      displayUnitNumber = numFromUnit;
    }
  }

  const chargeQuote = await loadPublicMoveInChargeQuote({
    facilityId,
    reservation,
    moveInDate,
  });
  const requiredPaymentCents = chargeQuote.totalCents;
  const paymentRequired = isPublicMoveInStripePaymentRequired(facilityPre, chargeQuote.totalAmount);

  if (paymentRequired) {
    if (skipPayment) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Payment is required to complete this move-in.',
      );
    }
    if (!paymentIntentId) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Payment is required before completing move-in.',
      );
    }
  }

  const expectedFromReservation = Number(reservation.expectedCheckoutAmountCents);
  const minimumPaymentCents =
    Number.isFinite(expectedFromReservation) && expectedFromReservation > 0
      ? expectedFromReservation
      : requiredPaymentCents;

  if (paymentRequired || (!skipPayment && paymentIntentId)) {
    if (requiredPaymentCents > 0 && minimumPaymentCents !== requiredPaymentCents) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Move-in charges changed since checkout started. Refresh and try again.',
      );
    }
    try {
      const stripe = getStripeClient();
      const connectAccountId = resolveMoveInPaymentStripeAccountId(facilityPre);
      if (!connectAccountId) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'Facility must have Stripe Connect configured to verify payment',
        );
      }
      const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId, {
        stripeAccount: connectAccountId,
      });

      const requiredCents = Math.max(requiredPaymentCents, minimumPaymentCents);
      if (paymentIntent.amount_received < requiredCents) {
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
  } else if (!skipPayment && requiredPaymentCents > 0) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Payment is required to complete this move-in.',
    );
  }

  const verifiedTotalAmount = chargeQuote.totalAmount;

  await assertOnlineRentalNotOnDnrList(admin.firestore(), {
    name: name.trim(),
    email: normalizedEmail,
    phone: phone.trim(),
  });

  const unitTypeRaw = preloadedUnitData ? String(preloadedUnitData.unitType || 'standard') : 'standard';
  const unitTypeDisplay = humanizeUnitType(unitTypeRaw);
  const unitDescriptionForContext = preloadedUnitData
    ? String(preloadedUnitData.description || '').trim()
    : '';
  const facilityInfoLines: string[] = [];
  if (facilityAddressForContext) facilityInfoLines.push(`Address: ${facilityAddressForContext}`);
  if (facilityPhoneForContext) facilityInfoLines.push(`Phone: ${facilityPhoneForContext}`);
  if (facilityEmailForContext) facilityInfoLines.push(`Email: ${facilityEmailForContext}`);
  const contractDescriptionParts: string[] = [
    `Online self-service move-in for unit ${displayUnitNumber} (${unitTypeDisplay}) at ${facilityNameForContext}.`,
    '',
  ];
  if (facilityInfoLines.length > 0) {
    contractDescriptionParts.push('Facility information', ...facilityInfoLines);
  }
  if (unitDescriptionForContext) {
    if (facilityInfoLines.length > 0) contractDescriptionParts.push('');
    contractDescriptionParts.push(`Unit description: ${unitDescriptionForContext}`);
  }
  const contractDescription = contractDescriptionParts.join('\n');

  const onlineMoveInContext = {
    unitId: unitId || null,
    unitNumber: displayUnitNumber,
    unitType: unitTypeRaw,
    unitTypeDisplay,
    unitDescription: unitDescriptionForContext || null,
    facilityName: facilityNameForContext,
    facilityAddress: facilityAddressForContext || null,
    facilityPhone: facilityPhoneForContext || null,
    facilityEmail: facilityEmailForContext || null,
  };

  const templateBinding = await readOnlineMoveInTemplateBinding(facilityId);
  let templatePdfBytes: Buffer | null = null;
  if (templateBinding) {
    templatePdfBytes = await downloadTemplatePdfToBuffer(
      templateBinding.url,
      facilityId,
      templateBinding.documentSha256,
    );
    if (!templatePdfBytes) {
      functions.logger.warn('Public move-in: could not download configured lease template PDF', {
        facilityId,
        templateId: templateBinding.templateId,
      });
    }
  }
  const activatedLeaseTemplate = templateBinding && templatePdfBytes
    ? { ...templateBinding, pdfBytes: templatePdfBytes }
    : null;

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

    const facilityDocRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilitySnap = await tx.get(facilityDocRef);
    const facilityOwnerUid = (facilitySnap.data() as Record<string, any> | undefined)?.ownerUid || 'publicMoveIn';

    // If this move-in originated from tenant portal, link the new tenant record
    // to the same portal account identity as the source tenant.
    let linkedPortalFields: Record<string, any> = {
      portalEnabled: false,
      portalAccessCode: null,
      portalWelcomeMessage: null,
      portalLastAccessAt: null,
      portalVisitCount: 0,
      portalAccountId: null,
      primaryPortalTenant: false,
    };
    if (reservationSource === 'tenant_portal_additional_unit' && portalSourceTenantId) {
      const sourceTenantRef = facilityDocRef.collection('tenants').doc(portalSourceTenantId);
      const sourceTenantSnap = await tx.get(sourceTenantRef);
      if (sourceTenantSnap.exists) {
        const sourceTenantData = sourceTenantSnap.data() as Record<string, any>;
        const sourceEmailLower = (sourceTenantData.emailLower || '').toString().trim().toLowerCase();
        const sourcePortalEnabled = sourceTenantData.portalEnabled === true;
        if (!sourcePortalEnabled || sourceEmailLower !== normalizedEmail) {
          throw new functions.https.HttpsError(
            'permission-denied',
            'Portal-linked move-in validation failed',
          );
        }
        const sourceAccessCode = (sourceTenantData.portalAccessCode || '').toString().trim();
        const sourcePortalAccountId = (sourceTenantData.portalAccountId || '').toString().trim();
        const resolvedPortalAccountId = sourcePortalAccountId || portalSourceTenantId;
        linkedPortalFields = {
          portalEnabled: true,
          portalAccessCode: sourceAccessCode.length > 0 ? sourceAccessCode : null,
          portalWelcomeMessage: sourceTenantData.portalWelcomeMessage ?? null,
          portalLastAccessAt: null,
          portalVisitCount: 0,
          portalAccountId: resolvedPortalAccountId,
          primaryPortalTenant: false,
        };
        // Backfill account id on the source tenant when missing so subsequent fetches link both.
        if (!sourcePortalAccountId) {
          tx.update(sourceTenantRef, {
            portalAccountId: resolvedPortalAccountId,
            updatedAt: nowTs,
          });
        }
      }
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
      email: normalizedEmail,
      emailLower: normalizedEmail,
      phone: phone.trim(),
      phoneDigits: phone.replace(/[^\d]/g, ''),
      unitNumber: displayUnitNumber,
      monthlyRate: deriveMonthlyRate(),
      notes: String(data?.notes || '').trim(),
      createdAt: nowTs,
      createdBy: 'publicMoveIn',
      isActive: true,
      isOnDNR: false,
      leadSource: 'onlineRental',
      // SMS opt-in captured on the public rental form.
      ...resolveSmsConsentFields(reservationMetadata, nowTs),
      governmentIdType: normalizedGovernmentIdType.length > 0 ? normalizedGovernmentIdType : null,
      governmentIdNumber: normalizedGovernmentIdNumber.length > 0 ? normalizedGovernmentIdNumber : null,
      governmentIdState: normalizedGovernmentIdState.length > 0 ? normalizedGovernmentIdState : null,
      governmentIdCountry: normalizedGovernmentIdCountry.length > 0 ? normalizedGovernmentIdCountry : null,
      emergencyContacts: emergencyContactName
        ? [{
            name: emergencyContactName,
            relationship: normalizedEmergencyContactRelationship || null,
            phone: emergencyContactPhone || '',
            email: normalizedEmergencyContactEmail || null,
            isPrimary: true,
            isEmergency: true,
          }]
        : [],
      addresses: address
        ? [{
            id: '',
            type: 'mailing',
            street1: address,
            street2: String(addressLine2 || '').trim(),
            city: String(city || '').trim(),
            state: String(state || '').trim(),
            zipCode: String(zipCode || '').trim(),
            country: normalizedCountry,
            isPrimary: true,
            notes: '',
          }]
        : [],
      ...linkedPortalFields,
      ...(enrollAutopay
        ? {
          autopay: {
            requested: true,
            enabled: false,
            status: 'REQUESTED',
            updatedBy: 'PUBLIC_MOVE_IN',
            updatedAt: nowTs,
          },
        }
        : {}),
    };

    tx.set(tenantRef, tenantData);

    // Create contract (minimal signed agreement record)
    const contractRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('contracts')
      .doc();

    const contractPayload: Record<string, any> = {
      facilityId,
      facilityOwnerUid,
      tenantId: tenantRef.id,
      title: activatedLeaseTemplate?.title || 'Storage Rental Agreement',
      description: contractDescription,
      type: activatedLeaseTemplate?.type || 'storage',
      status: 'signed',
      templateId: activatedLeaseTemplate?.templateId || null,
      fileUrl: activatedLeaseTemplate?.url || null,
      signedFileUrl: null,
      createdAt: nowTs,
      updatedAt: nowTs,
      createdBy: 'publicMoveIn',
      sentAt: nowTs,
      signedAt: nowTs,
      expiresAt: null,
      sentBy: 'publicMoveIn',
      signedBy: name.trim(),
      customFields: {
        publicMoveInSignature: {
          signaturePngBase64: normalizedSignaturePngBase64,
          signedAt: normalizedSignatureSignedAt || new Date().toISOString(),
          signerName: name.trim(),
          signerEmail: email.trim().toLowerCase(),
        },
        onlineMoveInContext,
        ...(activatedLeaseTemplate
          ? { onlineMoveInContractTemplateId: activatedLeaseTemplate.templateId }
          : {}),
      },
      notes: null,
      isActive: true,
      complianceStatus: activatedLeaseTemplate?.complianceStatus || 'active',
      isLicensedForm: activatedLeaseTemplate?.isLicensedForm ?? false,
      ...(activatedLeaseTemplate?.documentSha256
        ? { documentSha256: activatedLeaseTemplate.documentSha256 }
        : {}),
      ...(activatedLeaseTemplate?.fileSize != null
        ? { fileSize: activatedLeaseTemplate.fileSize }
        : {}),
      ...(activatedLeaseTemplate?.contentType
        ? { contentType: activatedLeaseTemplate.contentType }
        : {}),
    };
    tx.set(contractRef, contractPayload);

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

  // Generate and store a reviewable PDF (dashboard contract detail uses signedFileUrl / fileUrl).
  try {
    const certParams = {
      facilityName: facilityNameForContext,
      unitNumber: displayUnitNumber,
      unitTypeDisplay,
      facilityAddress: facilityAddressForContext || undefined,
      facilityPhone: facilityPhoneForContext || undefined,
      tenantName: name.trim(),
      tenantEmail: normalizedEmail,
      signedAtLabel: normalizedSignatureSignedAt || new Date().toISOString(),
      signaturePngBase64: normalizedSignaturePngBase64,
      headerTitle: activatedLeaseTemplate?.title ?? null,
    };
    const pdfBuf = await mergeTemplateWithCertificatePdf(
      activatedLeaseTemplate?.pdfBytes ?? null,
      certParams,
    );
    const docHash = crypto.createHash('sha256').update(pdfBuf).digest('hex');
    const storagePathPdf = `facilities/${facilityId}/contracts/${contractId}/signed_move_in_agreement.pdf`;
    const bucketPdf = admin.storage().bucket();
    const filePdf = bucketPdf.file(storagePathPdf);
    const downloadTokenPdf = crypto.randomUUID();
    await filePdf.save(pdfBuf, {
      contentType: 'application/pdf',
      metadata: {
        contentType: 'application/pdf',
        metadata: { firebaseStorageDownloadTokens: downloadTokenPdf },
      },
    });
    const signedPdfUrl = await getDownloadURL(filePdf);
    const originalLeaseUrl = activatedLeaseTemplate?.url || null;
    await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('contracts')
      .doc(contractId)
      .update({
        signedFileUrl: signedPdfUrl,
        fileUrl: originalLeaseUrl || signedPdfUrl,
        storagePath: storagePathPdf,
        documentSha256: docHash,
        fileSize: pdfBuf.length,
        contentType: 'application/pdf',
        uploadedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
  } catch (pdfErr: any) {
    functions.logger.error('Public move-in: contract PDF upload failed', { message: pdfErr?.message, contractId, facilityId });
  }

  if (enrollAutopay) {
    try {
      await createAutopayNotificationAndEvent(
        facilityId,
        tenantId,
        name.trim(),
        'AUTOPAY_REQUESTED',
        'REQUESTED',
        'SYSTEM',
        `${name.trim()} requested automatic draft (autopay) during online move-in.`,
        null,
      );
    } catch (apErr: any) {
      functions.logger.warn('Public move-in: autopay notification failed', { message: apErr?.message });
    }
  }

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
  if (!skipPayment && paymentIntentId && verifiedTotalAmount > 0) {
    const ledgerRef = admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('ledgers')
      .doc();

    await ledgerRef.set({
      tenantId,
      facilityId,
      type: 'payment',
      amount: -Number(verifiedTotalAmount),
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

  // Best-effort email confirmation (do not fail move-in if email provider is unavailable).
  try {
    const facilitySnap = await admin.firestore().collection('facilities').doc(facilityId).get();
    const facilityData = (facilitySnap.data() || {}) as Record<string, any>;
    const facilityName = String(facilityData.name || 'Storage Facility');
    const facilityAddress = String(facilityData.address || facilityData.location || '').trim() || null;
    const facilityPhone = String(facilityData.phone || '').trim() || null;
    const senderEmail = String(SENDGRID_FROM_EMAIL.value() || '').trim();
    if (senderEmail) {
      await sendFacilityEmailWithCompliance(
        {
          to: normalizedEmail,
          from: { email: senderEmail, name: facilityName },
          subject: `Move-in confirmed for ${facilityName}`,
        },
        `<p>Hi ${escapeHtml(name.trim())},</p>
         <p>Your move-in request has been completed for <strong>${escapeHtml(facilityName)}</strong>.</p>
         <p><strong>Unit:</strong> ${escapeHtml(displayUnitNumber)} (${escapeHtml(unitTypeDisplay)})</p>
         <p><strong>Move-in date:</strong> ${escapeHtml(moveInDate.toISOString().slice(0, 10))}</p>
         <p>If you need help, reply to this email or contact the facility.</p>`,
        `Hi ${name.trim()},

Your move-in request has been completed for ${facilityName}.
Unit: ${displayUnitNumber} (${unitTypeDisplay})
Move-in date: ${moveInDate.toISOString().slice(0, 10)}

If you need help, contact the facility.`,
        {
          facilityId,
          tenantId,
          facilityName,
          facilityAddress,
          facilityPhone,
        },
      );
    } else {
      functions.logger.warn('Move-in confirmation email skipped: SENDGRID_SENDER_EMAIL is not configured');
    }
  } catch (emailError: any) {
    functions.logger.error('Failed to send move-in confirmation email', {
      reservationId,
      tenantId,
      error: emailError?.message || String(emailError),
    });
  }

  return {
    success: true,
    tenantId,
    contractId,
    gateAccessCode,
    reservationId,
  };
});

