import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';
import type { Firestore } from 'firebase-admin/firestore';

import {
  REVIEW_ACTIONS,
  SFC_BOOKING_SOURCES,
  STAYS_CALLABLES,
  STAYS_LIMITS,
  STAY_COLLECTIONS,
  STAY_KINDS,
  STAY_SOURCES,
  HardConflictNight,
  NightClaim,
  StayAccessDoc,
  StayDoc,
  StayFolioDoc,
  StayIncomeDoc,
  StayKind,
  StayListingDoc,
  StayPrivateDoc,
  StayQuote,
  StayReviewAction,
  StayRole,
  StaySource,
  StayStaffField,
  StaysCancelStayResponse,
  StaysCreateStayResponse,
  StaysModifyStayResponse,
  StaysQuoteResponse,
  StaysReviewStayResponse,
  StaysWarning,
  Ymd,
} from '@sfc/functions-shared/stays/contracts';
import { addDays, diffDays, enumerateNights, facilityToday, isValidYmd, localDateTimeToUtc, monthOf } from '@sfc/functions-shared/stays/dates';
import { applyPayment, paymentStatusOf } from '@sfc/functions-shared/stays/folio';
import { incomeIdManual, lockBucketId, normalizeAirbnbCode, stayIdForAirbnb, stayIdManual, taskIdTurnover } from '@sfc/functions-shared/stays/ids';
import { checkRequested, clampedNights, isActiveStatus, lockHorizon, lockMonthsFor } from '@sfc/functions-shared/stays/nightLocks';
import { quoteStay } from '@sfc/functions-shared/stays/quote';
import { wantsTurnover } from '@sfc/functions-shared/stays/turnoverPlan';
import { StayValidationError, validateOptionalTime, validateText } from '@sfc/functions-shared/stays/validation';

import { confirmedTimeZone } from '../common/controls';
import { staysError } from '../common/errors';
import {
  StaysCallContext,
  StaysDeps,
  assertEmployeeSetting,
  auditStays,
  defaultStaysDeps,
  optionalDocId,
  requireDocId,
  requireRequestId,
  requireYmd,
  runStaysGuards,
  staysCallable,
} from '../common/guards';
import { applyStayMutations } from '../common/stayWriter';
import { displayNameFrom, doNotRentNameMatch, newProfileDoc, phoneLast4, resolveGuestProfile } from './guests';
import { assertReceivedDate, manualIncomeDoc, parsePayment, receivedAtFor } from './payments';
import {
  FreshSync,
  activeChannels,
  assertBookable,
  defaultFreshSync,
  facilityCol,
  folioRef,
  incomeRef,
  invalid,
  isFeedOwned,
  isOtaSource,
  loadListing,
  providerForSource,
  providerName,
  refreshChannelsFirst,
  shortLeadCheck,
  stayLabel,
  stayRef,
  toWire,
  validated,
} from './shared';

/**
 * Bookings and blocks (spec §1.1 C–E, §6.5): quote, create, modify, cancel
 * and review. Every stay write goes through applyStayMutations, which owns
 * the night locks, so two people can never book the same night; the stay,
 * its folio, its first payment, its private details and the guest profile
 * are written in that one transaction.
 */

const STAFF: readonly StayRole[] = ['owner', 'manager', 'employee'];
const OWNER_OR_MANAGER: readonly StayRole[] = ['owner', 'manager'];

// ---------------------------------------------------------------------------
// Request parsing
// ---------------------------------------------------------------------------

function roleNotAllowed(ctx: StaysCallContext, message: string): functions.https.HttpsError {
  return staysError('permission-denied', 'role_not_allowed', message, { role: ctx.role });
}

function optionalFlag(data: Record<string, unknown>, field: string): boolean {
  const value = data[field];
  if (value === undefined || value === null) return false;
  if (typeof value !== 'boolean') throw invalid(field, `${field} must be true or false.`);
  return value;
}

function enumField<T extends string>(value: unknown, field: string, allowed: readonly T[]): T {
  if (typeof value !== 'string' || !(allowed as readonly string[]).includes(value)) {
    throw invalid(field, `${field} must be one of: ${allowed.join(', ')}.`);
  }
  return value as T;
}

function count(value: unknown, field: string, max: number, fallback: number): number {
  if (value === undefined || value === null) return fallback;
  if (!Number.isInteger(value) || (value as number) < 0 || (value as number) > max) {
    throw invalid(field, `${field} must be a whole number from 0 to ${max}.`);
  }
  return value as number;
}

interface GuestFields {
  guestDisplayName: string;
  adults: number;
  children: number;
  pets: number;
  rvLengthFt: number | null;
}

const NO_GUEST: GuestFields = { guestDisplayName: '', adults: 0, children: 0, pets: 0, rvLengthFt: null };

function parseGuest(value: unknown, field: string): GuestFields {
  if (value === undefined || value === null) return { ...NO_GUEST, adults: 1 };
  if (typeof value !== 'object' || Array.isArray(value)) throw invalid(field, 'The guest details are missing.');
  const g = value as Record<string, unknown>;
  const rv = g.rvLengthFt;
  if (rv !== undefined && rv !== null && (!Number.isInteger(rv) || (rv as number) < 0 || (rv as number) > 80)) {
    throw invalid(`${field}.rvLengthFt`, 'RV length is a whole number of feet, up to 80.');
  }
  return {
    guestDisplayName: validated(() => validateText(g.displayName ?? '', `${field}.displayName`, { max: 60, singleLine: true })),
    adults: count(g.adults, `${field}.adults`, 50, 1),
    children: count(g.children, `${field}.children`, 50, 0),
    pets: count(g.pets, `${field}.pets`, 20, 0),
    rvLengthFt: typeof rv === 'number' ? rv : null,
  };
}

/** A partial guest change (staysModifyStay): only the keys sent. */
function parseGuestPatch(value: unknown, field: string): Partial<GuestFields> {
  if (value === undefined || value === null) return {};
  if (typeof value !== 'object' || Array.isArray(value)) throw invalid(field, 'The guest details are missing.');
  const g = value as Record<string, unknown>;
  const out: Partial<GuestFields> = {};
  if (g.displayName !== undefined) {
    out.guestDisplayName = validated(() => validateText(g.displayName, `${field}.displayName`, { max: 60, singleLine: true }));
  }
  if (g.adults !== undefined) out.adults = count(g.adults, `${field}.adults`, 50, 0);
  if (g.children !== undefined) out.children = count(g.children, `${field}.children`, 50, 0);
  if (g.pets !== undefined) out.pets = count(g.pets, `${field}.pets`, 20, 0);
  if (g.rvLengthFt !== undefined) {
    const rv = g.rvLengthFt;
    if (rv !== null && (!Number.isInteger(rv) || (rv as number) < 0 || (rv as number) > 80)) {
      throw invalid(`${field}.rvLengthFt`, 'RV length is a whole number of feet, up to 80.');
    }
    out.rvLengthFt = rv as number | null;
  }
  return out;
}

