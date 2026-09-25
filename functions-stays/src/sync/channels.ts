import * as functions from 'firebase-functions/v1';
import { Timestamp } from 'firebase-admin/firestore';

import {
  SafeFetchError,
  SafeFetchResult,
  allowedIcalHosts,
  urlFingerprint,
  validateFeedUrl,
} from '@sfc/functions-shared/net/safeFetch';
import { normalizeBlockRanges } from '@sfc/functions-shared/stays/blocks';
import {
  CHANNEL_PROVIDERS,
  ChannelProvider,
  STAYS_CURRENT_DOC_ID,
  STAYS_LIMITS,
  STAYS_SECRET_SUBCOLLECTION,
  StayDoc,
  StaysChannelSyncResult,
  StaysRemoveChannelResponse,
  StaysSyncNowResponse,
  StaysUpsertChannelResponse,
  StaysWarning,
  Ymd,
} from '@sfc/functions-shared/stays/contracts';
import { facilityToday } from '@sfc/functions-shared/stays/dates';
import { IcsParseError, ParseIcsResult, parseIcs } from '@sfc/functions-shared/stays/ical';
import { randomId } from '@sfc/functions-shared/stays/ids';
import { lockHorizon } from '@sfc/functions-shared/stays/nightLocks';

import { confirmedTimeZone } from '../common/controls';
import { isStaysError, staysError } from '../common/errors';
import { StaysCallContext, auditStays, optionalDocId, requireDocId, runStaysGuards, staysCallable } from '../common/guards';
import { applyStayMutations } from '../common/stayWriter';
import type { StayMutation } from '../common/stayWriter';
import {
  SYNC_ACTOR,
  StaysSyncCallableDeps,
  channelBlocksCol,
  channelsCol,
  defaultSyncCallableDeps,
  listingsCol,
  providerLabel,
  staysCol,
} from './common';
import { splitFeed, syncChannel } from './syncChannel';

/**
 * Channel callables (spec §6.5): connect a feed (with a preview first),
 * remove one, and Sync now. Owner and manager only: the feed URL is a bearer
 * secret, so it is written to secret/current, which no client can read, and
 * never returned, logged or audited.
 */

const OM = ['owner', 'manager'] as const;
const LABEL_MAX = 60;
/** Sync now: the whole call stays inside the callable's 60 s. */
const SYNC_NOW_BUDGET_MS = 45_000;

function asBool(value: unknown, field: string, fallback?: boolean): boolean {
  if (value === undefined && fallback !== undefined) return fallback;
  if (typeof value !== 'boolean') throw staysError('invalid-argument', 'invalid_argument', `${field} must be true or false.`, { field });
  return value;
}

function asProvider(value: unknown): ChannelProvider {
  if (!(CHANNEL_PROVIDERS as readonly unknown[]).includes(value)) {
    throw staysError('invalid-argument', 'invalid_argument', 'Pick which site the calendar comes from.', { field: 'provider' });
  }
  return value as ChannelProvider;
}

function cleanLabel(value: unknown, provider: ChannelProvider): string {
  if (value !== undefined && value !== null && typeof value !== 'string') {
    throw staysError('invalid-argument', 'invalid_argument', 'The name must be text.', { field: 'label' });
  }
  const label = (typeof value === 'string' ? value : '').replace(/\s+/g, ' ').trim().slice(0, LABEL_MAX);
  return label || `${providerLabel(provider)} calendar`;
}

