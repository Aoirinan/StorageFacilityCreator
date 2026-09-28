import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';
import type { CollectionReference, DocumentReference, Firestore, Transaction } from 'firebase-admin/firestore';

import {
  OTA_SOURCES,
  STAY_COLLECTIONS,
  StayDoc,
  StayListingDoc,
  StaySource,
  StaysWarning,
  Wire,
  Ymd,
} from '@sfc/functions-shared/stays/contracts';
import { localDateTimeToUtc } from '@sfc/functions-shared/stays/dates';
import { StayValidationError } from '@sfc/functions-shared/stays/validation';

import { staysError } from '../common/errors';

/**
 * Helpers the booking, listing and money callables share. Nothing here
 * decides a booking; it reads docs, words errors and shapes responses.
 */

export function facilityCol(db: Firestore, facilityId: string, name: string): CollectionReference {
  return db.collection('facilities').doc(facilityId).collection(name);
}

export function stayRef(db: Firestore, facilityId: string, stayId: string): DocumentReference {
  return facilityCol(db, facilityId, STAY_COLLECTIONS.stays).doc(stayId);
}

export function folioRef(db: Firestore, facilityId: string, stayId: string): DocumentReference {
  return facilityCol(db, facilityId, STAY_COLLECTIONS.folios).doc(stayId);
}

export function incomeRef(db: Firestore, facilityId: string, entryId: string): DocumentReference {
  return facilityCol(db, facilityId, STAY_COLLECTIONS.income).doc(entryId);
}

export function listingRef(db: Firestore, facilityId: string, listingId: string): DocumentReference {
  return facilityCol(db, facilityId, STAY_COLLECTIONS.listings).doc(listingId);
}

function isTimestampLike(value: unknown): value is Timestamp {
  return (
    value instanceof Timestamp ||
    (!!value && typeof (value as Timestamp).toMillis === 'function' && typeof (value as Timestamp).toDate === 'function')
  );
}

/** A doc as a callable returns it: Firestore Timestamps become ISO-8601 strings. */
export function toWire<T>(value: T): Wire<T> {
  const convert = (v: unknown): unknown => {
    if (isTimestampLike(v)) return v.toDate().toISOString();
    if (Array.isArray(v)) return v.map(convert);
    if (v && typeof v === 'object') {
      const out: Record<string, unknown> = {};
      for (const [key, inner] of Object.entries(v as Record<string, unknown>)) {
        if (inner !== undefined) out[key] = convert(inner);
      }
      return out;
    }
    return v;
  };
  return convert(value) as Wire<T>;
}

/**
 * Runs pure validation and turns its StayValidationError into the Stays
 * error the app words: a date field is `invalid_dates`, anything else
 * `invalid_argument`, with the field named in details.
 */
export function validated<T>(fn: () => T): T {
  try {
    return fn();
  } catch (error) {
    if (error instanceof StayValidationError) {
      const dateField = error.field === 'checkIn' || error.field === 'checkOut';
      throw staysError('invalid-argument', dateField ? 'invalid_dates' : 'invalid_argument', error.message, {
        field: error.field,
      });
    }
    throw error;
  }
}

export function invalid(field: string, message: string): functions.https.HttpsError {
  return staysError('invalid-argument', 'invalid_argument', message, { field });
}

export function isOtaSource(source: string): boolean {
  return (OTA_SOURCES as readonly string[]).includes(source);
}

/**
 * Another channel's calendar decides this stay's dates: it came from a feed,
 * or a feed adopted it. A detached stay (restored after "Removed from
 * Airbnb", or its channel removed) is SFC's whatever its origin: the feed no
 * longer updates it, so SFC must be able to cancel or re-date it, or its
 * nights would be held for good.
 */
export function isFeedOwned(stay: Pick<StayDoc, 'origin' | 'sync'>): boolean {
  if (stay.sync?.detached === true) return false;
  return stay.origin === 'feed' || !!stay.sync;
}

/** The channel a stay's source names, for `external.provider`. */
export function providerForSource(source: StaySource): 'airbnb' | 'vrbo' | 'booking' | 'hipcamp' | 'other' {
  switch (source) {
    case 'airbnb':
    case 'vrbo':
    case 'booking':
    case 'hipcamp':
      return source;
    default:
      return 'other';
  }
}

/** A listing, or not_found. */
export async function loadListing(
  db: Firestore,
  facilityId: string,
  listingId: string,
  tx?: Transaction,
): Promise<StayListingDoc> {
  const ref = listingRef(db, facilityId, listingId);
  const snap = tx ? await tx.get(ref) : await ref.get();
  if (!snap.exists) {
    throw staysError('not-found', 'not_found', 'That listing was not found. It may have been removed.', { listingId });
  }
  return snap.data() as StayListingDoc;
}