const GUEST_FIELD_OWNERSHIP: Record<keyof GuestFields, StayStaffField> = {
  guestDisplayName: 'guestDisplayName',
  adults: 'adults',
  children: 'children',
  pets: 'pets',
  rvLengthFt: 'rvLengthFt',
};

function parseAdjustment(value: unknown): { cents: number; reason: string } | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'object' || Array.isArray(value)) throw invalid('adjustment', 'The adjustment is missing its amount.');
  const a = value as Record<string, unknown>;
  if (!Number.isInteger(a.cents) || a.cents === 0 || Math.abs(a.cents as number) > 10_000_000) {
    throw invalid('adjustment.cents', 'An adjustment is a whole number of cents (negative for a discount).');
  }
  const reason = validated(() => validateText(a.reason, 'adjustment.reason', { min: 1, max: 200, singleLine: true }));
  return { cents: a.cents as number, reason };
}

/** A stay of 1–180 nights with check-out after check-in (spec §6.10). */
function assertNightCount(checkIn: Ymd, checkOut: Ymd): number {
  if (checkIn >= checkOut) {
    throw staysError('invalid-argument', 'invalid_dates', 'Check-out must be after check-in.', { field: 'checkOut' });
  }
  const nights = diffDays(checkIn, checkOut);
  if (nights > STAYS_LIMITS.manualStayMaxNights) {
    throw staysError(
      'invalid-argument',
      'max_nights',
      `A stay can be up to ${STAYS_LIMITS.manualStayMaxNights} nights. For longer, rent it monthly as a storage-style tenancy.`,
      { maxNights: STAYS_LIMITS.manualStayMaxNights },
    );
  }
  return nights;
}

function assertListingRules(listing: StayListingDoc, nights: number, opts: { checkMin: boolean }): void {
  const rules = listing.stayRules ?? { minNights: 1, maxNights: STAYS_LIMITS.manualStayMaxNights };
  if (opts.checkMin && nights < rules.minNights) {
    throw staysError(
      'failed-precondition',
      'min_nights',
      `${listing.name} has a ${rules.minNights}-night minimum. Change it on the listing to make an exception.`,
      { minNights: rules.minNights },
    );
  }
  if (nights > rules.maxNights) {
    throw staysError('failed-precondition', 'max_nights', `${listing.name} takes stays of up to ${rules.maxNights} nights.`, {
      maxNights: rules.maxNights,
    });
  }
}

function assertBeforeHorizonEnd(checkOut: Ymd, clampTo: Ymd): void {
  if (checkOut > clampTo) {
    throw staysError('invalid-argument', 'invalid_dates', `That is too far ahead: a booking must end by ${clampTo}.`, {
      maxCheckOut: clampTo,
    });
  }
}

/** Heads-ups about the party that never stop a booking. */
function partyWarnings(listing: StayListingDoc, guest: Pick<GuestFields, 'adults' | 'children' | 'pets' | 'rvLengthFt'>): StaysWarning[] {
  const warnings: StaysWarning[] = [];
  const max = listing.capacity?.maxGuests ?? 0;
  const guests = guest.adults + guest.children;
  if (max > 0 && guests > max) {
    warnings.push({ code: 'over_capacity', message: `${guests} guests is more than ${listing.name} sleeps (${max}).`, details: { maxGuests: max } });
  }
  if (guest.pets > 0 && listing.capacity?.petsAllowed !== true) {
    warnings.push({ code: 'pets_not_allowed', message: `${listing.name} is set to no pets.` });
  }
  const maxLength = listing.rv?.maxLengthFt ?? null;
  if (guest.rvLengthFt && maxLength && guest.rvLengthFt > maxLength) {
    warnings.push({
      code: 'rv_too_long',
      message: `A ${guest.rvLengthFt} ft rig is longer than ${listing.name} takes (${maxLength} ft).`,
      details: { maxLengthFt: maxLength },
    });
  }
  return warnings;
}

function listingGroupOf(listing: StayListingDoc): string {
  const group = (listing.group ?? '').trim();
  if (group) return group;
  return listing.kind === 'rv_site' || listing.kind === 'tent_site' ? 'RV park' : 'Listings';
}

export function folioFromQuote(
  facilityId: string,
  stayId: string,
  quote: StayQuote,
  adjustment: { cents: number; reason: string; by: string } | null,
  now: Timestamp,
  base?: Pick<StayFolioDoc, 'paidCents' | 'quoteVersion' | 'airbnb'> | null,
): StayFolioDoc {
  const paidCents = base?.paidCents ?? 0;
  return {
    facilityId,
    stayId,
    currency: 'usd',
    lines: quote.lines,
    taxLines: quote.taxLines,
    subtotalCents: quote.subtotalCents,
    taxCents: quote.taxCents,
    totalCents: quote.totalCents,
    paidCents,
    balanceCents: quote.totalCents - paidCents,
    quoteVersion: (base?.quoteVersion ?? 0) + 1,
    quotedAt: now,
    adjustment,
    airbnb: base?.airbnb ?? null,
    updatedAt: now,
  };
}

// ---------------------------------------------------------------------------
// Availability reads (for the quote)
// ---------------------------------------------------------------------------

type BucketMap = Record<string, { nights: Record<Ymd, NightClaim> }>;

async function readBuckets(db: Firestore, facilityId: string, listingId: string, months: string[]): Promise<BucketMap> {
  if (months.length === 0) return {};
  const col = facilityCol(db, facilityId, STAY_COLLECTIONS.nightLocks);
  const snaps = await db.getAll(...months.map((m) => col.doc(lockBucketId(listingId, m))));
  const out: BucketMap = {};
  snaps.forEach((snap, i) => {
    const nights = snap.exists ? (snap.get('nights') as Record<Ymd, NightClaim> | undefined) : undefined;
    out[months[i]] = { nights: nights ?? {} };
  });
  return out;
}

async function labelledConflicts(
  db: Firestore,
  facilityId: string,
  conflicts: { date: Ymd; stayId: string }[],
): Promise<HardConflictNight[]> {
  const ids = [...new Set(conflicts.map((c) => c.stayId))];
  const docs = new Map<string, StayDoc>();
  if (ids.length > 0) {
    const snaps = await db.getAll(...ids.map((id) => stayRef(db, facilityId, id)));
    snaps.forEach((s) => {
      if (s.exists) docs.set(s.id, s.data() as StayDoc);
    });
  }
  return conflicts.map((c) => ({ date: c.date, stayId: c.stayId, label: stayLabel(docs.get(c.stayId)) }));
}

/**
 * 1–2 free nights left between this stay and the next or previous one: hard
 * to sell, so she may want to adjust the dates. Any claim, hard or a channel
 * block, counts as taken; nights before today are not counted as gaps.
 */
