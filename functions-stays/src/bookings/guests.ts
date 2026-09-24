import * as functions from 'firebase-functions/v1';
import type { DocumentReference, Firestore, QueryDocumentSnapshot, Timestamp } from 'firebase-admin/firestore';

import {
  STAYS_CALLABLES,
  STAY_COLLECTIONS,
  StayGuestProfileCreateInput,
  StayGuestProfileDoc,
  StayGuestSearchResult,
  StayGuestVehicle,
  StayRole,
  StaysSearchGuestsResponse,
} from '@sfc/functions-shared/stays/contracts';
import { guestProfileIdFor } from '@sfc/functions-shared/stays/ids';
import { StayValidationError, validateOptionalText, validateText } from '@sfc/functions-shared/stays/validation';

import { staysError } from '../common/errors';
import {
  StaysDeps,
  assertEmployeeSetting,
  defaultStaysDeps,
  enforceUserRateLimit,
  isOwnerOrManager,
  runStaysGuards,
  staysCallable,
} from '../common/guards';
import { facilityCol, toWire, validated } from './shared';

/**
 * Returning guests (spec §1.1 P): owner/manager-only profiles with contact
 * details, a vehicle and a do-not-rent flag. Staff booking walk-ups find a
 * returning guest by name, whole phone number or plate, and see the
 * do-not-rent flag but never the contact details or the reason.
 */

const STAFF: readonly StayRole[] = ['owner', 'manager', 'employee'];

export function profilesCol(db: Firestore, facilityId: string) {
  return facilityCol(db, facilityId, STAY_COLLECTIONS.guestProfiles);
}

// ---------------------------------------------------------------------------
// Normalising what a person typed
// ---------------------------------------------------------------------------

/**
 * A phone number in E.164. Ten digits (or eleven starting with 1) are a
 * North American number; anything starting with + keeps its country code.
 * A number that is neither is refused rather than guessed at.
 */
export function normalizePhone(value: unknown, field = 'phone'): string | null {
  const text = validateOptionalText(value, field, { max: 30, singleLine: true });
  if (text === null) return null;
  if (!/^[+\d\s().-]+$/.test(text)) throw new StayValidationError(field, 'A phone number has only digits, spaces and + ( ) - .');
  const digits = text.replace(/\D/g, '');
  if (text.startsWith('+')) {
    if (digits.length < 8 || digits.length > 15) throw new StayValidationError(field, 'That phone number is too short or too long.');
    return `+${digits}`;
  }
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith('1')) return `+${digits}`;
  throw new StayValidationError(field, 'Enter the full phone number with area code, or start with + and the country code.');
}

export function normalizeEmail(value: unknown, field = 'email'): string | null {
  const text = validateOptionalText(value, field, { max: 200, singleLine: true });
  if (text === null) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text)) throw new StayValidationError(field, 'That email address does not look right.');
  return text.toLowerCase();
}

/** Plates are matched as typed on a sign: upper case, no spaces or dashes. */
export function normalizePlate(value: unknown, field = 'vehicle.plate'): string | null {
  const text = validateOptionalText(value, field, { max: 20, singleLine: true });
  return text === null ? null : text.toUpperCase().replace(/[\s-]/g, '');
}

export function normalizeVehicle(value: unknown, field = 'vehicle'): StayGuestVehicle | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) throw new StayValidationError(field, 'vehicle must be an object.');
  const v = value as Record<string, unknown>;
  const rvLength = v.rvLengthFt;
  if (rvLength !== undefined && rvLength !== null && (!Number.isInteger(rvLength) || (rvLength as number) < 0 || (rvLength as number) > 80)) {
    throw new StayValidationError(`${field}.rvLengthFt`, 'RV length is a whole number of feet, up to 80.');
  }
  const vehicle: StayGuestVehicle = {
    plate: normalizePlate(v.plate, `${field}.plate`),
    state: validateOptionalText(v.state, `${field}.state`, { max: 40, singleLine: true }),
    make: validateOptionalText(v.make, `${field}.make`, { max: 60, singleLine: true }),
    rvType: validateOptionalText(v.rvType, `${field}.rvType`, { max: 60, singleLine: true }),
    rvLengthFt: typeof rvLength === 'number' ? rvLength : null,
  };
  return Object.values(vehicle).every((x) => x === null) ? null : vehicle;
}

export interface GuestProfileCreate {
  name: string;
  phoneE164: string | null;
  email: string | null;
  vehicle: StayGuestVehicle | null;
  notes: string;
}

export function validateProfileCreate(value: unknown, field = 'guestProfile.create'): GuestProfileCreate {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new StayValidationError(field, 'The guest details are missing.');
  }
  const v = value as StayGuestProfileCreateInput & Record<string, unknown>;
  return {
    name: validateText(v.name, `${field}.name`, { min: 1, max: 120, singleLine: true }),
    phoneE164: normalizePhone(v.phone, `${field}.phone`),
    email: normalizeEmail(v.email, `${field}.email`),
    vehicle: normalizeVehicle(v.vehicle, `${field}.vehicle`),
    notes: validateText(v.notes ?? '', `${field}.notes`, { max: 2000 }),
  };
}

