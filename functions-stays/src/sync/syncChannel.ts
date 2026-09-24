import { randomBytes } from 'crypto';
import * as functions from 'firebase-functions/v1';
import { DocumentReference, DocumentSnapshot, Firestore, Timestamp } from 'firebase-admin/firestore';

import { SafeFetchError, SafeFetchResult, allowedIcalHosts } from '@sfc/functions-shared/net/safeFetch';
import { markEchoes, normalizeBlockRanges, sameBlockRanges } from '@sfc/functions-shared/stays/blocks';
import {
  ChannelBlockRange,
  ChannelProvider,
  ChannelSyncStatus,
  CHANNEL_PROVIDERS,
  STAYS_CURRENT_DOC_ID,
  STAYS_LIMITS,
  STAYS_SECRET_SUBCOLLECTION,
  STAY_COLLECTIONS,
  StayControlsDoc,
  StayDoc,
  StayExternalRef,
  StaySyncState,
  StaysChannelSyncResult,
  SyncTrigger,
  Ymd,
} from '@sfc/functions-shared/stays/contracts';
import { diffDays, facilityToday } from '@sfc/functions-shared/stays/dates';
import { IcsParseError, ParseIcsResult, classifyEvent, extractAirbnbRefs, keptSummary, parseIcs } from '@sfc/functions-shared/stays/ical';
import { staysForExport } from '@sfc/functions-shared/stays/icsWriter';
import {
  notificationId,
  sha256Hex,
  stayIdForAirbnb,
  stayIdForFeed,
  syncLogIdManual,
  syncLogIdScheduled,
} from '@sfc/functions-shared/stays/ids';
import { StayLockOutcome, isActiveStatus, lockHorizon } from '@sfc/functions-shared/stays/nightLocks';
import {
  ExistingFeedStay,
  FeedMatch,
  FeedReservation,
  FeedSyncPlan,
  MissUpdate,
  UID_HISTORY_MAX,
  advanceMissesOnUnchanged,
  planFeedSync,
} from '@sfc/functions-shared/stays/stayDiff';

import { confirmedTimeZone, loadControls } from '../common/controls';
import { isStaysError } from '../common/errors';
import { StayNotificationInput, writeStayNotifications } from '../common/notify';
import { StaysGate, evaluateStaysGate, loadStaysGate } from '../common/serverConfig';
import { StatusChange, StayMutation, WriteOnlyTransaction, applyStayMutations } from '../common/stayWriter';
import {
  SYNC_ACTOR,
  SyncDeps,
  channelBlocksCol,
  channelCollectsPayment,
  channelsCol,
  channelsRoute,
  defaultSyncDeps,
  exportLinksCol,
  exportTargetForProvider,
  facilityCol,
  formatDay,
  formatRange,
  listingsCol,
  nightsLabel,
  providerLabel,
  sourceForProvider,
  stayRoute,
  staysCol,
  syncLogCol,
  syncStatusForFetchError,
  tsMillis,
} from './common';

/**
 * One channel's sync (spec §6.7 syncChannel): lease, fetch, diff, write.
 *
 *  1. Take the channel's lease ({runId, expiresAt: now+4 min}) in a
 *     transaction, or skip when another run holds it.
 *  2. Read the feed URL from the channel's secret doc.
 *  3. Fetch it through safeFetchText with the stored ETag / Last-Modified.
 *  4. 304, or the same body as last time: nothing to diff, but misses keep
 *     counting for stays already missing (advanceMissesOnUnchanged).
 *  5. Otherwise parse, plan (planFeedSync) and normalise the soft blocks,
 *     then apply everything through stayWriter.applyStayMutations in feed
 *     mode, in chronological chunks of at most 150 stays; the block ranges
 *     go in the first chunk.
 *  6. Write the channel's health and release the lease, log the run in
 *     staySyncLog, and write the in-app notifications.
 *
 * A failed fetch or parse never counts as a miss and changes no stay. Every
 * write is idempotent: running the same feed twice changes nothing the
 * second time, and a run that dies half way is finished by the next one.
 */

export const SYNC_LEASE_MS = 4 * 60_000;
/** A seen-again stay's lastSeenAt is refreshed at most this often when nothing else about it changes. */
export const LAST_SEEN_REFRESH_MS = 6 * 60 * 60_000;
/**
 * On an unchanged feed, lastSuccessAt is rewritten at most this often (unless
 * misses advanced). Well inside the app's 6-hour "not synced" warning, so a
 * healthy feed never shows as stale.
 */
export const UNCHANGED_SUCCESS_WRITE_MS = 60 * 60_000;
/** Consecutive failures before STAY_FEED_FAILING (a 'gone' link alerts at once). */
export const FAILURES_BEFORE_ALERT = 3;
export const SYNC_LOG_RETENTION_MS = 30 * 24 * 60 * 60_000;

export interface SyncChannelOptions {
  deps?: Partial<SyncDeps>;
  /** Scheduled runs: the slot ('YYYY-MM-DDTHH:mm', UTC). It names the log doc and is the miss clock. */
  slot?: string;
  controls?: StayControlsDoc;
  gate?: StaysGate;
  runId?: string;
}

/** The channel doc, read defensively. */
interface ChannelState {
  id: string;
  listingId: string;
  provider: ChannelProvider;
  label: string;
  active: boolean;
  importBlocks: boolean;
  sync: {
    etag: string | null;
    lastModified: string | null;
    contentSha256: string | null;
    consecutiveFailures: number;
    futureReservationCount: number;
    firstSyncCompletedAt: Timestamp | null;
    suspiciousSince: Timestamp | null;
    lastSuccessAtMs: number | null;
    lastStatus: ChannelSyncStatus | null;
  };
}

function readChannel(id: string, data: Record<string, unknown>): ChannelState {
  const sync = (data.sync && typeof data.sync === 'object' ? data.sync : {}) as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === 'string' ? v : null);
  const int = (v: unknown) => (Number.isInteger(v) && (v as number) >= 0 ? (v as number) : 0);
  const provider = (CHANNEL_PROVIDERS as readonly string[]).includes(data.provider as string)
    ? (data.provider as ChannelProvider)
    : 'other';
  return {
    id,
    listingId: typeof data.listingId === 'string' ? data.listingId : '',
    provider,
    label: typeof data.label === 'string' ? data.label : '',
    active: data.active === true,
    importBlocks: data.importBlocks !== false,
    sync: {
      etag: str(sync.etag),
      lastModified: str(sync.lastModified),
      contentSha256: str(sync.contentSha256),
      consecutiveFailures: int(sync.consecutiveFailures),
      futureReservationCount: int(sync.futureReservationCount),
      firstSyncCompletedAt: (sync.firstSyncCompletedAt as Timestamp | undefined) ?? null,
      suspiciousSince: (sync.suspiciousSince as Timestamp | undefined) ?? null,
      lastSuccessAtMs: tsMillis(sync.lastSuccessAt),
      lastStatus: (str(sync.lastStatus) as ChannelSyncStatus | null) ?? null,
    },
  };
}