function orphanGapWarnings(buckets: BucketMap, checkIn: Ymd, checkOut: Ymd, excludeStayId: string, today: Ymd): StaysWarning[] {
  const taken = (night: Ymd): boolean | null => {
    const bucket = buckets[monthOf(night)];
    if (!bucket) return null; // not read (outside the horizon): unknown
    const claim = bucket.nights[night];
    return !!claim && claim.s !== excludeStayId;
  };
  const warnings: StaysWarning[] = [];
  const gap = (start: Ymd, step: 1 | -1): Ymd[] | null => {
    const free: Ymd[] = [];
    for (let i = 0; i < 3; i++) {
      const night = addDays(start, step * i);
      const t = taken(night);
      if (t === null) return null;
      if (t) return free.length >= 1 && free.length <= 2 ? free : null;
      if (night < today) return null;
      free.push(night);
    }
    return null;
  };
  const before = gap(addDays(checkIn, -1), -1);
  if (before) {
    const nights = [...before].sort();
    warnings.push({
      code: 'orphan_gap',
      message: `This leaves ${nights.length === 1 ? 'a 1-night gap' : 'a 2-night gap'} before it (${nights.join(', ')}) that is hard to fill.`,
      details: { side: 'before', nights },
    });
  }
  const after = gap(checkOut, 1);
  if (after) {
    warnings.push({
      code: 'orphan_gap',
      message: `This leaves ${after.length === 1 ? 'a 1-night gap' : 'a 2-night gap'} after it (${after.join(', ')}) that is hard to fill.`,
      details: { side: 'after', nights: after },
    });
  }
  return warnings;
}

// ---------------------------------------------------------------------------
// staysQuote
// ---------------------------------------------------------------------------

export async function handleQuote(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysQuoteResponse> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.quote,
      roles: STAFF,
      validate: (d) => {
        requireDocId(d, 'listingId');
        requireYmd(d, 'checkIn');
        requireYmd(d, 'checkOut');
        optionalDocId(d, 'excludeStayId');
      },
      rateLimit: { key: 'stays_quote', windowSeconds: 60, perUser: 120 },
    },
    deps,
  );
  const d = ctx.data;
  const listingId = d.listingId as string;
  const checkIn = d.checkIn as Ymd;
  const checkOut = d.checkOut as Ymd;
  const excludeStayId = optionalDocId(d, 'excludeStayId');
  const party = {
    adults: count(d.adults, 'adults', 50, 1),
    children: count(d.children, 'children', 50, 0),
    pets: count(d.pets, 'pets', 20, 0),
  };
  const adjustmentCents = d.adjustmentCents === undefined || d.adjustmentCents === null ? 0 : d.adjustmentCents;
  if (!Number.isInteger(adjustmentCents)) throw invalid('adjustmentCents', 'The adjustment is a whole number of cents.');

  const tz = confirmedTimeZone(ctx.controls);
  const today = facilityToday(tz, ctx.nowMs);
  const { clampFrom, clampTo } = lockHorizon(today);
  assertNightCount(checkIn, checkOut);
  assertBeforeHorizonEnd(checkOut, clampTo);

  const listing = await loadListing(ctx.db, ctx.facilityId, listingId);
  assertBookable(listing, listingId);
  const quote = validated(() =>
    quoteStay(listing, ctx.controls, { checkIn, checkOut, ...party, adjustmentCents: adjustmentCents as number }),
  );

  // Three nights either side too, for the orphan-gap check.
  const months = lockMonthsFor(addDays(checkIn, -3), addDays(checkOut, 3), clampFrom, clampTo);
  const buckets = await readBuckets(ctx.db, ctx.facilityId, listingId, months);
  const requested = clampedNights(checkIn, checkOut, clampFrom, clampTo);
  const check = checkRequested(buckets, excludeStayId ?? '', requested);
  const hardConflicts = await labelledConflicts(ctx.db, ctx.facilityId, check.hardConflicts);

  const channels = await activeChannels(ctx.db, ctx.facilityId, listingId);
  const checkInTime = listing.times?.checkIn ?? ctx.controls.defaultCheckInTime;
  const warnings: StaysWarning[] = [];
  // A quote only reports the short-notice rule; the booking itself enforces it.
  const lead = shortLeadCheck({
    channels,
    checkIn,
    checkInTime,
    tz,
    nowMs: ctx.nowMs,
    hours: ctx.controls.shortLeadWarningHours,
    acknowledged: true,
  });
  const shortLead = lead !== null;
  if (lead) warnings.push(lead);
  if (check.softNights.length > 0) {
    warnings.push({
      code: 'soft_nights',
      message: `${check.softNights.length === 1 ? '1 night is' : `${check.softNights.length} nights are`} blocked on a channel calendar. You can book over them after confirming.`,
      details: { dates: check.softNights },
    });
  }
  warnings.push(...partyWarnings(listing, { ...party, rvLengthFt: null }));
  if (hardConflicts.length === 0) warnings.push(...orphanGapWarnings(buckets, checkIn, checkOut, excludeStayId ?? '', today));

  return {
    available: hardConflicts.length === 0,
    hardConflicts,
    softNights: check.softNights,
    shortLead,
    quote,
    warnings,
  };
}

export const staysQuote = staysCallable(STAYS_CALLABLES.quote, (data, context) => handleQuote(data, context));

// ---------------------------------------------------------------------------
// staysCreateStay
// ---------------------------------------------------------------------------

async function createRetryResponse(db: Firestore, facilityId: string, stayId: string, stay: StayDoc, requestId: string): Promise<StaysCreateStayResponse> {
  const [folio, income] = await db.getAll(folioRef(db, facilityId, stayId), incomeRef(db, facilityId, incomeIdManual(requestId)));
  return {
    stayId,
    created: false,
    status: stay.status,
    folio: folio.exists ? toWire(folio.data() as StayFolioDoc) : null,
    incomeEntryId: income.exists ? income.id : null,
    warnings: [],
  };
}

function duplicateReservation(stayId: string, stay: StayDoc | null | undefined): functions.https.HttpsError {
  return staysError(
    'already-exists',
    'duplicate_reservation',
    `That reservation is already in Stays${stay ? ` (${stayLabel(stay)})` : ''}. Open it instead.`,
    { stayId },
  );
}

