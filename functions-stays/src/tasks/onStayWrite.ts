import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { Timestamp } from 'firebase-admin/firestore';
import type { Firestore, Transaction } from 'firebase-admin/firestore';

import {
  STAY_COLLECTIONS,
  StayDoc,
  StayListingDoc,
  StayTaskDoc,
  Ymd,
} from '@sfc/functions-shared/stays/contracts';
import { canonicalIanaZone, facilityToday } from '@sfc/functions-shared/stays/dates';
import { notificationId, taskIdTurnover } from '@sfc/functions-shared/stays/ids';
import {
  TurnoverPlan,
  inactiveTurnoverDigest,
  isArrival,
  isInactiveTurnoverDigest,
  planTurnover,
} from '@sfc/functions-shared/stays/turnoverPlan';

import { loadControls } from '../common/controls';
import { StayNotificationInput, writeStayNotifications } from '../common/notify';
import { evaluateStaysGate, loadStaysGate } from '../common/serverConfig';
import { STAYS_RUNTIME } from '../common/guards';
import { shortDate, turnoverRoute } from '../bookings/shared';

/**
 * staysOnStayWrite (spec §6.6): keeps each stay's automatic turnover task,
 * stayTasks/turnover_{stayId}, in step with the bookings.
 *
 * On a change to a stay's dates, times, listing, status, kind or arrival it
 * re-plans that stay's turnover and its predecessor's on the same listing
 * (whose next arrival, and so due-by time, may have moved). A task is
 * written only when its plan digest changed. Done tasks are never reopened;
 * a cancelled, removed or no-show stay cancels its to-do task, or flags one
 * already in progress or done. It never writes to stays.
 *
 * What the trigger cannot see (bookings from before turnovers were on,
 * changes made while Stays was paused) is caught up by reconcileTurnovers.
 */

export const SYSTEM_ACTOR = 'system:stays-trigger';

/** The stay fields a turnover depends on. */
const PLAN_FIELDS = ['checkIn', 'checkOut', 'checkInTime', 'checkOutTime', 'listingId', 'status', 'kind', 'arrivalState'] as const;

export function turnoverRelevantChange(before: StayDoc | null, after: StayDoc | null): boolean {
  if (!before || !after) return before !== after;
  return PLAN_FIELDS.some((f) => before[f] !== after[f]);
}

export interface TriggerDeps {
  db: () => Firestore;
  now: () => number;
}

export function defaultTriggerDeps(): TriggerDeps {
  return { db: () => admin.firestore(), now: () => Date.now() };
}

/**
 * The facility may run Stays automation right now: the platform gate is
 * open (a paused or unlisted facility changes nothing), the module is on and
 * its zone confirmed. Returns the zone, or null.
 */
export async function automationZone(db: Firestore, facilityId: string, nowMs: number, need: 'turnovers' | 'module') {
  const gate = await loadStaysGate(db, nowMs);
  const { allowed, paused } = evaluateStaysGate(gate, facilityId);
  if (!allowed || paused) return null;
  const controls = await loadControls(db, facilityId);
  if (controls.moduleEnabled !== true) return null;
  if (need === 'turnovers' && controls.turnoverTasksEnabled !== true) return null;
  const tz = canonicalIanaZone(controls.timeZone);
  if (!tz || !controls.timeZoneConfirmedAt) return null;
  return { tz, controls };
}

type TaskWrite =
  | { op: 'none' }
  | { op: 'create'; doc: StayTaskDoc }
  | { op: 'update'; patch: Partial<StayTaskDoc> };

/**
 * What to do to a turnover task given its plan (pure; see the header).
 * `now` stamps the write; `today` stops a task being made for a checkout
 * already past (a stay imported after the fact).
 */
