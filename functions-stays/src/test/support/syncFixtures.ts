/**
 * Set-up for the channel sync, worker, export-link and export-feed tests: a
 * listing, a connected channel with its secret URL, an in-memory "feed
 * server" standing in for safeFetchText, and a builder for Airbnb-shaped
 * iCal text (synthetic: the codes and phone numbers are fake).
 */
import { SafeFetchError, SafeFetchErrorCode, SafeFetchOptions, SafeFetchResult } from '@sfc/functions-shared/net/safeFetch';

import type { SyncDeps } from '../../sync/common';
import type { StaysSyncCallableDeps } from '../../sync/common';
import { FakeFirestore } from './fakeFirestore';
import { FAC, NOW, fakeDeps, seedControls, seedFacility, seedGate } from './staysFixtures';
import { resetStaysGateCacheForTests } from '../../common/serverConfig';

export const LISTING = 'lst_airbnb1';
export const CHANNEL = 'ch_airbnb1';
export const FEED_URL = 'https://www.airbnb.com/calendar/ical/111222333.ics?s=0123456789abcdef';
export const MIN = 60_000;

export const P = {
  stays: `facilities/${FAC}/stays`,
  locks: `facilities/${FAC}/stayNightLocks`,
  blocks: `facilities/${FAC}/stayChannelBlocks`,
  channels: `facilities/${FAC}/stayChannels`,
  notifications: `facilities/${FAC}/Notifications`,
  syncLog: `facilities/${FAC}/staySyncLog`,
  private: `facilities/${FAC}/stayPrivate`,
  access: `facilities/${FAC}/stayAccess`,
  links: `facilities/${FAC}/stayExportLinks`,
  listings: `facilities/${FAC}/stayListings`,
  income: `facilities/${FAC}/stayIncome`,
};

export interface FeedEvent {
  /** An Airbnb confirmation code: a reservation with a reservation link. */
  code?: string;
  uid?: string;
  checkIn: string;
  checkOut: string;
  summary?: string;
  phone?: string;
}

const ymd = (d: string) => d.replace(/-/g, '');