export async function handleCreateStay(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
  freshSync: FreshSync | null = defaultFreshSync(),
): Promise<StaysCreateStayResponse> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.createStay,
      roles: STAFF,
      validate: (d) => {
        requireRequestId(d);
        requireDocId(d, 'listingId');
        requireYmd(d, 'checkIn');
        requireYmd(d, 'checkOut');
      },
      rateLimit: { key: 'stays_create', windowSeconds: 60, perFacility: 60, perUser: 20 },
    },
    deps,
  );
  const { db, facilityId, controls, nowMs, uid } = ctx;
  const d = ctx.data;
  const requestId = d.requestId as string;
  const listingId = d.listingId as string;
  const checkIn = d.checkIn as Ymd;
  const checkOut = d.checkOut as Ymd;
  const kind: StayKind = enumField(d.kind, 'kind', STAY_KINDS);
  const source: StaySource = enumField(d.source, 'source', STAY_SOURCES);
  const isReservation = kind === 'reservation';
  if (isReservation && source === 'owner') throw invalid('source', 'A guest booking needs a source: direct, phone, walk-up or a channel.');
  if (!isReservation && source !== 'owner') throw invalid('source', 'Owner and maintenance blocks have the source "owner".');
  const ota = isOtaSource(source);

  let confirmationCode: string | null = null;
  if (ota) {
    if (source === 'airbnb') {
      confirmationCode = normalizeAirbnbCode(d.confirmationCode);
      if (!confirmationCode) throw invalid('confirmationCode', 'Enter the Airbnb confirmation code, e.g. HMABC12345.');
    } else {
      const code = typeof d.confirmationCode === 'string' ? d.confirmationCode.trim() : '';
      if (!/^[A-Za-z0-9-]{3,40}$/.test(code)) throw invalid('confirmationCode', `Enter the ${providerName(providerForSource(source))} confirmation number.`);
      confirmationCode = code;
    }
  }

  const guest = isReservation ? parseGuest(d.guest, 'guest') : { ...NO_GUEST };
  const payment = d.payment === undefined || d.payment === null ? null : parsePayment(d.payment, 'payment');
  const adjustment = parseAdjustment(d.adjustment);
  const times = d.times === undefined || d.times === null ? {} : (d.times as Record<string, unknown>);
  if (typeof times !== 'object' || Array.isArray(times)) throw invalid('times', 'times must be an object.');
  const timeIn = validated(() => validateOptionalTime(times.checkIn, 'times.checkIn'));
  const timeOut = validated(() => validateOptionalTime(times.checkOut, 'times.checkOut'));
  const checkInNow = optionalFlag(d, 'checkInNow');
  const overrideSoftBlocks = optionalFlag(d, 'overrideSoftBlocks');
  const acknowledgeShortLead = optionalFlag(d, 'acknowledgeShortLead');
  const acknowledgeDoNotRent = optionalFlag(d, 'acknowledgeDoNotRent');
  const notes = validated(() => validateText(d.notes ?? '', 'notes', { max: 2000 }));

  // Employees: walk-up, phone and direct bookings only, when the owner allows it.
  if (ctx.role === 'employee') {
    assertEmployeeSetting(ctx, 'employeesCanBook');
    if (!isReservation || !(SFC_BOOKING_SOURCES as readonly string[]).includes(source)) {
      throw roleNotAllowed(ctx, 'Employees can book walk-up, phone and direct stays only.');
    }
    if (adjustment) throw roleNotAllowed(ctx, 'Only an owner or manager can adjust the price.');
    if (overrideSoftBlocks) throw roleNotAllowed(ctx, 'Only an owner or manager can book over a channel block.');
    if (acknowledgeDoNotRent) throw roleNotAllowed(ctx, 'Only an owner or manager can book a guest on the do-not-rent list.');
    if (payment) assertEmployeeSetting(ctx, 'employeesCanRecordCash');
  }
  if (payment && (ota || !isReservation)) {
    throw invalid('payment', ota ? `${providerName(providerForSource(source))} collects this booking's payment.` : 'Blocks have no payments.');
  }
  if (adjustment && (ota || !isReservation)) throw invalid('adjustment', 'Only SFC-priced bookings have a price to adjust.');
  if (checkInNow && !isReservation) throw invalid('checkInNow', 'Only a guest booking can be checked in.');

  const tz = confirmedTimeZone(controls);
  const today = facilityToday(tz, nowMs);
  const { clampFrom, clampTo } = lockHorizon(today);
  const nights = assertNightCount(checkIn, checkOut);
  const earliest = ctx.role === 'employee' ? addDays(today, -1) : clampFrom;
  if (checkIn < earliest) {
    throw staysError('invalid-argument', 'invalid_dates', 'That check-in is too far in the past to book.', { field: 'checkIn', earliest });
  }
  assertBeforeHorizonEnd(checkOut, clampTo);
  if (checkInNow && checkIn > today) throw invalid('checkInNow', 'A guest can be checked in on or after the arrival day.');
  if (payment) assertReceivedDate(payment.receivedDate, today, 'payment.receivedDate');

  const listing = await loadListing(db, facilityId, listingId);
  assertBookable(listing, listingId);
  if (isReservation) assertListingRules(listing, nights, { checkMin: true });

  // Airbnb reservations converge on airbnb_{CODE}, whoever enters them first.
  const stayId = source === 'airbnb' ? stayIdForAirbnb(confirmationCode!) : stayIdManual(requestId);
  const existingSnap = await stayRef(db, facilityId, stayId).get();
  if (existingSnap.exists) {
    const existing = existingSnap.data() as StayDoc;
    if (existing.requestId !== requestId) throw duplicateReservation(stayId, existing);
    return createRetryResponse(db, facilityId, stayId, existing, requestId);
  }

  const warnings: StaysWarning[] = [];
  const profile = isReservation ? await resolveGuestProfile(db, facilityId, requestId, d.guestProfile) : null;
  if (profile?.doNotRent) {
    if (!acknowledgeDoNotRent) {
      throw staysError(
        'failed-precondition',
        'do_not_rent',
        ctx.role === 'employee'
          ? 'This guest is on the do-not-rent list. Ask the owner or a manager.'
          : 'This guest is on your do-not-rent list. Confirm to book them anyway.',
        { profileId: profile.profileId },
      );
    }
    warnings.push({ code: 'do_not_rent', message: 'Booked even though this guest is on your do-not-rent list.', details: { profileId: profile.profileId } });
  } else if (profile && (await doNotRentNameMatch(db, facilityId, profile.name, profile.profileId))) {
    warnings.push({ code: 'do_not_rent', message: `Someone named ${profile.name} is on your do-not-rent list. Check it is not the same guest.` });
  }
  if (isReservation && !guest.guestDisplayName && profile) guest.guestDisplayName = displayNameFrom(profile.name);
  // A returning RVer's rig length comes from their profile when the desk left it blank.
  const knownRig = profile?.existing?.vehicle?.rvLengthFt ?? profile?.create?.vehicle?.rvLengthFt ?? null;
  if (isReservation && guest.rvLengthFt === null && knownRig) guest.rvLengthFt = knownRig;

  const checkInTime = timeIn ?? listing.times?.checkIn ?? controls.defaultCheckInTime;
  const checkOutTime = timeOut ?? listing.times?.checkOut ?? controls.defaultCheckOutTime;

  // SFC's own bookings and blocks on a listing a channel also sells: the
  // short-notice rule, then a fresh look at the channel calendars.
  if (!ota) {
    const channels = await activeChannels(db, facilityId, listingId);
    const lead = shortLeadCheck({
      channels,
      checkIn,
      checkInTime,
      tz,
      nowMs,
      hours: controls.shortLeadWarningHours,
      acknowledged: acknowledgeShortLead,
    });
    if (lead) warnings.push(lead);
    const refreshed = await refreshChannelsFirst({
      sync: freshSync,
      channels,
      facilityId,
      syncEnabled: controls.icalSyncEnabled === true,
      nowMs,
    });
    if (refreshed) warnings.push(refreshed);
  }

  const priced = isReservation && !ota;
  const quote = priced
    ? validated(() => quoteStay(listing, controls, { checkIn, checkOut, adults: guest.adults, children: guest.children, pets: guest.pets, adjustmentCents: adjustment?.cents ?? 0 }))
    : null;
  if (isReservation) warnings.push(...partyWarnings(listing, guest));

  const now = Timestamp.fromMillis(nowMs);
  const stay: StayDoc = {
    facilityId,
    listingId,
    listingName: listing.name,
    listingGroup: listingGroupOf(listing),
    listingKind: listing.kind,
    kind,
    source,
    origin: 'sfc',
    status: 'confirmed',
    arrivalState: checkInNow ? 'checked_in' : 'upcoming',
    checkIn,
    checkOut,
    nights,
    checkInTime,
    checkOutTime,
    ...guest,
    paymentStatus: 'none',
    external: confirmationCode
      ? {
          provider: providerForSource(source),
          uid: null,
          uidHistory: [],
          confirmationCode,
          reservationUrl: source === 'airbnb' ? `https://www.airbnb.com/hosting/reservations/details/${confirmationCode}` : null,
          summary: null,
        }
      : null,
    sync: null,
    conflict: null,
    staffNotes: notes,
    cleanerNotes: '',
    tags: [],
    messageMarks: {},
    turnoverTaskId: null,
    checkedInAt: checkInNow ? now : null,
    checkedOutAt: null,
    cancelledAt: null,
    cancelledBy: null,
    cancelReason: null,
    requestId,
    version: 1,
    createdAtMs: nowMs,
    createdAt: now,
    createdBy: uid,
    updatedAt: now,
    updatedBy: uid,
  };

  let folio: StayFolioDoc | null = quote
    ? folioFromQuote(facilityId, stayId, quote, adjustment ? { ...adjustment, by: uid } : null, now)
    : null;
  let income: StayIncomeDoc | null = null;
  const entryId = incomeIdManual(requestId);
  if (payment && folio) {
    income = manualIncomeDoc({
      facilityId,
      stayId,
      stay,
      folioBefore: folio,
      payment,
      requestId,
      memo: '',
      receivedAt: receivedAtFor(payment.receivedDate, today, tz, nowMs),
      actor: uid,
      now,
    });
    folio = { ...applyPayment(folio, payment.amountCents), updatedAt: now };
  }
  stay.paymentStatus = paymentStatusOf(folio, stay);
  // The turnover trigger makes turnover_{stayId}; the stay names it up front so the app can open it.
  if (controls.turnoverTasksEnabled === true && wantsTurnover(stay, listing)) stay.turnoverTaskId = taskIdTurnover(stayId);

  const last4 = phoneLast4(profile?.phoneE164 ?? null);
  const privateDoc: StayPrivateDoc = {
    facilityId,
    stayId,
    guestProfileId: profile?.profileId ?? null,
    fullName: profile?.name ?? null,
    phoneLast4: last4,
    privateNotes: '',
    updatedAt: now,
    updatedBy: uid,
  };
  const accessDoc: StayAccessDoc | null =
    listing.accessCodeMode === 'phone_last4' && last4
      ? { facilityId, stayId, doorCode: last4, gateCode: null, accessNotes: '', source: 'phone_last4', updatedAt: now, updatedBy: uid }
      : null;
  const firstStayAt = Timestamp.fromDate(localDateTimeToUtc(checkIn, checkInTime, tz));

  const result = await applyStayMutations({
    db,
    facilityId,
    controls,
    nowMs,
    actor: uid,
    mutations: [{ stayId, next: stay, mode: 'sfc', createOnly: true, overrideSoftBlocks }],
    extraReads: profile ? [profile.ref] : [],
    extraWrites: (tx, snaps, plan) => {
      if (plan.skipped.includes(stayId)) {
        // Someone else's write made this id meanwhile (the feed, the CSV, or this same request).
        if (plan.before[stayId]?.requestId !== requestId) throw duplicateReservation(stayId, plan.before[stayId]);
        return;
      }
      if (folio) tx.set(folioRef(db, facilityId, stayId), folio);
      if (income) tx.create(incomeRef(db, facilityId, entryId), income);
      tx.set(facilityCol(db, facilityId, STAY_COLLECTIONS.private).doc(stayId), privateDoc);
      if (accessDoc) tx.set(facilityCol(db, facilityId, STAY_COLLECTIONS.access).doc(stayId), accessDoc);
      if (profile) {
        const snap = snaps[0];
        if (snap.exists) {
          const current = snap.data() as { stayCount?: number; lastStayAt?: Timestamp | null };
          const last = current.lastStayAt && typeof current.lastStayAt.toMillis === 'function' ? current.lastStayAt : null;
          tx.update(profile.ref, {
            stayCount: (Number.isInteger(current.stayCount) ? (current.stayCount as number) : 0) + 1,
            lastStayAt: last && last.toMillis() > firstStayAt.toMillis() ? last : firstStayAt,
            updatedAt: now,
            updatedBy: uid,
          });
        } else if (profile.create) {
          tx.set(profile.ref, newProfileDoc(facilityId, profile.create, uid, now, firstStayAt));
        } else {
          throw staysError('not-found', 'not_found', 'That returning guest was deleted meanwhile. Pick them again.', {
            profileId: profile.profileId,
          });
        }
      }
    },
  });

  if (result.plan.skipped.includes(stayId)) {
    return createRetryResponse(db, facilityId, stayId, result.plan.before[stayId]!, requestId);
  }
  const written = result.plan.after[stayId]!;
  await auditStays(ctx, {
    eventType: 'stays.stay.created',
    targetType: 'stay',
    targetId: stayId,
    metadata: {
      listingId,
      kind,
      source,
      nights,
      checkedIn: checkInNow,
      incomeEntryId: income ? entryId : null,
      overrideSoftBlocks,
      acknowledgedShortLead: acknowledgeShortLead,
      acknowledgedDoNotRent: acknowledgeDoNotRent,
    },
  });
  return {
    stayId,
    created: true,
    status: written.status,
    folio: folio ? toWire(folio) : null,
    incomeEntryId: income ? entryId : null,
    warnings,
  };
}

