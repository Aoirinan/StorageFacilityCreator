import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getFirestore } from '@sfc/functions-shared/firestoreLazy';
import { getFacilityDataForUserOrThrow } from '@sfc/functions-shared/auth/facilityAccess';

/**
 * Delinquency Rules (consistent with Flutter app):
 * - "current": no unpaid invoices past due date
 * - "late": 1-9 days past due
 * - "overdue": 10-29 days past due
 * - "severely_overdue": 30+ days past due
 */

interface TenantData {
  /** Doc id, for logs. */
  id?: string;
  isActive: boolean;
  monthlyRate: number;
  paidThrough?: admin.firestore.Timestamp | null;
  createdAt: admin.firestore.Timestamp;
  /** Matches app `TenantAutopayModel`: revenue counts when status === 'ON'. */
  autopay?: { status?: string; enabled?: boolean };
}

function tenantAutopayOn(tenant: TenantData): boolean {
  return tenant.autopay?.status === 'ON';
}

interface UnitInput {
  id: string;
  status: string;
  tenantId?: string | null;
  /** Office, manager residence or personal-use space; see countsTowardOccupancy. */
  internalUse?: boolean;
  archived?: boolean;
  /** When the pass read the unit; a heal applies only if it is unchanged since. */
  updateTime?: admin.firestore.Timestamp;
}

/** An orphan unit to heal, with the version of it the pass read. */
interface OrphanUnit {
  id: string;
  updateTime?: admin.firestore.Timestamp;
}

/**
 * Units that count toward Total/Occupied/Vacant: every unit except archived
 * ones and internal-use space (office, manager residence, personal use,
 * `internalUse === true`). The app applies the same test
 * (FacilityStatsService.countsTowardOccupancy plus UnitService's archived
 * filter); test/fixtures/unit_occupancy_counts.json at the repo root holds the
 * cases both sides are tested against. Orphan healing below deliberately
 * still scans every unit, counted or not.
 *
 * This used to exclude `publicListingEnabled === false`, the "List on public
 * website" switch. Owners whose rental page is not live turn that off for
 * most units (86 of 89 at one facility), and the mirror then said 3 units.
 * That switch now only decides what the public map shows.
 *
 * `(archived ?? false) === false` is the exact test Flutter's UnitService
 * applies, so a stray non-boolean value is dropped by both sides rather than
 * by one. Only an exact `true` marks internal use, as in the app's UnitModel.
 */
function countsTowardOccupancy(unit: UnitInput): boolean {
  return unit.internalUse !== true && (unit.archived ?? false) === false;
}

function countCanonicalOccupied(
  units: UnitInput[],
  tenantIds: Set<string>,
): { occupiedUnits: number; orphanIds: string[] } {
  const orphanIds: string[] = [];
  let occupiedUnits = 0;
  for (const unit of units) {
    if (unit.status !== 'occupied') continue;
    const tenantId = unit.tenantId ?? null;
    const tenantExists = tenantId != null && tenantIds.has(tenantId);
    if (tenantExists) {
      occupiedUnits++;
    } else {
      orphanIds.push(unit.id);
    }
  }
  return { occupiedUnits, orphanIds };
}

/**
 * Calculate days late for a tenant (mirrors Flutter LateLogicService).
 */
function isTenantLate(
  tenant: TenantData,
  gracePeriodDays: number = 3,
  now: Date = new Date(),
): boolean {
  const startOfCurrentMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  const paidThrough = tenant.paidThrough?.toDate();

  if (!paidThrough) {
    const daysSinceCreation = Math.floor(
      (now.getTime() - tenant.createdAt.toDate().getTime()) / (1000 * 60 * 60 * 24),
    );
    if (daysSinceCreation <= 30) {
      return false;
    }
    const created = tenant.createdAt.toDate();
    if (created.getFullYear() === now.getFullYear() && created.getMonth() === now.getMonth()) {
      return false;
    }
    return true;
  }

  const graceBoundary = new Date(
    startOfCurrentMonth.getTime() - gracePeriodDays * 24 * 60 * 60 * 1000,
  );
  return paidThrough < graceBoundary;
}