/** A fetch failure as the error the app shows under the link box. */
function fetchErrorToStays(error: SafeFetchError): functions.https.HttpsError {
  switch (error.code) {
    case 'invalid_url':
    case 'blocked_host':
    case 'blocked_ip':
      return staysError('invalid-argument', 'feed_host_not_allowed', error.message, { code: error.code });
    case 'too_large':
      return staysError('failed-precondition', 'feed_too_large', 'That calendar is too large to import.', { code: error.code });
    case 'invalid_feed':
      return staysError('failed-precondition', 'feed_invalid', 'That link did not return a calendar. Copy the Export calendar link again.', {
        code: error.code,
      });
    case 'gone':
      return staysError('failed-precondition', 'feed_fetch_failed', 'The calendar site says that link does not work. Copy a fresh Export calendar link.', {
        code: error.code,
        httpStatus: error.httpStatus,
      });
    default:
      return staysError('unavailable', 'feed_fetch_failed', 'The calendar could not be read right now. Try again in a minute.', {
        code: error.code,
        httpStatus: error.httpStatus,
      });
  }
}

async function requireListing(ctx: StaysCallContext, listingId: string): Promise<Record<string, unknown>> {
  const snap = await listingsCol(ctx.db, ctx.facilityId).doc(listingId).get();
  if (!snap.exists) throw staysError('not-found', 'not_found', 'That listing was not found.', { listingId });
  const data = snap.data() as Record<string, unknown>;
  if (data.archived === true) throw staysError('failed-precondition', 'listing_inactive', 'That listing is archived.', { listingId });
  return data;
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

export interface FeedPreview {
  reservations: number;
  blocks: number;
  firstDate: Ymd | null;
  lastDate: Ymd | null;
  nextArrival: Ymd | null;
  warnings: StaysWarning[];
}

/** "Found 6 reservations, 3 blocked ranges, next arrival Oct 3": what is ahead in the feed. */
export function previewFeed(parsed: ParseIcsResult, provider: ChannelProvider, listingId: string, todayYmd: Ymd): FeedPreview {
  const { clampTo } = lockHorizon(todayYmd);
  const feed = splitFeed(parsed, provider, listingId);
  const upcoming = feed.reservations.filter((r) => r.checkOut > todayYmd);
  const blocks = normalizeBlockRanges(feed.blocks, { clampFrom: todayYmd, clampTo }).ranges;
  const starts = [...upcoming.map((r) => r.checkIn), ...blocks.map((b) => b.checkIn)].sort();
  const ends = [...upcoming.map((r) => r.checkOut), ...blocks.map((b) => b.checkOut)].sort();
  const arrivals = upcoming.map((r) => r.checkIn).filter((d) => d >= todayYmd).sort();
  const warnings: StaysWarning[] = [];
  if (parsed.eventCount === 0) {
    warnings.push({
      code: 'feed_empty',
      message: 'This calendar has no events. If the listing has bookings, check that you copied its Export calendar link.',
    });
  }
  const skipped = parsed.skippedInvalid + feed.tooLong;
  if (skipped > 0) {
    warnings.push({ code: 'events_skipped', message: `${skipped} event(s) could not be read and will be left out.`, details: { count: skipped } });
  }
  if (parsed.skippedRecurring > 0) {
    warnings.push({
      code: 'recurring_events_skipped',
      message: `${parsed.skippedRecurring} repeating event(s) will be left out.`,
      details: { count: parsed.skippedRecurring },
    });
  }
  if (parsed.events.some((e) => e.checkOut > clampTo)) {
    warnings.push({
      code: 'far_future_clamped',
      message: 'Some dates are more than 18 months away. SFC holds nights up to 18 months ahead and picks up the rest as they come closer.',
    });
  }
  return {
    reservations: upcoming.length,
    blocks: blocks.length,
    firstDate: starts[0] ?? null,
    lastDate: ends[ends.length - 1] ?? null,
    nextArrival: arrivals[0] ?? null,
    warnings,
  };
}

// ---------------------------------------------------------------------------
// staysUpsertChannel
// ---------------------------------------------------------------------------

function newChannelSync() {
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

export async function upsertChannelHandler(
  raw: unknown,
  context: functions.https.CallableContext,
  deps: StaysSyncCallableDeps = defaultSyncCallableDeps(),
): Promise<StaysUpsertChannelResponse> {
  const dryRun = typeof raw === 'object' && raw !== null && (raw as Record<string, unknown>).dryRun === true;
  const ctx = await runStaysGuards(
    raw,
    context,
    {
      callable: 'staysUpsertChannel',
      roles: OM,
      validate: (d) => {
        requireDocId(d, 'listingId');
        asProvider(d.provider);
        asBool(d.dryRun, 'dryRun');
        asBool(d.importBlocks, 'importBlocks', true);
        optionalDocId(d, 'channelId');
        if (typeof d.url !== 'string' || d.url.trim().length === 0) {
          throw staysError('invalid-argument', 'invalid_argument', 'Paste the calendar link.', { field: 'url' });
        }
      },
      // A preview fetches someone else's server: 10 an hour per person.
      rateLimit: dryRun
        ? { key: 'stays_channel_preview', windowSeconds: 3600, perUser: 10 }
        : { key: 'stays_channel_save', windowSeconds: 3600, perFacility: 30, perUser: 20 },
    },
    deps,
  );
  const d = ctx.data;
  const listingId = d.listingId as string;
  const provider = asProvider(d.provider);
  const importBlocks = asBool(d.importBlocks, 'importBlocks', true);
  const label = cleanLabel(d.label, provider);
  const channelIdIn = optionalDocId(d, 'channelId');
  const tz = confirmedTimeZone(ctx.controls);
  await requireListing(ctx, listingId);

  const allowedHosts = allowedIcalHosts(ctx.gate.extraIcalHosts);
  let validated: ReturnType<typeof validateFeedUrl>;
  try {
    validated = validateFeedUrl(d.url, allowedHosts);
  } catch (error) {
    if (error instanceof SafeFetchError) throw fetchErrorToStays(error);
    throw error;
  }

  if (dryRun) {
    let fetched: SafeFetchResult;
    try {
      fetched = await deps.fetchFeed(validated.url, { allowedHosts });
    } catch (error) {
      if (error instanceof SafeFetchError) throw fetchErrorToStays(error);
      throw error;
    }
    if (fetched.status !== 200 || typeof fetched.body !== 'string') {
      throw staysError('unavailable', 'feed_fetch_failed', 'The calendar could not be read right now. Try again in a minute.');
    }
    let parsed: ParseIcsResult;
    try {
      parsed = parseIcs(fetched.body, tz);
    } catch (error) {
      if (error instanceof IcsParseError) {
        throw error.code === 'too_large'
          ? staysError('failed-precondition', 'feed_too_large', 'That calendar is too large to import.')
          : staysError('failed-precondition', 'feed_invalid', 'That link did not return a calendar. Copy the Export calendar link again.');
      }
      throw error;
    }
    const preview = previewFeed(parsed, provider, listingId, facilityToday(tz, ctx.nowMs));
    return { dryRun: true, status: 'ok', ...preview };
  }

  const fingerprint = urlFingerprint(validated.url);
  const now = Timestamp.fromMillis(ctx.nowMs);
  const col = channelsCol(ctx.db, ctx.facilityId);
  const channelId = channelIdIn ?? randomId('ch');
  const ref = col.doc(channelId);
  const secretRef = ref.collection(STAYS_SECRET_SUBCOLLECTION).doc(STAYS_CURRENT_DOC_ID);
  const created = await ctx.db.runTransaction(async (tx) => {
    const active = await tx.get(col.where('active', '==', true));
    const existing = channelIdIn ? await tx.get(ref) : null;
    if (existing && (!existing.exists || existing.get('active') !== true)) {
      throw staysError('not-found', 'not_found', 'That calendar connection was not found.', { channelId });
    }
    if (existing && existing.get('listingId') !== listingId) {
      throw staysError('invalid-argument', 'invalid_argument', 'A calendar connection cannot move to another listing. Remove it and add it there.');
    }
    const others = active.docs.filter((doc) => doc.id !== channelId);
    // One calendar feeds one listing, across the whole facility: the same link on two
    // listings would put its bookings on both, and an Airbnb booking (one id per
    // facility) would hop between them whenever either feed missed a fetch.
    const duplicate = others.find((doc) => doc.get('urlFingerprint') === fingerprint);
    if (duplicate) {
      const here = duplicate.get('listingId') === listingId;
      throw staysError(
        'already-exists',
        'invalid_argument',
        here
          ? 'That calendar link is already connected to this listing.'
          : 'That calendar link is already connected to another listing. Each calendar belongs to one listing: copy the export link of the right one.',
        { channelId: duplicate.id, listingId: duplicate.get('listingId') },
      );
    }
    if (!existing) {
      if (others.filter((doc) => doc.get('listingId') === listingId).length >= STAYS_LIMITS.channelsPerListing) {
        throw staysError('failed-precondition', 'limit_reached', `A listing can have at most ${STAYS_LIMITS.channelsPerListing} calendar connections.`);
      }
      if (others.length >= STAYS_LIMITS.channelsPerFacility) {
        throw staysError('failed-precondition', 'limit_reached', `A facility can have at most ${STAYS_LIMITS.channelsPerFacility} calendar connections.`);
      }
      tx.create(ref, {
        facilityId: ctx.facilityId,
        listingId,
        provider,
        label,
        active: true,
        importBlocks,
        urlHost: validated.host,
        urlFingerprint: fingerprint,
        sync: newChannelSync(),
        createdAt: now,
        createdBy: ctx.uid,
        updatedAt: now,
      });
    } else {
      const patch: Record<string, unknown> = { provider, label, importBlocks, urlHost: validated.host, urlFingerprint: fingerprint, updatedAt: now };
      // A new link or a change to block import: the next sync diffs in full.
      if (existing.get('urlFingerprint') !== fingerprint || existing.get('importBlocks') !== importBlocks || existing.get('provider') !== provider) {
        // A sync in flight read the old settings; its result would land on top of the reset
        // (a rename is harmless and goes through).
        const lease = existing.get('sync.lease') as { expiresAt?: Timestamp } | null | undefined;
        const expires = lease?.expiresAt && typeof lease.expiresAt.toMillis === 'function' ? lease.expiresAt.toMillis() : null;
        if (expires !== null && expires > ctx.nowMs) {
          throw staysError('aborted', 'contention', 'This calendar is syncing right now. Try again in a minute.');
        }
        patch['sync.etag'] = null;
        patch['sync.lastModified'] = null;
        patch['sync.contentSha256'] = null;
        patch['sync.consecutiveFailures'] = 0;
      }
      tx.update(ref, patch);
    }
    tx.set(secretRef, { url: validated.url, updatedAt: now });
    return !existing;
  });

  let firstSync: StaysChannelSyncResult;
  try {
    firstSync = await syncChannel(ctx.facilityId, channelId, 'save', {
      deps: { db: deps.db, now: deps.now, fetchFeed: deps.fetchFeed },
      controls: ctx.controls,
      gate: ctx.gate,
    });
  } catch (error) {
    functions.logger.error('stays: first sync after saving a channel failed', {
      facilityId: ctx.facilityId,
      channelId,
      error: error instanceof Error ? error.message : String(error),
    });
    firstSync = {
      channelId,
      status: 'http_error',
      httpStatus: null,
      created: 0,
      dateChanged: 0,
      restored: 0,
      missesAdvanced: 0,
      removed: 0,
      needsReview: 0,
      conflicts: 0,
      blocks: 0,
      durationMs: 0,
    };
  }

  await auditStays(ctx, {
    eventType: 'stays.channel.saved',
    targetType: 'stayChannel',
    targetId: channelId,
    metadata: { listingId, provider, urlHost: validated.host, urlFingerprint: fingerprint, created, importBlocks, firstSyncStatus: firstSync.status },
  });
  return { dryRun: false, channelId, urlHost: validated.host, urlFingerprint: fingerprint, firstSync };
}

// ---------------------------------------------------------------------------
// staysRemoveChannel
// ---------------------------------------------------------------------------

export async function removeChannelHandler(
  raw: unknown,
  context: functions.https.CallableContext,
  deps: StaysSyncCallableDeps = defaultSyncCallableDeps(),
): Promise<StaysRemoveChannelResponse> {
  const ctx = await runStaysGuards(
    raw,
    context,
    {
      callable: 'staysRemoveChannel',
      roles: OM,
      validate: (d) => void requireDocId(d, 'channelId'),
      rateLimit: { key: 'stays_channel_remove', windowSeconds: 60, perFacility: 20 },
    },
    deps,
  );
  const channelId = ctx.data.channelId as string;
  const ref = channelsCol(ctx.db, ctx.facilityId).doc(channelId);
  const now = Timestamp.fromMillis(ctx.nowMs);

  const listingId = await ctx.db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw staysError('not-found', 'not_found', 'That calendar connection was not found.', { channelId });
    const lease = snap.get('sync.lease') as { expiresAt?: Timestamp } | null | undefined;
    const expires = lease?.expiresAt && typeof lease.expiresAt.toMillis === 'function' ? lease.expiresAt.toMillis() : null;
    // A sync in flight would put its blocks back after we cleared them.
    if (snap.get('active') === true && expires !== null && expires > ctx.nowMs) {
      throw staysError('aborted', 'contention', 'This calendar is syncing right now. Try again in a minute.');
    }
    tx.update(ref, { active: false, 'sync.lease': null, updatedAt: now });
    tx.delete(ref.collection(STAYS_SECRET_SUBCOLLECTION).doc(STAYS_CURRENT_DOC_ID));
    return snap.get('listingId') as string;
  });

  // Its soft blocks go (the locks rebuild without them); its bookings stay, marked detached.
  const stays = await staysCol(ctx.db, ctx.facilityId).where('sync.channelId', '==', channelId).get();
  const ids = stays.docs.filter((doc) => doc.get('sync.detached') !== true).map((doc) => doc.id);
  const blocksDoc = await channelBlocksCol(ctx.db, ctx.facilityId).doc(channelId).get();
  const hasBlocks = blocksDoc.exists && Array.isArray(blocksDoc.get('ranges')) && (blocksDoc.get('ranges') as unknown[]).length > 0;
  let detached = 0;
  const chunks: string[][] = [];
  for (let i = 0; i < ids.length; i += STAYS_LIMITS.stayMutationsPerTransaction) chunks.push(ids.slice(i, i + STAYS_LIMITS.stayMutationsPerTransaction));
  if (chunks.length === 0 && hasBlocks) chunks.push([]);
  const stayCol = staysCol(ctx.db, ctx.facilityId);
  for (let c = 0; c < chunks.length; c++) {
    for (let attempt = 1; ; attempt++) {
      // Re-read each round, so an edit made meanwhile is kept (the version check covers the rest).
      const snaps = chunks[c].length ? await ctx.db.getAll(...chunks[c].map((id) => stayCol.doc(id))) : [];
      const mutations: StayMutation[] = [];
      for (const snap of snaps) {
        if (!snap.exists) continue;
        const doc = snap.data() as StayDoc;
        if (doc.sync?.channelId !== channelId || doc.sync.detached === true) continue;
        mutations.push({
          stayId: snap.id,
          next: {
            ...doc,
            sync: { ...doc.sync, detached: true },
            version: (Number.isInteger(doc.version) ? doc.version : 0) + 1,
            updatedAt: now,
            updatedBy: ctx.uid,
          },
          mode: 'feed',
          expectedVersion: Number.isInteger(doc.version) ? doc.version : 0,
        });
      }
      try {
        await applyStayMutations({
          db: ctx.db,
          facilityId: ctx.facilityId,
          controls: ctx.controls,
          mutations,
          channelBlockUpdates: c === 0 && (hasBlocks || blocksDoc.exists) ? [{ channelId, listingId, ranges: [] }] : [],
          actor: SYNC_ACTOR,
          nowMs: ctx.nowMs,
        });
        detached += mutations.length;
        break;
      } catch (error) {
        if (attempt < 3 && (isStaysError(error, 'version_mismatch') || isStaysError(error, 'contention'))) continue;
        throw error;
      }
    }
  }

  await auditStays(ctx, {
    eventType: 'stays.channel.removed',
    targetType: 'stayChannel',
    targetId: channelId,
    metadata: { listingId, detachedStays: detached },
  });
  return { channelId, detachedStays: detached };
}

