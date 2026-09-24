import * as functions from 'firebase-functions/v1';
import {
  DocumentData,
  DocumentReference,
  DocumentSnapshot,
  Firestore,
  Timestamp,
  Transaction,
} from 'firebase-admin/firestore';

import {
  ChannelBlockRange,
  NightClaim,
  STAYS_LIMITS,
  STAY_COLLECTIONS,
  StayConflict,
  StayControlsDoc,
  StayDoc,
  StayStatus,
  YearMonth,
  Ymd,
} from '@sfc/functions-shared/stays/contracts';
import { facilityToday, monthEnd, monthOf, monthStart, nextMonth } from '@sfc/functions-shared/stays/dates';
import { lockBucketId, sha256Hex } from '@sfc/functions-shared/stays/ids';
import {
  LockBlockInput,
  LockStayInput,
  StayLockOutcome,
  checkRequested,
  clampedNights,
  isActiveStatus,
  lockHorizon,
  lockMonthsFor,
  rebuildBuckets,
} from '@sfc/functions-shared/stays/nightLocks';

import { confirmedTimeZone } from './controls';
import { isAborted, staysError } from './errors';

/**
 * The only way a stay, a lock bucket or a channel block set is written
 * (spec §3.4 invariant 2, §6.4). One transaction:
 *  1. reads the lock buckets for the affected months of every listing involved;
 *  2. queries each listing's stays with checkOut > the first month's start,
 *     keeping those with checkIn < the last month's end;
 *  3. reads the listing's channel block docs;
 *  4. runs the caller's extra reads (folio, income id, profile);
 *  5. validates: an SFC write is refused on a hard night another stay holds,
 *     and on a soft (channel-block) night unless overrideSoftBlocks; a feed
 *     write records a conflict instead;
 *  6. rebuilds the buckets from the stays and writes only the buckets and
 *     stay statuses that changed, plus the caller's extra writes.
 *
 * The bucket docs are the serialization point: two writers on the same
 * listing-month contend and one retries, so two browsers cannot book the
 * same night, and cancelling a conflict's winner hands its nights back in the
 * same commit.
 */

export interface StayMutation {
  stayId: string;
  /** The stay as it should be after this write; null deletes it, releasing its nights. */
  next: StayDoc | null;
  /** When set, the stored stay's `version` must equal it (0: the stay must not exist yet). */
  expectedVersion?: number;
  /** 'sfc' writes are validated and refused on conflict; 'feed' writes record the conflict. */
  mode: 'sfc' | 'feed';
  overrideSoftBlocks?: boolean;
  /**
   * An idempotent create: when the stay already exists this mutation is
   * skipped (listed in plan.skipped) and nothing about that stay changes, so
   * a retried request returns `created:false`.
   */
  createOnly?: boolean;
}

export interface ChannelBlockUpdate {
  channelId: string;
  listingId: string;
  /** Kept from the stored doc when omitted. */
  provider?: string;
  /** Replaces the feed's whole set (spec §3.4 invariant 4); [] removes every block. */
  ranges: ChannelBlockRange[];
}

/** A rebuild with no mutation: the daily drift repair, ≤20 months per listing per call. */
export interface ListingRebuild {
  listingId: string;
  months: YearMonth[];
}

export interface StayWritePlan {
  facilityId: string;
  nowMs: number;
  todayYmd: Ymd;
  clampFrom: Ymd;
  clampTo: Ymd;
  /** The stored docs of the mutated stays (null: did not exist). */
  before: Record<string, StayDoc | null>;
  /** What was written for each mutated stay (null: deleted). Skipped createOnly stays are absent. */
  after: Record<string, StayDoc | null>;
  /** createOnly mutations whose stay already existed. */
  skipped: string[];
  /** The months rebuilt per listing. */
  listingMonths: Record<string, YearMonth[]>;
  outcomes: Record<string, StayLockOutcome>;
}