function calculateDaysLate(
  tenant: TenantData,
  gracePeriodDays: number = 3,
  now: Date = new Date(),
): number {
  if (!isTenantLate(tenant, gracePeriodDays, now)) {
    return 0;
  }

  const startOfCurrentMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  const paidThrough = tenant.paidThrough?.toDate();

  if (!paidThrough) {
    const daysSinceCreation = Math.floor(
      (now.getTime() - tenant.createdAt.toDate().getTime()) / (1000 * 60 * 60 * 24),
    );
    return daysSinceCreation > 30 ? daysSinceCreation - 30 : 1;
  }

  const difference = Math.floor(
    (startOfCurrentMonth.getTime() - paidThrough.getTime()) / (1000 * 60 * 60 * 24) - gracePeriodDays,
  );
  return difference < 0 ? 0 : difference;
}

/** Everything a stats pass needs from Firestore, read before anything is written. */
interface FacilityStatsInputs {
  gracePeriodDays: number;
  units: UnitInput[];
  /** Every tenant doc id, active or archived: archiving a tenant does not free the unit. */
  allTenantIds: Set<string>;
  activeTenants: TenantData[];
}

/** Seams for tests; production passes the Firestore-backed implementations below. */
export interface FacilityStatsDeps {
  /** Null when the facility doc does not exist. */
  load: (facilityId: string) => Promise<FacilityStatsInputs | null>;
  healOrphans: (facilityId: string, orphans: OrphanUnit[]) => Promise<void>;
}

/**
 * Counts and delinquency for one facility from inputs already in hand. Units
 * are limited to counted ones (see countsTowardOccupancy); revenue and past
 * due come from active tenants only.
 *
 * A tenant doc whose dates cannot be read (no createdAt, or a paidThrough
 * that is not a Timestamp) is logged and left out of the past-due buckets;
 * it still counts as active and toward revenue. One such doc used to make
 * every pass for the facility throw, which froze its counts.
 */
function summarizeFacilityStats(
  inputs: FacilityStatsInputs,
  now: Date = new Date(),
): Record<string, number> {
  const counted = inputs.units.filter(countsTowardOccupancy);
  const { occupiedUnits } = countCanonicalOccupied(counted, inputs.allTenantIds);
  const totalUnits = counted.length;
  const availableUnits = Math.max(0, totalUnits - occupiedUnits);

  let scheduledMonthlyRevenue = 0;
  let autopayMonthlyRevenue = 0;
  let tenantsLate = 0; // 1-9 days
  let tenantsOverdue = 0; // 10-29 days
  let tenantsSeverelyOverdue = 0; // 30+ days

  for (const tenant of inputs.activeTenants) {
    // A non-number rate (e.g. a string) would turn the sum into a string.
    const rate =
      typeof tenant.monthlyRate === 'number' && Number.isFinite(tenant.monthlyRate)
        ? tenant.monthlyRate
        : 0;
    scheduledMonthlyRevenue += rate;
    if (tenantAutopayOn(tenant)) {
      autopayMonthlyRevenue += rate;
    }

    let daysLate: number;
    try {
      daysLate = calculateDaysLate(tenant, inputs.gracePeriodDays, now);
    } catch (error) {
      console.warn(
        `⚠️ [facility_stats] Tenant ${tenant.id ?? '(unknown id)'} left out of past-due counts: unreadable dates`,
        error,
      );
      continue;
    }
    if (daysLate >= 30) {
      tenantsSeverelyOverdue++;
    } else if (daysLate >= 10) {
      tenantsOverdue++;
    } else if (daysLate >= 1) {
      tenantsLate++;
    }
  }

  return {
    totalUnits,
    occupiedUnits,
    availableUnits,
    totalTenantsActive: inputs.activeTenants.length,
    scheduledMonthlyRevenue,
    autopayMonthlyRevenue,
    tenantsLate,
    tenantsOverdue,
    tenantsSeverelyOverdue,
    totalPastDue: tenantsLate + tenantsOverdue + tenantsSeverelyOverdue,
  };
}

/**
 * Null when the facility doc does not exist, with nothing else read. A
 * deleted facility's subcollection writes (a recursive delete fires one per
 * doc) used to run full passes that wrote stats/current under the deleted
 * facility and then failed with NOT_FOUND on the facility update.
 */
