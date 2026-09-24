import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

/**
 * The online move-in form: contact details, mailing address, emergency
 * contact, government ID and signature.
 *
 * The renter used to fill it in after paying, on the page Stripe sent them
 * back to. A renter who paid and closed the tab never filled it in, so nothing
 * could complete their move-in. createPublicMoveInCheckout now saves the form
 * before it creates the Checkout Session, and the move-in is completed from
 * the saved form by whichever comes first: the renter's browser or the Stripe
 * webhook (paidCheckoutCompletion.ts).
 */
export type MoveInForm = {
  name: string;
  email: string;
  phone: string;
  address: string;
  addressLine2: string;
  city: string;
  state: string;
  zipCode: string;
  country: string;
  emergencyContactName: string;
  emergencyContactPhone: string;
  emergencyContactRelationship: string;
  emergencyContactEmail: string;
  governmentIdType: string;
  governmentIdNumber: string;
  governmentIdState: string;
  governmentIdCountry: string;
  notes: string;
  signaturePngBase64: string;
  signatureSignedAt: string;
  enrollAutopay: boolean;
};

/**
 * Saved forms, one per reservation, keyed by the reservation id. Server-only
 * (firestore-rules-src/16a-publicMoveIn.rules): it holds a government ID
 * number and a signature. Kept out of publicReservations, which facility staff
 * can list. Deleted when the move-in completes or the reservation is
 * cancelled, and otherwise by the TTL policy on `expireAt`.
 */
export const PUBLIC_MOVE_IN_FORMS_COLLECTION = 'publicMoveInForms';

/**
 * How long a saved form is kept when the move-in never completes. Longer
 * than a reservation stays open after checkout (FINISH_AFTER_LAPSE_HOURS),
 * with room for the owner to sort out a payment that could not be used.
 */
export const SAVED_MOVE_IN_FORM_DAYS = 7;

/** `details.reason` on the refusal to complete from a saved form when none was saved. */
export const MOVE_IN_FORM_NOT_SAVED_REASON = 'moveInFormNotSaved';

export const MOVE_IN_FORM_NOT_SAVED_MESSAGE =
  'Your move-in details were not saved. Fill in the form and submit it again.';

/** A signature pad PNG is tens of kilobytes; this keeps a saved form well inside Firestore's 1 MiB document limit. */
const MAX_SIGNATURE_CHARS = 700_000;
const MAX_FIELD_CHARS = 1_000;
const MAX_NOTES_CHARS = 4_000;

function text(value: unknown): string {
  return value == null ? '' : String(value).trim();
}

/**
 * The form in a callable's payload or a saved form, normalised the way
 * completePublicMoveIn always has: trimmed, emails lower case, countries
 * upper case. Nothing is required here; see [assertMoveInFormComplete].
 */
export function moveInFormFromData(data: Record<string, unknown> | null | undefined): MoveInForm {
  const d = data || {};
  return {
    name: text(d.name),
    email: text(d.email).toLowerCase(),
    phone: text(d.phone),
    address: text(d.address),
    addressLine2: text(d.addressLine2),
    city: text(d.city),
    state: text(d.state),
    zipCode: text(d.zipCode),
    country: text(d.country).toUpperCase(),
    emergencyContactName: text(d.emergencyContactName),
    emergencyContactPhone: text(d.emergencyContactPhone),
    emergencyContactRelationship: text(d.emergencyContactRelationship),
    emergencyContactEmail: text(d.emergencyContactEmail).toLowerCase(),
    governmentIdType: text(d.governmentIdType),
    governmentIdNumber: text(d.governmentIdNumber),
    governmentIdState: text(d.governmentIdState),
    governmentIdCountry: text(d.governmentIdCountry).toUpperCase(),
    notes: text(d.notes),
    signaturePngBase64: text(d.signaturePngBase64),
    signatureSignedAt: text(d.signatureSignedAt),
    enrollAutopay:
      d.enrollAutopayInterest === true ||
      d.enrollAutopayInterest === 'true' ||
      d.enrollAutopay === true,
  };
}

/**
 * Refuses a form a move-in cannot be completed from: the fields
 * completePublicMoveIn has always required, and nothing too large to store.
 * Checkout applies the same test before the renter pays, so a form it saved
 * is never refused here after payment.
 */
export function assertMoveInFormComplete(form: MoveInForm): void {
  if (!form.name || !form.email || !form.phone || !form.signaturePngBase64) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing required fields');
  }
  if (form.signaturePngBase64.length > MAX_SIGNATURE_CHARS) {
    throw new functions.https.HttpsError('invalid-argument', 'The signature is too large. Clear it and sign again.');
  }
  for (const [field, value] of Object.entries(form)) {
    if (typeof value !== 'string' || field === 'signaturePngBase64') continue;
    const limit = field === 'notes' ? MAX_NOTES_CHARS : MAX_FIELD_CHARS;
    if (value.length > limit) {
      throw new functions.https.HttpsError('invalid-argument', `${field} is too long`);
    }
  }
}

export function savedMoveInFormRef(reservationId: string): admin.firestore.DocumentReference {
  return admin.firestore().collection(PUBLIC_MOVE_IN_FORMS_COLLECTION).doc(reservationId);
}

/** Writes [form] for [reservationId] in [tx], replacing any saved before. */
export function saveMoveInForm(
  tx: admin.firestore.Transaction,
  params: { reservationId: string; facilityId: string; form: MoveInForm; now: Date },
): void {
  tx.set(savedMoveInFormRef(params.reservationId), {
    reservationId: params.reservationId,
    facilityId: params.facilityId,
    form: params.form,
    savedAt: admin.firestore.FieldValue.serverTimestamp(),
    expireAt: admin.firestore.Timestamp.fromDate(
      new Date(params.now.getTime() + SAVED_MOVE_IN_FORM_DAYS * 24 * 60 * 60 * 1000),
    ),
  });
}

/** The form saved for [reservationId], or null when none was. */
export async function loadSavedMoveInForm(reservationId: string): Promise<MoveInForm | null> {
  const snap = await savedMoveInFormRef(reservationId).get();
  if (!snap.exists) return null;
  const saved = (snap.data() || {}) as Record<string, unknown>;
  return moveInFormFromData(saved.form as Record<string, unknown> | undefined);
}