/** An Airbnb-style export. */
export function airbnbIcs(events: FeedEvent[]): string {
  const lines = ['BEGIN:VCALENDAR', 'PRODID:-//Airbnb Inc//Hosting Calendar 1.0//EN', 'CALSCALE:GREGORIAN', 'VERSION:2.0'];
  for (const e of events) {
    lines.push('BEGIN:VEVENT', `DTEND;VALUE=DATE:${ymd(e.checkOut)}`, `DTSTART;VALUE=DATE:${ymd(e.checkIn)}`);
    lines.push(`UID:${e.uid ?? (e.code ? `uid-${e.code.toLowerCase()}@airbnb.com` : `blk-${e.checkIn}-${e.checkOut}@airbnb.com`)}`);
    if (e.code) {
      lines.push(
        `DESCRIPTION:Reservation URL: https://www.airbnb.com/hosting/reservations/details/${e.code}\\nPhone Number (Last 4 Digits): ${e.phone ?? '0100'}`,
      );
    }
    lines.push(`SUMMARY:${e.summary ?? (e.code ? 'Reserved' : 'Airbnb (Not available)')}`, 'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines.join('\r\n') + '\r\n';
}

/** Stands in for safeFetchText: serves the current text, honours ETags, or fails on demand. */
export class FeedServer {
  body = airbnbIcs([]);
  private version = 1;
  error: SafeFetchError | null = null;
  calls: { url: string; opts: SafeFetchOptions }[] = [];
  /** Awaited before answering; lets a test hold a sync mid-fetch. */
  gate: Promise<void> | null = null;

  get etag(): string {
    return `"v${this.version}"`;
  }

  set(events: FeedEvent[]): void {
    this.body = airbnbIcs(events);
    this.version++;
    this.error = null;
  }

  setText(text: string): void {
    this.body = text;
    this.version++;
    this.error = null;
  }

  fail(code: SafeFetchErrorCode, httpStatus: number | null = null): void {
    this.error = new SafeFetchError(code, 'The calendar site returned an error.', httpStatus, 'www.airbnb.com');
  }

  fetchFeed = async (url: string, opts: SafeFetchOptions): Promise<SafeFetchResult> => {
    this.calls.push({ url, opts });
    if (this.gate) await this.gate;
    if (this.error) throw this.error;
    if (opts.etag && opts.etag === this.etag) return { status: 304, etag: this.etag, finalHost: 'www.airbnb.com' };
    return { status: 200, body: this.body, etag: this.etag, finalHost: 'www.airbnb.com' };
  };
}

export function seedListing(fake: FakeFirestore, id = LISTING, patch: Record<string, unknown> = {}): void {
  fake.seed(`${P.listings}/${id}`, {
    facilityId: FAC,
    name: 'Airbnb 1',
    shortCode: 'A1',
    kind: 'vacation_rental',
    group: 'Airbnbs',
    active: true,
    archived: false,
    times: { checkIn: '16:00', checkOut: '10:00' },
    accessCodeMode: 'phone_last4',
    ...patch,
  });
}

export function channelSyncDefaults(): Record<string, unknown> {
  return {
    lastAttemptAt: null,
    lastSuccessAt: null,
    lastChangedAt: null,
    lastStatus: null,
    lastHttpStatus: null,
    lastErrorCode: null,
    consecutiveFailures: 0,
    etag: null,
    lastModified: null,
    contentSha256: null,
    eventCount: 0,
    futureReservationCount: 0,
    blockCount: 0,
    firstSyncCompletedAt: null,
    suspiciousSince: null,
    lease: null,
  };
}

export function seedChannel(fake: FakeFirestore, id = CHANNEL, patch: Record<string, unknown> = {}, url = FEED_URL): void {
  fake.seed(`${P.channels}/${id}`, {
    facilityId: FAC,
    listingId: LISTING,
    provider: 'airbnb',
    label: 'Airbnb 1 calendar',
    active: true,
    importBlocks: true,
    urlHost: 'www.airbnb.com',
    urlFingerprint: 'abc123abc123',
    sync: channelSyncDefaults(),
    createdAt: null,
    createdBy: 'uid-owner',
    updatedAt: null,
    ...patch,
  });
  fake.seed(`${P.channels}/${id}/secret/current`, { url, updatedAt: null });
}

export interface SyncWorld {
  fake: FakeFirestore;
  feed: FeedServer;
  now: { ms: number };
  deps: SyncDeps;
  callableDeps: StaysSyncCallableDeps;
  handle: ReturnType<typeof fakeDeps>;
}

/** A facility with Stays on, one Airbnb listing and (unless told otherwise) its channel. */
export function syncWorld(opts: { channel?: boolean; controls?: Record<string, unknown>; gate?: Record<string, unknown> } = {}): SyncWorld {
  resetStaysGateCacheForTests();
  const fake = new FakeFirestore();
  const now = { ms: NOW };
  fake.clock = () => now.ms;
  seedFacility(fake);
  seedGate(fake, opts.gate ?? {});
  seedControls(fake, { icalSyncEnabled: true, ...(opts.controls ?? {}) });
  seedListing(fake);
  if (opts.channel !== false) seedChannel(fake);
  const feed = new FeedServer();
  const handle = fakeDeps(fake, NOW);
  const deps: SyncDeps = { db: () => fake.firestore(), now: () => now.ms, fetchFeed: feed.fetchFeed };
  const callableDeps: StaysSyncCallableDeps = {
    ...handle.deps,
    now: () => now.ms,
    fetchFeed: feed.fetchFeed,
  };
  return { fake, feed, now, deps, callableDeps, handle };
}

/** The UTC sync slot for a time, as the scheduler names it. */
export function slotOf(ms: number): string {
  return new Date(Math.floor(ms / (30 * MIN)) * 30 * MIN).toISOString().slice(0, 16);
}

export function notificationTypes(fake: FakeFirestore): string[] {
  return fake.list(P.notifications).map((n) => n.data.type as string);
}

export function nightsOf(fake: FakeFirestore, month: string, listingId = LISTING): Record<string, { s: string; h: boolean; e?: boolean }> {
  return (fake.read(`${P.locks}/${listingId}_${month}`)?.nights ?? {}) as Record<string, { s: string; h: boolean; e?: boolean }>;
}

export { FAC, NOW, seedGate, seedControls };