async function loadFacilityStatsInputs(
  facilityId: string,
  db: admin.firestore.Firestore = getFirestore(),
): Promise<FacilityStatsInputs | null> {
  const facilityDoc = await db.collection('facilities').doc(facilityId).get();
  if (!facilityDoc.exists) return null;
  const billingSettings = facilityDoc.data()?.billingSettings as
    | { gracePeriodDays?: number | string }
    | undefined;
  const rawGrace = billingSettings?.gracePeriodDays;
  const gracePeriodDays =
    typeof rawGrace === 'number'
      ? rawGrace
      : parseInt(String(rawGrace ?? ''), 10) || 3;

  // Units strictly before tenants, never in parallel. A unit is linked to its
  // tenant in the same write as the tenant doc or after it, so a tenant read
  // taken after the unit read contains that tenant. Read the other way round
  // (or concurrently), a move-in landing between the two reads looks like an
  // orphan and the heal frees a unit that was just rented.
  const unitsSnapshot = await db
    .collection('facilities')
    .doc(facilityId)
    .collection('units')
    .get();
  const units = unitsSnapshot.docs.map((doc) => ({
    ...(doc.data() as {
      status: string;
      tenantId?: string | null;
      internalUse?: boolean;
      archived?: boolean;
    }),
    id: doc.id,
    updateTime: doc.updateTime,
  }));

  const allTenantsSnapshot = await db
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .get();

  const activeTenantsSnapshot = await db
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .where('isActive', '==', true)
    .get();

  return {
    gracePeriodDays,
    units,
    allTenantIds: new Set(allTenantsSnapshot.docs.map((d) => d.id)),
    activeTenants: activeTenantsSnapshot.docs.map((d) => ({ ...(d.data() as TenantData), id: d.id })),
  };
}

/** Orphan heals written at once; bounded so a large heal cannot open thousands of writes. */
const HEAL_CONCURRENCY = 50;

/**
 * Firestore's answer when a precondition no longer holds (the unit changed
 * since the pass read it) or the unit is gone. Both mean: nothing to heal.
 */
function isStaleHealError(error: unknown): boolean {
  const code = (error as { code?: unknown } | null | undefined)?.code;
  return (
    code === 9 || // FAILED_PRECONDITION
    code === 5 || // NOT_FOUND
    code === 'failed-precondition' ||
    code === 'not-found'
  );
}

/** Writes one heal, applied only if the unit is still at `updateTime`. */
type HealWrite = (unitId: string, updateTime: admin.firestore.Timestamp) => Promise<unknown>;

/**
 * Orphan units (status=occupied, tenant missing) become available with no
 * tenant, each only if it has not changed since the pass read it.
 *
 * The heal used to be a blind batch update applied after reads up to a
 * second old. createTenant writes the tenant and then the unit, so a
 * move-in that relinked an orphan unit in between was overwritten back to
 * available. A unit that changed (or was deleted) is now skipped; its write
 * triggers another pass. Other write errors still fail the pass.
 */
async function healOrphanUnitsWith(
  facilityId: string,
  orphans: OrphanUnit[],
  write: HealWrite,
): Promise<{ healed: number; skipped: number }> {
  let healed = 0;
  let skipped = 0;
  const failures: unknown[] = [];
  for (let i = 0; i < orphans.length; i += HEAL_CONCURRENCY) {
    const chunk = orphans.slice(i, i + HEAL_CONCURRENCY);
    const results = await Promise.allSettled(
      chunk.map(async (unit) => {
        // Every unit read from Firestore has one; without it there is no
        // safe way to heal, so leave the unit for the next pass.
        if (!unit.updateTime) return false;
        await write(unit.id, unit.updateTime);
        return true;
      }),
    );
    for (const result of results) {
      if (result.status === 'fulfilled') {
        if (result.value) healed++;
        else skipped++;
      } else if (isStaleHealError(result.reason)) {
        skipped++;
      } else {
        failures.push(result.reason);
      }
    }
  }
  console.log(
    `🔧 [facility_stats] Healed ${healed} orphan unit(s) for ${facilityId}` +
      (skipped > 0 ? `; skipped ${skipped} changed since the read` : ''),
  );
  if (failures.length > 0) throw failures[0];
  return { healed, skipped };
}

