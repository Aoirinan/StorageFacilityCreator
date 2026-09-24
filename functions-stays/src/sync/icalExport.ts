import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';
import type { Firestore } from 'firebase-admin/firestore';

import {
  EXPORT_SCOPES,
  EXPORT_TARGET_PROVIDERS,
  ExportScope,
  ExportTargetProvider,
  STAYS_LIMITS,
  STAY_TOP_LEVEL_COLLECTIONS,
  StayDoc,
} from '@sfc/functions-shared/stays/contracts';
import { addDays, facilityToday } from '@sfc/functions-shared/stays/dates';
import { exportTokenHash, sha256Hex } from '@sfc/functions-shared/stays/ids';
import { buildIcs, staysForExport } from '@sfc/functions-shared/stays/icsWriter';

import { confirmedTimeZone, loadControls } from '../common/controls';
import { STAYS_RUNTIME } from '../common/guards';
import { evaluateStaysGate, loadStaysGate } from '../common/serverConfig';
import { exportLinksCol, listingsCol, staysCol, tsMillis } from './common';

/**
 * The iCal export feed (spec §6.9): GET /api/ical/{48-hex token}.ics, which
 * the prod Hosting target rewrites to this function.
 *
 *  - 404 for anything that is not a known, active token (generic body);
 *  - 429 past 30 fetches a minute per token or 300 per client IP, counted
 *    only for known tokens (the lookup comes first);
 *  - 503 with Retry-After: 900 when Stays is paused or not allowed here,
 *    the module or export is off, the link is not active, or any read
 *    fails. Never an empty 200: a channel that got an empty calendar would
 *    free every night we had blocked, while after a 503 it keeps its last
 *    good copy.
 *
 * The content is built from stays only (never the imported channel blocks,
 * so nothing a channel told us goes back out), leaves out the target
 * channel's own bookings, and carries no guest data (icsWriter). Responses
 * are `no-store`, so a revoked link stops working at once and fetch
 * telemetry is not hidden behind the CDN. There is no App Check (channels
 * cannot send it); the unguessable token and the rate limits stand in.
 */

const PATH_RE = /^\/api\/ical\/([a-f0-9]{48})\.ics$/;
const COMMON_HEADERS: Record<string, string> = { 'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex' };
const RATE_WINDOW_MS = 60_000;
const TELEMETRY_EVERY_MS = 10 * 60_000;

export interface IcalExportDeps {
  db: () => Firestore;
  now: () => number;
}

function defaultDeps(): IcalExportDeps {
  return { db: () => admin.firestore(), now: () => Date.now() };
}

/** The Express request/response surface the handler uses (tests pass plain objects). */
export interface ExportRequest {
  method?: string;
  path?: string;
  url?: string;
  ip?: string;
  headers: Record<string, string | string[] | undefined>;
}

export interface ExportResponse {
  status(code: number): ExportResponse;
  set(headers: Record<string, string>): ExportResponse;
  send(body: string): unknown;
  end(): unknown;
}

function header(req: ExportRequest, name: string): string {
  const v = req.headers[name.toLowerCase()];
  return (Array.isArray(v) ? v[0] : v) ?? '';
}

/**
 * The caller's address for the per-IP limit, from headers the hosting
 * platform sets rather than the X-Forwarded-For chain Express reads for
 * req.ip. Behind the Hosting rewrite, the CDN puts the end user's address in
 * Fastly-Client-IP; the leftmost X-Forwarded-For entry is the caller's own
 * claim or a Google front-end hop, and X-AppEngine-User-IP is the peer that
 * reached the function, which through Hosting is a hop every caller shares.
 * A direct call to the function URL has no CDN, so that peer is the caller
 * and X-AppEngine-User-IP is used. A direct caller can still send its own
 * Fastly-Client-IP: that only picks its bucket, and since only known tokens
 * are counted, the per-token limit is the one that cannot be dodged.
 */