interface ListingInfo {
  name: string;
  group: string;
  kind: StayDoc['listingKind'];
  checkInTime: string;
  checkOutTime: string;
  phoneLast4Codes: boolean;
}

async function loadListingInfo(db: Firestore, facilityId: string, listingId: string, controls: StayControlsDoc): Promise<ListingInfo> {
  const snap = await listingsCol(db, facilityId).doc(listingId).get();
  const d = (snap.exists ? snap.data() : {}) as Record<string, unknown>;
  const times = (d.times && typeof d.times === 'object' ? d.times : {}) as Record<string, unknown>;
  const hm = (v: unknown, fallback: string) => (typeof v === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(v) ? v : fallback);
  return {
    name: typeof d.name === 'string' && d.name ? d.name : 'Listing',
    group: typeof d.group === 'string' ? d.group : '',
    kind: (typeof d.kind === 'string' ? d.kind : 'other') as StayDoc['listingKind'],
    checkInTime: hm(times.checkIn, controls.defaultCheckInTime),
    checkOutTime: hm(times.checkOut, controls.defaultCheckOutTime),
    phoneLast4Codes: d.accessCodeMode === 'phone_last4',
  };
}

function emptyResult(channelId: string, status: ChannelSyncStatus): StaysChannelSyncResult {
  return {
    channelId,
    status,
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

/** The stored stay, as the diff sees it. */
export function toExistingFeedStay(stayId: string, doc: StayDoc): ExistingFeedStay {
  const sync = (doc.sync ?? null) as Partial<StaySyncState> | null;
  const ext = (doc.external ?? null) as Partial<StayExternalRef> | null;
  return {
    stayId,
    status: doc.status,
    arrivalState: doc.arrivalState ?? 'upcoming',
    paymentStatus: doc.paymentStatus ?? 'none',
    checkIn: doc.checkIn,
    checkOut: doc.checkOut,
    channelId: typeof sync?.channelId === 'string' ? sync.channelId : null,
    detached: sync?.detached === true,
    uid: typeof ext?.uid === 'string' ? ext.uid : null,
    uidHistory: Array.isArray(ext?.uidHistory) ? ext!.uidHistory!.filter((u): u is string => typeof u === 'string') : [],
    confirmationCode: typeof ext?.confirmationCode === 'string' ? ext.confirmationCode : null,
    missCount: Number.isInteger(sync?.missCount) ? (sync!.missCount as number) : 0,
    firstMissAtMs: tsMillis(sync?.firstMissAt),
    lastMissAtMs: tsMillis(sync?.lastMissAt),
    needsReview: sync?.needsReview === true,
    agedOut: tsMillis(sync?.agedOutAt) !== null,
  };
}

// ---------------------------------------------------------------------------
// Lease
// ---------------------------------------------------------------------------

type LeaseResult = { kind: 'ok'; channel: ChannelState } | { kind: 'missing' | 'inactive' | 'held'; channel: ChannelState | null };

async function takeLease(db: Firestore, ref: DocumentReference, runId: string, nowMs: number): Promise<LeaseResult> {
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return { kind: 'missing', channel: null };
    const channel = readChannel(ref.id, snap.data() as Record<string, unknown>);
    if (!channel.active) return { kind: 'inactive', channel };
    const lease = snap.get('sync.lease') as { runId?: string; expiresAt?: Timestamp } | null | undefined;
    const expires = tsMillis(lease?.expiresAt);
    if (lease && expires !== null && expires > nowMs && lease.runId !== runId) return { kind: 'held', channel };
    tx.update(ref, {
      'sync.lease': { runId, expiresAt: Timestamp.fromMillis(nowMs + SYNC_LEASE_MS) },
      'sync.lastAttemptAt': Timestamp.fromMillis(nowMs),
    });
    return { kind: 'ok', channel };
  });
}

/** Writes the run's health and releases the lease, unless another run has taken it since. */
async function finishLease(db: Firestore, ref: DocumentReference, runId: string, patch: Record<string, unknown>): Promise<void> {
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return;
    const lease = snap.get('sync.lease') as { runId?: string } | null | undefined;
    if (lease && lease.runId !== runId) return;
    tx.update(ref, { ...patch, 'sync.lease': null });
  });
}

// ---------------------------------------------------------------------------
// Turning the plan into stay docs
// ---------------------------------------------------------------------------

interface SyncContext {
  db: Firestore;
  facilityId: string;
  channel: ChannelState;
  controls: StayControlsDoc;
  listing: ListingInfo;
  todayYmd: Ymd;
  nowMs: number;
  now: Timestamp;
  missClock: Timestamp;
}

type Transform = (stored: StayDoc | null) => StayDoc | null;

interface PlannedChange {
  stayId: string;
  /** Orders the chunks chronologically. */
  checkIn: Ymd;
  create: boolean;
  transform: Transform;
  /** From an Airbnb feed: goes to stayPrivate (and stayAccess in phone-last-4 mode). */
  phoneLast4: string | null;
}

function versionOf(doc: StayDoc | null | undefined): number {
  return doc && Number.isInteger(doc.version) ? doc.version : 0;
}

/** The sync state of a stay the feed lists right now. */
function seenSync(ctx: SyncContext, stored: StayDoc | null): StaySyncState {
  const prev = stored?.sync ?? null;
  const same = prev?.channelId === ctx.channel.id;
  return {
    channelId: ctx.channel.id,
    firstSeenAt: same && prev?.firstSeenAt ? prev.firstSeenAt : ctx.now,
    lastSeenAt: ctx.now,
    missCount: 0,
    firstMissAt: null,
    lastMissAt: null,
    needsReview: false,
    agedOutAt: null,
    detached: false,
  };
}

function mergedExternal(ctx: SyncContext, stored: StayDoc | null, p: FeedReservation): StayExternalRef {
  const prev = stored?.external ?? null;
  const history = Array.isArray(prev?.uidHistory) ? [...prev!.uidHistory] : [];
  if (prev?.uid && p.uid && prev.uid !== p.uid && !history.includes(prev.uid)) history.push(prev.uid);
  return {
    provider: ctx.channel.provider,
    uid: p.uid ?? prev?.uid ?? null,
    uidHistory: history.slice(-UID_HISTORY_MAX),
    confirmationCode: p.confirmationCode ?? prev?.confirmationCode ?? null,
    reservationUrl: p.reservationUrl ?? prev?.reservationUrl ?? null,
    summary: p.summary ?? prev?.summary ?? null,
  };
}