async function healOrphanUnits(
  facilityId: string,
  orphans: OrphanUnit[],
  unitsRef: admin.firestore.CollectionReference = getFirestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('units'),
): Promise<void> {
  await healOrphanUnitsWith(facilityId, orphans, (unitId, updateTime) =>
    unitsRef.doc(unitId).update(
      {
        status: 'available',
        tenantId: admin.firestore.FieldValue.delete(),
        tenantName: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { lastUpdateTime: updateTime },
    ),
  );
}

const firestoreFacilityStatsDeps: FacilityStatsDeps = {
  load: loadFacilityStatsInputs,
  healOrphans: healOrphanUnits,
};

/**
 * Mirror occupied + unit-doc count onto the facility root doc, then write the
 * stats doc. The facility update goes first: it fails with NOT_FOUND for a
 * facility deleted since the pass read it, before stats/current is recreated
 * under it.
 */
async function persistFacilityStats(
  facilityId: string,
  stats: Record<string, unknown>,
  db: admin.firestore.Firestore = getFirestore(),
): Promise<void> {
  const occupied = Number(stats.occupiedUnits ?? 0);
  const unitDocCount = Number(stats.totalUnits ?? 0);
  const facilityRef = db.collection('facilities').doc(facilityId);
  await facilityRef.update({
    occupiedUnits: occupied,
    unitDocCount,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  await facilityRef.collection('stats').doc('current').set(stats, { merge: true });
}

/**
 * Compute comprehensive facility statistics.
 * Uses canonical occupancy (only count occupied if tenant exists). Heals orphan units.
 *
 * Throws when a read fails. It used to return all-zero stats instead, which
 * every caller then persisted: one transient read error blanked the facility
 * mirror that search, the super-admin totals and the facility cards show,
 * until the next unit or tenant write. Healing runs only after every read has
 * succeeded, so a partial tenant list can never free a rented unit.
 */
async function computeFacilityStats(
  facilityId: string,
  deps: FacilityStatsDeps = firestoreFacilityStatsDeps,
): Promise<Record<string, unknown> | null> {
  const inputs = await deps.load(facilityId);
  if (inputs === null) {
    // Deleted facility: nothing to heal or count.
    console.log(`⏭️ [facility_stats] Facility ${facilityId} no longer exists; nothing recomputed`);
    return null;
  }

  // Healing scans every unit (archived and internal-use too) so a stale
  // tenantId anywhere still gets cleared; only the counts are limited.
  const { orphanIds } = countCanonicalOccupied(inputs.units, inputs.allTenantIds);
  if (orphanIds.length > 0) {
    const orphanIdSet = new Set(orphanIds);
    await deps.healOrphans(
      facilityId,
      inputs.units
        .filter((unit) => orphanIdSet.has(unit.id))
        .map(({ id, updateTime }) => ({ id, updateTime })),
    );
  }

  return {
    ...summarizeFacilityStats(inputs),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

/**
 * Compute, then persist. A failed compute throws before anything is written;
 * a deleted facility (null stats) writes nothing and returns null.
 */
async function recomputeAndPersistFacilityStats(
  facilityId: string,
  compute: (facilityId: string) => Promise<Record<string, unknown> | null> = computeFacilityStats,
  persist: (facilityId: string, stats: Record<string, unknown>) => Promise<void> = persistFacilityStats,
): Promise<Record<string, unknown> | null> {
  const stats = await compute(facilityId);
  if (stats === null) return null;
  await persist(facilityId, stats);
  return stats;
}

export const facilityStatsTestUtils = {
  tenantAutopayOn,
  isTenantLate,
  calculateDaysLate,
  countCanonicalOccupied,
  countsTowardOccupancy,
  summarizeFacilityStats,
  computeFacilityStats,
  recomputeAndPersistFacilityStats,
  healOrphanUnitsWith,
  healOrphanUnits,
  loadFacilityStatsInputs,
  persistFacilityStats,
};

/**
 * Recomputing stats is O(facility size): computeFacilityStats() reads the facility
 * doc, every unit, and the tenant collection twice. That is fine for one interactive
 * edit and ruinous for a bulk write — on 2026-08-31 a load test wrote ~30,000 tenant
 * docs and each one recomputed its whole facility, turning 30k writes into ~5.0M
 * document reads in a single hour (see docs/LOAD_AND_SECURITY_TEST_REPORT.md).
 *
 * So collapse bursts instead of serving each write. The first writer claims a window
 * and recomputes; writers arriving inside that window only mark the facility dirty
 * and return. The claim holder then drains the dirty flag, so writes that landed
 * while it was computing still get a fresh pass rather than waiting for the nightly
 * job. A lone edit finds no live claim and recomputes immediately, exactly as before.
 *
 * Worst case a burst's tail is stale until the next write or
 * updateAllFacilityStatsNightly, which already exists for precisely that reason.
 */
const STATS_COALESCE_WINDOW_MS = 15_000;

/** Bounded so a long burst cannot hold an invocation open until the function times out. */
const STATS_MAX_DRAIN_PASSES = 3;

/**
 * How soon after a failed pass the next write may claim again. Releasing to
 * zero let a failure that keeps happening (reads timing out on a very large
 * facility, say) run passes back to back through a burst, each with its
 * retry, instead of one per window.
 */
const STATS_FAILED_PASS_BACKOFF_MS = 5_000;

/** The claimedAt a failed pass releases to: claimable again after the backoff. */
function releasedStatsClaimAtMs(nowMs: number): number {
  return nowMs - STATS_COALESCE_WINDOW_MS + STATS_FAILED_PASS_BACKOFF_MS;
}

/**
 * Pure claim decision, split out so the window logic is testable without Firestore.
 * A facility whose last claim has aged out is recomputed immediately; one inside a
 * live window is left to the claim holder.
 */
function shouldClaimStatsRecompute(claimedAtMs: number, nowMs: number): boolean {
  return nowMs - claimedAtMs >= STATS_COALESCE_WINDOW_MS;
}

function statsClaimRef(facilityId: string) {
  return getFirestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('stats')
    .doc('recompute');
}

/** claimed: we recompute. coalesced: a live claim holder covers us. */
export type StatsClaimOutcome = 'claimed' | 'coalesced' | 'facility-missing';

/**
 * Claim the recompute window, or mark dirty and let the holder cover us.
 *
 * A deleted facility is never claimed: the claim writes stats/recompute, and
 * a recursive delete fires one trigger per subcollection doc, which used to
 * recreate it under the deleted facility. The existence read sits outside
 * the transaction so claims do not lock the facility doc, which every pass
 * updates.
 */
async function claimStatsRecompute(
  facilityId: string,
  db: admin.firestore.Firestore = getFirestore(),
): Promise<StatsClaimOutcome> {
  const facilityRef = db.collection('facilities').doc(facilityId);
  if (!(await facilityRef.get()).exists) return 'facility-missing';

  const ref = facilityRef.collection('stats').doc('recompute');
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const claimedAt: number = snap.data()?.claimedAt?.toMillis?.() ?? 0;

    if (!shouldClaimStatsRecompute(claimedAt, now)) {
      tx.set(ref, { dirty: true }, { merge: true });
      return 'coalesced';
    }
    tx.set(
      ref,
      { claimedAt: admin.firestore.Timestamp.fromMillis(now), dirty: false },
      { merge: true },
    );
    return 'claimed';
  });
}

/**
 * End our claim early, after a failed pass, so a write after a short backoff
 * (STATS_FAILED_PASS_BACKOFF_MS) recomputes instead of waiting out the window
 * behind a pass that did not finish. The dirty flag is kept for that next
 * claim holder. If our pass outlived the window and another writer has
 * claimed since, this shortens their claim too; the worst case is one extra
 * concurrent pass. An update, not a merge-set, so a claim doc deleted with
 * its facility is not recreated (the update fails and is logged).
 */
async function releaseStatsClaim(
  facilityId: string,
  ref: admin.firestore.DocumentReference = statsClaimRef(facilityId),
  nowMs: number = Date.now(),
): Promise<void> {
  await ref.update({
    claimedAt: admin.firestore.Timestamp.fromMillis(releasedStatsClaimAtMs(nowMs)),
  });
}

/** Consume the dirty flag set by writers that arrived during our recompute. */
async function consumeStatsDirtyFlag(facilityId: string): Promise<boolean> {
  const ref = statsClaimRef(facilityId);
  return getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.data()?.dirty) return false;
    tx.set(ref, { dirty: false }, { merge: true });
    return true;
  });
}