/** "Jane Doe" → "Jane D.": the most a stay doc (read by every role) carries of a name. */
export function displayNameFrom(fullName: string): string {
  const parts = fullName.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '';
  if (parts.length === 1) return parts[0].slice(0, 60);
  const last = parts[parts.length - 1];
  return `${parts[0]} ${last[0].toUpperCase()}.`.slice(0, 60);
}

/** The last four digits of a phone number, for the per-stay door code and stayPrivate. */
export function phoneLast4(phoneE164: string | null): string | null {
  if (!phoneE164) return null;
  const digits = phoneE164.replace(/\D/g, '');
  return digits.length >= 4 ? digits.slice(-4) : null;
}

// ---------------------------------------------------------------------------
// Profile resolution for a booking
// ---------------------------------------------------------------------------

export interface ResolvedProfile {
  profileId: string;
  ref: DocumentReference;
  /** null: a new profile this booking creates. */
  existing: StayGuestProfileDoc | null;
  /** What a new profile is made from. */
  create: GuestProfileCreate | null;
  name: string;
  /**
   * The guest's phone for this booking: the chosen profile's, or the one
   * typed in. A contact match never lends the matched profile's phone (see
   * matchedBy): the booker did not supply it and may not be allowed to see it.
   */
  phoneE164: string | null;
  doNotRent: boolean;
  /**
   * How an existing profile was found: picked by id, or matched on the phone
   * or email typed for a new guest. null for a profile this booking creates.
   */
  matchedBy: 'profile_id' | 'phone' | 'email' | null;
}

/**
 * The profile a booking names: an existing one, or one to create. A new
 * guest whose phone or email is already on file is the same guest, so the
 * existing profile (and its do-not-rent flag) is used rather than a
 * duplicate that would slip past the flag. The caller decides whether the
 * booker may use a profile found that way (employees may not).
 */
export async function resolveGuestProfile(
  db: Firestore,
  facilityId: string,
  requestId: string,
  ref: unknown,
): Promise<ResolvedProfile | null> {
  if (ref === undefined || ref === null) return null;
  if (typeof ref !== 'object' || Array.isArray(ref)) {
    throw staysError('invalid-argument', 'invalid_argument', 'guestProfile must name a profile or the guest to add.', {
      field: 'guestProfile',
    });
  }
  const col = profilesCol(db, facilityId);
  const r = ref as Record<string, unknown>;
  if (r.profileId !== undefined) {
    if (typeof r.profileId !== 'string' || !/^[^/]{1,128}$/.test(r.profileId)) {
      throw staysError('invalid-argument', 'invalid_argument', 'That guest profile id is not valid.', { field: 'guestProfile.profileId' });
    }
    const snap = await col.doc(r.profileId).get();
    if (!snap.exists) {
      throw staysError('not-found', 'not_found', 'That returning guest was not found. They may have been deleted.', {
        profileId: r.profileId,
      });
    }
    const doc = snap.data() as StayGuestProfileDoc;
    return {
      profileId: snap.id,
      ref: snap.ref,
      existing: doc,
      create: null,
      name: doc.name,
      phoneE164: doc.phoneE164 ?? null,
      doNotRent: doc.doNotRent === true,
      matchedBy: 'profile_id',
    };
  }
  const create = validated(() => validateProfileCreate(r.create));
  const lookups: ['phoneE164' | 'email', string | null][] = [
    ['phoneE164', create.phoneE164],
    ['email', create.email],
  ];
  for (const [field, value] of lookups) {
    if (!value) continue;
    const match = await col.where(field, '==', value).limit(1).get();
    if (!match.empty) {
      const doc = match.docs[0].data() as StayGuestProfileDoc;
      return {
        profileId: match.docs[0].id,
        ref: match.docs[0].ref,
        existing: doc,
        create: null,
        name: doc.name,
        phoneE164: create.phoneE164,
        doNotRent: doc.doNotRent === true,
        matchedBy: field === 'phoneE164' ? 'phone' : 'email',
      };
    }
  }
  const profileId = guestProfileIdFor(requestId);
  return {
    profileId,
    ref: col.doc(profileId),
    existing: null,
    create,
    name: create.name,
    phoneE164: create.phoneE164,
    doNotRent: false,
    matchedBy: null,
  };
}

/** Another profile with exactly this name is on the do-not-rent list (a warning, not a refusal). */
export async function doNotRentNameMatch(db: Firestore, facilityId: string, name: string, exceptId: string | null): Promise<boolean> {
  const snap = await profilesCol(db, facilityId)
    .where('doNotRent', '==', true)
    .where('nameLower', '==', name.trim().toLowerCase())
    .limit(3)
    .get();
  return snap.docs.some((d) => d.id !== exceptId);
}

