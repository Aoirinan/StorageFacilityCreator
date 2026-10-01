import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import * as crypto from 'crypto';
import { getDownloadURL } from 'firebase-admin/storage';
import {
  enforceAppCheckOrThrow,
  enforceRateLimit,
  escapeHtml,
  enabledOnlineUnitTypes,
  facilityTakesOnlineRentals,
  getStripeClient,
  isArchivedForOnlineRental,
  isInternalUseUnit,
  isUnitOfferedOnline,
  isUnitTypeOfferedOnline,
  moveInPaymentReturnedBeforeMoveIn,
  readActiveTenantUnitClaims,
  sendFacilityEmailWithCompliance,
  unitNotOfferedOnlineReason,
  unitTypeOf,
} from '@sfc/functions-shared';
import type { ActiveTenantUnitClaims } from '@sfc/functions-shared';
import {
  amountsMatchCents,
  isPublicMoveInStripePaymentRequired,
  isUnpricedPaidMoveIn,
  loadPublicMoveInChargeQuote,
  MOVE_IN_NOT_PRICED_MESSAGE,
} from './moveInCharges';
import { SENDGRID_API_KEY, SENDGRID_FROM_EMAIL, STRIPE_SECRETS } from './secrets';
import { optionalStripeCheckoutCustomerEmail } from './stripeHelpers';
import {
  CHECKOUT_ALREADY_PAID_MESSAGE,
  expireRecordedSessionOnRefusal,
  paymentIntentIdOf,
  recordCheckoutSession,
  recordedCheckoutSession,
  reusableCheckoutSession,
} from './checkoutSessionReuse';
import type { PayableSession } from './checkoutSessionReuse';
import { generateAccessCode } from './accessCode';
import { createAutopayNotificationAndEvent } from './autopayNotification';
import { resolveSmsConsentFields } from './smsConsent';
import { assertOnlineRentalNotOnDnrList } from './dnrScreening';
import { resolveMoveInPaymentStripeAccountId } from './moveInPayment';
import { assertFacilityHasTenantCapacity } from './tenantCapacity';
import { unitIsTaken } from './unitTaken';
import {
  CHECKOUT_ATTEMPT_FIELD,
  CHECKOUT_PAID_FIELD,
  CHECKOUT_RUN_OUT_MESSAGE,
  CHECKOUT_SESSION_EXPIRES_FIELD,
  checkoutFieldsOf,
  checkoutHoldWindow,
  checkoutMayHaveBeenPaid,
  holdCapCountsFrom,
  holdForPaidCheckout,
  holderMayBePaying,
  laterExpiry,
  narrowCheckoutSessionExpiry,
  readHoldersReservation,
  restoreHoldAfterFailedCheckout,
  timestampToDate,
  unitHoldRef,
} from './checkoutHold';
import type { ReplacedHold } from './checkoutHold';
import {
  onlineMoveInReviewAlert,
  onlineMoveInReviewRef,
} from './onlineMoveInReview';
import type { MoveInReviewReason, MoveInUnitChanges } from './onlineMoveInReview';
import {
  PAYMENT_ALREADY_USED_MESSAGE,
  PAYMENT_REFUNDED_MESSAGE,
  PAYMENT_RETURNED_BEFORE_MOVE_IN_MESSAGE,
  PUBLIC_MOVE_IN_PAYMENTS_COLLECTION,
  moveInPaymentStoppedBy,
  paymentOwnership,
  refusePaidMoveIn,
  resumePaidMoveInRefund,
} from './paidMoveInRefund';
import type { OfferedPayment, PaidMoveInRefusal } from './paidMoveInRefund';

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
 * Whether [reservation] ([reservationId]) was paid for through its checkout
 * and the payment has neither moved anyone in nor been refused and refunded:
 * a renter who paid and never finished. From the payment a confirmation
 * found, or else from the Checkout Session checkout recorded, which Stripe is
 * asked about. False when Stripe cannot say: the reservation is then marked
 * expired, which leaves it to be found paid on a later look.
 */
async function hasUnfinishedPayment(reservationId: string, reservation: Record<string, unknown>): Promise<boolean> {
  let paymentIntentId = textOf(reservation[CHECKOUT_PAID_FIELD]);
  if (!paymentIntentId) {
    const recorded = recordedCheckoutSession(reservation);
    if (!recorded) return false;
    const facilityId = textOf(reservation.facilityId);
    let account = recorded.accountId;
    try {
      if (!account && facilityId) {
        const facility = await admin.firestore().collection('facilities').doc(facilityId).get();
        account = textOf(facility.data()?.stripeConnectAccountId);
      }
      if (!account) return false;
      const session = await getStripeClient().checkout.sessions.retrieve(recorded.id, {}, { stripeAccount: account });
      if (session.payment_status !== 'paid' || session.metadata?.reservationId !== reservationId) return false;
      paymentIntentId = textOf(paymentIntentIdOf(session));
    } catch (err: unknown) {
      functions.logger.warn('getPublicReservationByToken: could not check the recorded session of a lapsed reservation', {
        facilityId,
        reservationId,
        sessionId: recorded.id,
        message: err instanceof Error ? err.message : String(err),
      });
      return false;
    }
  }
  if (!paymentIntentId) return false;
  const use = await admin.firestore().collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(paymentIntentId).get();
  return !use.exists;
}

/**
 * Public token lookup for reservation flow.
 * This keeps unauthenticated move-in working while Firestore blocks anonymous list queries.
 *
 * A reservation whose hold lapsed is marked expired and not returned, unless
 * its renter may still be paying (checkoutMayHaveBeenPaid) or paid and never
 * finished (hasUnfinishedPayment). Only the first day after checkout counted
 * before: a renter who paid and came back later was told 'not found', and
 * nothing refunded them or told the owner. Now they finish, or completion
 * refuses and refunds them and says so.
 */