/** Seams for tests; production passes the real Firestore-backed implementations. */
export interface StatsCoalesceHooks {
  claim: (facilityId: string) => Promise<StatsClaimOutcome>;
  consumeDirty: (facilityId: string) => Promise<boolean>;
  recompute: (facilityId: string) => Promise<void>;
  release: (facilityId: string) => Promise<void>;
}

const firestoreStatsCoalesceHooks: StatsCoalesceHooks = {
  claim: (facilityId: string) => claimStatsRecompute(facilityId),
  consumeDirty: consumeStatsDirtyFlag,
  release: (facilityId: string) => releaseStatsClaim(facilityId),
  recompute: async (facilityId: string) => {
    await recomputeAndPersistFacilityStats(facilityId);
  },
};

/**
 * Recompute and persist a facility's stats, collapsing concurrent writes into a
 * single pass. Errors are logged rather than thrown: a stats refresh must never
 * fail the tenant or unit write that triggered it.
 *
 * After a failed pass, writes that landed during it (they only marked the
 * facility dirty) get one retry, and if the facility still fails the claim is
 * released. A failed pass used to exit holding the claim with the dirty flag
 * set, so those writes, and any in the rest of the window, waited for the
 * next write after it or the nightly job.
 */
async function recomputeFacilityStatsCoalesced(
  facilityId: string,
  reason: string,
  hooks: StatsCoalesceHooks = firestoreStatsCoalesceHooks,
): Promise<void> {
  let claimed = false;
  try {
    const outcome = await hooks.claim(facilityId);
    if (outcome === 'facility-missing') {
      console.log(`⏭️ Stats recompute for ${facilityId} skipped: the facility no longer exists (${reason})`);
      return;
    }
    if (outcome === 'coalesced') {
      console.log(`⏭️ Stats recompute for ${facilityId} coalesced into an in-flight pass (${reason})`);
      return;
    }
    claimed = true;

    let retried = false;
    // The retry is on top of the drain passes, so a failure on the last one
    // still gets it.
    for (let pass = 0; pass < STATS_MAX_DRAIN_PASSES + (retried ? 1 : 0); pass++) {
      try {
        await hooks.recompute(facilityId);
      } catch (error) {
        if (retried || !(await hooks.consumeDirty(facilityId))) throw error;
        retried = true;
        console.warn(`⚠️ Stats pass for ${facilityId} failed with writes waiting; retrying once (${reason}):`, error);
        continue;
      }
      if (!(await hooks.consumeDirty(facilityId))) break;
    }

    console.log(`✅ Stats updated for facility ${facilityId} (${reason})`);
  } catch (error) {
    console.error(`❌ Error updating stats for facility ${facilityId} (${reason}):`, error);
    if (claimed) {
      try {
        await hooks.release(facilityId);
      } catch (releaseError) {
        console.error(`❌ Could not release the stats claim for ${facilityId}:`, releaseError);
      }
    }
  }
}