export const staysCreateStay = staysCallable(STAYS_CALLABLES.createStay, (data, context) => handleCreateStay(data, context));

// ---------------------------------------------------------------------------
// staysModifyStay
// ---------------------------------------------------------------------------

const MODIFY_KEYS = new Set(['checkIn', 'checkOut', 'listingId', 'checkInTime', 'checkOutTime', 'guest']);

export async function handleModifyStay(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
  freshSync: FreshSync | null = defaultFreshSync(),
): Promise<StaysModifyStayResponse> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.modifyStay,
      roles: STAFF,
      validate: (d) => void requireDocId(d, 'stayId'),
      rateLimit: { key: 'stays_modify', windowSeconds: 60, perFacility: 60, perUser: 30 },
    },
    deps,
  );
  const { db, facilityId, controls, nowMs, uid } = ctx;
  const d = ctx.data;
  const stayId = d.stayId as string;
  if (!Number.isInteger(d.expectedVersion) || (d.expectedVersion as number) < 0) {
    throw invalid('expectedVersion', 'expectedVersion is required: send the version of the booking you opened.');
  }
  const expectedVersion = d.expectedVersion as number;
  const changes = d.changes === undefined || d.changes === null ? {} : d.changes;
  if (typeof changes !== 'object' || Array.isArray(changes)) throw invalid('changes', 'changes must be an object.');
  const c = changes as Record<string, unknown>;
  for (const key of Object.keys(c)) {
    if (!MODIFY_KEYS.has(key)) throw invalid(`changes.${key}`, `${key} cannot be changed here.`);
  }
  if (c.checkIn !== undefined && !isValidYmd(c.checkIn)) {
    throw staysError('invalid-argument', 'invalid_dates', 'Check-in must be a YYYY-MM-DD date.', { field: 'changes.checkIn' });
  }
  if (c.checkOut !== undefined && !isValidYmd(c.checkOut)) {
    throw staysError('invalid-argument', 'invalid_dates', 'Check-out must be a YYYY-MM-DD date.', { field: 'changes.checkOut' });
  }
  if (c.listingId !== undefined) requireDocId(c, 'listingId');
  const newTimeIn = validated(() => validateOptionalTime(c.checkInTime, 'changes.checkInTime'));
  const newTimeOut = validated(() => validateOptionalTime(c.checkOutTime, 'changes.checkOutTime'));
  const guestPatch = parseGuestPatch(c.guest, 'changes.guest');
  const payment = d.payment === undefined || d.payment === null ? null : parsePayment(d.payment, 'payment');
  const requestId = payment ? requireRequestId(d) : null;
  const overrideSoftBlocks = optionalFlag(d, 'overrideSoftBlocks');
  const acknowledgeShortLead = optionalFlag(d, 'acknowledgeShortLead');

  const tz = confirmedTimeZone(controls);
  const today = facilityToday(tz, nowMs);
  const { clampFrom, clampTo } = lockHorizon(today);

  const snap = await stayRef(db, facilityId, stayId).get();
  if (!snap.exists) throw staysError('not-found', 'not_found', 'That booking was not found.', { stayId });
  const stored = snap.data() as StayDoc;
  const storedVersion = Number.isInteger(stored.version) ? stored.version : 0;
  if (storedVersion !== expectedVersion) {
    throw staysError('aborted', 'version_mismatch', 'This booking changed since you opened it. Reload and try again.', {
      stayId,
      version: storedVersion,
    });
  }

  const checkIn = (c.checkIn as Ymd | undefined) ?? stored.checkIn;
  const checkOut = (c.checkOut as Ymd | undefined) ?? stored.checkOut;
  const listingId = (c.listingId as string | undefined) ?? stored.listingId;
  const datesChanged = checkIn !== stored.checkIn || checkOut !== stored.checkOut;
  const listingChanged = listingId !== stored.listingId;
  const guestKeys = (Object.keys(guestPatch) as (keyof GuestFields)[]).filter((k) => guestPatch[k] !== (stored as unknown as GuestFields)[k]);
  const partyChanged = guestKeys.some((k) => k === 'adults' || k === 'children' || k === 'pets');
  const checkInTime = newTimeIn ?? stored.checkInTime;
  const checkOutTime = newTimeOut ?? stored.checkOutTime;
  const timesChanged = checkInTime !== stored.checkInTime || checkOutTime !== stored.checkOutTime;
  const active = isActiveStatus(stored.status);
  const ota = isOtaSource(stored.source);

  if (ctx.role === 'employee') {
    assertEmployeeSetting(ctx, 'employeesCanBook');
    const onlyExtendsWalkUp =
      stored.kind === 'reservation' &&
      stored.source === 'walk_up' &&
      !listingChanged &&
      checkIn === stored.checkIn &&
      checkOut > stored.checkOut &&
      guestKeys.length === 0 &&
      !timesChanged;
    if (!onlyExtendsWalkUp) throw roleNotAllowed(ctx, 'Employees can only add nights to a walk-up stay.');
    if (overrideSoftBlocks) throw roleNotAllowed(ctx, 'Only an owner or manager can book over a channel block.');
    if (payment) assertEmployeeSetting(ctx, 'employeesCanRecordCash');
  }
  if ((datesChanged || listingChanged) && isFeedOwned(stored)) {
    const where = providerName(stored.external?.provider ?? providerForSource(stored.source));
    throw staysError(
      'failed-precondition',
      'feed_owned_dates',
      `Change the dates in ${where}; Stays picks the change up within 30 minutes.`,
      { provider: stored.external?.provider ?? stored.source },
    );
  }
  if ((datesChanged || listingChanged) && !active) throw invalid('changes', 'Restore this booking before changing its dates.');
  if (guestKeys.length > 0 && stored.kind !== 'reservation') throw invalid('changes.guest', 'Blocks have no guests.');
  if (payment && (stored.kind !== 'reservation' || ota)) throw invalid('payment', 'Record payments only on bookings Stays prices.');
  if (payment) assertReceivedDate(payment.receivedDate, today, 'payment.receivedDate');

  const listing = await loadListing(db, facilityId, listingId);
  const nights = datesChanged ? assertNightCount(checkIn, checkOut) : stored.nights;
  if (datesChanged || listingChanged) {
    if (listingChanged) assertBookable(listing, listingId);
    if (stored.kind === 'reservation' && (listingChanged || nights > stored.nights)) {
      assertListingRules(listing, nights, { checkMin: false });
    }
    if (checkIn !== stored.checkIn && checkIn < clampFrom) {
      throw staysError('invalid-argument', 'invalid_dates', 'That check-in is too far in the past.', { field: 'checkIn' });
    }
    if (checkOut > clampTo && (listingChanged || checkOut > stored.checkOut)) assertBeforeHorizonEnd(checkOut, clampTo);
  }

  const noChange = !datesChanged && !listingChanged && !timesChanged && guestKeys.length === 0 && !payment;
  const folioSnap = await folioRef(db, facilityId, stayId).get();
  const storedFolio = folioSnap.exists ? (folioSnap.data() as StayFolioDoc) : null;
  if (noChange) return { stay: toWire(stored), folio: storedFolio ? toWire(storedFolio) : null };

  const warnings: StaysWarning[] = [];
  // Nights this change adds (a move re-takes all of them).
  const kept = new Set(active && !listingChanged ? enumerateNights(stored.checkIn, stored.checkOut) : []);
  const added = enumerateNights(checkIn, checkOut).filter((n) => !kept.has(n));
  if (added.length > 0 && !ota) {
    const channels = await activeChannels(db, facilityId, listingId);
    const firstUpcoming = added.find((n) => n >= today) ?? null;
    if (firstUpcoming) {
      const lead = shortLeadCheck({
        channels,
        checkIn: firstUpcoming,
        checkInTime,
        tz,
        nowMs,
        hours: controls.shortLeadWarningHours,
        acknowledged: acknowledgeShortLead,
      });
      if (lead) warnings.push(lead);
    }
    const refreshed = await refreshChannelsFirst({ sync: freshSync, channels, facilityId, syncEnabled: controls.icalSyncEnabled === true, nowMs });
    if (refreshed) warnings.push(refreshed);
  }

  const now = Timestamp.fromMillis(nowMs);
  // A stored doc may predate a field; Firestore refuses undefined, so each falls back to its empty value.
  const guestNext: GuestFields = {
    guestDisplayName: guestPatch.guestDisplayName ?? stored.guestDisplayName ?? '',
    adults: guestPatch.adults ?? stored.adults ?? 0,
    children: guestPatch.children ?? stored.children ?? 0,
    pets: guestPatch.pets ?? stored.pets ?? 0,
    rvLengthFt: guestPatch.rvLengthFt !== undefined ? guestPatch.rvLengthFt : (stored.rvLengthFt ?? null),
  };

  // The price moves with the dates and the party; a move alone keeps the price agreed.
  const priced = stored.kind === 'reservation' && !ota;
  const requote = priced && (datesChanged || partyChanged || (!storedFolio && listingChanged));
  let folio: StayFolioDoc | null = storedFolio;
  if (requote) {
    const adjustment = storedFolio?.adjustment ?? null;
    const quote = validated(() =>
      quoteStay(listing, controls, {
        checkIn,
        checkOut,
        adults: guestNext.adults,
        children: guestNext.children,
        pets: guestNext.pets,
        adjustmentCents: adjustment?.cents ?? 0,
      }),
    );
    folio = folioFromQuote(facilityId, stayId, quote, adjustment, now, storedFolio);
  }
  const next: StayDoc = {
    ...stored,
    listingId,
    listingName: listing.name,
    listingGroup: listingGroupOf(listing),
    listingKind: listing.kind,
    checkIn,
    checkOut,
    nights,
    checkInTime,
    checkOutTime,
    ...guestNext,
    version: storedVersion + 1,
    updatedAt: now,
    updatedBy: uid,
  };
  let income: StayIncomeDoc | null = null;
  const entryId = requestId ? incomeIdManual(requestId) : null;
  if (payment && folio && entryId && requestId) {
    income = manualIncomeDoc({
      facilityId,
      stayId,
      stay: next,
      folioBefore: folio,
      payment,
      requestId,
      memo: '',
      receivedAt: receivedAtFor(payment.receivedDate, today, tz, nowMs),
      actor: uid,
      now,
    });
    folio = { ...applyPayment(folio, payment.amountCents), updatedAt: now };
  } else if (payment) {
    throw invalid('payment', 'This booking has no folio to record a payment against.');
  }
  if (priced) {
    next.paymentStatus = paymentStatusOf(folio, next, { refunded: stored.paymentStatus === 'refunded' && (folio?.paidCents ?? 0) <= 0 });
  }
  if (controls.turnoverTasksEnabled === true && wantsTurnover(next, listing)) next.turnoverTaskId = taskIdTurnover(stayId);

  const owns = guestKeys.map((k) => GUEST_FIELD_OWNERSHIP[k]);
  const result = await applyStayMutations({
    db,
    facilityId,
    controls,
    nowMs,
    actor: uid,
    mutations: [{ stayId, next, expectedVersion, mode: 'sfc', overrideSoftBlocks, owns }],
    extraReads: [folioRef(db, facilityId, stayId), ...(entryId ? [incomeRef(db, facilityId, entryId)] : [])],
    extraWrites: (tx, snaps) => {
      const current = snaps[0].exists ? (snaps[0].data() as StayFolioDoc) : null;
      // A payment recorded meanwhile bumps the stay's version too, so this is a safety net.
      if ((current?.paidCents ?? null) !== (storedFolio?.paidCents ?? null) || (current?.totalCents ?? null) !== (storedFolio?.totalCents ?? null)) {
        throw staysError('aborted', 'version_mismatch', 'This booking changed since you opened it. Reload and try again.', { stayId });
      }
      if (entryId && snaps[1]?.exists) throw invalid('requestId', 'That payment was already recorded.');
      if (folio && folio !== storedFolio) tx.set(folioRef(db, facilityId, stayId), folio);
      if (income && entryId) tx.create(incomeRef(db, facilityId, entryId), income);
    },
  });

  const written = result.plan.after[stayId]!;
  await auditStays(ctx, {
    eventType: 'stays.stay.modified',
    targetType: 'stay',
    targetId: stayId,
    metadata: {
      datesChanged,
      listingChanged,
      fromListingId: listingChanged ? stored.listingId : null,
      timesChanged,
      guestFields: guestKeys,
      requoted: requote,
      incomeEntryId: income ? entryId : null,
      status: written.status,
    },
  });
  return { stay: toWire(written), folio: folio ? toWire(folio) : null };
}