export const getPublicReservationByToken = functions
  .runWith({ secrets: STRIPE_SECRETS })
  .https.onCall(async (data: any, context) => {
  enforceAppCheckOrThrow(context);
  const token = String(data?.token || '').trim();
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(token)) {
    throw new functions.https.HttpsError('invalid-argument', 'Valid token is required');
  }

  const snapshot = await admin.firestore()
    .collection('publicReservations')
    .where('moveInToken', '==', token)
    .where('status', 'in', ['pending', 'confirmed', 'expired'])
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
  const alreadyExpired = reservation.status === 'expired';
  // Still returned when checkout has started: the renter may have paid, and
  // completePublicMoveIn moves in or refunds a renter who has paid.
  if (alreadyExpired || (expiresAt && expiresAt.toDate() < new Date() && !checkoutMayHaveBeenPaid(reservation))) {
    if (!await hasUnfinishedPayment(doc.id, reservation)) {
      if (!alreadyExpired) {
        await doc.ref.set(
          {
            status: 'expired',
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }
      return { found: false };
    }
    functions.logger.info('getPublicReservationByToken: a lapsed reservation was paid for and never finished', {
      facilityId: facilityIdForRateLimit,
      reservationId: doc.id,
    });
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

/** For a renter whose payment could not be checked, where trying again can settle it. */
export const PAYMENT_CHECK_UNAVAILABLE_MESSAGE =
  'Your payment could not be checked just now. Please try again in a moment.';

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
  // The public website shows "Rent now" by the same test
  // (facilityAcceptsPublicRentals), so it never links to this refusal.
  if (!facilityTakesOnlineRentals(settings)) {
    throw new functions.https.HttpsError('failed-precondition', ONLINE_RENTALS_OFF_MESSAGE);
  }
  return settings;
}

/**
 * Whether checkout must refuse the unit [unitId] ([unit] its doc, null when
 * gone): not available or reserved, not offered online, of a type the owner
 * does not rent online ([enabledUnitTypes]), or taken (unitIsTaken). The
 * tenants' claims are read ([readClaims]) only for a unit that passes the
 * rest. Same test and refusal as both holds.
 */
async function unitCannotBeRentedOnline(
  unitId: string,
  unit: Record<string, unknown> | null,
  enabledUnitTypes: string[],
  readClaims: () => Promise<ActiveTenantUnitClaims>,
): Promise<boolean> {
  if (!unit) return true;
  const status = String(unit.status || '').toLowerCase();
  if (status !== 'available' && status !== 'reserved') return true;
  if (!isUnitOfferedOnline(unit) || !isUnitTypeOfferedOnline(unit, enabledUnitTypes)) return true;
  return unitIsTaken(unitId, unit, await readClaims());
}

/** A doc's text field trimmed, or null when it is not a string or is blank (TenantModel.textField). */
function textOf(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

/**
 * The fields that make the unit [unitId] ([unit] is its doc) a new tenant's
 * unit, as the app's move-in writes them (TenantService.createTenant with a
 * picked unit, TenantModel.primaryUnitCreate): the unit's number trimmed, its
 * id, and its area trimmed, left out when it has none. Without unitId an
 * online tenant's unit was named by number alone, which is no one unit where
 * numbers repeat across areas: the claim rule (activeTenantUnitClaims) then
 * took every unit with that number off the market.
 */
function primaryUnitCreateFields(unitId: string, unit: Record<string, unknown>): Record<string, string> {
  const unitNumber = String(unit.unitNumber ?? '').trim();
  const unitArea = textOf(unit.area);
  return {
    ...(unitNumber ? { unitNumber } : {}),
    unitId,
    ...(unitArea ? { unitArea } : {}),
  };
}

/** The id of an online move-in's payment row in the facility's ledgers: one per PaymentIntent. */
export function moveInPaymentLedgerId(paymentIntentId: string): string {
  return `publicMoveInPayment_${paymentIntentId}`;
}

function facilityTenants(facilityId: string): admin.firestore.CollectionReference {
  return admin.firestore().collection('facilities').doc(facilityId).collection('tenants');
}

/**
 * Why [unit] is no longer offered online, or null: taken off online rental,
 * or of a type the owner no longer rents online. A listing choice, not a
 * physical one, so a renter who has already paid is still moved in.
 */
function moveInReviewReasonFor(
  unit: Record<string, unknown>,
  enabledUnitTypes: string[],
): MoveInReviewReason | null {
  const reason = unitNotOfferedOnlineReason(unit);
  if (reason) return reason;
  return isUnitTypeOfferedOnline(unit, enabledUnitTypes) ? null : 'unit-type-not-offered';
}

async function readPublicSettings(facilityId: string): Promise<Record<string, unknown>> {
  const snap = await admin.firestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('settings')
    .doc('public')
    .get();
  return (snap.data() || {}) as Record<string, unknown>;
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
    // it. And a unit a tenant has, by link or by an active tenant's claim
    // (their unitId, or with none their unit number in their area): the map
    // shows it rented, but a stale map or a direct call with its published id
    // held it, and a second tenant moved in. The tenants are read only for a
    // unit that passes the rest.
    if (
      (unitStatus !== 'available' && unitStatus !== 'reserved') ||
      !isUnitOfferedOnline(unitData) ||
      !isUnitTypeOfferedOnline(unitData, enabledUnitTypes) ||
      unitIsTaken(unitRef.id, unitData, await readActiveTenantUnitClaims(facilityTenants(String(facilityId)), tx))
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

export const CANCEL_AFTER_CHECKOUT_MESSAGE =
  'This reservation has gone to payment, so it cannot be cancelled here. If you paid, finish your move-in ' +
  'from your move-in link; otherwise it ends on its own. Contact the facility for help.';

/**
 * Whether [reservation] has been to Stripe's checkout, so it may have been
 * paid: checkout started, a session recorded, or a paid one confirmed.
 * Stripe is not asked, and a session paid but never confirmed looks like one
 * never paid, so any of these counts.
 */
function wentToCheckout(reservation: Record<string, unknown>): boolean {
  return reservation.checkoutUpdatedAt != null ||
    recordedCheckoutSession(reservation) != null ||
    Boolean(textOf(reservation[CHECKOUT_PAID_FIELD]));
}

/**
 * Token-gated public status transition. Public clients may only cancel an
 * active reservation; confirmation and completion remain server-controlled.
 *
 * Not one that has been to checkout (wentToCheckout): cancelling it deleted
 * its hold and refunded nothing, so a renter who had paid lost the unit, and
 * their money stayed with the owner, who was told nothing. A reservation
 * that went to checkout ends by completing, by a refusal that refunds the
 * payment (paidMoveInRefund.ts), or by lapsing.
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
    // Read here, so a checkout started since the read above is seen.
    if (wentToCheckout(reservation)) {
      throw new functions.https.HttpsError('failed-precondition', CANCEL_AFTER_CHECKOUT_MESSAGE);
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

export const createPublicMoveInCheckout = functions
  .runWith({ secrets: STRIPE_SECRETS })
  .https.onCall(expireRecordedSessionOnRefusal(async (data: any, context) => {
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

  // Keyed on the facility from the stored reservation, never the request.
  await enforceRateLimit({
    facilityId: String(facilityId),
    key: 'createPublicMoveInCheckout',
    limit: 30,
    windowSeconds: 60,
    userId: context.auth?.uid || null,
  });

  // The unit can be rented, unlisted, archived, set to internal use or have
  // its type taken off online rental while it is held (up to 15 minutes for a
  // public hold, 60 for a tenant-portal one). completePublicMoveIn has to
  // refund or move in such a renter once they have paid, so checkout refuses
  // them first. Same test and refusal as both holds, including a tenant's
  // link or claim, which the public map shows as rented; trimmed as
  // loadPublicMoveInChargeQuote does, so the unit checked is the unit priced.
  // Checked here first so a refused renter is not screened and priced, and
  // again in the transaction below, which decides.
  const reservedUnitId = String(reservation.unitId || '').trim();
  const reservedUnitRef = reservedUnitId
    ? admin.firestore().collection('facilities').doc(facilityId).collection('units').doc(reservedUnitId)
    : null;
  let checkoutUnitTypes: string[] = [];
  if (reservedUnitRef) {
    const [unitSnap, publicSettings] = await Promise.all([reservedUnitRef.get(), readPublicSettings(facilityId)]);
    checkoutUnitTypes = enabledOnlineUnitTypes(publicSettings);
    if (await unitCannotBeRentedOnline(
      reservedUnitId,
      unitSnap.exists ? (unitSnap.data() as Record<string, unknown>) : null,
      checkoutUnitTypes,
      () => readActiveTenantUnitClaims(facilityTenants(facilityId)),
    )) {
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

  await assertOnlineRentalNotOnDnrList(admin.firestore(), {
    name: reservation.name ? String(reservation.name).trim() : '',
    email: String(reservation.email || '').trim().toLowerCase(),
    phone: reservation.phone ? String(reservation.phone).trim() : '',
  });

  // Priced for the renter's move-in date, or today when they gave none. That
  // day is recorded with the amount (checkoutMoveInDate), and completion prices
  // it rather than its own today: proration changes at midnight, server time
  // (UTC), so a renter who paid before it and finished after it was refused
  // as 'charges changed' and refunded.
  const moveInDate = timestampToDate(reservation.moveInDate) ?? new Date();
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
  // short expiry below, by only the minutes to come back from it; confirming
  // a paid session gives the time to finish the form (holdForPaidCheckout).
  // Written before Stripe is called: if this fails, there is no payable
  // session that the hold does not cover.
  const holdWindow = checkoutHoldWindow(new Date(), holdCapCountsFrom(reservation));
  if (!holdWindow) {
    throw new functions.https.HttpsError('failed-precondition', CHECKOUT_RUN_OUT_MESSAGE);
  }
  const holdUntil = holdWindow.holdUntil;
  const holdRef = reservedUnitId ? unitHoldRef(facilityId, reservedUnitId) : null;
  const attemptId = crypto.randomUUID();
  const replaced = await admin.firestore().runTransaction(async (tx): Promise<ReplacedHold> => {
    const currentSnap = await tx.get(reservationRef);
    const current = (currentSnap.data() || {}) as Record<string, any>;
    if (current.status !== 'pending' && current.status !== 'confirmed') {
      throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
    }
    // Paid already (from a tab opened before the payment, say): refused
    // before anything is written. Before, it was found paid only when Stripe
    // was asked, after the writes below: its amount and priced day were
    // overwritten until restoreHoldAfterFailedCheckout put them back, and a
    // completion in between, or a restore that failed, could check the
    // payment against them and refund it as 'charges changed'. A refund for
    // changed charges clears the field, so that renter can still pay the new
    // amount.
    if (textOf(current[CHECKOUT_PAID_FIELD])) {
      throw new functions.https.HttpsError('failed-precondition', CHECKOUT_ALREADY_PAID_MESSAGE);
    }
    // The unit and its tenants, read again here: checked only before the
    // transaction, a unit another renter completed onto (or the owner
    // rented) in between still got a payable session, and completion then
    // refunded this renter after taking their money. Read here, a change to
    // either before the commit makes the transaction run again.
    if (reservedUnitRef) {
      const unitSnap = await tx.get(reservedUnitRef);
      if (await unitCannotBeRentedOnline(
        reservedUnitId,
        unitSnap.exists ? (unitSnap.data() as Record<string, unknown>) : null,
        checkoutUnitTypes,
        () => readActiveTenantUnitClaims(facilityTenants(facilityId), tx),
      )) {
        throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
      }
    }

    let hold: Record<string, any> | null = null;
    if (holdRef) {
      const holdSnap = await tx.get(holdRef);
      hold = holdSnap.exists ? (holdSnap.data() as Record<string, any>) : null;
      const heldUntil = timestampToDate(hold?.expiresAt);
      if (hold && hold.reservationId !== String(reservationId) && heldUntil && heldUntil > new Date()) {
        throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
      }
    }

    tx.update(reservationRef, {
      expectedCheckoutAmountCents: chargeQuote.totalCents,
      checkoutMoveInDate: admin.firestore.Timestamp.fromDate(moveInDate),
      [CHECKOUT_ATTEMPT_FIELD]: attemptId,
      // Before Stripe is asked, so no payable session outlasts it: the one
      // made below ends then, and one handed back ends sooner (narrowed after).
      [CHECKOUT_SESSION_EXPIRES_FIELD]: admin.firestore.Timestamp.fromDate(
        laterExpiry(current[CHECKOUT_SESSION_EXPIRES_FIELD], holdWindow.sessionExpiresAt),
      ),
      checkoutUpdatedAt: admin.firestore.FieldValue.serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromDate(laterExpiry(current.expiresAt, holdUntil)),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const ownHold = Boolean(hold && hold.reservationId === String(reservationId));
    if (holdRef && ownHold) {
      tx.update(holdRef, {
        expiresAt: admin.firestore.Timestamp.fromDate(laterExpiry(hold?.expiresAt, holdUntil)),
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
    return {
      reservationExpiresAt: current.expiresAt ?? null,
      checkoutFields: checkoutFieldsOf(current),
      holdExpiresAt: ownHold ? hold?.expiresAt ?? null : null,
    };
  });

  /**
   * Records when [payable], a session made earlier and handed back, stops
   * taking payment. Best effort: failing leaves the later expiry written
   * above, which only counts this renter as paying for longer.
   */
  const narrowSessionExpiry = async (payable: PayableSession): Promise<void> => {
    if (!payable.expiresAt) return;
    try {
      await narrowCheckoutSessionExpiry({ reservationRef, attemptId, payableUntil: payable.expiresAt });
    } catch (err: any) {
      functions.logger.warn('createPublicMoveInCheckout: could not record when the handed-back session expires', {
        facilityId,
        reservationId: String(reservationId),
        sessionId: payable.id,
        error: err?.message || String(err),
      });
    }
  };

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
    // After every check above, so a session is handed back only for a unit
    // that can still be rented. One payable session per reservation
    // (checkoutSessionReuse.ts).
    const sessionLookup = {
      reservationId: String(reservationId),
      cents,
      stripeAccount: connectAccountId,
      now: new Date(),
    };
    const reusable = await reusableCheckoutSession(
      stripe.checkout.sessions,
      recordedCheckoutSession(reservation),
      sessionLookup,
    );
    if (reusable) {
      await narrowSessionExpiry(reusable);
      return {
        checkoutUrl: reusable.url,
        sessionId: reusable.id,
      };
    }
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
          type: 'public_move_in',
          reservationId: String(reservationId),
          moveInToken: String(token),
          facilityId,
        },
        // Checkout does not copy the session's metadata to the PaymentIntent,
        // and completion sees only the PaymentIntent. Tagged, it can be
        // refused for another reservation, and refunded for this one, without
        // asking Stripe for its session. No token: it is a secret. No
        // facilityId: the charge.refunded webhook (functions-integrations)
        // posts a refund to the ledger of any PaymentIntent carrying one, and
        // a move-in refunded here never posted its payment there.
        payment_intent_data: {
          metadata: {
            type: 'public_move_in',
            reservationId: String(reservationId),
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

    // Recorded before its link is handed out, so the next press finds it.
    const payable = await recordCheckoutSession(
      stripe.checkout.sessions,
      reservationRef,
      recordedCheckoutSession(reservation),
      { id: session.id, url: session.url },
      sessionLookup,
    );
    // Another press's session, when one was recorded meanwhile.
    await narrowSessionExpiry(payable);
    return {
      checkoutUrl: payable.url,
      sessionId: payable.id,
    };
  } catch (err: unknown) {
    // No session the renter can pay: the unit need not stay held for one.
    try {
      await restoreHoldAfterFailedCheckout({
        reservationRef,
        holdRef,
        reservationId: String(reservationId),
        attemptId,
        holdUntil,
        replaced,
      });
    } catch (restoreErr: any) {
      functions.logger.error('createPublicMoveInCheckout: could not restore the hold after a failed checkout', {
        facilityId,
        reservationId: String(reservationId),
        error: restoreErr?.message || String(restoreErr),
      });
    }
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
}));

/**
 * When a paid Checkout Session was paid, as near as it says: its
 * PaymentIntent's creation when expanded, else the session's own creation
 * (both no later than the payment), else [now]. Early rather than late, so
 * the cap on how long the payer keeps the unit (PAID_HOLD_MAX_HOURS) is
 * never stretched.
 */
function paidAtOf(
  session: { created?: number | null; payment_intent?: unknown },
  now: Date,
): Date {
  const intentCreated = (session.payment_intent as { created?: unknown } | null | undefined)?.created;
  const seconds = typeof intentCreated === 'number' ? intentCreated
    : typeof session.created === 'number' ? session.created
      : null;
  if (seconds == null || !Number.isFinite(seconds)) return now;
  const at = new Date(seconds * 1000);
  return at < now ? at : now;
}

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

  if (!reservationId || !token) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'reservationId and token are required',
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

  // With no sessionId, the session checkout recorded for this reservation
  // (checkoutSessionReuse.ts). A renter who paid in Stripe's tab and closed it
  // before its redirect, or who came back on the link without it, had no
  // session_id: the page never confirmed the payment, paying again was refused
  // as already paid, and nothing let them finish. The move-in page asks this
  // way on opening and before starting a checkout, so nothing recorded, nothing
  // paid, or Stripe not answering is 'not paid', not an error: checkout makes
  // its own check of the recorded session before it makes another.
  const notPaid = { success: false, paid: false };
  const recorded = sessionId ? null : recordedCheckoutSession(reservation);
  if (!sessionId && !recorded) return notPaid;
  // Completion verifies the payment on the facility's account now; checkout
  // expires a session left on a previous one, or refuses it as already paid.
  if (recorded?.accountId && recorded.accountId !== connectAccountId) return notPaid;

  const stripe = getStripeClient();
  let session: Awaited<ReturnType<typeof stripe.checkout.sessions.retrieve>>;
  try {
    session = await stripe.checkout.sessions.retrieve(
      String(sessionId || recorded?.id),
      {
        expand: ['payment_intent'],
      },
      {
        stripeAccount: connectAccountId,
      },
    );
  } catch (err: unknown) {
    if (sessionId) throw err;
    functions.logger.warn('confirmPublicMoveInCheckout: recorded session could not be read', {
      facilityId,
      reservationId: String(reservationId),
      sessionId: recorded?.id,
      message: err instanceof Error ? err.message : String(err),
    });
    return notPaid;
  }

  if (session.payment_status !== 'paid') {
    if (!sessionId) return notPaid;
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
  // Refused at completion and refunded (changed charges leave the
  // reservation open to pay again), or refunded in Stripe or disputed before
  // the move-in: it can never move anyone in. Handed back, the page offered
  // it as the payment to finish with, the renter filled in and signed the
  // whole form, and completion refused it.
  const stoppedBy = await moveInPaymentStoppedBy(paymentIntentId);
  if (stoppedBy) {
    if (!sessionId) return notPaid;
    throw new functions.https.HttpsError(
      'failed-precondition',
      stoppedBy === 'refunded' ? PAYMENT_REFUNDED_MESSAGE : PAYMENT_RETURNED_BEFORE_MOVE_IN_MESSAGE,
    );
  }
  if (!sessionId) {
    functions.logger.info('confirmPublicMoveInCheckout: found a paid session no redirect confirmed', {
      facilityId,
      reservationId: String(reservationId),
      sessionId: session.id,
      paymentIntentId,
    });
  }

  // Paid: the renter now re-enters the whole form (Stripe's redirect reloads
  // the page), so the unit is held for them again, whether or not the
  // checkout's hold has lapsed, for an hour but never past
  // PAID_HOLD_MAX_HOURS after payment. Not claimed over the live hold of
  // another renter who may be paying for it; completion refunds this renter
  // if that one still has the unit then. Recorded for the sweep as well, as
  // the Connect webhook records it. A failure here does not stop them:
  // completion checks the unit itself.
  try {
    const now = new Date();
    const unitHold = await holdForPaidCheckout({
      facilityId,
      reservationId: String(reservationId),
      paymentIntentId,
      checkoutSessionId: session.id,
      connectAccountId,
      amountCents: typeof session.amount_total === 'number' ? session.amount_total : null,
      paidAt: paidAtOf(session, now),
      now,
    });
    if (unitHold !== 'held') {
      functions.logger.warn('confirmPublicMoveInCheckout: a paid renter\'s unit was not held for them', {
        facilityId,
        reservationId: String(reservationId),
        paymentIntentId,
        outcome: unitHold,
      });
    }
  } catch (err: any) {
    functions.logger.error('confirmPublicMoveInCheckout: could not hold the unit for a paid renter', {
      facilityId,
      reservationId: String(reservationId),
      error: err?.message || String(err),
    });
  }

  return {
    success: true,
    paid: true,
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
    rvSite: 'RV site',
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

  // A renter who says they have paid is not turned away before the payment is
  // verified: once it is, they are moved in or refunded, never just refused.
  // Refusing here first left a renter who had paid with no tenancy and no
  // refund, and nothing said to the owner.
  const claimsPayment = !skipPayment && Boolean(paymentIntentId);
  // The first reason a renter who has paid cannot be moved in, with the error
  // an unpaid move-in gets for it. Acted on once the payment is verified.
  // (Cast, not annotated: TypeScript does not see the closure below assign it.)
  let paidRefusal = null as { refusal: PaidMoveInRefusal; unpaidError: functions.https.HttpsError } | null;
  const refuseUnlessPaid = (refusal: PaidMoveInRefusal, unpaidError: functions.https.HttpsError): void => {
    if (!claimsPayment) throw unpaidError;
    paidRefusal ??= { refusal, unpaidError };
  };

  const reservationStatus = String(reservation.status || '');
  const reservationActive = reservationStatus === 'pending' || reservationStatus === 'confirmed';
  const nowTs = admin.firestore.FieldValue.serverTimestamp();
  const expiresAt = reservation.expiresAt as admin.firestore.Timestamp | undefined;
  const reservationExpired = Boolean(expiresAt && expiresAt.toDate() < new Date());
  if (!claimsPayment) {
    if (!reservationActive) {
      throw new functions.https.HttpsError('failed-precondition', 'Reservation is not active');
    }
    if (reservationExpired) {
      // Left open while a renter who went to checkout may still come back
      // with their payment: getPublicReservationByToken finds only open ones.
      if (!checkoutMayHaveBeenPaid(reservation)) {
        await reservationRef.update({ status: 'expired', updatedAt: nowTs });
      }
      throw new functions.https.HttpsError('failed-precondition', 'Reservation has expired');
    }
  } else if (!reservationActive && reservationStatus !== 'expired') {
    // Completed or cancelled. An expired hold is not a refusal for a renter
    // who has paid: the hold is 15 minutes and paying can take longer, and
    // the unit itself decides below.
    refuseUnlessPaid(
      'reservation-closed',
      new functions.https.HttpsError('failed-precondition', 'Reservation is not active'),
    );
  }

  // Derive core context
  const facilityId = reservation.facilityId as string | undefined;
  const unitId = reservation.unitId as string | undefined;
  let displayUnitNumber = (reservation.unitNumber as string | undefined) || 'Unassigned';
  const reservationMetadata = (reservation.metadata as Record<string, any> | undefined) || {};
  const reservationSource = String(reservationMetadata.source || '').trim();
  const portalSourceTenantId = String(reservationMetadata.portalTenantId || '').trim();
  // The day checkout priced when the renter gave no move-in date: priced
  // afresh, a completion after midnight (UTC) quoted another day's proration
  // than the renter paid, and refused and refunded them as 'charges changed'.
  const moveInDate =
    timestampToDate(reservation.moveInDate) ?? timestampToDate(reservation.checkoutMoveInDate) ?? new Date();

  if (!facilityId) {
    throw new functions.https.HttpsError('failed-precondition', 'Reservation missing facilityId');
  }

  const facilityPreSnap = await admin.firestore().collection('facilities').doc(facilityId).get();
  const facilityPre = (facilityPreSnap.data() || {}) as Record<string, any>;
  const facilityNameForContext = String(facilityPre.name || 'Storage Facility').trim();
  const facilityAddressForContext = String(facilityPre.address || '').trim();
  const facilityPhoneForContext = String(facilityPre.phone || '').trim();
  const facilityEmailForContext = String(facilityPre.email || '').trim();

  // The unit types the owner rents online. Both holds and checkout check them;
  // looked at again here as the other listing choices are.
  const enabledUnitTypes = enabledOnlineUnitTypes(await readPublicSettings(facilityId));

  let preloadedUnitData: Record<string, any> | null = null;
  // Why the unit is no longer offered online, when it was unlisted, archived,
  // set to internal use or had its type taken off online rental since the
  // hold. Refused below only if nothing has been paid.
  let unitNotOfferedReason: MoveInReviewReason | null = null;
  // Optional unit validation. Checked again in the transaction, which decides.
  if (unitId) {
    const unitSnap = await admin.firestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('units')
      .doc(unitId)
      .get();

    if (!unitSnap.exists) {
      refuseUnlessPaid('unit-missing', new functions.https.HttpsError('not-found', 'Reserved unit not found'));
    } else {
      preloadedUnitData = unitSnap.data() as Record<string, any>;
      if (unitIsTaken(unitSnap.id, preloadedUnitData, await readActiveTenantUnitClaims(facilityTenants(facilityId)))) {
        refuseUnlessPaid(
          'unit-taken',
          new functions.https.HttpsError('failed-precondition', 'Unit is no longer available'),
        );
      }
      unitNotOfferedReason = moveInReviewReasonFor(preloadedUnitData, enabledUnitTypes);
      const numFromUnit = String(preloadedUnitData.unitNumber || '').trim();
      if (numFromUnit) {
        displayUnitNumber = numFromUnit;
      }
    }
  }

  const chargeQuote = await loadPublicMoveInChargeQuote({
    facilityId,
    reservation,
    moveInDate,
  });
  const requiredPaymentCents = chargeQuote.totalCents;
  const paymentRequired = isPublicMoveInStripePaymentRequired(facilityPre, chargeQuote.totalAmount);

  // A unit with rent priced at $0 at a facility paid online: pricing went
  // wrong, and the no-payment path below would hand the unit over for free.
  // A renter who says they paid (claimsPayment) through a checkout that
  // priced a positive amount still goes on to have the payment verified
  // against that amount, and is moved in or refunded: one who has paid is
  // not turned away. Checkout records that amount (at least $0.50) before
  // any session exists, so every renter who paid through it passes here; a
  // payment offered with no amount recorded was not made through checkout,
  // and with a $0 quote any untagged payment on the account would otherwise
  // cover it.
  const paidAtCheckout = claimsPayment && Number(reservation.expectedCheckoutAmountCents) > 0;
  if (isUnpricedPaidMoveIn(facilityPre, chargeQuote) && !paidAtCheckout) {
    functions.logger.error('Public move-in: a unit with rent was priced at nothing', {
      facilityId,
      reservationId,
      unitId: unitId || null,
      monthlyRent: chargeQuote.monthlyRent,
      moveInDate: moveInDate.toISOString(),
    });
    throw new functions.https.HttpsError('failed-precondition', MOVE_IN_NOT_PRICED_MESSAGE);
  }

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
  let verifiedPaymentMetadata: Record<string, string> = {};
  // Whether the payment names no reservation (taken before checkout tagged
  // payments) and its Checkout Session showed it was this reservation's.
  let untaggedPaymentShownOurs = false;
  const holdLapsedBeforeTransaction = reservationExpired || reservationStatus === 'expired';
  // The facility's connected account, which holds the payment and any refund.
  const connectAccountId = resolveMoveInPaymentStripeAccountId(facilityPre) || '';
  if (paymentVerified) {
    const chargesChanged = requiredPaymentCents > 0 && minimumPaymentCents !== requiredPaymentCents;
    try {
      const stripe = getStripeClient();
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
      const amountReceived = Number(paymentIntent.amount_received) || 0;
      // Money was taken, if not the amount now owed: refunded below, once the
      // payment is known to be this reservation's, rather than kept.
      const tookMoney =
        paymentIntent.status === 'succeeded' && amountReceived > 0 && String(paymentIntent.id || '').trim() !== '';
      const amountMismatch = new functions.https.HttpsError(
        'failed-precondition',
        'Payment not completed or amount mismatch',
      );
      if (amountReceived < requiredCents && !tookMoney) {
        throw amountMismatch;
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
      // one-use record written with the tenant below while the hold is live,
      // and on its Checkout Session once the hold has lapsed.
      const paymentMetadata = paymentIntent.metadata || {};
      const paymentType = String(paymentMetadata.type || '').trim();
      const paidReservationId = String(paymentMetadata.reservationId || '').trim();
      if (
        (paymentType && paymentType !== 'public_move_in') ||
        (paidReservationId && paidReservationId !== String(reservationId))
      ) {
        throw new functions.https.HttpsError(
          'failed-precondition',
          'This payment was made for a different reservation. Contact the facility.',
        );
      }
      verifiedPaymentIntentId = String(paymentIntent.id || '').trim();
      if (!verifiedPaymentIntentId) {
        throw new functions.https.HttpsError('internal', 'Failed to validate payment intent');
      }
      verifiedAmountReceivedCents = amountReceived;
      verifiedPaymentMetadata = (paymentMetadata || {}) as Record<string, string>;

      // Once the hold has lapsed nothing keeps the unit for this renter, so
      // only a payment shown to be this reservation's finishes the move-in
      // (#29's rule). Checkout tags each payment with its reservation; one
      // that names none, taken by a session made before it did, is looked up
      // by its Checkout Session. Otherwise the move-in link of a lapsed
      // reservation took any untagged payment on the facility's account that
      // covered the quote.
      if (paidReservationId !== String(reservationId) && holdLapsedBeforeTransaction) {
        const ownership = await paymentOwnership(
          { facilityId, connectAccountId, reservationId: String(reservationId) },
          {
            paymentIntentId: verifiedPaymentIntentId,
            amountReceivedCents: amountReceived,
            metadata: verifiedPaymentMetadata,
          },
        );
        if (ownership === 'unknown') {
          throw new functions.https.HttpsError('unavailable', PAYMENT_CHECK_UNAVAILABLE_MESSAGE);
        }
        if (ownership === 'another') {
          throw new functions.https.HttpsError('failed-precondition', 'Reservation has expired');
        }
        untaggedPaymentShownOurs = true;
      }

      // The charges were quoted again since Checkout took the payment (the
      // owner changed a rate or fee), or the payment is short of them. Paying
      // again on this page would charge twice, so this payment is refunded.
      if (chargesChanged) {
        refuseUnlessPaid(
          'charges-changed',
          new functions.https.HttpsError(
            'failed-precondition',
            'Move-in charges changed since checkout started. Refresh and try again.',
          ),
        );
      } else if (amountReceived < requiredCents) {
        refuseUnlessPaid('charges-changed', amountMismatch);
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

  // Move-ins completed before the one-use record existed left only their
  // payment ledger entry. A failed lookup is logged and let through: the
  // record still stops any payment used from now on, and a renter who has
  // paid is not turned away by a read error. It does stop a refund, below.
  let earlierUseUnknown = false;
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
      earlierUseUnknown = true;
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

    // A refund already decided for this payment (a completion that died
    // before Stripe answered, or whose refund failed) is finished, not
    // decided again.
    const priorUse = await admin.firestore()
      .collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION)
      .doc(verifiedPaymentIntentId)
      .get();
    const priorUseData = (priorUse.data() || {}) as Record<string, any>;
    if (priorUse.exists && priorUseData.refund) {
      await resumePaidMoveInRefund({ facilityId, connectAccountId }, verifiedPaymentIntentId, priorUseData);
    }
  }

  // A renter who has paid is never turned away for capacity or for a unit
  // taken off online rental: both were checked when checkout was created, and
  // refusing after Checkout has charged left the renter paid with no tenancy,
  // no refund and nothing said to the owner. A paid move-in into a unit no
  // longer offered goes ahead and the owner is told (in the transaction).
  // A move-in with nothing to pay has no checkout, so it is refused here.
  if (!paymentVerified) {
    if (unitNotOfferedReason) {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
    }
    await assertFacilityHasTenantCapacity(admin.firestore(), facilityId);
  }

  const verifiedTotalAmount = chargeQuote.totalAmount;

  if (!paidRefusal) {
    try {
      await assertOnlineRentalNotOnDnrList(admin.firestore(), {
        name: name.trim(),
        email: normalizedEmail,
        phone: phone.trim(),
      });
    } catch (err: any) {
      if (!paymentVerified) throw err;
      if (err instanceof functions.https.HttpsError && err.code === 'failed-precondition') {
        // On the list: not someone the owner will rent to, paid or not.
        refuseUnlessPaid('do-not-rent', err);
      } else {
        // The lookup failed. The renter was screened at the hold and at
        // checkout, before paying, so a read error does not keep their money.
        functions.logger.error('Public move-in: Do Not Rent lookup failed after payment; moving in', {
          facilityId,
          reservationId,
          error: err?.message || String(err),
        });
      }
    }
  }

  /** The verified payment, for a refusal that refunds it. */
  const offeredPayment = (): OfferedPayment => ({
    paymentIntentId: String(verifiedPaymentIntentId),
    amountReceivedCents: verifiedAmountReceivedCents,
    metadata: verifiedPaymentMetadata,
  });
  /**
   * Turns away a renter who has paid, refunding them (paidMoveInRefund.ts).
   * Not while it is unknown whether this payment completed a move-in before
   * the one-use record existed: refunding that one would give the renter
   * their money back and leave them the tenancy. Trying again settles it.
   */
  const refusePaid = async (
    refusal: PaidMoveInRefusal,
    unpaidError: functions.https.HttpsError,
  ): Promise<never> => {
    if (earlierUseUnknown) {
      throw new functions.https.HttpsError('unavailable', PAYMENT_CHECK_UNAVAILABLE_MESSAGE);
    }
    return refusePaidMoveIn({
      facilityId,
      connectAccountId,
      reservationId: String(reservationId),
      unitId: unitId || null,
      unitNumber: displayUnitNumber,
      renterName: name.trim(),
      refusal,
      unpaidError,
      payment: offeredPayment(),
      knownToBeThisReservations: untaggedPaymentShownOurs,
    });
  };
  if (paidRefusal) {
    await refusePaid(paidRefusal.refusal, paidRefusal.unpaidError);
  }

  // As the app reads the type; a type stored blank is shown as standard.
  const unitTypeRaw = (preloadedUnitData ? unitTypeOf(preloadedUnitData) : '') || 'standard';
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

  type MoveInTransactionResult =
    | { kind: 'moved-in'; tenantId: string; contractId: string; reviewReason: MoveInReviewReason | null }
    | { kind: 'refused'; refusal: PaidMoveInRefusal; unpaidError: functions.https.HttpsError }
    | { kind: 'refund-decided'; record: Record<string, any> };

  // Perform transactional writes for tenant/contract/unit/reservation/charges.
  // Everything that decides whether to move in is read again here, where it
  // cannot change before the writes land: a unit rented or deleted after the
  // reads above failed the unit update after payment, with no refund.
  const transactionResult = await admin.firestore().runTransaction(async (tx): Promise<MoveInTransactionResult> => {
    // Unpaid: refused with the error, as before. Paid: nothing is written,
    // and the payment is refunded after the transaction.
    const refuse = (refusal: PaidMoveInRefusal, unpaidError: functions.https.HttpsError): MoveInTransactionResult => {
      if (!paymentVerified) throw unpaidError;
      return { kind: 'refused', refusal, unpaidError };
    };

    // Re-check reservation inside transaction
    const freshReservation = await tx.get(reservationRef);
    // One PaymentIntent completes one move-in. Read here and written with the
    // tenant, so two completions racing on one payment cannot both succeed.
    const paymentUseRef = verifiedPaymentIntentId
      ? admin.firestore().collection(PUBLIC_MOVE_IN_PAYMENTS_COLLECTION).doc(verifiedPaymentIntentId)
      : null;
    const paymentUseSnap = paymentUseRef ? await tx.get(paymentUseRef) : null;
    const facilityDocRef = admin.firestore().collection('facilities').doc(facilityId);
    const facilitySnap = await tx.get(facilityDocRef);
    const unitRef = unitId ? facilityDocRef.collection('units').doc(unitId) : null;
    const unitSnap = unitRef ? await tx.get(unitRef) : null;
    // Who else has the unit: an active tenant who claims it by their own
    // record. Read here, so a tenant added since the reads above is seen.
    const tenantClaims = unitRef
      ? await readActiveTenantUnitClaims(facilityDocRef.collection('tenants'), tx)
      : null;
    const holdRef = unitId ? unitHoldRef(facilityId, unitId) : null;
    const holdSnap = holdRef ? await tx.get(holdRef) : null;

    const freshData = (freshReservation.data() || {}) as Record<string, any>;
    if (freshReservation.exists && freshData.moveInToken !== token) {
      throw new functions.https.HttpsError('permission-denied', 'Invalid token');
    }
    // Before the reservation's state: a payment that completed this very
    // reservation is used, not refunded.
    if (paymentUseSnap?.exists) {
      const used = (paymentUseSnap.data() || {}) as Record<string, any>;
      if (used.refund) return { kind: 'refund-decided', record: used };
      // Refunded in Stripe, or disputed, before this move-in: it moved
      // nobody in, and the webhook told the owner.
      if (moveInPaymentReturnedBeforeMoveIn(used)) {
        functions.logger.warn('Public move-in: payment refunded or disputed before the move-in', {
          facilityId,
          reservationId,
          paymentIntentId: verifiedPaymentIntentId,
        });
        throw new functions.https.HttpsError('failed-precondition', PAYMENT_RETURNED_BEFORE_MOVE_IN_MESSAGE);
      }
      functions.logger.warn('Public move-in: payment already used', {
        facilityId,
        reservationId,
        paymentIntentId: verifiedPaymentIntentId,
        usedByReservationId: used.reservationId,
      });
      throw new functions.https.HttpsError('failed-precondition', PAYMENT_ALREADY_USED_MESSAGE);
    }
    if (!freshReservation.exists) {
      return refuse('reservation-closed', new functions.https.HttpsError('not-found', 'Reservation not found'));
    }
    const freshStatus = String(freshData.status || '');
    if (freshStatus === 'completed' && verifiedPaymentIntentId && freshData.paymentIntentId === verifiedPaymentIntentId) {
      // Completed with this payment before its use was recorded.
      throw new functions.https.HttpsError('failed-precondition', PAYMENT_ALREADY_USED_MESSAGE);
    }
    if (
      freshStatus !== 'pending' &&
      freshStatus !== 'confirmed' &&
      !(paymentVerified && freshStatus === 'expired')
    ) {
      return refuse(
        'reservation-closed',
        new functions.https.HttpsError('failed-precondition', 'Reservation is not active'),
      );
    }

    if (unitSnap && !unitSnap.exists) {
      return refuse('unit-missing', new functions.https.HttpsError('not-found', 'Reserved unit not found'));
    }
    const freshUnit = (unitSnap?.data() || null) as Record<string, any> | null;
    if (unitRef && freshUnit && tenantClaims && unitIsTaken(unitRef.id, freshUnit, tenantClaims)) {
      return refuse(
        'unit-taken',
        new functions.https.HttpsError('failed-precondition', 'Unit is no longer available'),
      );
    }
    // A hold that lapsed (checkout extends it past payment, checkoutHold.ts)
    // lets another renter hold the unit; theirs is honoured if they may be
    // paying for it (holderMayBePaying). One who has not gone to pay has paid
    // nothing, so this renter, who has, moves in, and their checkout is then
    // refused before it takes any money. Both read here, not before the
    // transaction, so neither can change between the check and the move-in.
    const hold = (holdSnap?.data() || null) as Record<string, any> | null;
    const heldUntil = timestampToDate(hold?.expiresAt);
    const heldByAnother = Boolean(
      hold && hold.reservationId !== String(reservationId) && heldUntil && heldUntil > new Date(),
    );
    const ownHoldLapsed = (timestampToDate(freshData.expiresAt)?.getTime() ?? Infinity) < Date.now();
    if (ownHoldLapsed && heldByAnother && holderMayBePaying(await readHoldersReservation(tx, hold))) {
      return refuse(
        'unit-held',
        new functions.https.HttpsError('failed-precondition', 'Unit is not currently available'),
      );
    }
    const reviewReason = freshUnit ? moveInReviewReasonFor(freshUnit, enabledUnitTypes) : null;
    if (reviewReason && !paymentVerified) {
      throw new functions.https.HttpsError('failed-precondition', 'Unit is not currently available');
    }
    // The hold lapsed after the check before the transaction, so a payment
    // naming no reservation has not been shown to be this one's. Trying
    // again looks it up.
    if (
      ownHoldLapsed &&
      verifiedPaymentIntentId &&
      String(verifiedPaymentMetadata.reservationId || '').trim() !== String(reservationId) &&
      !untaggedPaymentShownOurs
    ) {
      throw new functions.https.HttpsError('unavailable', PAYMENT_CHECK_UNAVAILABLE_MESSAGE);
    }

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
          return refuse(
            'portal-link',
            new functions.https.HttpsError('permission-denied', 'Portal-linked move-in validation failed'),
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
      // The unit as read in this transaction, so the label, id and area agree.
      ...(unitRef && freshUnit ? primaryUnitCreateFields(unitRef.id, freshUnit) : {}),
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

    // The payment, in the commit that posts the charges it pays. Written
    // after the commit (and after the contract PDF and autopay), an instance
    // that died in between left the tenant owing what they had paid, and the
    // one-use record then refused the payment to a retry. Keyed by the
    // PaymentIntent, so it is one row however the move-in is retried.
    if (!skipPayment && verifiedPaymentIntentId && verifiedTotalAmount > 0) {
      tx.set(facilityDocRef.collection('ledgers').doc(moveInPaymentLedgerId(verifiedPaymentIntentId)), {
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

    // Update unit status
    if (unitRef && freshUnit) {
      // A renter now occupies it, so it must show where rented units show. An
      // archived unit is left out of Units, the stats and the reports (and
      // nothing in the app restores one); an internal-use unit is left out of
      // occupancy and revenue. Either hid a tenant who is being billed.
      const unitChanges: MoveInUnitChanges = {
        restored: isArchivedForOnlineRental(freshUnit),
        internalUseCleared: isInternalUseUnit(freshUnit),
      };
      tx.update(unitRef, {
        status: 'occupied',
        tenantId: tenantRef.id,
        tenantName: name,
        moveInDate: moveInDate,
        updatedAt: nowTs,
        updatedBy: 'publicMoveIn',
        ...(unitChanges.restored
          ? {
            archived: false,
            isActive: true,
            archivedAt: admin.firestore.FieldValue.delete(),
            archivedByUid: admin.firestore.FieldValue.delete(),
          }
          : {}),
        ...(unitChanges.internalUseCleared ? { internalUse: false } : {}),
      });
      if (unitChanges.internalUseCleared) {
        // Logged as UnitService.updateUnit logs it: internal use moves
        // reported occupancy, so the change is on record whoever makes it.
        tx.set(facilityDocRef.collection('auditLogs').doc(), {
          eventType: 'unit.internalUseChanged',
          actorUid: 'system',
          facilityId,
          targetType: 'unit',
          targetId: unitRef.id,
          tenantId: tenantRef.id,
          before: { internalUse: true },
          after: { internalUse: false },
          metadata: {
            unitNumber: displayUnitNumber,
            source: 'publicMoveIn',
            reservationId: String(reservationId),
          },
          timestamp: nowTs,
        });
      }

      // Reached only when paid (unpaid ones were refused above). Written with
      // the tenancy, so the owner cannot miss it.
      if (reviewReason) {
        tx.set(
          onlineMoveInReviewRef(facilityId, String(reservationId)),
          onlineMoveInReviewAlert({
            facilityId,
            tenantId: tenantRef.id,
            tenantName: name.trim(),
            unitId: unitRef.id,
            unitNumber: displayUnitNumber,
            reason: reviewReason,
            unitChanges,
            reservationId: String(reservationId),
            paymentIntentId: verifiedPaymentIntentId,
          }),
        );
      }
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

    // The unit is rented, so this reservation's hold (or a lapsed one) goes
    // with the move-in, in the same commit. Another renter's live hold is
    // left for them to end; a delete after the commit removed any hold there.
    if (holdRef && hold && !heldByAnother) {
      tx.delete(holdRef);
    }

    // Update reservation status
    tx.update(reservationRef, {
      status: 'completed',
      completedAt: nowTs,
      updatedAt: nowTs,
      tenantId: tenantRef.id,
      contractId: contractRef.id,
      completedBy: 'publicMoveIn',
      paymentIntentId: verifiedPaymentIntentId,
    });

    return {
      kind: 'moved-in',
      tenantId: tenantRef.id,
      contractId: contractRef.id,
      reviewReason,
    };
  });

  if (transactionResult.kind === 'refused') {
    await refusePaid(transactionResult.refusal, transactionResult.unpaidError);
  }
  if (transactionResult.kind === 'refund-decided') {
    // A refund decided by a completion racing this one: finish it.
    await resumePaidMoveInRefund(
      { facilityId, connectAccountId },
      String(verifiedPaymentIntentId),
      transactionResult.record,
    );
  }
  if (transactionResult.kind !== 'moved-in') {
    throw new functions.https.HttpsError('internal', 'Move-in could not be completed');
  }
  const { tenantId, contractId, reviewReason } = transactionResult;

  if (reviewReason) {
    functions.logger.warn('Paid online move-in completed into a unit no longer offered online', {
      facilityId,
      tenantId,
      unitId,
      reason: reviewReason,
      reservationId,
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