/** A new profile doc, as the rules would accept it (stayCount and lastStayAt are server-kept). */
export function newProfileDoc(
  facilityId: string,
  create: GuestProfileCreate,
  actor: string,
  now: Timestamp,
  firstStayAt: Timestamp | null,
): StayGuestProfileDoc {
  return {
    facilityId,
    name: create.name,
    nameLower: create.name.toLowerCase(),
    phoneE164: create.phoneE164,
    email: create.email,
    vehicle: create.vehicle,
    notes: create.notes,
    doNotRent: false,
    doNotRentReason: null,
    consent: null,
    stayCount: firstStayAt ? 1 : 0,
    lastStayAt: firstStayAt,
    createdAt: now,
    createdBy: actor,
    updatedAt: now,
    updatedBy: actor,
  };
}

// ---------------------------------------------------------------------------
// staysSearchGuests
// ---------------------------------------------------------------------------

export function searchResult(profileId: string, doc: StayGuestProfileDoc, includeContact: boolean): StayGuestSearchResult {
  const result: StayGuestSearchResult = {
    profileId,
    name: doc.name ?? '',
    rvLengthFt: doc.vehicle?.rvLengthFt ?? null,
    lastStayAt: doc.lastStayAt ? (toWire(doc.lastStayAt) as unknown as string) : null,
    stayCount: Number.isInteger(doc.stayCount) ? doc.stayCount : 0,
    doNotRent: doc.doNotRent === true,
  };
  if (includeContact) {
    result.phoneE164 = doc.phoneE164 ?? null;
    result.email = doc.email ?? null;
  }
  return result;
}

const MAX_RESULTS = 10;

/** An employee's whole-phone-number searches: plenty for a front desk, too few to guess a number with. */
export const EMPLOYEE_PHONE_LOOKUPS = { key: 'stays_guest_phone', perHour: 20 } as const;

/** A complete phone number in E.164, or null for anything shorter or malformed. */
function wholePhoneOrNull(query: string): string | null {
  try {
    return normalizePhone(query, 'query');
  } catch (error) {
    if (error instanceof StayValidationError) return null;
    throw error;
  }
}

export async function handleSearchGuests(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysSearchGuestsResponse> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.searchGuests,
      roles: STAFF,
      rateLimit: { key: 'stays_guest_search', windowSeconds: 60, perUser: 60 },
    },
    deps,
  );
  assertEmployeeSetting(ctx, 'employeesCanBook');
  if (typeof ctx.data.query !== 'string' || ctx.data.query.length > 80) {
    throw staysError('invalid-argument', 'invalid_argument', 'Search with up to 80 characters.', { field: 'query' });
  }
  const query = ctx.data.query.trim();
  if (query.length < 2) return [];

  const col = profilesCol(ctx.db, ctx.facilityId);
  const found = new Map<string, StayGuestProfileDoc>();
  const add = (docs: QueryDocumentSnapshot[]) => {
    for (const d of docs) if (!found.has(d.id)) found.set(d.id, d.data() as StayGuestProfileDoc);
  };

  const lower = query.toLowerCase();
  add((await col.where('nameLower', '>=', lower).where('nameLower', '<', `${lower}`).orderBy('nameLower').limit(MAX_RESULTS).get()).docs);

  const includeContact = isOwnerOrManager(ctx.role);
  // A phone number (4+ digits and nothing else). Owners and managers, who see
  // numbers anyway, prefix-match the E.164 form. Employees match only the
  // whole number: a prefix match would answer "does her number start with
  // 4065550?" and so give her number away a digit at a time. Whole-number
  // lookups are capped per hour too: an employee who knows a guest's last 4
  // (her door code on a phone_last4 listing) and area code could otherwise
  // try all 1,000 exchanges in under 20 minutes.
  const digits = query.replace(/\D/g, '');
  if (/^[+\d\s().-]+$/.test(query) && digits.length >= 4) {
    if (includeContact) {
      const prefix = query.startsWith('+') ? `+${digits}` : digits.length === 11 && digits.startsWith('1') ? `+${digits}` : `+1${digits}`;
      add((await col.where('phoneE164', '>=', prefix).where('phoneE164', '<', `${prefix}`).orderBy('phoneE164').limit(MAX_RESULTS).get()).docs);
    } else {
      const whole = wholePhoneOrNull(query);
      if (whole) {
        await enforceUserRateLimit(ctx, EMPLOYEE_PHONE_LOOKUPS.key, EMPLOYEE_PHONE_LOOKUPS.perHour, 3600);
        add((await col.where('phoneE164', '==', whole).limit(MAX_RESULTS).get()).docs);
      }
    }
  }
  // A plate: letters and digits with at least one digit.
  const plate = query.toUpperCase().replace(/[\s-]/g, '');
  if (/^[A-Z0-9]{2,10}$/.test(plate) && /\d/.test(plate)) {
    add((await col.where('vehicle.plate', '==', plate).limit(MAX_RESULTS).get()).docs);
  }

  return [...found.entries()]
    .sort(([, a], [, b]) => (a.nameLower ?? '').localeCompare(b.nameLower ?? ''))
    .slice(0, MAX_RESULTS)
    .map(([id, doc]) => searchResult(id, doc, includeContact));
}

export const staysSearchGuests = staysCallable(STAYS_CALLABLES.searchGuests, (data, context) => handleSearchGuests(data, context));