export const staysModifyStay = staysCallable(STAYS_CALLABLES.modifyStay, async (data, context) => handleModifyStay(data, context));

// ---------------------------------------------------------------------------
// staysCancelStay
// ---------------------------------------------------------------------------

export async function handleCancelStay(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysCancelStayResponse> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.cancelStay,
      roles: OWNER_OR_MANAGER,
      validate: (d) => void requireDocId(d, 'stayId'),
      rateLimit: { key: 'stays_cancel', windowSeconds: 60, perFacility: 30 },
    },
    deps,
  );
  const { db, facilityId, controls, nowMs, uid } = ctx;
  const stayId = ctx.data.stayId as string;
  if (!Number.isInteger(ctx.data.expectedVersion)) throw invalid('expectedVersion', 'expectedVersion is required.');
  const expectedVersion = ctx.data.expectedVersion as number;
  const reason = validated(() => validateText(ctx.data.reason, 'reason', { min: 1, max: 500 }));
  const noShow = optionalFlag(ctx.data, 'noShow');
  const tz = confirmedTimeZone(controls);
  const today = facilityToday(tz, nowMs);

  const [staySnap, folioSnap] = await db.getAll(stayRef(db, facilityId, stayId), folioRef(db, facilityId, stayId));
  if (!staySnap.exists) throw staysError('not-found', 'not_found', 'That booking was not found.', { stayId });
  const stored = staySnap.data() as StayDoc;
  const storedVersion = Number.isInteger(stored.version) ? stored.version : 0;
  if (storedVersion !== expectedVersion) {
    throw staysError('aborted', 'version_mismatch', 'This booking changed since you opened it. Reload and try again.', { stayId, version: storedVersion });
  }
  if (isFeedOwned(stored)) {
    const where = providerName(stored.external?.provider ?? providerForSource(stored.source));
    throw staysError('failed-precondition', 'feed_owned_dates', `Cancel it in ${where}; Stays picks the change up within 30 minutes.`, {
      provider: stored.external?.provider ?? stored.source,
    });
  }
  if (!isActiveStatus(stored.status)) throw invalid('stayId', 'This booking is already cancelled.');
  if (stored.arrivalState === 'checked_in' || stored.arrivalState === 'checked_out') {
    throw invalid('stayId', 'This guest already checked in. Check them out, or shorten the stay, instead.');
  }
  if (noShow && (stored.kind !== 'reservation' || stored.checkIn > today)) {
    throw invalid('noShow', 'A guest can be marked a no-show from their arrival day on.');
  }

  const folio = folioSnap.exists ? (folioSnap.data() as StayFolioDoc) : null;
  const now = Timestamp.fromMillis(nowMs);
  const next: StayDoc = {
    ...stored,
    status: 'cancelled',
    arrivalState: noShow ? 'no_show' : stored.arrivalState,
    conflict: null,
    cancelledAt: now,
    cancelledBy: uid,
    cancelReason: reason,
    version: storedVersion + 1,
    updatedAt: now,
    updatedBy: uid,
  };
  next.paymentStatus = isOtaSource(stored.source) ? stored.paymentStatus : paymentStatusOf(folio, next, { refunded: stored.paymentStatus === 'refunded' });

  const result = await applyStayMutations({
    db,
    facilityId,
    controls,
    nowMs,
    actor: uid,
    mutations: [{ stayId, next, expectedVersion, mode: 'sfc', owns: noShow ? ['arrivalState'] : [] }],
    extraWrites: (_tx, _snaps, plan) => {
      // Staff check-ins do not move the version: refuse if one landed meanwhile.
      const arrival = plan.before[stayId]?.arrivalState;
      if (arrival === 'checked_in' || arrival === 'checked_out') {
        throw invalid('stayId', 'This guest was just checked in. Check them out, or shorten the stay, instead.');
      }
    },
  });
  const written = result.plan.after[stayId]!;
  await auditStays(ctx, {
    eventType: 'stays.stay.cancelled',
    targetType: 'stay',
    targetId: stayId,
    metadata: {
      noShow,
      releasedNights: stored.nights,
      freedStays: result.statusChanges.filter((s) => s.stayId !== stayId && s.to === 'confirmed').map((s) => s.stayId),
    },
  });
  return { stay: toWire(written) };
}

