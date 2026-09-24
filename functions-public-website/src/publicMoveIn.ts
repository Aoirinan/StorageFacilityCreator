import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import { getDownloadURL } from 'firebase-admin/storage';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
  escapeHtml,
  enabledOnlineUnitTypes,
  getStripeClient,
  isUnitOfferedOnline,
  isUnitTypeOfferedOnline,
  PUBLIC_MOVE_IN_PAYMENT_TYPE,
  sendFacilityEmailWithCompliance,
  unitNotOfferedOnlineReason,
} from '@sfc/functions-shared';
import type { UnitNotOfferedReason } from '@sfc/functions-shared';
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
import { assertFacilityHasTenantCapacity } from './tenantCapacity';
import {
  CHECKOUT_RUN_OUT_MESSAGE,
  checkoutHoldWindow,
  laterExpiry,
  mayFinishAfterLapsedHold,
  timestampToDate,
} from './checkoutHold';
import { notifyOwnerOfMoveInToUnitNotOffered } from './onlineMoveInReview';
import {
  assertMoveInFormComplete,
  loadSavedMoveInForm,
  MOVE_IN_FORM_NOT_SAVED_MESSAGE,
  MOVE_IN_FORM_NOT_SAVED_REASON,
  moveInFormFromData,
  saveMoveInForm,
  savedMoveInFormRef,
} from './moveInForm';
import type { MoveInForm } from './moveInForm';

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

  // Completed too: a renter who paid and left may have been moved in by the
  // paid-checkout trigger, and on coming back should see that, not the form.
  const snapshot = await admin.firestore()
    .collection('publicReservations')
    .where('moveInToken', '==', token)
    .where('status', 'in', ['pending', 'confirmed', 'completed'])
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
  if (reservation.status === 'completed') {
    // Only what the page shows for a finished move-in: no charges, no form.
    return {
      found: true,
      reservation: {
        id: doc.id,
        facilityId: reservation.facilityId || '',
        unitId: reservation.unitId || null,
        unitNumber: reservation.unitNumber || null,
        email: reservation.email || '',
        name: reservation.name || null,
        status: 'completed',
        moveInDate: timestampToDate(reservation.moveInDate)?.toISOString() || null,
        completedAt: timestampToDate(reservation.completedAt)?.toISOString() || null,
      },
    };
  }
  const expiresAt = reservation.expiresAt as admin.firestore.Timestamp | undefined;
  // A reservation that went to checkout stays open for a while after its hold
  // lapses: this is how a renter who paid gets back to the form after Stripe.
  // completePublicMoveIn decides whether they can still finish.
  if (expiresAt && expiresAt.toDate() < new Date() && !mayFinishAfterLapsedHold(reservation, new Date())) {
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
 * Stable, short, non-identifying label for the caller, used to partition rate
 * limit counters. Hashed so no raw IP is written to Firestore.
 */
function callerFingerprint(context: functions.https.CallableContext): string {
  if (context.auth?.uid) return `u_${context.auth.uid.slice(0, 16)}`;
  const req = context.rawRequest as { ip?: string; headers?: Record<string, unknown> } | undefined;
  const forwarded = String(req?.headers?.['x-forwarded-for'] ?? '').split(',')[0].trim();
  const ip = forwarded || String(req?.ip ?? '');
  if (!ip) return 'anon';
  return `ip_${crypto.createHash('sha256').update(ip).digest('hex').slice(0, 16)}`;
}

export const ONLINE_RENTALS_OFF_MESSAGE =
  'This facility is not taking online rentals right now. Please contact the facility.';

/**
 * The public rental page offers a unit only when the owner has turned online
 * rentals on (FacilityPublicSettings.publicRentalsEnabled, off by default), so
 * a direct call is held to the same switch. The setting is already public in
 * the facility's publicFacilityMaps doc, so saying so leaks nothing.
 *
 * Returns the settings, so the hold can apply their unit types too.
 */
async function assertFacilityTakesOnlineRentals(facilityId: string): Promise<Record<string, unknown>> {
  const settingsSnap = await admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('settings')
    .doc('public')
    .get();
  const settings = (settingsSnap.data() || {}) as Record<string, unknown>;
  if (settings.publicRentalsEnabled !== true) {
    throw new functions.https.HttpsError('failed-precondition', ONLINE_RENTALS_OFF_MESSAGE);
  }
  return settings;
}

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

  // Second, tighter budget partitioned by caller.
  //
  // The facility-wide limit above bounds total load but does nothing about one
  // actor taking the whole allowance: holds mark units unavailable, so a single
  // caller could hold every unit in a facility and exhaust the budget real
  // renters need, emptying the storefront. Partitioning the key gives each
  // caller its own counter without changing the shared helper.
  await enforceRateLimit({
    facilityId: String(facilityId),
    key: `createPublicReservationHold_caller_${callerFingerprint(context)}`,
    limit: 5,
    windowSeconds: 60,
    userId: context.auth?.uid || null,
  });

  const publicSettings = await assertFacilityTakesOnlineRentals(String(facilityId));
  const enabledUnitTypes = enabledOnlineUnitTypes(publicSettings);

  await assertOnlineRentalNotOnDnrList(admin.firestore(), {
    name: name ? String(name).trim() : '',
    email: String(email).trim().toLowerCase(),
    phone: phone ? String(phone).trim() : '',
  });

  // Before the unit is held, so a renter at a full facility finds out first.
  await assertFacilityHasTenantCapacity(admin.firestore(), String(facilityId));

  const now = new Date();
  // Capped at 15 minutes, not 60. A hold makes the unit unavailable to everyone
  // else, so a long window is a cheap way to keep inventory off the market.
  // Starting checkout extends it to cover payment and the form (checkoutHold.ts).
  const boundedMinutes = Math.max(1, Math.min(Number(holdMinutes) || 10, 15));
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
    // One refusal for all of these, so a caller cannot tell an unlisted or
    // internal-use unit from a rented one. The unit type too: the public map
    // marks a type the owner turned off not rentable, but a direct call held
    // it.
    if (
      (unitStatus !== 'available' && unitStatus !== 'reserved') ||
      !isUnitOfferedOnline(unitData) ||
      !isUnitTypeOfferedOnline(unitData, enabledUnitTypes)
    ) {
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
      // Allowlisted, never spread. This is an unauthenticated endpoint, and the
      // reservation's metadata is read back later when charges are computed, so
      // copying the caller's object wholesale let them inject pricing fields.
      metadata: {
        holdType: 'checkout',
        holdMinutes: boundedMinutes,
        source: (metadata && typeof metadata.source === 'string')
          ? String(metadata.source).slice(0, 64)
          : 'publicMap',
        smsConsent: metadata?.smsConsent === true,
        smsConsentSource: (metadata && typeof metadata.smsConsentSource === 'string')
          ? String(metadata.smsConsentSource).slice(0, 64)
          : null,
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
    // No move-in will be completed from it.
    tx.delete(savedMoveInFormRef(reservationId));
  });

  return { success: true, status: 'cancelled' };
});