export function decideTaskWrite(
  facilityId: string,
  stayId: string,
  existing: StayTaskDoc | null,
  plan: TurnoverPlan | null,
  today: Ymd,
  now: Timestamp,
): TaskWrite {
  const stamp = { updatedAt: now, updatedBy: SYSTEM_ACTOR };
  if (!plan) {
    const inactive = inactiveTurnoverDigest(stayId);
    if (!existing || existing.plannedDigest === inactive) return { op: 'none' };
    if (existing.status === 'todo') return { op: 'update', patch: { status: 'cancelled', plannedDigest: inactive, ...stamp } };
    // Work already started or finished is flagged for her to look at, never undone.
    if (existing.status === 'in_progress' || existing.status === 'done') {
      return { op: 'update', patch: { needsAttention: true, plannedDigest: inactive, ...stamp } };
    }
    return { op: 'none' };
  }
  const t = plan.task;
  const planned = {
    listingId: t.listingId,
    stayId: t.stayId,
    nextStayId: t.nextStayId,
    title: t.title,
    dueStartAt: Timestamp.fromMillis(t.dueStartAtMs),
    dueStartLocal: t.dueStartLocal,
    dueByAt: Timestamp.fromMillis(t.dueByAtMs),
    dueByLocal: t.dueByLocal,
    dueDate: t.dueDate,
    sameDayTurn: t.sameDayTurn,
    plannedDigest: plan.digest,
  };
  if (!existing) {
    if (t.dueDate < today) return { op: 'none' };
    return {
      op: 'create',
      doc: {
        facilityId,
        category: 'turnover',
        ...planned,
        notes: '',
        priority: t.priority,
        status: 'todo',
        needsAttention: false,
        assigneeUid: t.assigneeUid,
        assigneeName: t.assigneeName,
        checklist: t.checklist.map((i) => ({ id: i.id, label: i.label, done: false, doneAt: null, doneBy: null })),
        suppliesLow: [],
        issueNote: '',
        photoPaths: [],
        startedAt: null,
        completedAt: null,
        completedBy: null,
        createdBy: SYSTEM_ACTOR,
        createdAt: now,
        ...stamp,
      },
    };
  }
  if (existing.plannedDigest === plan.digest) return { op: 'none' };
  // Done is never reopened, and a skip was a person's decision.
  if (existing.status === 'done' || existing.status === 'skipped') return { op: 'none' };
  const wasInactive = isInactiveTurnoverDigest(existing.plannedDigest);
  if (existing.status === 'cancelled') {
    // Reopen only a task this trigger cancelled (its stay came back), never one a person cancelled.
    if (!wasInactive || t.dueDate < today) return { op: 'none' };
    return {
      op: 'update',
      patch: { ...planned, status: 'todo', needsAttention: false, priority: t.sameDayTurn ? 'high' : 'normal', ...stamp },
    };
  }
  // A same-day turn is high priority; one that stops being same-day drops back, otherwise a person's choice stands.
  const priority = t.sameDayTurn ? 'high' : existing.sameDayTurn ? 'normal' : existing.priority ?? 'normal';
  const patch: Partial<StayTaskDoc> = { ...planned, priority, ...stamp };
  if (wasInactive) patch.needsAttention = false;
  return { op: 'update', patch };
}

function staysCol(db: Firestore, facilityId: string) {
  return db.collection('facilities').doc(facilityId).collection(STAY_COLLECTIONS.stays);
}

function tasksCol(db: Firestore, facilityId: string) {
  return db.collection('facilities').doc(facilityId).collection(STAY_COLLECTIONS.tasks);
}

/** The next arrival on the listing on or after `from`, other than `stayId`. */
async function nextArrival(tx: Transaction, db: Firestore, facilityId: string, listingId: string, from: Ymd, stayId: string) {
  const snap = await tx.get(staysCol(db, facilityId).where('listingId', '==', listingId).where('checkIn', '>=', from).orderBy('checkIn').limit(10));
  for (const d of snap.docs) {
    if (d.id === stayId) continue;
    const doc = d.data() as StayDoc;
    if (isArrival(doc)) return { stayId: d.id, ...doc };
  }
  return null;
}

/** The stay whose checkout comes last on or before `onOrBefore` on the listing: the one whose turnover leads into `stayId`. */
async function predecessorOf(db: Firestore, facilityId: string, listingId: string, onOrBefore: Ymd, stayId: string): Promise<string | null> {
  const snap = await staysCol(db, facilityId)
    .where('listingId', '==', listingId)
    .where('checkOut', '<=', onOrBefore)
    .orderBy('checkOut', 'desc')
    .limit(10)
    .get();
  for (const d of snap.docs) {
    if (d.id === stayId) continue;
    const doc = d.data() as StayDoc;
    if (isArrival(doc)) return d.id;
  }
  return null;
}

export interface ReplanResult {
  taskId: string;
  write: TaskWrite['op'];
  /** The task after the write, when one exists. */
  task: StayTaskDoc | null;
  listingName: string;
}