function newFeedStay(ctx: SyncContext, p: FeedReservation): StayDoc {
  const listing = ctx.listing;
  const past = p.checkOut <= ctx.todayYmd;
  return {
    facilityId: ctx.facilityId,
    listingId: ctx.channel.listingId,
    listingName: listing.name,
    listingGroup: listing.group,
    listingKind: listing.kind,
    kind: 'reservation',
    source: sourceForProvider(ctx.channel.provider),
    origin: 'feed',
    status: 'confirmed',
    // A booking that ended before the feed was connected is history, not an overdue departure.
    arrivalState: past ? 'checked_out' : 'upcoming',
    checkIn: p.checkIn,
    checkOut: p.checkOut,
    nights: diffDays(p.checkIn, p.checkOut),
    checkInTime: listing.checkInTime,
    checkOutTime: listing.checkOutTime,
    guestDisplayName: '',
    adults: 0,
    children: 0,
    pets: 0,
    rvLengthFt: null,
    paymentStatus: channelCollectsPayment(ctx.channel.provider) ? 'channel_collected' : 'none',
    external: mergedExternal(ctx, null, p),
    sync: seenSync(ctx, null),
    conflict: null,
    staffNotes: '',
    cleanerNotes: '',
    tags: [],
    messageMarks: {},
    turnoverTaskId: null,
    checkedInAt: null,
    checkedOutAt: null,
    cancelledAt: null,
    cancelledBy: null,
    cancelReason: null,
    requestId: null,
    version: 1,
    createdAtMs: ctx.nowMs,
    createdAt: ctx.now,
    createdBy: SYNC_ACTOR,
    updatedAt: ctx.now,
    updatedBy: SYNC_ACTOR,
  };
}

/** Whether a stay still belongs to this channel (it may have been adopted elsewhere meanwhile). */
function ownedBy(ctx: SyncContext, stored: StayDoc | null): stored is StayDoc {
  return !!stored && stored.sync?.channelId === ctx.channel.id && stored.sync?.detached !== true;
}

function bumped(ctx: SyncContext, doc: StayDoc): StayDoc {
  return { ...doc, version: versionOf(doc) + 1, updatedAt: ctx.now, updatedBy: SYNC_ACTOR };
}

function sameJson(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

/** A stay the feed lists again (same dates, new dates, or back after a removal). */
function seenTransform(ctx: SyncContext, match: FeedMatch, kind: 'touch' | 'date_change' | 'restore', adopted: boolean): Transform {
  return (stored) => {
    if (!stored || stored.status === 'cancelled') return null;
    if (!adopted && !ownedBy(ctx, stored)) return null;
    const p = match.reservation;
    const external = mergedExternal(ctx, stored, p);
    const sync = seenSync(ctx, stored);
    let next: StayDoc = { ...stored, external, sync };
    if (kind === 'date_change' || kind === 'restore') {
      next = { ...next, checkIn: p.checkIn, checkOut: p.checkOut, nights: diffDays(p.checkIn, p.checkOut) };
    }
    if (kind === 'restore') {
      next = { ...next, status: 'confirmed', cancelledAt: null, cancelledBy: null, cancelReason: null };
    }
    if (kind === 'touch' && !adopted) {
      const prev = stored.sync;
      const material =
        !sameJson(stored.external ?? null, external) ||
        (prev?.missCount ?? 0) !== 0 ||
        prev?.firstMissAt != null ||
        prev?.needsReview === true ||
        prev?.agedOutAt != null ||
        prev?.detached === true;
      const lastSeen = tsMillis(prev?.lastSeenAt);
      const stale = lastSeen === null || ctx.nowMs - lastSeen >= LAST_SEEN_REFRESH_MS;
      if (!material && !stale) return null;
      if (!material) return next;
    }
    // Dates, status or ownership changed: a new version, so an open edit sees it.
    return bumped(ctx, next);
  };
}

interface MissOps {
  miss?: MissUpdate;
  remove?: boolean;
  review?: boolean;
  ageOut?: boolean;
}

function missTransform(ctx: SyncContext, ops: MissOps): Transform {
  return (stored) => {
    if (!ownedBy(ctx, stored)) return null;
    const prev = stored.sync as StaySyncState;
    const sync: StaySyncState = { ...prev };
    if (ops.miss) {
      sync.missCount = ops.miss.missCount;
      sync.firstMissAt = Timestamp.fromMillis(ops.miss.firstMissAtMs);
      sync.lastMissAt = Timestamp.fromMillis(ops.miss.lastMissAtMs);
    }
    if (ops.ageOut) sync.agedOutAt = ctx.now;
    let next: StayDoc = { ...stored, sync };
    if (ops.remove) {
      if (!isActiveStatus(stored.status)) return sameJson(prev, sync) ? null : next;
      next = {
        ...next,
        status: 'removed_from_feed',
        cancelledAt: ctx.now,
        cancelledBy: 'feed',
        cancelReason: `Removed from ${providerLabel(ctx.channel.provider)}`,
      };
      return bumped(ctx, next);
    }
    if (ops.review && sync.needsReview !== true) {
      next = { ...next, sync: { ...sync, needsReview: true } };
      return bumped(ctx, next);
    }
    return sameJson(prev, sync) ? null : next;
  };
}

function changesFromPlan(ctx: SyncContext, plan: FeedSyncPlan, existing: Map<string, ExistingFeedStay>): PlannedChange[] {
  const changes: PlannedChange[] = [];
  const adopted = new Set(plan.adopted);
  for (const p of plan.creates) {
    changes.push({
      stayId: p.stayId,
      checkIn: p.checkIn,
      create: true,
      transform: (stored) => (stored ? null : newFeedStay(ctx, p)),
      phoneLast4: p.phoneLast4,
    });
  }
  const seen: [FeedMatch[], 'touch' | 'date_change' | 'restore'][] = [
    [plan.touches, 'touch'],
    [plan.dateChanges, 'date_change'],
    [plan.restores, 'restore'],
  ];
  for (const [list, kind] of seen) {
    for (const m of list) {
      changes.push({
        stayId: m.stayId,
        checkIn: m.reservation.checkIn,
        create: false,
        transform: seenTransform(ctx, m, kind, adopted.has(m.stayId)),
        phoneLast4: m.reservation.phoneLast4,
      });
    }
  }
  const ops = new Map<string, MissOps>();
  const op = (id: string) => {
    let o = ops.get(id);
    if (!o) ops.set(id, (o = {}));
    return o;
  };
  for (const m of plan.missesAdvanced) op(m.stayId).miss = m;
  for (const id of plan.removals) {
    op(id).remove = true;
    if (plan.missState[id]) op(id).miss = plan.missState[id];
  }
  for (const id of plan.reviews) {
    op(id).review = true;
    if (plan.missState[id]) op(id).miss = plan.missState[id];
  }
  for (const id of plan.agedOut) op(id).ageOut = true;
  for (const [id, o] of ops) {
    changes.push({ stayId: id, checkIn: existing.get(id)?.checkIn ?? '0000-00-00', create: false, transform: missTransform(ctx, o), phoneLast4: null });
  }
  return changes;
}

interface ApplyResult {
  after: Record<string, StayDoc | null>;
  before: Record<string, StayDoc | null>;
  statusChanges: StatusChange[];
  outcomes: Record<string, StayLockOutcome>;
  written: Set<string>;
}

/** Private phone last 4 (and the door code in phone-last-4 mode), only when it changed. */
function phoneWrites(ctx: SyncContext, byStay: Map<string, string>): {
  refs: DocumentReference[];
  write: (tx: WriteOnlyTransaction, snaps: DocumentSnapshot[], writePlan: { after: Record<string, StayDoc | null> }) => void;
} {
  const privateCol = facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.private);
  const accessCol = facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.access);
  const ids = [...byStay.keys()];
  const withAccess = ctx.listing.phoneLast4Codes === true;
  const refs: DocumentReference[] = [];
  for (const id of ids) {
    refs.push(privateCol.doc(id));
    if (withAccess) refs.push(accessCol.doc(id));
  }
  return {
    refs,
    write: (tx, snaps, writePlan) => {
      let i = 0;
      for (const id of ids) {
        const privSnap = snaps[i++];
        const accessSnap = withAccess ? snaps[i++] : null;
        if (!writePlan.after[id]) continue;
        const last4 = byStay.get(id)!;
        const priv = privSnap.exists ? (privSnap.data() as Record<string, unknown>) : null;
        if (!priv || priv.phoneLast4 !== last4) {
          tx.set(
            privateCol.doc(id),
            priv
              ? { phoneLast4: last4, updatedAt: ctx.now, updatedBy: SYNC_ACTOR }
              : {
                  facilityId: ctx.facilityId,
                  stayId: id,
                  guestProfileId: null,
                  fullName: null,
                  phoneLast4: last4,
                  privateNotes: '',
                  updatedAt: ctx.now,
                  updatedBy: SYNC_ACTOR,
                },
            { merge: true },
          );
        }
        if (accessSnap) {
          const access = accessSnap.exists ? (accessSnap.data() as Record<string, unknown>) : null;
          // A code the owner typed in herself is hers; only a phone-last-4 code follows the feed.
          if (access && access.source !== 'phone_last4') continue;
          if (access && access.doorCode === last4) continue;
          tx.set(
            accessCol.doc(id),
            {
              facilityId: ctx.facilityId,
              stayId: id,
              doorCode: last4,
              gateCode: (access?.gateCode as string | null | undefined) ?? null,
              accessNotes: typeof access?.accessNotes === 'string' ? access.accessNotes : '',
              source: 'phone_last4',
              updatedAt: ctx.now,
              updatedBy: SYNC_ACTOR,
            },
            { merge: true },
          );
        }
      }
    },
  };
}