// ---------------------------------------------------------------------------
// staysSyncNow
// ---------------------------------------------------------------------------

function skippedResult(channelId: string): StaysChannelSyncResult {
  return {
    channelId,
    status: 'not_modified',
    httpStatus: null,
    created: 0,
    dateChanged: 0,
    restored: 0,
    missesAdvanced: 0,
    removed: 0,
    needsReview: 0,
    conflicts: 0,
    blocks: 0,
    durationMs: 0,
    skipped: true,
  };
}

export async function syncNowHandler(
  raw: unknown,
  context: functions.https.CallableContext,
  deps: StaysSyncCallableDeps = defaultSyncCallableDeps(),
): Promise<StaysSyncNowResponse> {
  const ctx = await runStaysGuards(
    raw,
    context,
    {
      callable: 'staysSyncNow',
      roles: OM,
      validate: (d) => void optionalDocId(d, 'channelId'),
      rateLimit: { key: 'stays_sync_now', windowSeconds: 86_400, perFacility: 20 },
    },
    deps,
  );
  const only = optionalDocId(ctx.data, 'channelId');
  const col = channelsCol(ctx.db, ctx.facilityId);
  let channelIds: string[];
  if (only) {
    const snap = await col.doc(only).get();
    if (!snap.exists || snap.get('active') !== true) {
      throw staysError('not-found', 'not_found', 'That calendar connection was not found.', { channelId: only });
    }
    channelIds = [only];
  } else {
    const snap = await col.where('active', '==', true).get();
    channelIds = snap.docs.map((doc) => doc.id).sort();
  }

  const results: StaysChannelSyncResult[] = [];
  const started = deps.now();
  for (const channelId of channelIds) {
    // One manual sync a minute per feed.
    try {
      await deps.enforceRateLimit({
        facilityId: ctx.facilityId,
        key: `stays_sync_now_ch_${channelId}`,
        limit: 1,
        windowSeconds: 60,
        userId: ctx.uid,
      });
    } catch (error) {
      if (error instanceof functions.https.HttpsError && error.code === 'resource-exhausted') {
        if (only) throw staysError('resource-exhausted', 'rate_limited', 'That calendar was synced less than a minute ago.');
        results.push(skippedResult(channelId));
        continue;
      }
      throw error;
    }
    if (deps.now() - started > SYNC_NOW_BUDGET_MS) {
      results.push(skippedResult(channelId));
      continue;
    }
    results.push(
      await syncChannel(ctx.facilityId, channelId, 'manual', {
        deps: { db: deps.db, now: deps.now, fetchFeed: deps.fetchFeed },
        controls: ctx.controls,
        gate: ctx.gate,
      }),
    );
  }

  await auditStays(ctx, {
    eventType: 'stays.channel.synced_manually',
    targetType: 'stayChannel',
    targetId: only ?? 'all',
    metadata: { channels: results.map((r) => ({ channelId: r.channelId, status: r.status, skipped: r.skipped === true })) },
  });
  return { results };
}

export const staysUpsertChannel = staysCallable('staysUpsertChannel', (data, context) => upsertChannelHandler(data, context));
export const staysRemoveChannel = staysCallable('staysRemoveChannel', (data, context) => removeChannelHandler(data, context));
export const staysSyncNow = staysCallable('staysSyncNow', (data, context) => syncNowHandler(data, context));