export const createPublicMoveInCheckout = functions
  .runWith({ secrets: STRIPE_SECRETS })
  .https.onCall(async (data: any, context) => {
  // Every sibling public callable enforces App Check; this one took no `context`
  // at all, so it could not. It creates Stripe Checkout Sessions on the
  // operator's connected account, making it an unauthenticated, unmetered way to
  // spend their Stripe quota.
  enforceAppCheckOrThrow(context);
  const {
    reservationId,
    token,
    amount,
    description,
    moveInForm: rawMoveInForm,
  } = data || {};

  if (!reservationId || !token || amount == null) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'reservationId, token, and amount are required',
    );
  }
  // The move-in form is saved before the renter pays, so the move-in can be
  // completed from it if they never come back from Stripe (moveInForm.ts).
  // A page loaded before the form was sent here sends none.
  if (!rawMoveInForm || typeof rawMoveInForm !== 'object') {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Please refresh this page, then fill in the move-in form before paying.',
    );
  }
  const moveInForm = moveInFormFromData(rawMoveInForm as Record<string, unknown>);
  assertMoveInFormComplete(moveInForm);

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

  // Keyed on the facility from the stored reservation, never the request.
  await enforceRateLimit({
    facilityId: String(facilityId),
    key: 'createPublicMoveInCheckout',
    limit: 30,
    windowSeconds: 60,
    userId: context.auth?.uid || null,
  });

  // The unit can be rented, unlisted, archived or set to internal use while it
  // is held (up to 15 minutes for a public hold, 60 for a tenant-portal one).
  // completePublicMoveIn refuses such a unit too, but only after Checkout has
  // taken the payment, leaving the owner to refund it by hand. Same test and
  // refusal as both holds; trimmed as loadPublicMoveInChargeQuote does, so the
  // unit checked is the unit priced.
  const reservedUnitId = String(reservation.unitId || '').trim();
  if (reservedUnitId) {
    const unitSnap = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('units')
      .doc(reservedUnitId)
      .get();
    const unitData = unitSnap.exists ? (unitSnap.data() as Record<string, any>) : null;
    const unitStatus = String(unitData?.status || '').toLowerCase();
    if (
      !unitData ||
      (unitStatus !== 'available' && unitStatus !== 'reserved') ||
      !isUnitOfferedOnline(unitData)
    ) {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
    }
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

  // Checked again before any payment is taken: the hold may be up to 15
  // minutes old, and tenant-portal holds are created in another codebase.
  await assertFacilityHasTenantCapacity(admin.firestore(), facilityId);

  const reservedIdentity = {
    name: reservation.name ? String(reservation.name).trim() : '',
    email: String(reservation.email || '').trim().toLowerCase(),
    phone: reservation.phone ? String(reservation.phone).trim() : '',
  };
  await assertOnlineRentalNotOnDnrList(admin.firestore(), reservedIdentity);
  // Completion screens the name, email and phone on the form, so a form that
  // differs is screened here too: a match found only after payment leaves the
  // renter paid and refused.
  if (
    moveInForm.name.toLowerCase() !== reservedIdentity.name.toLowerCase() ||
    moveInForm.email !== reservedIdentity.email ||
    moveInForm.phone.replace(/\D/g, '') !== reservedIdentity.phone.replace(/\D/g, '')
  ) {
    await assertOnlineRentalNotOnDnrList(admin.firestore(), {
      name: moveInForm.name,
      email: moveInForm.email,
      phone: moveInForm.phone,
    });
  }

  // Completion refuses a tenant-portal move-in under an email that is not the
  // portal tenant's, when it writes the move-in, which is after payment. The
  // form is here now, so the same test runs before it.
  const reservationMetadata = (reservation.metadata as Record<string, any> | undefined) || {};
  const portalSourceTenantId = String(reservationMetadata.portalTenantId || '').trim();
  if (String(reservationMetadata.source || '').trim() === 'tenant_portal_additional_unit' && portalSourceTenantId) {
    const sourceTenantSnap = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .doc(portalSourceTenantId)
      .get();
    if (
      sourceTenantSnap.exists &&
      !portalTenantMayLink(sourceTenantSnap.data() as Record<string, any>, moveInForm.email)
    ) {
      throw new functions.https.HttpsError('permission-denied', 'Portal-linked move-in validation failed');
    }
  }

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

  const cents = chargeQuote.totalCents;
  if (cents < 50) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'The amount due is below the $0.50 card minimum. Contact the facility to complete payment.',
    );
  }

  // The hold is extended to outlast the Checkout Session, which is given a
  // short expiry below, so a renter who pays still holds the unit while they
  // come back and finish the form. Written before Stripe is called: if this
  // fails, there is no payable session that the hold does not cover.
  const holdWindow = checkoutHoldWindow(new Date(), timestampToDate(reservation.reservedAt));
  if (!holdWindow) {
    throw new functions.https.HttpsError('failed-precondition', CHECKOUT_RUN_OUT_MESSAGE);
  }
  const holdUntil = holdWindow.holdUntil;
  await admin.firestore().runTransaction(async (tx) => {
    const currentSnap = await tx.get(reservationRef);
    const current = (currentSnap.data() || {}) as Record<string, any>;
    if (current.status !== 'pending' && current.status !== 'confirmed') {
      throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
    }

    let holdRef: admin.firestore.DocumentReference | null = null;
    let hold: Record<string, any> | null = null;
    if (reservedUnitId) {
      holdRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('mapEngine')
        .doc('activeHolds')
        .collection('items')
        .doc(reservedUnitId);
      const holdSnap = await tx.get(holdRef);
      hold = holdSnap.exists ? (holdSnap.data() as Record<string, any>) : null;
      const heldUntil = timestampToDate(hold?.expiresAt);
      if (hold && hold.reservationId !== String(reservationId) && heldUntil && heldUntil > new Date()) {
        throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
      }
    }

    tx.update(reservationRef, {
      expectedCheckoutAmountCents: chargeQuote.totalCents,
      checkoutUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromDate(laterExpiry(current.expiresAt, holdUntil)),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    // With the hold, before Stripe is called: every payable session has a form.
    saveMoveInForm(tx, {
      reservationId: String(reservationId),
      facilityId,
      form: moveInForm,
      now: new Date(),
    });
    if (holdRef && hold && hold.reservationId === String(reservationId)) {
      tx.update(holdRef, {
        expiresAt: admin.firestore.Timestamp.fromDate(laterExpiry(hold.expiresAt, holdUntil)),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } else if (holdRef) {
      // Missing, or another reservation's lapsed hold: hold the unit again, as
      // createPublicReservationHold would.
      tx.set(holdRef, {
        facilityId,
        unitId: reservedUnitId,
        reservationId: String(reservationId),
        status: 'pending',
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        expiresAt: admin.firestore.Timestamp.fromDate(holdUntil),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
  });

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
        // Stripe's default is 24 hours; the hold only covers this long.
        expires_at: Math.floor(holdWindow.sessionExpiresAt.getTime() / 1000),
        metadata: {
          type: PUBLIC_MOVE_IN_PAYMENT_TYPE,
          reservationId: String(reservationId),
          moveInToken: String(token),
          facilityId,
        },
        // On the PaymentIntent too, so completePublicMoveIn can tell which
        // reservation a payment was for. The token stays off it.
        payment_intent_data: {
          metadata: {
            type: PUBLIC_MOVE_IN_PAYMENT_TYPE,
            reservationId: String(reservationId),
            facilityId,
          },
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
    // Logged in full above, but not returned: this caller is an anonymous member
    // of the public, and Stripe's message describes the operator's connected
    // account configuration.
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Payment could not be started. Please contact the facility directly.',
    );
  }
});

/**
 * Confirm Stripe Checkout payment result for public move-in.
 */
export const confirmPublicMoveInCheckout = functions
  .runWith({ secrets: STRIPE_SECRETS })
  .https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
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
  await enforceRateLimit({
    facilityId: String(facilityId),
    key: 'confirmPublicMoveInCheckout',
    limit: 30,
    windowSeconds: 60,
    userId: context.auth?.uid || null,
  });
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
 * One document per PaymentIntent that has completed an online move-in, keyed
 * by the PaymentIntent id. Top level rather than under the facility, so a
 * connected account shared by two facilities cannot spend one payment at each.
 */
export const PUBLIC_MOVE_IN_PAYMENTS_COLLECTION = 'publicMoveInPayments';

const PAYMENT_ALREADY_USED_MESSAGE =
  'This payment has already been used to complete a move-in. Contact the facility.';

/**
 * A payment the paid-checkout trigger could not use for its move-in, and told
 * the owner to refund, is recorded in PUBLIC_MOVE_IN_PAYMENTS_COLLECTION with
 * `refusedAt`, so it cannot complete a move-in afterwards: by then the owner
 * may have refunded it.
 */
export const PAYMENT_REFUSED_MESSAGE =
  'This payment could not be used for this move-in, and the facility has been asked to refund it. Contact the facility.';

export const OTHER_RESERVATION_PAYMENT_MESSAGE =
  'This payment was made for a different reservation. Contact the facility.';

/**
 * Whether a tenant-portal renter may take another unit linked to their portal
 * account: the portal tenant still has the portal, and the move-in is under
 * the same email. Checked at checkout, before payment, and again when the
 * move-in is written.
 */
function portalTenantMayLink(sourceTenantData: Record<string, any>, email: string): boolean {
  const sourceEmailLower = (sourceTenantData.emailLower || '').toString().trim().toLowerCase();
  return sourceTenantData.portalEnabled === true && sourceEmailLower === email;
}

/** Who is completing an online move-in. */
export type MoveInCaller =
  /** The renter's browser, holding the reservation's move-in token. */
  | { kind: 'renter'; token: string }
  /**
   * The paid-checkout trigger (paidCheckoutCompletion.ts), after the Stripe
   * webhook recorded a paid Checkout Session for the reservation. It holds no
   * token: it acts for a payment Stripe reported, and that payment is
   * verified here exactly as the renter's is.
   */
  | { kind: 'paidCheckout'; checkoutSessionId: string };

/** The move-in form: sent with the request, or saved when checkout was created. */
export type MoveInFormSource = { kind: 'provided'; form: MoveInForm } | { kind: 'saved' };

export type MoveInCompletion =
  | {
      status: 'completed';
      reservationId: string;
      tenantId: string;
      contractId: string;
      gateAccessCode: string | null;
    }
  /** The reservation had already been completed; nothing was written. */
  | {
      status: 'alreadyCompleted';
      reservationId: string;
      tenantId: string | null;
      /** The payment that completed it, if one did. */
      paymentIntentId: string | null;
    };

function assertCallerMayComplete(caller: MoveInCaller, reservation: Record<string, any>): void {
  if (caller.kind === 'renter' && reservation.moveInToken !== caller.token) {
    throw new functions.https.HttpsError('permission-denied', 'Invalid token');
  }
}

function alreadyCompleted(reservationId: string, reservation: Record<string, any>): MoveInCompletion {
  return {
    status: 'alreadyCompleted',
    reservationId,
    tenantId: reservation.tenantId ? String(reservation.tenantId) : null,
    paymentIntentId: reservation.paymentIntentId ? String(reservation.paymentIntentId) : null,
  };
}

/**
 * Completes an online move-in.
 * - Checks the reservation, and the caller's token
 * - Verifies the payment with Stripe: amount, status, reservation, one use
 * - Creates the tenant, contract and move-in charges, occupies the unit and
 *   completes the reservation, in one transaction
 * - Then the signed PDF, payment ledger entry, gate code and confirmation email
 *
 * The only place a move-in is completed: by the renter's browser
 * (completePublicMoveIn) and, for a renter who paid and never came back, by
 * the paid-checkout trigger (paidCheckoutCompletion.ts). Either can come
 * first, or both at once. The reservation's status and the payment's one-use
 * record are read and written in the one transaction, so a reservation is
 * completed once and a payment completes one move-in; the later caller gets
 * `alreadyCompleted`. Refusals throw HttpsErrors.
 */
export async function completeMoveInForReservation(params: MoveInCompletionRequest): Promise<MoveInCompletion> {
  try {
    return await completeMoveInOnce(params);
  } catch (err: unknown) {
    // Any refusal of a reservation that is now completed means it was
    // completed, by an earlier call or by the other caller while this one was
    // between its first read and its transaction. What that caller wrote
    // reads as a refusal here: the reservation is not active, the payment
    // posted to the ledger is "already used", the unit is occupied. The
    // paid-checkout trigger would otherwise tell the owner to refund a renter
    // who was moved in, and the renter would be shown an error.
    if (!(err instanceof functions.https.HttpsError)) throw err;
    // A failed read throws its own error, not the refusal: the refusal may be
    // of a move-in that was done, and read as one it would tell the owner to
    // refund a tenant. The read error is retried like any other failure.
    const snap = await admin.firestore().collection('publicReservations').doc(params.reservationId).get();
    const current = snap.exists ? (snap.data() as Record<string, any>) : undefined;
    if (current?.status !== 'completed') throw err;
    assertCallerMayComplete(params.caller, current);
    return alreadyCompleted(params.reservationId, current);
  }
}

type MoveInCompletionRequest = {
  reservationId: string;
  caller: MoveInCaller;
  formSource: MoveInFormSource;
  paymentIntentId: string | null;
  skipPayment: boolean;
};

async function completeMoveInOnce(params: MoveInCompletionRequest): Promise<MoveInCompletion> {
  const { reservationId, caller, formSource, skipPayment } = params;
  const paymentIntentId = params.paymentIntentId ? String(params.paymentIntentId).trim() || null : null;
  if (caller.kind === 'paidCheckout' && (skipPayment || !paymentIntentId)) {
    // A paid checkout completes a move-in with its payment or not at all.
    throw new functions.https.HttpsError('internal', 'A paid checkout must be completed with its payment');
  }

  const reservationRef = admin.firestore().collection('publicReservations').doc(reservationId);
  const reservationSnap = await reservationRef.get();

  if (!reservationSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Reservation not found');
  }

  const reservation = reservationSnap.data() as Record<string, any>;

  assertCallerMayComplete(caller, reservation);

  // A completed reservation is refused here, and reported as completed by
  // completeMoveInForReservation.
  if (reservation.status !== 'pending' && reservation.status !== 'confirmed') {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
  }

  const nowTs = admin.firestore.FieldValue.serverTimestamp();
  const expiresAt = reservation.expiresAt as admin.firestore.Timestamp | undefined;
  // A renter who went to checkout may be back after their hold lapsed, having
  // paid. They may still finish if the payment is for this reservation and
  // nobody else has the unit: both are checked below.
  let finishingAfterLapsedHold = false;
  if (expiresAt && expiresAt.toDate() < new Date()) {
    if (!mayFinishAfterLapsedHold(reservation, new Date())) {
      await reservationRef.update({ status: 'expired', updatedAt: nowTs });
      throw new functions.https.HttpsError('failed-precondition', 'Reservation has expired');
    }
    // Not marked expired: the renter may yet come back with their payment.
    if (skipPayment || !paymentIntentId) {
      throw new functions.https.HttpsError('failed-precondition', 'Reservation has expired');
    }
    finishingAfterLapsedHold = true;
  }

  // Read after the reservation checks, so a cancelled or expired reservation
  // is refused as that rather than as having no form.
  let form: MoveInForm;
  if (formSource.kind === 'provided') {
    form = formSource.form;
  } else {
    const saved = await loadSavedMoveInForm(reservationId);
    if (!saved) {
      throw new functions.https.HttpsError('failed-precondition', MOVE_IN_FORM_NOT_SAVED_MESSAGE, {
        reason: MOVE_IN_FORM_NOT_SAVED_REASON,
      });
    }
    form = saved;
  }
  assertMoveInFormComplete(form);
  const {
    name,
    phone,
    address,
    addressLine2,
    city,
    state,
    zipCode,
    emergencyContactName,
    emergencyContactPhone,
    enrollAutopay,
  } = form;
  const normalizedEmail = form.email;
  const normalizedCountry = form.country;
  const normalizedGovernmentIdType = form.governmentIdType;
  const normalizedGovernmentIdNumber = form.governmentIdNumber;
  const normalizedGovernmentIdState = form.governmentIdState;
  const normalizedGovernmentIdCountry = form.governmentIdCountry;
  const normalizedEmergencyContactRelationship = form.emergencyContactRelationship;
  const normalizedEmergencyContactEmail = form.emergencyContactEmail;
  const normalizedSignaturePngBase64 = form.signaturePngBase64;
  const normalizedSignatureSignedAt = form.signatureSignedAt;

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
  // Why the unit is no longer offered online, when it was unlisted, archived
  // or set to internal use since the hold. Refused below only if nothing
  // has been paid.
  let unitNotOfferedReason: UnitNotOfferedReason | null = null;
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
    // Both hold callables and checkout check this too. Looked at again for a
    // unit unlisted, archived or set to internal use since then; whether that
    // refuses the move-in waits on the payment check below.
    unitNotOfferedReason = unitNotOfferedOnlineReason(preloadedUnitData);
    if (finishingAfterLapsedHold) {
      // With the hold lapsed, another renter may be holding the unit now.
      const holdSnap = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('mapEngine')
        .doc('activeHolds')
        .collection('items')
        .doc(unitId)
        .get();
      const hold = holdSnap.exists ? (holdSnap.data() as Record<string, any>) : null;
      const heldUntil = timestampToDate(hold?.expiresAt);
      if (hold && hold.reservationId !== String(reservationId) && heldUntil && heldUntil > new Date()) {
        throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
      }
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

  const paymentVerified = paymentRequired || (!skipPayment && Boolean(paymentIntentId));
  // Stripe's id for the verified payment, which is the key for its use record.
  let verifiedPaymentIntentId: string | null = null;
  let verifiedAmountReceivedCents = 0;
  if (paymentVerified) {
    if (!paymentIntentId) {
      // Unreachable: a required payment without an id was refused above.
      throw new functions.https.HttpsError(
        'failed-precondition',
        'Payment is required before completing move-in.',
      );
    }
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

      // confirmPublicMoveInCheckout hands the PaymentIntent id to the browser,
      // so a renter can offer one reservation's payment for another. A
      // PaymentIntent whose metadata names another reservation, or another
      // kind of payment, is refused. One with no such metadata relies on the
      // one-use record written with the tenant below.
      const paymentMetadata = paymentIntent.metadata || {};
      const paymentType = String(paymentMetadata.type || '').trim();
      const paidReservationId = String(paymentMetadata.reservationId || '').trim();
      if (
        (paymentType && paymentType !== PUBLIC_MOVE_IN_PAYMENT_TYPE) ||
        (paidReservationId && paidReservationId !== String(reservationId))
      ) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          OTHER_RESERVATION_PAYMENT_MESSAGE,
        );
      }
      // A lapsed hold is honoured only for a payment that names this
      // reservation (createPublicMoveInCheckout puts it on the PaymentIntent),
      // not one that names none.
      if (finishingAfterLapsedHold && paidReservationId !== String(reservationId)) {
        throw new functions.https.HttpsError('failed-precondition', 'Reservation has expired');
      }
      // The paid-checkout trigger completes a move-in unasked, so only with a
      // payment made through this reservation's checkout, which names it.
      // Untagged payments are accepted from the renter's browser only.
      if (caller.kind === 'paidCheckout' && paidReservationId !== String(reservationId)) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          OTHER_RESERVATION_PAYMENT_MESSAGE,
        );
      }

      verifiedPaymentIntentId = String(paymentIntent.id || '').trim();
      if (!verifiedPaymentIntentId) {
        throw new functions.https.HttpsError('internal', 'Failed to validate payment intent');
      }
      verifiedAmountReceivedCents = paymentIntent.amount_received;
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

  // Move-ins completed before the one-use record existed left only their
  // payment ledger entry. A failed lookup is logged and let through: the
  // record still stops any payment used from now on, and a renter who has
  // paid is not turned away by a read error.
  if (verifiedPaymentIntentId) {
    let usedByEarlierMoveIn = false;
    try {
      const priorEntries = await admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .where('referenceId', '==', verifiedPaymentIntentId)
        .get();
      usedByEarlierMoveIn = priorEntries.docs.some((doc) => {
        const entry = (doc.data() || {}) as Record<string, any>;
        return entry.type === 'payment' && entry.createdBy === 'publicMoveIn';
      });
    } catch (err: any) {
      functions.logger.error('Public move-in: prior payment lookup failed', {
        error: err?.message || String(err),
        facilityId,
        paymentIntentId: verifiedPaymentIntentId,
      });
    }
    if (usedByEarlierMoveIn) {
      functions.logger.warn('Public move-in: payment already used by an earlier move-in', {
        facilityId,
        reservationId,
        paymentIntentId: verifiedPaymentIntentId,
      });
      throw new functions.https.HttpsError('failed-precondition', PAYMENT_ALREADY_USED_MESSAGE);
    }
  }

  // A renter who has paid is never turned away for capacity or for a unit
  // taken off online rental: both were checked when checkout was created, and
  // refusing after Checkout has charged left the renter paid with no tenancy,
  // no refund and nothing said to the owner. A paid move-in into a unit no
  // longer offered goes ahead and the owner is told (after the transaction).
  // A move-in with nothing to pay has no checkout, so it is refused here.
  if (!paymentVerified) {
    if (unitNotOfferedReason) {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
    }
    await assertFacilityHasTenantCapacity(admin.firestore(), facilityId);
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

  // The tenant's ongoing rent comes from the unit document only.
  //
  // Reading it from reservation metadata or from the caller's line items let an
  // unauthenticated mover set their own recurring rent for the life of the
  // tenancy, not just the move-in payment.
  const deriveMonthlyRate = (): number => {
    const unitRate = Number(preloadedUnitData?.monthlyRate);
    return Number.isFinite(unitRate) && unitRate > 0 ? unitRate : 0;
  };

  // Perform transactional writes for tenant/contract/unit/reservation/charges
  const transactionResult = await admin.firestore().runTransaction(async (tx) => {
    // Re-check reservation inside transaction. Completed by the other caller
    // since the checks above, it is refused here: the renter's browser and
    // the paid-checkout trigger can arrive together.
    const freshReservation = await tx.get(reservationRef);
    if (!freshReservation.exists) {
      throw new functions.https.HttpsError('not-found', 'Reservation not found');
    }
    const freshData = freshReservation.data() as Record<string, any>;
    assertCallerMayComplete(caller, freshData);
    if (freshData.status !== 'pending' && freshData.status !== 'confirmed') {
      throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
    }

    // One PaymentIntent completes one move-in. Read here and written with the
    // tenant, so two completions racing on one payment cannot both succeed.
    const paymentUseRef = verifiedPaymentIntentId
      ? admin.firestore().collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(verifiedPaymentIntentId)
      : null;
    if (paymentUseRef) {
      const paymentUseSnap = await tx.get(paymentUseRef);
      if (paymentUseSnap.exists) {
        const paymentUse = (paymentUseSnap.data() || {}) as Record<string, any>;
        functions.logger.warn('Public move-in: payment already used', {
          facilityId,
          reservationId,
          paymentIntentId: verifiedPaymentIntentId,
          usedByReservationId: paymentUse.reservationId,
          refused: paymentUse.refusedAt != null,
        });
        throw new functions.https.HttpsError(
          'failed-precondition',
          paymentUse.refusedAt != null ? PAYMENT_REFUSED_MESSAGE : PAYMENT_ALREADY_USED_MESSAGE,
        );
      }
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
        if (!portalTenantMayLink(sourceTenantData, normalizedEmail)) {
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
      notes: form.notes,
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
          signerEmail: normalizedEmail,
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

    // Ledger entries for charges.
    //
    // Posted from the server-computed quote, not from the caller's `lineItems`.
    // The client payload could previously be emptied (creating a tenancy with no
    // debits while the payment still posted a credit) or filled with arbitrary
    // amounts and ledger types.
    chargeQuote.lineItems.forEach((item) => {
      const ledgerRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .doc();

      tx.set(ledgerRef, {
        tenantId: tenantRef.id,
        facilityId,
        type: item.type || 'moveInCharge',
        amount: Number(item.amount || 0),
        description: item.description || 'Move-in charge',
        referenceId: contractRef.id,
        entryDate: moveInDate,
        dueDate: null,
        status: 'posted',
        createdAt: nowTs,
        createdBy: 'publicMoveIn',
        metadata: {
          lineItemId: null,
          isProrated: item.type === 'proratedRent',
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

    if (paymentUseRef) {
      tx.set(paymentUseRef, {
        paymentIntentId: verifiedPaymentIntentId,
        facilityId,
        reservationId: String(reservationId),
        tenantId: tenantRef.id,
        contractId: contractRef.id,
        amountReceivedCents: verifiedAmountReceivedCents,
        createdAt: nowTs,
        createdBy: 'publicMoveIn',
      });
    }

    // The payment, with the tenant it pays for. Written after the
    // transaction, it was lost whenever that write failed: a retry finds the
    // reservation completed and writes nothing.
    if (!skipPayment && verifiedPaymentIntentId && verifiedTotalAmount > 0) {
      const paymentLedgerRef = admin.firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .doc();
      tx.set(paymentLedgerRef, {
        tenantId: tenantRef.id,
        facilityId,
        type: 'payment',
        amount: -Number(verifiedTotalAmount),
        description: 'Move-in payment',
        referenceId: verifiedPaymentIntentId,
        entryDate: new Date(),
        status: 'posted',
        createdAt: nowTs,
        createdBy: 'publicMoveIn',
        metadata: {
          paymentIntentId: verifiedPaymentIntentId,
        },
      });
    }

    // The tenant's gate code, and the unit's checkout hold cleared, with the
    // tenant too. Done after the transaction, a run that stopped after it
    // (a timeout, an instance lost) left them undone, and nothing redid them:
    // the next run finds the reservation completed.
    const gateAccessCode = generateAccessCode();
    tx.set(
      admin.firestore().collection('facilities').doc(facilityId).collection('gateAccess').doc(),
      {
        facilityId,
        tenantId: tenantRef.id,
        tenantName: name,
        accessCode: gateAccessCode,
        isActive: true,
        validFrom: null,
        validUntil: null,
        allowedDays: [],
        allowedStartTime: null,
        allowedEndTime: null,
        notes: 'Auto-generated from public move-in',
        createdAt: nowTs,
        updatedAt: nowTs,
        createdBy: 'publicMoveIn',
      },
    );
    if (unitId) {
      tx.delete(
        admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('mapEngine')
          .doc('activeHolds')
          .collection('items')
          .doc(unitId),
      );
    }

    // Update reservation status
    tx.update(reservationRef, {
      status: 'completed',
      completedAt: nowTs,
      updatedAt: nowTs,
      tenantId: tenantRef.id,
      contractId: contractRef.id,
      completedBy: 'publicMoveIn',
      // Which caller got here first: the renter's browser or the paid-checkout trigger.
      completedVia: caller.kind,
      paymentIntentId: verifiedPaymentIntentId,
    });

    // Its contents are on the tenant and the contract now; the government ID
    // and signature are not kept a second time.
    tx.delete(savedMoveInFormRef(reservationId));

    return {
      tenantId: tenantRef.id,
      contractId: contractRef.id,
      gateAccessCode,
    };
  });

  const { tenantId, contractId, gateAccessCode } = transactionResult;

  // Reached only when paid (unpaid ones were refused above).
  if (unitNotOfferedReason && unitId) {
    await notifyOwnerOfMoveInToUnitNotOffered({
      facilityId,
      tenantId,
      tenantName: name.trim(),
      unitId,
      unitNumber: displayUnitNumber,
      reason: unitNotOfferedReason,
      reservationId: String(reservationId),
      paymentIntentId: verifiedPaymentIntentId,
    });
  }

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

  functions.logger.info('Public move-in completed', {
    reservationId,
    facilityId,
    tenantId,
    contractId,
    paymentIntentId,
    completedVia: caller.kind,
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
    status: 'completed',
    reservationId,
    tenantId,
    contractId,
    gateAccessCode,
  };
}

/**
 * The renter's browser completes their online move-in (no auth; the
 * reservation's move-in token).
 *
 * The form comes with the request, or, with `useSavedForm`, is the one saved
 * when checkout was created: a renter coming back from Stripe has paid and
 * already filled it in. A reservation already completed, as the paid-checkout
 * trigger may have done while they were away, answers `alreadyCompleted`.
 */
export const completePublicMoveIn = functions.runWith({ secrets: [...STRIPE_SECRETS, SENDGRID_API_KEY] }).https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);

  const reservationId = String(data?.reservationId || '').trim();
  const token = String(data?.token || '').trim();
  if (!reservationId || !token) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields');
  }
  if (reservationId.includes('/') || reservationId.length > 128) {
    throw new functions.https.HttpsError('invalid-argument', 'Valid reservationId is required');
  }
  let formSource: MoveInFormSource;
  if (data?.useSavedForm === true) {
    formSource = { kind: 'saved' };
  } else {
    const form = moveInFormFromData(data);
    assertMoveInFormComplete(form);
    formSource = { kind: 'provided', form };
  }

  const result = await completeMoveInForReservation({
    reservationId,
    caller: { kind: 'renter', token },
    formSource,
    paymentIntentId: data?.paymentIntentId ? String(data.paymentIntentId) : null,
    skipPayment: Boolean(data?.skipPayment),
  });

  if (result.status === 'alreadyCompleted') {
    return { success: true, alreadyCompleted: true, reservationId };
  }
  return {
    success: true,
    tenantId: result.tenantId,
    contractId: result.contractId,
    gateAccessCode: result.gateAccessCode,
    reservationId,
  };
});