/**
 * Trigger: Update facility stats when a tenant is created, updated, or deleted
 */
export const onTenantWrite = functions.firestore
  .document('facilities/{facilityId}/tenants/{tenantId}')
  .onWrite(async (change, context) => {
    const facilityId = context.params.facilityId;

    console.log(`📊 Updating facility stats for ${facilityId} after tenant change`);
    await recomputeFacilityStatsCoalesced(facilityId, 'tenant change');
  });

/**
 * Trigger: Update facility stats when a unit is created, updated, or deleted
 */
export const onUnitWrite = functions.firestore
  .document('facilities/{facilityId}/units/{unitId}')
  .onWrite(async (change, context) => {
    const facilityId = context.params.facilityId;

    console.log(`📊 Updating facility stats for ${facilityId} after unit change`);
    await recomputeFacilityStatsCoalesced(facilityId, 'unit change');
  });

/**
 * Scheduled function: Update all facility stats nightly (runs at 2 AM daily)
 * This ensures stats are always fresh even if triggers miss something
 */
export const updateAllFacilityStatsNightly = functions.pubsub
  .schedule('0 2 * * *') // Run at 2 AM daily
  .timeZone('America/New_York')
  .onRun(async (context) => {
    try {
      console.log('🕐 Starting nightly facility stats update');
      
      const facilitiesSnapshot = await getFirestore().collection('facilities').get();
      const facilityIds = facilitiesSnapshot.docs.map((doc) => doc.id);

      // allSettled, not all: a compute failure now throws instead of writing
      // zeros, and Promise.all would return on the first one while the other
      // facilities' passes were still running.
      const results = await Promise.allSettled(
        facilityIds.map((facilityId) => recomputeAndPersistFacilityStats(facilityId)),
      );
      let failed = 0;
      results.forEach((result, i) => {
        if (result.status === 'rejected') {
          failed++;
          console.error(`❌ Nightly stats update failed for facility ${facilityIds[i]}:`, result.reason);
        }
      });
      console.log(
        `✅ Nightly stats update complete for ${facilityIds.length - failed} of ${facilityIds.length} facilities`,
      );
    } catch (error) {
      console.error('❌ Error in nightly stats update:', error);
    }
  });