/** The transaction as extraWrites sees it: writes only (every read happens before). */
export interface WriteOnlyTransaction {
  set(ref: DocumentReference, data: DocumentData, options?: { merge?: boolean }): WriteOnlyTransaction;
  update(ref: DocumentReference, data: DocumentData): WriteOnlyTransaction;
  create(ref: DocumentReference, data: DocumentData): WriteOnlyTransaction;
  delete(ref: DocumentReference): WriteOnlyTransaction;
}

export interface ApplyStayMutationsInput {
  db: Firestore;
  facilityId: string;
  controls: StayControlsDoc;
  mutations: StayMutation[];
  channelBlockUpdates?: ChannelBlockUpdate[];
  rebuild?: ListingRebuild[];
  extraReads?: DocumentReference[];
  /** Income, folio, profile, private and access writes. Must not read; may throw to abort. */
  extraWrites?: (tx: WriteOnlyTransaction, snaps: DocumentSnapshot[], plan: StayWritePlan) => void;
  /** updatedBy on stays whose status changed because of this write. */
  actor?: string;
  nowMs?: number;
  /** Transaction attempts before `contention` (default 5). */
  maxAttempts?: number;
}

export interface StatusChange {
  stayId: string;
  from: StayStatus | null;
  to: StayStatus | null;
}

export interface ApplyStayMutationsResult {
  plan: StayWritePlan;
  outcomes: Record<string, StayLockOutcome>;
  /** Bucket doc ids written or deleted. */
  changedBuckets: string[];
  statusChanges: StatusChange[];
}

function facilityCol(db: Firestore, facilityId: string, name: string) {
  return db.collection('facilities').doc(facilityId).collection(name);
}

function tsMillis(value: unknown): number | null {
  if (value && typeof (value as Timestamp).toMillis === 'function') return (value as Timestamp).toMillis();
  return null;
}

/** A stable fingerprint of a doc, to skip writes that change nothing. */
export function docDigest(doc: unknown): string {
  const canonical = (value: unknown): unknown => {
    const ms = tsMillis(value);
    if (ms !== null) return { __ts: ms };
    if (Array.isArray(value)) return value.map(canonical);
    if (value && typeof value === 'object') {
      const out: Record<string, unknown> = {};
      for (const key of Object.keys(value as Record<string, unknown>).sort()) {
        const v = (value as Record<string, unknown>)[key];
        if (v !== undefined) out[key] = canonical(v);
      }
      return out;
    }
    return value;
  };
  return sha256Hex(JSON.stringify(canonical(doc)));
}

function toLockInput(stayId: string, doc: StayDoc): LockStayInput {
  return {
    stayId,
    status: doc.status,
    kind: doc.kind,
    source: doc.source,
    checkIn: doc.checkIn,
    checkOut: doc.checkOut,
    createdAtMs: typeof doc.createdAtMs === 'number' ? doc.createdAtMs : 0,
  };
}

function isActive(doc: StayDoc | null | undefined): doc is StayDoc {
  return !!doc && isActiveStatus(doc.status);
}