export function clientIp(req: ExportRequest): string {
  for (const name of ['fastly-client-ip', 'x-appengine-user-ip']) {
    const value = header(req, name).split(',')[0].trim();
    if (value) return value;
  }
  return req.ip || 'unknown';
}

/** Which channel is fetching, from its User-Agent. */
export function fetcherFamily(userAgent: string): ExportTargetProvider {
  const ua = userAgent.toLowerCase();
  if (ua.includes('airbnb')) return 'airbnb';
  if (ua.includes('vrbo') || ua.includes('homeaway') || ua.includes('expedia')) return 'vrbo';
  if (ua.includes('booking')) return 'booking';
  if (ua.includes('google')) return 'google';
  return 'other';
}

/** A fixed one-minute window in the root rateLimits collection; false once over the limit. */
async function allowFetch(db: Firestore, docId: string, limit: number, nowMs: number): Promise<boolean> {
  const ref = db.collection('rateLimits').doc(docId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const windowStart = snap.exists ? Number(snap.get('windowStart')) || 0 : 0;
    if (!snap.exists || nowMs - windowStart >= RATE_WINDOW_MS || nowMs < windowStart) {
      tx.set(ref, { count: 1, windowStart: nowMs, kind: 'stays_ical_export' });
      return true;
    }
    const count = Number(snap.get('count')) || 0;
    if (count >= limit) return false;
    tx.update(ref, { count: count + 1 });
    return true;
  });
}