/**
 * Applies the planned changes in chronological chunks. Each chunk re-reads
 * its stays and rebuilds them from the fresh docs, so a check-in, a note or
 * an owner's edit made since the plan was read is kept, and the writer's
 * version check covers the moment between that read and its transaction.
 */
async function applyChanges(
  ctx: SyncContext,
  changes: PlannedChange[],
  blockUpdate: { ranges: ChannelBlockRange[] } | null,
): Promise<ApplyResult> {
  const result: ApplyResult = { after: {}, before: {}, statusChanges: [], outcomes: {}, written: new Set() };
  const sorted = [...changes].sort((a, b) => (a.checkIn < b.checkIn ? -1 : a.checkIn > b.checkIn ? 1 : a.stayId < b.stayId ? -1 : 1));
  const chunks: PlannedChange[][] = [];
  for (let i = 0; i < sorted.length; i += STAYS_LIMITS.stayMutationsPerTransaction) {
    chunks.push(sorted.slice(i, i + STAYS_LIMITS.stayMutationsPerTransaction));
  }
  if (chunks.length === 0 && blockUpdate) chunks.push([]);
  const col = staysCol(ctx.db, ctx.facilityId);

  for (let c = 0; c < chunks.length; c++) {
    const chunk = chunks[c];
    for (let attempt = 1; ; attempt++) {
      const snaps = chunk.length ? await ctx.db.getAll(...chunk.map((ch) => col.doc(ch.stayId))) : [];
      const mutations: StayMutation[] = [];
      const phones = new Map<string, string>();
      chunk.forEach((ch, i) => {
        const stored = snaps[i].exists ? (snaps[i].data() as StayDoc) : null;
        if (ch.create === !!stored) return;
        const next = ch.transform(stored);
        if (!next) return;
        mutations.push({
          stayId: ch.stayId,
          next,
          mode: 'feed',
          ...(ch.create ? { createOnly: true } : { expectedVersion: versionOf(stored) }),
        });
        if (ch.phoneLast4) phones.set(ch.stayId, ch.phoneLast4);
      });
      const blocks = c === 0 && blockUpdate ? [{ channelId: ctx.channel.id, listingId: ctx.channel.listingId, provider: ctx.channel.provider, ranges: blockUpdate.ranges }] : [];
      if (mutations.length === 0 && blocks.length === 0) break;
      const phone = phoneWrites(ctx, phones);
      try {
        const res = await applyStayMutations({
          db: ctx.db,
          facilityId: ctx.facilityId,
          controls: ctx.controls,
          mutations,
          channelBlockUpdates: blocks,
          extraReads: phone.refs,
          extraWrites: phone.refs.length ? (tx, s, p) => phone.write(tx, s, p) : undefined,
          actor: SYNC_ACTOR,
          nowMs: ctx.nowMs,
        });
        for (const m of mutations) {
          if (res.plan.skipped.includes(m.stayId)) continue;
          result.before[m.stayId] = res.plan.before[m.stayId] ?? null;
          result.after[m.stayId] = res.plan.after[m.stayId] ?? null;
          result.written.add(m.stayId);
        }
        result.statusChanges.push(...res.statusChanges);
        Object.assign(result.outcomes, res.outcomes);
        break;
      } catch (error) {
        // Someone changed one of these stays between the re-read and the write: re-read and go again.
        if (attempt < 3 && (isStaysError(error, 'version_mismatch') || isStaysError(error, 'contention'))) continue;
        throw error;
      }
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Notifications (dates, listing names and guestDisplayName only)
// ---------------------------------------------------------------------------

function guestLabel(doc: StayDoc, provider: ChannelProvider): string {
  const name = (doc.guestDisplayName ?? '').trim();
  return name || `${providerLabel(provider)} guest`;
}

function stayNotifications(ctx: SyncContext, plan: FeedSyncPlan, applied: ApplyResult, firstSync: boolean): StayNotificationInput[] {
  const out: StayNotificationInput[] = [];
  const fid = ctx.facilityId;
  const listingName = ctx.listing.name;
  const label = providerLabel(ctx.channel.provider);
  const meta = (stayId: string) => ({ stayId, listingId: ctx.channel.listingId, channelId: ctx.channel.id, route: stayRoute(fid, stayId) });
  const written = (id: string) => (applied.written.has(id) ? applied.after[id] : null);

  if (!firstSync) {
    for (const p of plan.creates) {
      const doc = written(p.stayId);
      if (!doc || applied.before[p.stayId] || p.checkOut <= ctx.todayYmd) continue;
      out.push({
        id: notificationId({ kind: 'stay', type: 'STAY_BOOKING_IMPORTED', stayId: p.stayId, version: versionOf(doc) }),
        type: 'STAY_BOOKING_IMPORTED',
        message: `New ${label} booking at ${listingName}: ${formatRange(doc.checkIn, doc.checkOut)} (${nightsLabel(doc.checkIn, doc.checkOut)}).`,
        metadata: meta(p.stayId),
      });
    }
  }
  for (const m of plan.dateChanges) {
    const doc = written(m.stayId);
    if (!doc || (doc.checkIn === m.from.checkIn && doc.checkOut === m.from.checkOut)) continue;
    out.push({
      id: notificationId({ kind: 'stay', type: 'STAY_BOOKING_CHANGED', stayId: m.stayId, version: versionOf(doc) }),
      type: 'STAY_BOOKING_CHANGED',
      message: `${label} booking at ${listingName} moved to ${formatRange(doc.checkIn, doc.checkOut)} (was ${formatRange(m.from.checkIn, m.from.checkOut)}).`,
      metadata: meta(m.stayId),
    });
  }
  for (const m of plan.restores) {
    const doc = written(m.stayId);
    if (!doc) continue;
    out.push({
      id: notificationId({ kind: 'stay', type: 'STAY_BOOKING_CHANGED', stayId: m.stayId, version: versionOf(doc) }),
      type: 'STAY_BOOKING_CHANGED',
      message: `${label} booking at ${listingName}, ${formatRange(doc.checkIn, doc.checkOut)}, is back in the ${label} calendar.`,
      metadata: meta(m.stayId),
    });
  }
  for (const id of plan.removals) {
    const doc = written(id);
    if (!doc || doc.status !== 'removed_from_feed') continue;
    out.push({
      id: notificationId({ kind: 'stay', type: 'STAY_BOOKING_REMOVED', stayId: id, version: versionOf(doc) }),
      type: 'STAY_BOOKING_REMOVED',
      message: `${label} booking at ${listingName}, ${formatRange(doc.checkIn, doc.checkOut)}, is no longer in the ${label} calendar. Its nights are free again.`,
      metadata: meta(id),
    });
  }
  for (const id of plan.reviews) {
    const doc = written(id);
    if (!doc || doc.sync?.needsReview !== true) continue;
    out.push({
      id: notificationId({ kind: 'stay', type: 'STAY_BOOKING_NEEDS_REVIEW', stayId: id, version: versionOf(doc) }),
      type: 'STAY_BOOKING_NEEDS_REVIEW',
      message: `Check the ${label} booking at ${listingName}, ${formatRange(doc.checkIn, doc.checkOut)}: it left the ${label} calendar but is checked in or paid, so SFC kept it.`,
      metadata: meta(id),
    });
  }
  return out;
}

async function conflictNotifications(ctx: SyncContext, applied: ApplyResult): Promise<StayNotificationInput[]> {
  const ids = [...new Set(applied.statusChanges.filter((c) => c.to === 'conflict').map((c) => c.stayId))];
  if (ids.length === 0) return [];
  const col = staysCol(ctx.db, ctx.facilityId);
  const snaps = await ctx.db.getAll(...ids.map((id) => col.doc(id)));
  const out: StayNotificationInput[] = [];
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const doc = snap.data() as StayDoc;
    if (doc.status !== 'conflict') continue;
    const others = doc.conflict?.stayIds ?? applied.outcomes[snap.id]?.conflictStayIds ?? [];
    out.push({
      id: notificationId({ kind: 'conflict', stayId: snap.id, conflictStayIds: others }),
      type: 'STAY_CONFLICT',
      message: `Double booking at ${doc.listingName || ctx.listing.name}: ${guestLabel(doc, ctx.channel.provider)}, ${formatRange(doc.checkIn, doc.checkOut)}, overlaps another booking.`,
      metadata: { stayId: snap.id, listingId: doc.listingId, channelId: ctx.channel.id, route: stayRoute(ctx.facilityId, snap.id) },
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

async function loadOwnStays(ctx: SyncContext, fromYmd: Ymd): Promise<Map<string, StayDoc>> {
  const snap = await staysCol(ctx.db, ctx.facilityId)
    .where('sync.channelId', '==', ctx.channel.id)
    .where('checkOut', '>', fromYmd)
    .get();
  const out = new Map<string, StayDoc>();
  for (const d of snap.docs) {
    const doc = d.data() as StayDoc;
    if (doc.listingId === ctx.channel.listingId) out.set(d.id, doc);
  }
  return out;
}

/** Stay ids with posted income: never removed automatically. */
async function incomeStayIds(ctx: SyncContext, stayIds: string[]): Promise<Set<string>> {
  const out = new Set<string>();
  const col = facilityCol(ctx.db, ctx.facilityId, STAY_COLLECTIONS.income);
  for (const id of stayIds) {
    const snap = await col.where('stayId', '==', id).where('status', '==', 'posted').limit(1).get();
    if (!snap.empty) out.add(id);
  }
  return out;
}

/** Plans, and when a removal candidate turns out to have income, plans again with that known. */
async function planWithIncome(ctx: SyncContext, planOnce: (withIncome: Set<string>) => FeedSyncPlan): Promise<FeedSyncPlan> {
  let plan = planOnce(new Set());
  if (plan.removals.length > 0) {
    const withIncome = await incomeStayIds(ctx, plan.removals);
    if (withIncome.size > 0) plan = planOnce(withIncome);
  }
  return plan;
}

// ---------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------

interface RunOutcome {
  result: StaysChannelSyncResult;
  health: Record<string, unknown>;
  notifications: StayNotificationInput[];
}

function failure(ctx: SyncContext, status: ChannelSyncStatus, httpStatus: number | null, code: string): RunOutcome {
  const failures = ctx.channel.sync.consecutiveFailures + 1;
  const result = { ...emptyResult(ctx.channel.id, status), httpStatus };
  const notifications: StayNotificationInput[] = [];
  if (status === 'gone' || failures >= FAILURES_BEFORE_ALERT) {
    const label = providerLabel(ctx.channel.provider);
    const listingName = ctx.listing.name;
    notifications.push({
      // One a day per feed, whichever way it is failing.
      id: notificationId({ kind: 'feed', channelId: ctx.channel.id, status: 'failing', ymd: ctx.todayYmd }),
      type: 'STAY_FEED_FAILING',
      message:
        status === 'gone'
          ? `The ${label} calendar link for ${listingName} stopped working. Paste a fresh export link in Stays channels. Bookings are kept as they are.`
          : `SFC could not read the ${label} calendar for ${listingName} (${failures} tries in a row). Bookings are kept as they are.`,
      metadata: { listingId: ctx.channel.listingId, channelId: ctx.channel.id, route: channelsRoute(ctx.facilityId, ctx.channel.listingId) },
    });
  }
  return {
    result,
    health: {
      'sync.lastStatus': status,
      'sync.lastHttpStatus': httpStatus,
      'sync.lastErrorCode': code,
      'sync.consecutiveFailures': failures,
    },
    notifications,
  };
}

function successHealth(ctx: SyncContext, status: ChannelSyncStatus, httpStatus: number, fetched: SafeFetchResult): Record<string, unknown> {
  return {
    'sync.lastStatus': status,
    'sync.lastHttpStatus': httpStatus,
    'sync.lastErrorCode': null,
    'sync.consecutiveFailures': 0,
    'sync.etag': fetched.etag ?? ctx.channel.sync.etag ?? null,
    'sync.lastModified': fetched.lastModified ?? ctx.channel.sync.lastModified ?? null,
    'sync.firstSyncCompletedAt': ctx.channel.sync.firstSyncCompletedAt ?? ctx.now,
  };
}

async function runUnchanged(ctx: SyncContext, fetched: SafeFetchResult): Promise<RunOutcome> {
  const { clampFrom } = lockHorizon(ctx.todayYmd);
  const stays = await loadOwnStays(ctx, clampFrom);
  const existing = new Map<string, ExistingFeedStay>();
  for (const [id, doc] of stays) existing.set(id, toExistingFeedStay(id, doc));
  const suspicious = ctx.channel.sync.suspiciousSince !== null;
  const plan = await planWithIncome(ctx, (withIncome) =>
    advanceMissesOnUnchanged([...existing.values()], ctx.missClock.toMillis(), {
      channelId: ctx.channel.id,
      todayYmd: ctx.todayYmd,
      suspicious,
      withIncome,
    }),
  );
  const changes = changesFromPlan(ctx, plan, existing);
  let applied: ApplyResult = { after: {}, before: {}, statusChanges: [], outcomes: {}, written: new Set() };
  if (changes.length) applied = await applyChanges(ctx, changes, null);
  const health = successHealth(ctx, suspicious ? 'suspicious' : 'not_modified', fetched.status, fetched);
  const advanced = plan.missesAdvanced.length > 0;
  const lastOk = ctx.channel.sync.lastSuccessAtMs;
  if (advanced || lastOk === null || ctx.nowMs - lastOk >= UNCHANGED_SUCCESS_WRITE_MS || ctx.channel.sync.lastStatus !== health['sync.lastStatus']) {
    health['sync.lastSuccessAt'] = ctx.now;
  }
  if (applied.written.size > 0) health['sync.lastChangedAt'] = ctx.now;
  const notifications = [...stayNotifications(ctx, plan, applied, false), ...(await conflictNotifications(ctx, applied))];
  return {
    result: {
      ...emptyResult(ctx.channel.id, health['sync.lastStatus'] as ChannelSyncStatus),
      httpStatus: fetched.status,
      missesAdvanced: plan.missesAdvanced.filter((m) => applied.written.has(m.stayId)).length,
      removed: plan.removals.filter((id) => applied.after[id]?.status === 'removed_from_feed').length,
      needsReview: plan.reviews.filter((id) => applied.after[id]?.sync?.needsReview === true).length,
    },
    health,
    notifications,
  };
}

/** Reservations and block events of a parsed feed, with their stay ids. */
export function splitFeed(
  parsed: ParseIcsResult,
  provider: ChannelProvider,
  listingId: string,
): { reservations: FeedReservation[]; blocks: { checkIn: Ymd; checkOut: Ymd }[]; tooLong: number } {
  const reservations: FeedReservation[] = [];
  const blocks: { checkIn: Ymd; checkOut: Ymd }[] = [];
  let tooLong = 0;
  for (const ev of parsed.events) {
    if (classifyEvent(provider, ev.summary, ev.description) === 'block') {
      blocks.push({ checkIn: ev.checkIn, checkOut: ev.checkOut });
      continue;
    }
    if (diffDays(ev.checkIn, ev.checkOut) > STAYS_LIMITS.importedStayMaxNights) {
      tooLong++;
      continue;
    }
    const refs = provider === 'airbnb' ? extractAirbnbRefs(ev.description) : null;
    const code = refs?.confirmationCode ?? null;
    // Without a UID (not allowed by RFC 5545, but seen), the dates are the identity.
    const uid = ev.uid ?? `nouid:${ev.checkIn}:${ev.checkOut}`;
    reservations.push({
      stayId: code ? stayIdForAirbnb(code) : stayIdForFeed(listingId, provider, uid),
      uid,
      confirmationCode: code,
      reservationUrl: refs?.reservationUrl ?? null,
      summary: keptSummary(provider, ev.summary),
      phoneLast4: refs?.phoneLast4 ?? null,
      checkIn: ev.checkIn,
      checkOut: ev.checkOut,
    });
  }
  return { reservations, blocks, tooLong };
}

/** The stays the export link(s) to this channel's provider send: their comebacks are echoes. */
async function exportedStaysForEcho(ctx: SyncContext): Promise<{ checkIn: Ymd; checkOut: Ymd }[]> {
  const target = exportTargetForProvider(ctx.channel.provider);
  const links = await exportLinksCol(ctx.db, ctx.facilityId)
    .where('listingId', '==', ctx.channel.listingId)
    .where('active', '==', true)
    .get();
  const scopes = links.docs.filter((d) => d.get('targetProvider') === target).map((d) => d.get('scope'));
  if (scopes.length === 0) return [];
  const { clampFrom, clampTo } = lockHorizon(ctx.todayYmd);
  const snap = await staysCol(ctx.db, ctx.facilityId)
    .where('listingId', '==', ctx.channel.listingId)
    .where('checkOut', '>', clampFrom)
    .get();
  const stays = snap.docs.map((d) => ({ ...(d.data() as StayDoc), stayId: d.id }));
  const out: { checkIn: Ymd; checkOut: Ymd }[] = [];
  const seen = new Set<string>();
  for (const scope of scopes) {
    if (scope !== 'blocks_only' && scope !== 'sfc' && scope !== 'all') continue;
    for (const s of staysForExport(stays, { scope, targetProvider: target, todayYmd: ctx.todayYmd, lastCheckInYmd: clampTo })) {
      if (seen.has(s.stayId)) continue;
      seen.add(s.stayId);
      out.push({ checkIn: s.checkIn, checkOut: s.checkOut });
    }
  }
  return out;
}

async function runChanged(ctx: SyncContext, fetched: SafeFetchResult, body: string, bodySha: string): Promise<RunOutcome> {
  const tz = confirmedTimeZone(ctx.controls);
  let parsed: ParseIcsResult;
  try {
    parsed = parseIcs(body, tz);
  } catch (error) {
    if (error instanceof IcsParseError) {
      return failure(ctx, error.code === 'too_large' ? 'too_large' : 'invalid_feed', fetched.status, error.code);
    }
    throw error;
  }
  const listing = ctx.listing;
  const horizon = lockHorizon(ctx.todayYmd);
  const feed = splitFeed(parsed, ctx.channel.provider, ctx.channel.listingId);

  // This channel's stays, plus any stay a parsed reservation names that the channel does not own yet.
  const own = await loadOwnStays(ctx, horizon.clampFrom);
  const existing = new Map<string, ExistingFeedStay>();
  for (const [id, doc] of own) existing.set(id, toExistingFeedStay(id, doc));
  const unknownIds = [...new Set(feed.reservations.filter((r) => !own.has(r.stayId) && r.checkOut > horizon.clampFrom).map((r) => r.stayId))];
  const notOurs = new Set<string>();
  const channelActive = new Map<string, boolean>();
  const col = staysCol(ctx.db, ctx.facilityId);
  for (let i = 0; i < unknownIds.length; i += 100) {
    const snaps = await ctx.db.getAll(...unknownIds.slice(i, i + 100).map((id) => col.doc(id)));
    for (const snap of snaps) {
      if (!snap.exists) continue;
      const doc = snap.data() as StayDoc;
      const otherChannel = doc.sync && !doc.sync.detached && doc.sync.channelId !== ctx.channel.id ? doc.sync.channelId : null;
      let foreign = doc.listingId !== ctx.channel.listingId || doc.status === 'cancelled';
      if (!foreign && otherChannel) {
        if (!channelActive.has(otherChannel)) {
          const ch = await channelsCol(ctx.db, ctx.facilityId).doc(otherChannel).get();
          channelActive.set(otherChannel, ch.exists && ch.get('active') === true);
        }
        // Another live feed owns it (two links to one Airbnb listing): leave it to that feed.
        foreign = channelActive.get(otherChannel) === true;
      }
      if (foreign) notOurs.add(snap.id);
      else existing.set(snap.id, toExistingFeedStay(snap.id, doc));
    }
  }
  if (notOurs.size > 0) {
    functions.logger.warn('stays: feed lists bookings another listing or feed owns; left alone', {
      facilityId: ctx.facilityId,
      channelId: ctx.channel.id,
      count: notOurs.size,
    });
  }
  const reservations = feed.reservations.filter((r) => !notOurs.has(r.stayId));

  const plan = await planWithIncome(ctx, (withIncome) =>
    planFeedSync([...existing.values()], reservations, {
      channelId: ctx.channel.id,
      todayYmd: ctx.todayYmd,
      now: ctx.missClock.toMillis(),
      prevFutureCount: ctx.channel.sync.futureReservationCount,
      withIncome,
      feedEventCount: parsed.eventCount,
      createAfterYmd: horizon.clampFrom,
    }),
  );

  // Soft blocks: the feed's whole set, replaced as one. A suspicious feed keeps the last good set.
  const storedBlocks = await channelBlocksCol(ctx.db, ctx.facilityId).doc(ctx.channel.id).get();
  const storedRanges = (storedBlocks.exists && Array.isArray(storedBlocks.get('ranges')) ? storedBlocks.get('ranges') : []) as ChannelBlockRange[];
  let ranges: ChannelBlockRange[] = [];
  if (plan.suspicious) {
    ranges = storedRanges;
  } else if (ctx.channel.importBlocks) {
    ranges = normalizeBlockRanges(feed.blocks, horizon).ranges;
    const exported = ranges.length ? await exportedStaysForEcho(ctx) : [];
    ranges = markEchoes(ranges, exported);
  }
  const blocksChanged = !sameBlockRanges(storedRanges, ranges) || (!storedBlocks.exists && ranges.length > 0);

  const changes = changesFromPlan(ctx, plan, existing);
  const applied = await applyChanges(ctx, changes, blocksChanged ? { ranges } : null);

  const firstSync = ctx.channel.sync.firstSyncCompletedAt === null;
  const notifications = [...stayNotifications(ctx, plan, applied, firstSync), ...(await conflictNotifications(ctx, applied))];
  const conflicts = new Set(applied.statusChanges.filter((c) => c.to === 'conflict').map((c) => c.stayId)).size;
  const label = providerLabel(ctx.channel.provider);
  const listingName = listing.name;
  if (firstSync) {
    const upcoming = reservations.filter((r) => r.checkOut > ctx.todayYmd).sort((a, b) => (a.checkIn < b.checkIn ? -1 : 1));
    const next = upcoming.find((r) => r.checkIn >= ctx.todayYmd);
    const parts = [
      `${label} calendar connected for ${listingName}: ${upcoming.length} upcoming booking${upcoming.length === 1 ? '' : 's'}`,
      `${ranges.length} blocked range${ranges.length === 1 ? '' : 's'}`,
    ];
    notifications.unshift({
      id: notificationId({ kind: 'feed', channelId: ctx.channel.id, status: 'first_sync', ymd: ctx.todayYmd }),
      type: 'STAY_FEED_FIRST_SYNC',
      message:
        `${parts.join(' and ')}.` +
        (next ? ` Next arrival ${formatDay(next.checkIn)}.` : '') +
        (conflicts > 0 ? ` ${conflicts} double booking${conflicts === 1 ? '' : 's'} to check.` : ''),
      metadata: { listingId: ctx.channel.listingId, channelId: ctx.channel.id, route: channelsRoute(ctx.facilityId, ctx.channel.listingId) },
    });
  }
  if (plan.suspicious) {
    notifications.push({
      id: notificationId({ kind: 'feed', channelId: ctx.channel.id, status: 'suspicious', ymd: ctx.todayYmd }),
      type: 'STAY_FEED_SUSPICIOUS',
      message: `The ${label} calendar for ${listingName} suddenly looks empty or is missing many bookings. SFC removed nothing and will wait longer before removing any.`,
      metadata: { listingId: ctx.channel.listingId, channelId: ctx.channel.id, route: channelsRoute(ctx.facilityId, ctx.channel.listingId) },
    });
  }

  const status: ChannelSyncStatus = plan.suspicious ? 'suspicious' : 'ok';
  const health: Record<string, unknown> = {
    ...successHealth(ctx, status, 200, fetched),
    'sync.lastSuccessAt': ctx.now,
    'sync.contentSha256': bodySha,
    'sync.eventCount': parsed.eventCount,
    // While suspicious, keep the count the feed had, so an empty feed stays suspicious until it is resolved.
    'sync.futureReservationCount': plan.suspicious
      ? Math.max(ctx.channel.sync.futureReservationCount, plan.futureReservationCount)
      : plan.futureReservationCount,
    'sync.blockCount': ranges.length,
    'sync.suspiciousSince': plan.suspicious ? (ctx.channel.sync.suspiciousSince ?? ctx.now) : null,
  };
  if (applied.written.size > 0 || blocksChanged) health['sync.lastChangedAt'] = ctx.now;

  const createdIds = plan.creates.map((p) => p.stayId).filter((id) => applied.written.has(id) && !applied.before[id]);
  return {
    result: {
      ...emptyResult(ctx.channel.id, status),
      httpStatus: 200,
      created: createdIds.length,
      dateChanged: plan.dateChanges.filter((m) => applied.written.has(m.stayId)).length,
      restored: plan.restores.filter((m) => applied.after[m.stayId]?.status !== 'removed_from_feed' && applied.written.has(m.stayId)).length,
      missesAdvanced: plan.missesAdvanced.filter((m) => applied.written.has(m.stayId)).length,
      removed: plan.removals.filter((id) => applied.after[id]?.status === 'removed_from_feed').length,
      needsReview: plan.reviews.filter((id) => applied.after[id]?.sync?.needsReview === true).length,
      conflicts,
      blocks: ranges.length,
    },
    health,
    notifications,
  };
}

/**
 * Syncs one channel now. Returns the run's counts; a feed failure is a
 * result (with its status), not an exception. Throws only when the
 * facility's zone is unconfirmed or Firestore itself fails.
 */
export async function syncChannel(
  facilityId: string,
  channelId: string,
  trigger: SyncTrigger = 'manual',
  options: SyncChannelOptions = {},
): Promise<StaysChannelSyncResult> {
  const deps: SyncDeps = { ...defaultSyncDeps(), ...(options.deps ?? {}) };
  const db = deps.db();
  const startedMs = deps.now();
  const runId = options.runId ?? `${trigger}_${startedMs}_${randomBytes(4).toString('hex')}`;

  const gate = options.gate ?? (await loadStaysGate(db, startedMs));
  if (!evaluateStaysGate(gate, facilityId).allowed) {
    return { ...emptyResult(channelId, 'not_modified'), skipped: true };
  }
  const controls = options.controls ?? (await loadControls(db, facilityId));
  const tz = confirmedTimeZone(controls);
  const todayYmd = facilityToday(tz, startedMs);
  const slotMs = options.slot && trigger === 'scheduled' ? Date.parse(`${options.slot}:00Z`) : NaN;

  const chRef = channelsCol(db, facilityId).doc(channelId);
  const lease = await takeLease(db, chRef, runId, startedMs);
  if (lease.kind !== 'ok') {
    return { ...emptyResult(channelId, lease.channel?.sync.lastStatus ?? 'not_modified'), skipped: true };
  }

  // The listing names the stays and the notifications. A failed read ends the
  // run as a failure (lease released), never a sync with made-up names.
  let listing: ListingInfo | null = null;
  try {
    listing = await loadListingInfo(db, facilityId, lease.channel.listingId, controls);
  } catch (error) {
    functions.logger.error('stays: could not read the listing for a channel sync', {
      facilityId,
      channelId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
  const ctx: SyncContext = {
    db,
    facilityId,
    channel: lease.channel,
    controls,
    listing: listing ?? { name: 'a listing', group: '', kind: 'other', checkInTime: controls.defaultCheckInTime, checkOutTime: controls.defaultCheckOutTime, phoneLast4Codes: false },
    todayYmd,
    nowMs: startedMs,
    now: Timestamp.fromMillis(startedMs),
    // Scheduled runs count misses on the slot's clock, so runs 30 minutes apart are exactly 30 minutes apart.
    missClock: Timestamp.fromMillis(Number.isFinite(slotMs) && slotMs <= startedMs ? slotMs : startedMs),
  };

  let outcome: RunOutcome | null = null;
  // While a feed looks suspicious it is always fetched and diffed in full, so the
  // moment it recovers (or its missing bookings are resolved) the flag clears.
  const suspicious = ctx.channel.sync.suspiciousSince !== null;
  try {
    if (!listing) throw new Error('listing unreadable');
    const secret = await chRef.collection(STAYS_SECRET_SUBCOLLECTION).doc(STAYS_CURRENT_DOC_ID).get();
    const url = secret.exists ? secret.get('url') : null;
    if (typeof url !== 'string' || url.length === 0) {
      outcome = failure(ctx, 'gone', null, 'missing_url');
    } else {
      let fetched: SafeFetchResult | null = null;
      try {
        fetched = await deps.fetchFeed(url, {
          allowedHosts: allowedIcalHosts(gate.extraIcalHosts),
          etag: suspicious ? null : ctx.channel.sync.etag,
          lastModified: suspicious ? null : ctx.channel.sync.lastModified,
        });
      } catch (error) {
        if (!(error instanceof SafeFetchError)) throw error;
        outcome = failure(ctx, syncStatusForFetchError(error), error.httpStatus, error.code);
      }
      if (fetched) {
        const body = fetched.status === 200 ? (fetched.body ?? '') : '';
        const bodySha = fetched.status === 200 ? sha256Hex(body) : null;
        if (!suspicious && (fetched.status === 304 || (bodySha !== null && bodySha === ctx.channel.sync.contentSha256))) {
          outcome = await runUnchanged(ctx, fetched);
        } else if (fetched.status === 304) {
          // Only when a 304 came back to an unconditional request: treat as a failure, never as empty.
          outcome = failure(ctx, 'http_error', 304, 'unexpected_304');
        } else {
          outcome = await runChanged(ctx, fetched, body, bodySha as string);
        }
      }
    }
  } catch (error) {
    functions.logger.error('stays: channel sync failed', {
      facilityId,
      channelId,
      error: error instanceof Error ? error.message : String(error),
    });
    outcome = failure(ctx, 'http_error', null, 'internal');
  }
  if (!outcome) outcome = failure(ctx, 'http_error', null, 'internal');

  const finishedMs = deps.now();
  outcome.result.durationMs = Math.max(0, finishedMs - startedMs);
  await finishLease(db, chRef, runId, outcome.health);

  try {
    const logId = trigger === 'scheduled' && options.slot ? syncLogIdScheduled(options.slot, channelId) : syncLogIdManual(startedMs, channelId);
    const r = outcome.result;
    await syncLogCol(db, facilityId)
      .doc(logId)
      .set({
        facilityId,
        channelId,
        listingId: ctx.channel.listingId,
        trigger,
        status: r.status,
        httpStatus: r.httpStatus,
        errorCode: (outcome.health['sync.lastErrorCode'] as string | null | undefined) ?? null,
        created: r.created,
        dateChanged: r.dateChanged,
        restored: r.restored,
        missesAdvanced: r.missesAdvanced,
        removed: r.removed,
        needsReview: r.needsReview,
        conflicts: r.conflicts,
        blocks: r.blocks,
        durationMs: r.durationMs,
        finishedAt: Timestamp.fromMillis(finishedMs),
        expireAt: Timestamp.fromMillis(finishedMs + SYNC_LOG_RETENTION_MS),
      });
  } catch (error) {
    functions.logger.warn('stays: sync log write failed', { channelId, error: error instanceof Error ? error.message : String(error) });
  }

  if (outcome.notifications.length > 0) {
    await writeStayNotifications(db, facilityId, outcome.notifications, Timestamp.fromMillis(finishedMs));
  }
  return outcome.result;
}