function sameList(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

function monthsBetween(first: YearMonth, last: YearMonth): YearMonth[] {
  const out: YearMonth[] = [];
  for (let m = first; m <= last; m = nextMonth(m)) out.push(m);
  return out;
}

function conflictLabel(doc: StayDoc | undefined): string {
  if (!doc) return 'Another booking';
  const who =
    doc.kind === 'owner_block'
      ? 'Owner block'
      : doc.kind === 'maintenance_block'
        ? 'Maintenance block'
        : doc.guestDisplayName || 'Guest';
  return `${who} · ${doc.checkIn} to ${doc.checkOut}`;
}

/** The conflict field for a stay's outcome, keeping acknowledgement when nothing changed. */
function conflictFor(outcome: StayLockOutcome, stored: StayConflict | null | undefined, now: Timestamp): StayConflict | null {
  if (outcome.status !== 'conflict') return null;
  if (stored && sameList(stored.stayIds ?? [], outcome.conflictStayIds) && sameList(stored.nights ?? [], outcome.conflictNights)) {
    return stored;
  }
  return {
    stayIds: outcome.conflictStayIds,
    nights: outcome.conflictNights,
    detectedAt: now,
    acknowledgedAt: null,
    acknowledgedBy: null,
    note: null,
  };
}

interface ListingState {
  listingId: string;
  /** Months whose nights this write may change. */
  requested: Set<YearMonth>;
  /** Months rebuilt (requested, plus the rest of the affected stays' months when that fits). */
  months: YearMonth[];
  stays: Map<string, StayDoc>;
  blocks: Map<string, { provider: string; ranges: ChannelBlockRange[]; exists: boolean }>;
  bucketSnaps: Map<YearMonth, DocumentSnapshot>;
}

/** Month chunks (≤20 each) covering the whole lock horizon, for the drift rebuild. */
export function driftRebuildMonthChunks(todayYmd: Ymd): YearMonth[][] {
  const { clampFrom, clampTo } = lockHorizon(todayYmd);
  const all = monthsBetween(monthOf(clampFrom), monthOf(clampTo));
  const chunks: YearMonth[][] = [];
  for (let i = 0; i < all.length; i += STAYS_LIMITS.bucketsPerListingPerTransaction) {
    chunks.push(all.slice(i, i + STAYS_LIMITS.bucketsPerListingPerTransaction));
  }
  return chunks;
}

export async function applyStayMutations(input: ApplyStayMutationsInput): Promise<ApplyStayMutationsResult> {
  const { db, facilityId, controls } = input;
  const mutations = input.mutations ?? [];
  const nowMs = input.nowMs ?? Date.now();
  const actor = input.actor ?? 'system:stays-writer';

  if (mutations.length > STAYS_LIMITS.stayMutationsPerTransaction) {
    throw staysError('invalid-argument', 'invalid_argument', 'Too many stay changes in one write.');
  }
  const ids = new Set<string>();
  for (const m of mutations) {
    if (ids.has(m.stayId)) {
      throw staysError('invalid-argument', 'invalid_argument', 'A stay appears twice in one write.');
    }
    ids.add(m.stayId);
    if (m.next && m.next.facilityId !== facilityId) {
      throw staysError('invalid-argument', 'invalid_argument', 'A stay must belong to this facility.');
    }
  }

  const tz = confirmedTimeZone(controls);
  const todayYmd = facilityToday(tz, nowMs);
  const { clampFrom, clampTo } = lockHorizon(todayYmd);
  const now = Timestamp.fromMillis(nowMs);

  const staysCol = facilityCol(db, facilityId, STAY_COLLECTIONS.stays);
  const bucketsCol = facilityCol(db, facilityId, STAY_COLLECTIONS.nightLocks);
  const blocksCol = facilityCol(db, facilityId, STAY_COLLECTIONS.channelBlocks);

  const run = async (tx: Transaction): Promise<ApplyStayMutationsResult> => {
    // --- Reads: the mutated stays --------------------------------------
    const storedSnaps = mutations.length ? await tx.getAll(...mutations.map((m) => staysCol.doc(m.stayId))) : [];
    const before: Record<string, StayDoc | null> = {};
    const skipped: string[] = [];
    const live: StayMutation[] = [];
    mutations.forEach((m, i) => {
      const snap = storedSnaps[i];
      const stored = snap.exists ? (snap.data() as StayDoc) : null;
      before[m.stayId] = stored;
      if (m.createOnly && stored) {
        skipped.push(m.stayId);
        return;
      }
      if (m.expectedVersion !== undefined) {
        const version = stored ? (Number.isInteger(stored.version) ? stored.version : 0) : 0;
        if (version !== m.expectedVersion || (m.expectedVersion === 0 && stored)) {
          throw staysError('aborted', 'version_mismatch', 'This stay changed since you opened it. Reload and try again.', {
            stayId: m.stayId,
            version,
          });
        }
      }
      live.push(m);
    });

    // --- Which listings and months this write touches --------------------
    const listings = new Map<string, ListingState>();
    const listing = (listingId: string): ListingState => {
      let s = listings.get(listingId);
      if (!s) {
        s = { listingId, requested: new Set(), months: [], stays: new Map(), blocks: new Map(), bucketSnaps: new Map() };
        listings.set(listingId, s);
      }
      return s;
    };
    const addStayMonths = (doc: StayDoc | null) => {
      if (!isActive(doc)) return;
      const s = listing(doc.listingId);
      for (const m of lockMonthsFor(doc.checkIn, doc.checkOut, clampFrom, clampTo)) s.requested.add(m);
    };
    for (const m of live) {
      addStayMonths(before[m.stayId]);
      addStayMonths(m.next);
      // A stay with no nights in the horizon still needs its listing loaded to be written.
      if (m.next) listing(m.next.listingId);
    }

    const blockUpdates = input.channelBlockUpdates ?? [];
    const storedBlockSnaps = blockUpdates.length ? await tx.getAll(...blockUpdates.map((u) => blocksCol.doc(u.channelId))) : [];
    blockUpdates.forEach((u, i) => {
      const s = listing(u.listingId);
      const stored = storedBlockSnaps[i].exists ? (storedBlockSnaps[i].data() as { ranges?: ChannelBlockRange[] }) : null;
      for (const r of [...(stored?.ranges ?? []), ...u.ranges]) {
        for (const month of lockMonthsFor(r.checkIn, r.checkOut, clampFrom, clampTo)) s.requested.add(month);
      }
    });
    for (const r of input.rebuild ?? []) {
      const s = listing(r.listingId);
      for (const month of r.months) s.requested.add(month);
    }

    for (const s of listings.values()) {
      if (s.requested.size > STAYS_LIMITS.bucketsPerListingPerTransaction) {
        throw staysError('invalid-argument', 'invalid_argument', 'A write may touch at most 20 months of one listing.', {
          listingId: s.listingId,
        });
      }
    }

    // --- Reads: each listing's stays, widened once to whole stays -------
    const loadStays = async (s: ListingState, months: YearMonth[]) => {
      s.stays.clear();
      if (months.length === 0) return;
      const sorted = [...months].sort();
      const start = monthStart(sorted[0]);
      const end = monthEnd(sorted[sorted.length - 1]);
      const snap = await tx.get(staysCol.where('listingId', '==', s.listingId).where('checkOut', '>', start));
      const wanted = new Set(months);
      for (const d of snap.docs) {
        const doc = d.data() as StayDoc;
        if (!(doc.checkIn < end)) continue;
        // Only stays with a night in one of the months matter to them.
        const touches = lockMonthsFor(doc.checkIn, doc.checkOut, clampFrom, clampTo).some((m) => wanted.has(m));
        if (touches || ids.has(d.id)) s.stays.set(d.id, doc);
      }
    };
    for (const s of listings.values()) {
      const requested = [...s.requested].sort();
      await loadStays(s, requested);
      // A stay's status depends on all its nights, so rebuild every month of
      // each active stay the write touches, when that still fits.
      const widened = new Set(requested);
      for (const doc of s.stays.values()) {
        if (isActive(doc)) for (const m of lockMonthsFor(doc.checkIn, doc.checkOut, clampFrom, clampTo)) widened.add(m);
      }
      if (widened.size > requested.length && widened.size <= STAYS_LIMITS.bucketsPerListingPerTransaction) {
        s.months = [...widened].sort();
        await loadStays(s, s.months);
      } else {
        s.months = requested;
      }
    }

    // --- Reads: channel blocks and buckets --------------------------------
    for (const s of listings.values()) {
      const snap = await tx.get(blocksCol.where('listingId', '==', s.listingId));
      for (const d of snap.docs) {
        const data = d.data() as { provider?: string; ranges?: ChannelBlockRange[] };
        s.blocks.set(d.id, {
          provider: typeof data.provider === 'string' ? data.provider : 'other',
          ranges: Array.isArray(data.ranges) ? data.ranges : [],
          exists: true,
        });
      }
    }
    const bucketRefs: { s: ListingState; month: YearMonth; ref: DocumentReference }[] = [];
    for (const s of listings.values()) {
      for (const month of s.months) bucketRefs.push({ s, month, ref: bucketsCol.doc(lockBucketId(s.listingId, month)) });
    }
    const bucketSnaps = bucketRefs.length ? await tx.getAll(...bucketRefs.map((b) => b.ref)) : [];
    bucketRefs.forEach((b, i) => b.s.bucketSnaps.set(b.month, bucketSnaps[i]));

    const extraSnaps = input.extraReads?.length ? await tx.getAll(...input.extraReads) : [];

    // --- Apply in memory ----------------------------------------------------
    for (const m of live) {
      const old = before[m.stayId];
      if (old) listings.get(old.listingId)?.stays.delete(m.stayId);
      if (m.next) listing(m.next.listingId).stays.set(m.stayId, m.next);
    }
    for (const u of blockUpdates) {
      const s = listing(u.listingId);
      const stored = s.blocks.get(u.channelId);
      s.blocks.set(u.channelId, {
        provider: u.provider ?? stored?.provider ?? 'other',
        ranges: u.ranges,
        exists: true,
      });
    }

    const blockInputs = (s: ListingState): LockBlockInput[] =>
      [...s.blocks.entries()].map(([channelId, b]) => ({ channelId, provider: b.provider, ranges: b.ranges }));
    const lockInputs = (stays: Map<string, StayDoc>, without?: string): LockStayInput[] =>
      [...stays.entries()].filter(([id]) => id !== without).map(([id, doc]) => toLockInput(id, doc));

    // --- Validate SFC writes ------------------------------------------------
    for (const m of live) {
      if (m.mode !== 'sfc' || !isActive(m.next)) continue;
      const s = listing(m.next.listingId);
      const old = before[m.stayId];
      const kept = new Set(
        isActive(old) && old.listingId === m.next.listingId ? clampedNights(old.checkIn, old.checkOut, clampFrom, clampTo) : [],
      );
      // Only nights this write adds are checked: re-saving a stay must not
      // trip over a later stay that lost those nights to it.
      const added = clampedNights(m.next.checkIn, m.next.checkOut, clampFrom, clampTo).filter((n) => !kept.has(n));
      if (added.length === 0) continue;
      const others = rebuildBuckets({
        months: [...new Set(added.map(monthOf))],
        stays: lockInputs(s.stays, m.stayId),
        blocks: blockInputs(s),
        clampFrom,
        clampTo,
      });
      const check = checkRequested(others.buckets, m.stayId, added);
      if (check.hardConflicts.length > 0) {
        throw staysError('already-exists', 'hard_conflict', 'Those nights are already booked.', {
          nights: check.hardConflicts.map((c) => ({
            date: c.date,
            stayId: c.stayId,
            label: conflictLabel(s.stays.get(c.stayId)),
          })),
        });
      }
      if (check.softNights.length > 0 && m.overrideSoftBlocks !== true) {
        throw staysError(
          'failed-precondition',
          'soft_block',
          'Some of those nights are blocked on a channel calendar. Confirm to book over them.',
          { dates: check.softNights },
        );
      }
    }

    // --- Rebuild -------------------------------------------------------------
    const outcomes: Record<string, StayLockOutcome> = {};
    const rebuilt = new Map<string, ReturnType<typeof rebuildBuckets>>();
    for (const s of listings.values()) {
      const r = rebuildBuckets({ months: s.months, stays: lockInputs(s.stays), blocks: blockInputs(s), clampFrom, clampTo });
      rebuilt.set(s.listingId, r);
      Object.assign(outcomes, r.outcomes);
    }

    /** Whether every horizon night of a stay was rebuilt, so its outcome is complete. */
    const fullyRebuilt = (doc: StayDoc): boolean => {
      const s = listings.get(doc.listingId);
      if (!s) return false;
      const months = new Set(s.months);
      return lockMonthsFor(doc.checkIn, doc.checkOut, clampFrom, clampTo).every((m) => months.has(m));
    };

    const listingMonths: Record<string, YearMonth[]> = {};
    for (const s of listings.values()) listingMonths[s.listingId] = s.months;
    const plan: StayWritePlan = {
      facilityId,
      nowMs,
      todayYmd,
      clampFrom,
      clampTo,
      before,
      after: {},
      skipped,
      listingMonths,
      outcomes,
    };

    // --- Writes --------------------------------------------------------------
    const statusChanges: StatusChange[] = [];
    const changedBuckets: string[] = [];

    for (const m of live) {
      const old = before[m.stayId];
      const ref = staysCol.doc(m.stayId);
      if (!m.next) {
        plan.after[m.stayId] = null;
        if (old) {
          tx.delete(ref);
          statusChanges.push({ stayId: m.stayId, from: old.status, to: null });
        }
        continue;
      }
      let next: StayDoc = m.next;
      const outcome = outcomes[m.stayId];
      if (isActiveStatus(next.status)) {
        if (outcome && fullyRebuilt(next)) {
          next = { ...next, status: outcome.status, conflict: conflictFor(outcome, old?.conflict, now) };
        }
      } else if (next.conflict) {
        next = { ...next, conflict: null };
      }
      plan.after[m.stayId] = next;
      if (!old || docDigest(old) !== docDigest(next)) tx.set(ref, next);
      if ((old?.status ?? null) !== next.status) statusChanges.push({ stayId: m.stayId, from: old?.status ?? null, to: next.status });
    }

    const mutated = new Set(live.map((m) => m.stayId));
    for (const s of listings.values()) {
      for (const [stayId, doc] of s.stays) {
        if (mutated.has(stayId) || skipped.includes(stayId) || !isActive(doc)) continue;
        const outcome = outcomes[stayId];
        if (!outcome || !fullyRebuilt(doc)) continue;
        const conflict = conflictFor(outcome, doc.conflict, now);
        if (doc.status === outcome.status && conflict === (doc.conflict ?? null)) continue;
        tx.update(staysCol.doc(stayId), {
          status: outcome.status,
          conflict,
          version: (Number.isInteger(doc.version) ? doc.version : 0) + 1,
          updatedAt: now,
          updatedBy: actor,
        });
        if (doc.status !== outcome.status) statusChanges.push({ stayId, from: doc.status, to: outcome.status });
      }

      const r = rebuilt.get(s.listingId)!;
      for (const month of s.months) {
        const built = r.buckets[month];
        const snap = s.bucketSnaps.get(month);
        const storedDigest = snap?.exists ? (snap.get('digest') as string | undefined) : undefined;
        const empty = Object.keys(built.nights).length === 0;
        const ref = bucketsCol.doc(lockBucketId(s.listingId, month));
        if (empty) {
          if (snap?.exists) {
            tx.delete(ref);
            changedBuckets.push(ref.id);
          }
          continue;
        }
        if (storedDigest === built.digest) continue;
        tx.set(ref, {
          facilityId,
          listingId: s.listingId,
          month,
          nights: built.nights as Record<Ymd, NightClaim>,
          digest: built.digest,
          rebuiltAt: now,
        });
        changedBuckets.push(ref.id);
      }
    }

    for (const u of blockUpdates) {
      const s = listing(u.listingId);
      tx.set(blocksCol.doc(u.channelId), {
        facilityId,
        listingId: u.listingId,
        provider: s.blocks.get(u.channelId)?.provider ?? 'other',
        ranges: u.ranges,
        syncedAt: now,
      });
    }

    if (input.extraWrites) {
      const writeOnly: WriteOnlyTransaction = {
        set(ref, data, options) {
          if (options) tx.set(ref, data, options);
          else tx.set(ref, data);
          return writeOnly;
        },
        update(ref, data) {
          tx.update(ref, data);
          return writeOnly;
        },
        create(ref, data) {
          tx.create(ref, data);
          return writeOnly;
        },
        delete(ref) {
          tx.delete(ref);
          return writeOnly;
        },
      };
      input.extraWrites(writeOnly, extraSnaps, plan);
    }

    return { plan, outcomes, changedBuckets, statusChanges };
  };

  try {
    return await db.runTransaction(run, { maxAttempts: input.maxAttempts ?? 5 });
  } catch (error) {
    if (error instanceof functions.https.HttpsError) throw error;
    if (isAborted(error)) {
      throw staysError('aborted', 'contention', 'Someone else is changing these dates right now. Try again.');
    }
    throw error;
  }
}
