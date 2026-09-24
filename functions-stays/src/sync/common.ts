import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import type { CollectionReference, Firestore } from 'firebase-admin/firestore';

import {
  SafeFetchError,
  SafeFetchOptions,
  SafeFetchResult,
  safeFetchText,
} from '@sfc/functions-shared/net/safeFetch';
import {
  ChannelProvider,
  ChannelSyncStatus,
  ExportTargetProvider,
  STAY_COLLECTIONS,
  StaySource,
  Ymd,
} from '@sfc/functions-shared/stays/contracts';
import { diffDays } from '@sfc/functions-shared/stays/dates';

import type { StaysDeps } from '../common/guards';
import { defaultStaysDeps } from '../common/guards';

/**
 * Shared pieces of the channel sync, export links and the export feed:
 * collection refs, the fetch dependency, provider names and the date wording
 * used in notifications (dates and listing names only, never guest details).
 */

/** Actor for every write the sync makes. */
export const SYNC_ACTOR = 'system:stays-sync';

/** The sync's reach to the outside world; tests pass fakes. */
export interface SyncDeps {
  db: () => Firestore;
  now: () => number;
  fetchFeed: (url: string, opts: SafeFetchOptions) => Promise<SafeFetchResult>;
}

/** Callables need the guard deps as well as the fetch. */
export type StaysSyncCallableDeps = StaysDeps & Pick<SyncDeps, 'fetchFeed'>;

/** Production fetch: logs carry the host and the URL fingerprint only. */
export function productionFetchFeed(url: string, opts: SafeFetchOptions): Promise<SafeFetchResult> {
  return safeFetchText(url, opts, {
    log: (entry) => functions.logger.info('stays: feed fetch', entry),
  });
}

export function defaultSyncDeps(): SyncDeps {
  return { db: () => admin.firestore(), now: () => Date.now(), fetchFeed: productionFetchFeed };
}

export function defaultSyncCallableDeps(): StaysSyncCallableDeps {
  return { ...defaultStaysDeps(), fetchFeed: productionFetchFeed };
}

export function facilityCol(db: Firestore, facilityId: string, name: string): CollectionReference {
  return db.collection('facilities').doc(facilityId).collection(name);
}

export const staysCol = (db: Firestore, fid: string) => facilityCol(db, fid, STAY_COLLECTIONS.stays);
export const channelsCol = (db: Firestore, fid: string) => facilityCol(db, fid, STAY_COLLECTIONS.channels);
export const channelBlocksCol = (db: Firestore, fid: string) => facilityCol(db, fid, STAY_COLLECTIONS.channelBlocks);
export const exportLinksCol = (db: Firestore, fid: string) => facilityCol(db, fid, STAY_COLLECTIONS.exportLinks);
export const listingsCol = (db: Firestore, fid: string) => facilityCol(db, fid, STAY_COLLECTIONS.listings);
export const syncLogCol = (db: Firestore, fid: string) => facilityCol(db, fid, STAY_COLLECTIONS.syncLog);

/** What a channel's reservations are recorded as. */
export function sourceForProvider(provider: ChannelProvider): StaySource {
  switch (provider) {
    case 'airbnb':
    case 'vrbo':
    case 'booking':
    case 'hipcamp':
      return provider;
    default:
      return 'other_channel';
  }
}

/** The export target that sends to a channel of this provider (for echo marking). */
export function exportTargetForProvider(provider: ChannelProvider): ExportTargetProvider {
  switch (provider) {
    case 'airbnb':
    case 'vrbo':
    case 'booking':
    case 'google':
      return provider;
    default:
      return 'other';
  }
}

/** Channels that take the guest's money themselves. */
export function channelCollectsPayment(provider: ChannelProvider): boolean {
  return provider === 'airbnb' || provider === 'vrbo' || provider === 'booking' || provider === 'hipcamp';
}

export function providerLabel(provider: string): string {
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
      return 'channel';
  }
}

/** A fetch failure as the channel's sync status. */
export function syncStatusForFetchError(error: SafeFetchError): ChannelSyncStatus {
  switch (error.code) {
    case 'invalid_url':
    case 'blocked_host':
    case 'blocked_ip':
      return 'blocked_host';
    case 'timeout':
      return 'timeout';
    case 'too_large':
      return 'too_large';
    case 'gone':
      return 'gone';
    case 'invalid_feed':
      return 'invalid_feed';
    default:
      return 'http_error';
  }
}

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** 'Oct 3'. */
export function formatDay(ymd: Ymd): string {
  const [, m, d] = ymd.split('-').map(Number);
  return `${MONTHS[m - 1]} ${d}`;
}

/** 'Oct 3–6', or 'Oct 30 – Nov 2' across months. `checkOut` is the departure day. */
export function formatRange(checkIn: Ymd, checkOut: Ymd): string {
  if (checkIn.slice(0, 7) === checkOut.slice(0, 7)) return `${formatDay(checkIn)}–${Number(checkOut.slice(8))}`;
  return `${formatDay(checkIn)} – ${formatDay(checkOut)}`;
}

export function nightsLabel(checkIn: Ymd, checkOut: Ymd): string {
  const n = diffDays(checkIn, checkOut);
  return n === 1 ? '1 night' : `${n} nights`;
}

export function stayRoute(facilityId: string, stayId: string): string {
  return `/stays/booking?facilityId=${encodeURIComponent(facilityId)}&stayId=${encodeURIComponent(stayId)}`;
}

export function channelsRoute(facilityId: string, listingId: string): string {
  return `/stays/channels?facilityId=${encodeURIComponent(facilityId)}&listingId=${encodeURIComponent(listingId)}`;
}

/** The public app origin for export links (functions env PUBLIC_APP_URL, else the production app). */
export function publicAppUrl(): string {
  const v = process.env.PUBLIC_APP_URL?.trim();
  const base = v && v.length > 0 ? v : 'https://app.storagefacilitycreator.com';
  return base.replace(/\/$/, '');
}

export function exportUrlForToken(token: string): string {
  return `${publicAppUrl()}/api/ical/${token}.ics`;
}

export function tsMillis(value: unknown): number | null {
  if (value && typeof (value as { toMillis?: unknown }).toMillis === 'function') {
    return (value as { toMillis(): number }).toMillis();
  }
  return null;
}