export const staysCancelStay = staysCallable(STAYS_CALLABLES.cancelStay, (data, context) => handleCancelStay(data, context));

// ---------------------------------------------------------------------------
// staysReviewStay
// ---------------------------------------------------------------------------

export async function handleReviewStay(
  rawData: unknown,
  context: functions.https.CallableContext,
  deps: StaysDeps = defaultStaysDeps(),
): Promise<StaysReviewStayResponse> {
  const ctx = await runStaysGuards(
    rawData,
    context,
    {
      callable: STAYS_CALLABLES.reviewStay,
      roles: OWNER_OR_MANAGER,
      validate: (d) => void requireDocId(d, 'stayId'),
      rateLimit: { key: 'stays_review', windowSeconds: 60, perFacility: 60 },
    },
    deps,
  );
  const { db, facilityId, controls, nowMs, uid } = ctx;
  const stayId = ctx.data.stayId as string;
  const action: StayReviewAction = enumField(ctx.data.action, 'action', REVIEW_ACTIONS);
  const note = validated(() => validateText(ctx.data.note ?? '', 'note', { max: 500 }));
  const expected = ctx.data.expectedVersion;
  if (expected !== undefined && expected !== null && !Number.isInteger(expected)) throw invalid('expectedVersion', 'expectedVersion is a whole number.');

  const [staySnap, folioSnap] = await db.getAll(stayRef(db, facilityId, stayId), folioRef(db, facilityId, stayId));
  if (!staySnap.exists) throw staysError('not-found', 'not_found', 'That booking was not found.', { stayId });
  const stored = staySnap.data() as StayDoc;
  const storedVersion = Number.isInteger(stored.version) ? stored.version : 0;
  if (expected !== undefined && expected !== null && expected !== storedVersion) {
    throw staysError('aborted', 'version_mismatch', 'This booking changed since you opened it. Reload and try again.', { stayId, version: storedVersion });
  }
  const now = Timestamp.fromMillis(nowMs);
  const next: StayDoc = { ...stored, version: storedVersion + 1, updatedAt: now, updatedBy: uid };
  let mode: 'sfc' | 'feed' = 'sfc';
  let overrideSoftBlocks = false;
  const owns: StayStaffField[] = [];

  switch (action) {
    case 'acknowledge_conflict':
      if (stored.status !== 'conflict' || !stored.conflict) throw invalid('action', 'This booking has no double-booking to acknowledge.');
      next.conflict = { ...stored.conflict, acknowledgedAt: now, acknowledgedBy: uid, note: note || null };
      break;
    case 'restore':
      if (stored.status === 'removed_from_feed') {
        // She knows it is real. Detach it from the feed, or the next syncs would remove it again.
        next.status = 'confirmed';
        next.sync = stored.sync
          ? { ...stored.sync, detached: true, missCount: 0, firstMissAt: null, lastMissAt: null, needsReview: false }
          : null;
        // Recorded as a conflict if its nights were taken meanwhile, never refused.
        mode = 'feed';
      } else if (stored.status === 'cancelled') {
        next.status = 'confirmed';
        next.cancelledAt = null;
        next.cancelledBy = null;
        next.cancelReason = null;
        if (stored.arrivalState === 'no_show') {
          next.arrivalState = 'upcoming';
          owns.push('arrivalState');
        }
        // A hard claim taken meanwhile refuses the restore; a channel block does not.
        overrideSoftBlocks = true;
      } else {
        throw invalid('action', 'Only a cancelled or removed booking can be restored.');
      }
      if (!isOtaSource(stored.source) && stored.kind === 'reservation') {
        next.paymentStatus = paymentStatusOf(folioSnap.exists ? (folioSnap.data() as StayFolioDoc) : null, next);
      }
      break;
    case 'clear_review':
      if (!stored.sync?.needsReview) throw invalid('action', 'This booking is not flagged for review.');
      next.sync = { ...stored.sync, needsReview: false };
      break;
  }

  const result = await applyStayMutations({
    db,
    facilityId,
    controls,
    nowMs,
    actor: uid,
    mutations: [{ stayId, next, expectedVersion: storedVersion, mode, overrideSoftBlocks, owns }],
  });
  const written = result.plan.after[stayId]!;
  await auditStays(ctx, {
    eventType: 'stays.stay.reviewed',
    targetType: 'stay',
    targetId: stayId,
    metadata: { action, from: stored.status, to: written.status },
  });
  return { stay: toWire(written) };
}

export const staysReviewStay = staysCallable(STAYS_CALLABLES.reviewStay, (data, context) => handleReviewStay(data, context));