/** Seams for tests; production passes the real access check and recompute. */
export interface ManualStatsDeps {
  assertFacilityAccess: (uid: string, facilityId: string) => Promise<unknown>;
  recompute: (facilityId: string) => Promise<Record<string, unknown> | null>;
}

const firestoreManualStatsDeps: ManualStatsDeps = {
  assertFacilityAccess: getFacilityDataForUserOrThrow,
  recompute: (facilityId: string) => recomputeAndPersistFacilityStats(facilityId),
};

type ManualStatsContext = {
  auth?: { uid: string; token?: Record<string, unknown> };
};

async function handleUpdateFacilityStatsManual(
  data: unknown,
  context: ManualStatsContext,
  deps: ManualStatsDeps = firestoreManualStatsDeps,
): Promise<{ success: true }> {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const facilityId = (data as { facilityId?: unknown } | null | undefined)?.facilityId;
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  // Before any read or heal. This used to accept any signed-in user, so anyone
  // could read another operator's revenue and past-due counts and trigger unit
  // writes on their facility. Super admins pass by the server-set claim only,
  // the same rule firestore.rules applies.
  if (context.auth.token?.superadmin !== true) {
    await deps.assertFacilityAccess(context.auth.uid, facilityId);
  }

  try {
    console.log(`📊 Manual stats update requested for facility ${facilityId}`);
    await deps.recompute(facilityId);

    console.log(`✅ Manual stats update complete for facility ${facilityId}`);
    // Nothing else: the stats hold revenue and past-due counts, and this
    // callable is open to every facility role, staff included. The app never
    // read them from here.
    return { success: true };
  } catch (error) {
    console.error(`❌ Error in manual stats update for facility ${facilityId}:`, error);
    throw new functions.https.HttpsError('internal', 'Failed to update stats');
  }
}

/**
 * Callable function: Manually trigger stats update for a specific facility.
 * The app's "Sync counts" buttons call this; the caller must have access to
 * the facility (owner, roles map, managers map, active user_roles row) or be
 * a super admin.
 */
export const updateFacilityStatsManual = functions.https.onCall((data, context) =>
  handleUpdateFacilityStatsManual(data, context),
);

export const manualStatsTestUtils = {
  handleUpdateFacilityStatsManual,
};

/**
 * Coalescing seams for tests. Kept separate from facilityStatsTestUtils, which is
 * declared above the constants below and would hit the temporal dead zone.
 */
export const statsCoalesceTestUtils = {
  shouldClaimStatsRecompute,
  recomputeFacilityStatsCoalesced,
  claimStatsRecompute,
  releaseStatsClaim,
  STATS_COALESCE_WINDOW_MS,
  STATS_MAX_DRAIN_PASSES,
  STATS_FAILED_PASS_BACKOFF_MS,
};