/** Re-plans one stay's turnover in a transaction (fresh stay, next arrival and task reads). */
export async function replanTurnover(
  db: Firestore,
  facilityId: string,
  stayId: string,
  zone: { tz: string; controls: Awaited<ReturnType<typeof loadControls>> },
  listings: Map<string, StayListingDoc | null>,
  nowMs: number,
): Promise<ReplanResult> {
  const taskId = taskIdTurnover(stayId);
  const now = Timestamp.fromMillis(nowMs);
  const today = facilityToday(zone.tz, nowMs);
  const listingFor = async (listingId: string): Promise<StayListingDoc | null> => {
    if (!listings.has(listingId)) {
      const snap = await db.collection('facilities').doc(facilityId).collection(STAY_COLLECTIONS.listings).doc(listingId).get();
      listings.set(listingId, snap.exists ? (snap.data() as StayListingDoc) : null);
    }
    return listings.get(listingId) ?? null;
  };
  // Listings are read before the transaction: they change rarely, and a task
  // planned from a just-edited listing is re-planned on the stay's next change.
  const pre = await staysCol(db, facilityId).doc(stayId).get();
  if (pre.exists) await listingFor((pre.data() as StayDoc).listingId);

  return db.runTransaction(async (tx) => {
    const staySnap = await tx.get(staysCol(db, facilityId).doc(stayId));
    const stay = staySnap.exists ? (staySnap.data() as StayDoc) : null;
    const listing = stay ? await listingFor(stay.listingId) : null;
    const next = stay ? await nextArrival(tx, db, facilityId, stay.listingId, stay.checkOut, stayId) : null;
    const taskRef = tasksCol(db, facilityId).doc(taskId);
    const taskSnap = await tx.get(taskRef);
    const existing = taskSnap.exists ? (taskSnap.data() as StayTaskDoc) : null;
    const plan = stay && listing ? planTurnover({ stayId, ...stay }, next, listing, zone.controls) : null;
    const write = decideTaskWrite(facilityId, stayId, existing, plan, today, now);
    let task: StayTaskDoc | null = existing;
    if (write.op === 'create') {
      tx.create(taskRef, write.doc);
      task = write.doc;
    } else if (write.op === 'update') {
      tx.update(taskRef, write.patch);
      task = { ...(existing as StayTaskDoc), ...write.patch };
    }
    return { taskId, write: write.op, task, listingName: listing?.name ?? stay?.listingName ?? 'a listing' };
  });
}

/** A same-day turn from today on with nobody to do it: she hears about it once per due day. */
export function unassignedNotification(facilityId: string, r: ReplanResult, today: Ymd): StayNotificationInput | null {
  const t = r.task;
  if (!t || r.write === 'none' || t.status !== 'todo' || !t.sameDayTurn || t.assigneeUid || t.dueDate < today) return null;
  return {
    id: notificationId({ kind: 'unassigned', taskId: r.taskId, dueDate: t.dueDate }),
    type: 'STAY_TURNOVER_UNASSIGNED',
    message: `Same-day turnover at ${r.listingName} on ${shortDate(t.dueDate)} has nobody assigned.`,
    metadata: {
      taskId: r.taskId,
      ...(t.stayId ? { stayId: t.stayId } : {}),
      ...(t.listingId ? { listingId: t.listingId } : {}),
      route: turnoverRoute(facilityId, r.taskId),
    },
  };
}

export interface StayWriteOutcome {
  replanned: ReplanResult[];
  notified: string[];
}

export async function handleStayWrite(
  facilityId: string,
  stayId: string,
  before: StayDoc | null,
  after: StayDoc | null,
  deps: TriggerDeps = defaultTriggerDeps(),
): Promise<StayWriteOutcome> {
  const outcome: StayWriteOutcome = { replanned: [], notified: [] };
  if (!turnoverRelevantChange(before, after)) return outcome;
  const db = deps.db();
  const nowMs = deps.now();
  const zone = await automationZone(db, facilityId, nowMs, 'turnovers');
  if (!zone) return outcome;

  // This stay, and the stay before it on each listing it was or is on.
  const anchors = new Set<string>([stayId]);
  for (const s of [before, after]) {
    if (!s) continue;
    const pred = await predecessorOf(db, facilityId, s.listingId, s.checkIn, stayId);
    if (pred) anchors.add(pred);
  }
  const listings = new Map<string, StayListingDoc | null>();
  for (const id of anchors) {
    outcome.replanned.push(await replanTurnover(db, facilityId, id, zone, listings, nowMs));
  }

  const today = facilityToday(zone.tz, nowMs);
  const notices = outcome.replanned.map((r) => unassignedNotification(facilityId, r, today)).filter((n): n is StayNotificationInput => !!n);
  if (notices.length > 0) {
    const result = await writeStayNotifications(db, facilityId, notices, Timestamp.fromMillis(nowMs));
    outcome.notified = result.created;
  }
  return outcome;
}

/** The most bookings one catch-up re-plans: the soonest checkouts first. */
export const RECONCILE_MAX_STAYS = 500;
/** Re-plans run this many at a time; each writes only its own task, so they never contend. */
const RECONCILE_CONCURRENCY = 8;