export function createIcalExportHandler(deps: IcalExportDeps = defaultDeps()) {
  return async (req: ExportRequest, res: ExportResponse): Promise<void> => {
    const method = (req.method ?? 'GET').toUpperCase();
    const head = method === 'HEAD';
    const reply = (status: number, body: string, extra: Record<string, string> = {}) => {
      res.status(status).set({ ...COMMON_HEADERS, ...extra });
      if (head) res.end();
      else res.send(body);
    };
    const notFound = () => reply(404, 'Not found\n', { 'Content-Type': 'text/plain; charset=utf-8' });
    const unavailable = () =>
      reply(503, 'Calendar temporarily unavailable\n', { 'Content-Type': 'text/plain; charset=utf-8', 'Retry-After': '900' });

    if (method !== 'GET' && method !== 'HEAD') {
      reply(405, 'Method not allowed\n', { Allow: 'GET, HEAD', 'Content-Type': 'text/plain; charset=utf-8' });
      return;
    }
    const path = req.path ?? (req.url ?? '').split('?')[0];
    const match = PATH_RE.exec(path);
    if (!match) {
      notFound();
      return;
    }
    const tokenHash = exportTokenHash(match[1]);
    const db = deps.db();
    const nowMs = deps.now();
    let linkForStats: { facilityId: string; linkId: string; statsWrittenAtMs: number | null } | null = null;

    /** Fetch telemetry, at most every 10 minutes per link; never allowed to change the answer. */
    const recordFetch = async (status: number) => {
      if (!linkForStats) return;
      if (linkForStats.statsWrittenAtMs !== null && nowMs - linkForStats.statsWrittenAtMs < TELEMETRY_EVERY_MS) return;
      try {
        const now = Timestamp.fromMillis(nowMs);
        await exportLinksCol(db, linkForStats.facilityId)
          .doc(linkForStats.linkId)
          .update({
            'stats.lastFetchedAt': now,
            'stats.lastFetcher': fetcherFamily(header(req, 'user-agent')),
            'stats.lastStatus': status,
            'stats.statsWrittenAt': now,
          });
      } catch (error) {
        functions.logger.warn('stays: export telemetry write failed', {
          linkId: linkForStats.linkId,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    };

    try {
      const tokenSnap = await db.collection(STAY_TOP_LEVEL_COLLECTIONS.exportTokens).doc(tokenHash).get();
      if (!tokenSnap.exists || tokenSnap.get('active') !== true) {
        notFound();
        return;
      }
      // Only known tokens are counted: a guessed token costs one read and writes
      // nothing, so spraying random ones cannot fill rateLimits.
      if (!(await allowFetch(db, `staysIcalTok_${tokenHash.slice(0, 24)}`, STAYS_LIMITS.exportFetchesPerMinutePerToken, nowMs))) {
        reply(429, 'Too many requests\n', { 'Content-Type': 'text/plain; charset=utf-8', 'Retry-After': '60' });
        return;
      }
      const ipKey = sha256Hex(clientIp(req)).slice(0, 24);
      if (!(await allowFetch(db, `staysIcalIp_${ipKey}`, STAYS_LIMITS.exportFetchesPerMinutePerIp, nowMs))) {
        reply(429, 'Too many requests\n', { 'Content-Type': 'text/plain; charset=utf-8', 'Retry-After': '60' });
        return;
      }
      const facilityId = tokenSnap.get('facilityId');
      const listingId = tokenSnap.get('listingId');
      const linkId = tokenSnap.get('linkId');
      if (typeof facilityId !== 'string' || typeof listingId !== 'string' || typeof linkId !== 'string') {
        unavailable();
        return;
      }

      // The gate fails closed: a missing or unreadable config is "not allowed".
      const gate = await loadStaysGate(db, nowMs);
      if (!evaluateStaysGate(gate, facilityId).allowed) {
        unavailable();
        return;
      }
      const controls = await loadControls(db, facilityId);
      if (controls.moduleEnabled !== true || controls.icalExportEnabled !== true) {
        unavailable();
        return;
      }
      const tz = confirmedTimeZone(controls);

      const link = await exportLinksCol(db, facilityId).doc(linkId).get();
      if (link.exists) {
        linkForStats = { facilityId, linkId, statsWrittenAtMs: tsMillis(link.get('stats.statsWrittenAt')) };
      }
      const scope = link.get('scope') as ExportScope;
      const targetProvider = link.get('targetProvider') as ExportTargetProvider;
      if (
        !link.exists ||
        link.get('active') !== true ||
        link.get('listingId') !== listingId ||
        !(EXPORT_SCOPES as readonly string[]).includes(scope) ||
        !(EXPORT_TARGET_PROVIDERS as readonly string[]).includes(targetProvider)
      ) {
        await recordFetch(503);
        unavailable();
        return;
      }

      const listing = await listingsCol(db, facilityId).doc(listingId).get();
      const today = facilityToday(tz, nowMs);
      const snap = await staysCol(db, facilityId).where('listingId', '==', listingId).where('checkOut', '>=', today).get();
      const stays = snap.docs.map((d) => ({ ...(d.data() as StayDoc), stayId: d.id }));
      const events = staysForExport(stays, {
        scope,
        targetProvider,
        todayYmd: today,
        lastCheckInYmd: addDays(today, STAYS_LIMITS.lockHorizonFutureDays),
      });
      const listingName = typeof listing.get('name') === 'string' ? (listing.get('name') as string) : '';
      const body = buildIcs({
        calName: listingName ? `SFC ${listingName}` : 'SFC',
        events: events.map((s) => ({ stayId: s.stayId, checkIn: s.checkIn, checkOut: s.checkOut, version: s.version })),
        now: nowMs,
      });
      await recordFetch(200);
      reply(200, body, { 'Content-Type': 'text/calendar; charset=utf-8' });
    } catch (error) {
      // Never the token or its hash in a log line.
      functions.logger.error('stays: iCal export failed; answering 503', {
        linkId: linkForStats?.linkId ?? null,
        error: error instanceof Error ? error.message : String(error),
      });
      await recordFetch(503);
      unavailable();
    }
  };
}

const handler = createIcalExportHandler();

export const staysIcalExport = functions
  .runWith(STAYS_RUNTIME.export)
  .https.onRequest((req, res) => handler(req as unknown as ExportRequest, res as unknown as ExportResponse));