/** Only an active, unarchived listing takes new nights. */
export function assertBookable(listing: StayListingDoc, listingId: string): void {
  if (listing.active !== true || listing.archived === true) {
    throw staysError(
      'failed-precondition',
      'listing_inactive',
      `${listing.name || 'That listing'} is not taking bookings right now (it is turned off or archived).`,
      { listingId },
    );
  }
}

/** A stay, or not_found. */
export async function loadStay(db: Firestore, facilityId: string, stayId: string): Promise<StayDoc> {
  const snap = await stayRef(db, facilityId, stayId).get();
  if (!snap.exists) {
    throw staysError('not-found', 'not_found', 'That booking was not found. It may have been removed.', { stayId });
  }
  return snap.data() as StayDoc;
}

/** "Jane D. · 2026-10-10 to 2026-10-12", or "Owner block · …": the same wording the stay writer uses. */
export function stayLabel(doc: Pick<StayDoc, 'kind' | 'guestDisplayName' | 'checkIn' | 'checkOut'> | undefined): string {
  if (!doc) return 'Another booking';
  const who =
    doc.kind === 'owner_block'
      ? 'Owner block'
      : doc.kind === 'maintenance_block'
        ? 'Maintenance block'
        : doc.guestDisplayName || 'Guest';
  return `${who} · ${doc.checkIn} to ${doc.checkOut}`;
}

export interface ListingChannel {
  channelId: string;
  provider: string;
  /** Last successful sync, or null when it never succeeded. */
  lastSuccessMs: number | null;
}

/** The listing's active import feeds (stayChannels). */
export async function activeChannels(db: Firestore, facilityId: string, listingId: string): Promise<ListingChannel[]> {
  const snap = await facilityCol(db, facilityId, STAY_COLLECTIONS.channels).where('listingId', '==', listingId).get();
  return snap.docs
    .filter((d) => d.get('active') === true)
    .map((d) => {
      const last = d.get('sync.lastSuccessAt');
      return {
        channelId: d.id,
        provider: typeof d.get('provider') === 'string' ? (d.get('provider') as string) : 'other',
        lastSuccessMs: isTimestampLike(last) ? last.toMillis() : null,
      };
    });
}

/**
 * Whether check-in (its day and time at the facility) is within the
 * owner's short-notice window: too soon for a channel to have pulled SFC's
 * calendar. 0 hours turns the check off.
 */
export function isShortLead(checkIn: Ymd, checkInTime: string, tz: string, nowMs: number, hours: number): boolean {
  if (!(hours > 0)) return false;
  return localDateTimeToUtc(checkIn, checkInTime, tz).getTime() - nowMs < hours * 3_600_000;
}

/** Everyone's display name for a channel. */
export function providerName(provider: string): string {
  switch (provider) {
    case 'airbnb':
      return 'Airbnb';
    case 'vrbo':
      return 'VRBO';
    case 'booking':
      return 'Booking.com';
    case 'google':
      return 'Google Calendar';
    case 'hipcamp':
      return 'Hipcamp';
    default:
      return 'the other channel';
  }
}

export function joinNames(names: string[]): string {
  const unique = [...new Set(names)];
  if (unique.length <= 1) return unique[0] ?? '';
  return `${unique.slice(0, -1).join(', ')} and ${unique[unique.length - 1]}`;
}

/**
 * The short-notice rule (spec §1.1 D): SFC's own booking on a listing that
 * another channel also sells, starting inside the owner's window, needs her
 * to confirm she blocked those dates there too. Returns the warning to show
 * once confirmed, or null when the rule does not apply.
 */
export function shortLeadCheck(opts: {
  channels: ListingChannel[];
  checkIn: Ymd;
  checkInTime: string;
  tz: string;
  nowMs: number;
  hours: number;
  acknowledged: boolean;
}): StaysWarning | null {
  if (opts.channels.length === 0) return null;
  if (!isShortLead(opts.checkIn, opts.checkInTime, opts.tz, opts.nowMs, opts.hours)) return null;
  const providers = [...new Set(opts.channels.map((c) => c.provider))];
  const where = joinNames(providers.map(providerName));
  if (!opts.acknowledged) {
    throw staysError(
      'failed-precondition',
      'short_lead_ack_required',
      `This starts within ${opts.hours} hours. ${where} may not see it in time: block these dates in ${where} too, then confirm.`,
      { hours: opts.hours, providers },
    );
  }
  return {
    code: 'short_lead',
    message: `Short notice: make sure these dates are blocked in ${where} as well.`,
    details: { hours: opts.hours, providers },
  };
}