export interface ReconcileTurnoversResult {
  /** False when turnovers are not running (off, Stays off or paused, zone unconfirmed): nothing was read or written. */
  ran: boolean;
  /** Bookings looked at (checking out today or later). */
  stays: number;
  created: number;
  updated: number;
  /** Bookings whose re-plan threw; each is logged and retried on the next run. */
  failed: number;
  /** More bookings were due than one run covers; the rest wait for the next run. */
  truncated: boolean;
  notified: string[];
}

/**
 * The turnover catch-up. The trigger re-plans a task only when its booking
 * changes, and does nothing while turnovers or Stays are off or paused, so on
 * its own it misses: bookings made or imported before turnovers were turned
 * on, a cancellation made while the kill switch was on, and a trigger run
 * that failed. This re-plans the task of every booking checking out today or
 * later (up to RECONCILE_MAX_STAYS), each exactly as the trigger would, and
 * writes only the tasks whose plan changed, so a run with nothing to catch up
 * writes nothing.
 *
 * staysSetControls runs it when turnovers start; staysSaveListing runs it for
 * one listing when an edit changes what its turnovers say (the trigger sees
 * only booking changes); the nightly job (WP2's 03:00 drift pass) runs it to
 * heal what a pause or a failed trigger left behind.
 */
export async function reconcileTurnovers(
  db: Firestore,
  facilityId: string,
  nowMs: number,
  opts: { listingId?: string } = {},
): Promise<ReconcileTurnoversResult> {
  const result: ReconcileTurnoversResult = { ran: false, stays: 0, created: 0, updated: 0, failed: 0, truncated: false, notified: [] };
  const zone = await automationZone(db, facilityId, nowMs, 'turnovers');
  if (!zone) return result;
  result.ran = true;
  const today = facilityToday(zone.tz, nowMs);
  // Every status: a cancelled or removed booking's leftover to-do is cancelled too.
  // One past the cap is read, so "truncated" means a booking really was left out.
  const scope = opts.listingId ? staysCol(db, facilityId).where('listingId', '==', opts.listingId) : staysCol(db, facilityId);
  const snap = await scope.where('checkOut', '>=', today).orderBy('checkOut').limit(RECONCILE_MAX_STAYS + 1).get();
  const docs = snap.docs.slice(0, RECONCILE_MAX_STAYS);
  result.stays = docs.length;
  result.truncated = snap.size > RECONCILE_MAX_STAYS;
  if (result.truncated) {
    functions.logger.warn('stays: turnover catch-up covered only the soonest bookings', {
      facilityId,
      listingId: opts.listingId ?? null,
      limit: RECONCILE_MAX_STAYS,
    });
  }

  const listings = new Map<string, StayListingDoc | null>();
  const ids = docs.map((d) => d.id);
  const replanned: ReplanResult[] = [];
  // One booking that cannot be re-planned (a trigger racing it to create the
  // same task, say) is logged and left for the next run, not allowed to stop the rest.
  const replanOne = async (stayId: string): Promise<ReplanResult | null> => {
    try {
      return await replanTurnover(db, facilityId, stayId, zone, listings, nowMs);
    } catch (error) {
      result.failed++;
      functions.logger.warn('stays: turnover catch-up skipped a booking', {
        facilityId,
        stayId,
        error: error instanceof Error ? error.message : String(error),
      });
      return null;
    }
  };
  for (let i = 0; i < ids.length; i += RECONCILE_CONCURRENCY) {
    const chunk = await Promise.all(ids.slice(i, i + RECONCILE_CONCURRENCY).map(replanOne));
    replanned.push(...chunk.filter((r): r is ReplanResult => r !== null));
  }
  result.created = replanned.filter((r) => r.write === 'create').length;
  result.updated = replanned.filter((r) => r.write === 'update').length;

  const notices = replanned.map((r) => unassignedNotification(facilityId, r, today)).filter((n): n is StayNotificationInput => !!n);
  if (notices.length > 0) {
    result.notified = (await writeStayNotifications(db, facilityId, notices, Timestamp.fromMillis(nowMs))).created;
  }
  return result;
}

export const staysOnStayWrite = functions
  .runWith(STAYS_RUNTIME.trigger)
  .firestore.document('facilities/{facilityId}/stays/{stayId}')
  .onWrite(async (change, context) => {
    const before = change.before.exists ? (change.before.data() as StayDoc) : null;
    const after = change.after.exists ? (change.after.data() as StayDoc) : null;
    try {
      await handleStayWrite(context.params.facilityId as string, context.params.stayId as string, before, after);
    } catch (error) {
      // Not retried: the stay's next change, or its neighbour's, re-plans the task.
      functions.logger.error('staysOnStayWrite failed', {
        facilityId: context.params.facilityId,
        stayId: context.params.stayId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  });