/**
 * Refreshes a listing's channel calendars before SFC books on it (spec §6.5
 * staysCreateStay). WP2 provides the sync; it is loaded lazily so the
 * booking engine builds and runs without it, and a missing or failing sync
 * never stops a booking: the night locks stay authoritative.
 */
export type FreshSync = (facilityId: string, channelId: string, trigger: 'save') => Promise<unknown>;

const SYNC_MODULE = '../sync/syncChannel';

function loadSyncModule(): unknown {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  return require(SYNC_MODULE);
}

/** Node's "Cannot find module '../sync/syncChannel'", and not a module that one needs. */
function isSyncModuleMissing(error: unknown): boolean {
  const e = error as { code?: unknown; message?: unknown } | null;
  if (!e || e.code !== 'MODULE_NOT_FOUND' || typeof e.message !== 'string') return false;
  // The first line names the missing module; the require stack under it may name syncChannel too.
  return e.message.split('\n')[0].includes(`'${SYNC_MODULE}'`);
}

/**
 * WP2's syncChannel(facilityId, channelId, trigger), or null while it does
 * not exist. Only its absence is quiet: a sync module that fails to load is
 * logged as an error, so a broken build cannot silently turn the fresh sync
 * off (bookings still go ahead, with the "not refreshed" warning).
 */
export function defaultFreshSync(
  load: () => unknown = loadSyncModule,
  logError: (message: string, meta: Record<string, unknown>) => void = (message, meta) => functions.logger.error(message, meta),
): FreshSync | null {
  let mod: { syncChannel?: unknown } | null;
  try {
    mod = load() as { syncChannel?: unknown } | null;
  } catch (error) {
    if (!isSyncModuleMissing(error)) {
      logError('stays: the channel sync module failed to load; bookings skip the fresh sync', {
        error: error instanceof Error ? error.message.split('\n')[0] : String(error),
      });
    }
    return null;
  }
  if (typeof mod?.syncChannel === 'function') return mod.syncChannel as FreshSync;
  logError('stays: the channel sync module has no syncChannel export; bookings skip the fresh sync', {});
  return null;
}

export const FRESH_SYNC_MAX_AGE_MS = 5 * 60_000;
export const FRESH_SYNC_TIMEOUT_MS = 6_000;

export async function refreshChannelsFirst(opts: {
  sync: FreshSync | null;
  channels: ListingChannel[];
  facilityId: string;
  syncEnabled: boolean;
  nowMs: number;
  timeoutMs?: number;
}): Promise<StaysWarning | null> {
  const stale = opts.channels.filter((c) => c.lastSuccessMs === null || opts.nowMs - c.lastSuccessMs > FRESH_SYNC_MAX_AGE_MS);
  if (stale.length === 0) return null;
  if (!opts.sync || !opts.syncEnabled) {
    return {
      code: 'fresh_sync_skipped',
      message: 'Channel calendars were not refreshed first, so availability is as of their last sync.',
    };
  }
  let timer: NodeJS.Timeout | undefined;
  try {
    await Promise.race([
      Promise.all(stale.map((c) => opts.sync!(opts.facilityId, c.channelId, 'save'))),
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('fresh sync timed out')), opts.timeoutMs ?? FRESH_SYNC_TIMEOUT_MS);
      }),
    ]);
    return null;
  } catch (error) {
    functions.logger.warn('stays: fresh sync before booking failed', {
      facilityId: opts.facilityId,
      error: error instanceof Error ? error.message : String(error),
    });
    return {
      code: 'fresh_sync_failed',
      message: 'Could not refresh the channel calendars just now; availability is as of their last sync.',
    };
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** "Oct 3": for staff-visible notification text. */
export function shortDate(ymd: Ymd): string {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const [, m, d] = ymd.split('-').map(Number);
  return `${months[m - 1]} ${d}`;
}

/** In-app routes (lib/router/app_route.dart) a notification opens. */
export function stayRoute(facilityId: string, stayId: string): string {
  return `/stays/booking?facilityId=${encodeURIComponent(facilityId)}&stayId=${encodeURIComponent(stayId)}`;
}

export function turnoverRoute(facilityId: string, taskId: string): string {
  return `/stays/turnover?facilityId=${encodeURIComponent(facilityId)}&taskId=${encodeURIComponent(taskId)}`;
}
