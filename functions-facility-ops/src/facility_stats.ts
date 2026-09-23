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
  publicListingEnabled?: boolean;
  archived?: boolean;
}

/**
 * Units that count toward rentable-inventory stats (Total/Occupied/Vacant/
 * Available Units). Excludes staff-only spaces (manager residence, office,
 * personal-use) that have `publicListingEnabled === false` — the same flag
 * that already keeps them off the public map/website (mirrors Flutter
 * FacilityStatsService.countUnits), so an operator's internal-use
 * tracking entries don't inflate their own dashboard numbers. Orphan healing
 * below deliberately still scans every unit, rentable or not.
 *
 * Archived units are excluded too. They were counted here but not in the app,
 * so the facility-doc mirror (facility cards, search, super admin) ran higher
 * than every screen that counts units itself. `(archived ?? false) === false`
 * is the exact test Flutter's UnitService applies, so a stray non-boolean
 * value is dropped by both sides rather than by one.
 */
function isRentableUnit(unit: UnitInput): boolean {
  return unit.publicListingEnabled !== false && (unit.archived ?? false) === false;
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
  load: (facilityId: string) => Promise<FacilityStatsInputs>;
  healOrphans: (facilityId: string, orphanIds: string[]) => Promise<void>;
}

/**
 * Counts and delinquency for one facility from inputs already in hand. Units
 * are limited to rentable ones (see isRentableUnit); revenue and past due come
 * from active tenants only.
 */
function summarizeFacilityStats(
  inputs: FacilityStatsInputs,
  now: Date = new Date(),
): Record<string, number> {
  const rentable = inputs.units.filter(isRentableUnit);
  const { occupiedUnits } = countCanonicalOccupied(rentable, inputs.allTenantIds);
  const totalUnits = rentable.length;
  const availableUnits = Math.max(0, totalUnits - occupiedUnits);

  let scheduledMonthlyRevenue = 0;
  let autopayMonthlyRevenue = 0;
  let tenantsLate = 0; // 1-9 days
  let tenantsOverdue = 0; // 10-29 days
  let tenantsSeverelyOverdue = 0; // 30+ days

  for (const tenant of inputs.activeTenants) {
    const rate = tenant.monthlyRate || 0;
    scheduledMonthlyRevenue += rate;
    if (tenantAutopayOn(tenant)) {
      autopayMonthlyRevenue += rate;
    }

    const daysLate = calculateDaysLate(tenant, inputs.gracePeriodDays, now);
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

async function loadFacilityStatsInputs(facilityId: string): Promise<FacilityStatsInputs> {
  const facilityDoc = await getFirestore().collection('facilities').doc(facilityId).get();
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
  const unitsSnapshot = await getFirestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('units')
    .get();
  const units = unitsSnapshot.docs.map((doc) => ({
    id: doc.id,
    ...(doc.data() as {
      status: string;
      tenantId?: string | null;
      publicListingEnabled?: boolean;
      archived?: boolean;
    }),
  }));

  const allTenantsSnapshot = await getFirestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .get();

  const activeTenantsSnapshot = await getFirestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('tenants')
    .where('isActive', '==', true)
    .get();

  return {
    gracePeriodDays,
    units,
    allTenantIds: new Set(allTenantsSnapshot.docs.map((d) => d.id)),
    activeTenants: activeTenantsSnapshot.docs.map((d) => d.data() as TenantData),
  };
}

/** Orphan units (status=occupied, tenant missing) become available with no tenant. */
async function healOrphanUnits(facilityId: string, orphanIds: string[]): Promise<void> {
  const BATCH_LIMIT = 500;
  const unitsRef = getFirestore().collection('facilities').doc(facilityId).collection('units');
  for (let i = 0; i < orphanIds.length; i += BATCH_LIMIT) {
    const chunk = orphanIds.slice(i, i + BATCH_LIMIT);
    const batch = getFirestore().batch();
    for (const unitId of chunk) {
      batch.update(unitsRef.doc(unitId), {
        status: 'available',
        tenantId: admin.firestore.FieldValue.delete(),
        tenantName: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }
  console.log(`🔧 [facility_stats] Healed ${orphanIds.length} orphan unit(s) for ${facilityId}`);
}

const firestoreFacilityStatsDeps: FacilityStatsDeps = {
  load: loadFacilityStatsInputs,
  healOrphans: healOrphanUnits,
};

/** Write stats doc and mirror occupied + unit-doc count onto the facility root doc. */
async function persistFacilityStats(facilityId: string, stats: Record<string, unknown>): Promise<void> {
  const occupied = Number(stats.occupiedUnits ?? 0);
  const unitDocCount = Number(stats.totalUnits ?? 0);
  await getFirestore()
    .collection('facilities')
    .doc(facilityId)
    .collection('stats')
    .doc('current')
    .set(stats, { merge: true });
  await getFirestore().collection('facilities').doc(facilityId).update({
    occupiedUnits: occupied,
    unitDocCount,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
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
): Promise<Record<string, unknown>> {
  const inputs = await deps.load(facilityId);

  // Healing scans every unit (archived and staff-only too) so a stale tenantId
  // anywhere still gets cleared; only the counts are limited to rentable units.
  const { orphanIds } = countCanonicalOccupied(inputs.units, inputs.allTenantIds);
  if (orphanIds.length > 0) {
    await deps.healOrphans(facilityId, orphanIds);
  }

  return {
    ...summarizeFacilityStats(inputs),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
}

/** Compute, then persist. A failed compute throws before anything is written. */
async function recomputeAndPersistFacilityStats(
  facilityId: string,
  compute: (facilityId: string) => Promise<Record<string, unknown>> = computeFacilityStats,
  persist: (facilityId: string, stats: Record<string, unknown>) => Promise<void> = persistFacilityStats,
): Promise<Record<string, unknown>> {
  const stats = await compute(facilityId);
  await persist(facilityId, stats);
  return stats;
}

export const facilityStatsTestUtils = {
  tenantAutopayOn,
  isTenantLate,
  calculateDaysLate,
  countCanonicalOccupied,
  isRentableUnit,
  summarizeFacilityStats,
  computeFacilityStats,
  recomputeAndPersistFacilityStats,
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

/** Claim the recompute window, or mark dirty and let the holder cover us. */
async function claimStatsRecompute(facilityId: string): Promise<boolean> {
  const ref = statsClaimRef(facilityId);
  return getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const claimedAt: number = snap.data()?.claimedAt?.toMillis?.() ?? 0;

    if (!shouldClaimStatsRecompute(claimedAt, now)) {
      tx.set(ref, { dirty: true }, { merge: true });
      return false;
    }
    tx.set(
      ref,
      { claimedAt: admin.firestore.Timestamp.fromMillis(now), dirty: false },
      { merge: true },
    );
    return true;
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
  claim: (facilityId: string) => Promise<boolean>;
  consumeDirty: (facilityId: string) => Promise<boolean>;
  recompute: (facilityId: string) => Promise<void>;
}

const firestoreStatsCoalesceHooks: StatsCoalesceHooks = {
  claim: claimStatsRecompute,
  consumeDirty: consumeStatsDirtyFlag,
  recompute: async (facilityId: string) => {
    await recomputeAndPersistFacilityStats(facilityId);
  },
};

/**
 * Recompute and persist a facility's stats, collapsing concurrent writes into a
 * single pass. Errors are logged rather than thrown: a stats refresh must never
 * fail the tenant or unit write that triggered it.
 */
async function recomputeFacilityStatsCoalesced(
  facilityId: string,
  reason: string,
  hooks: StatsCoalesceHooks = firestoreStatsCoalesceHooks,
): Promise<void> {
  try {
    if (!(await hooks.claim(facilityId))) {
      console.log(`⏭️ Stats recompute for ${facilityId} coalesced into an in-flight pass (${reason})`);
      return;
    }

    for (let pass = 0; pass < STATS_MAX_DRAIN_PASSES; pass++) {
      await hooks.recompute(facilityId);
      if (!(await hooks.consumeDirty(facilityId))) break;
    }

    console.log(`✅ Stats updated for facility ${facilityId} (${reason})`);
  } catch (error) {
    console.error(`❌ Error updating stats for facility ${facilityId} (${reason}):`, error);
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
  recompute: (facilityId: string) => Promise<Record<string, unknown>>;
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
): Promise<{ success: true; stats: Record<string, unknown> }> {
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
    const stats = await deps.recompute(facilityId);

    console.log(`✅ Manual stats update complete for facility ${facilityId}`);
    return { success: true, stats };
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
  STATS_COALESCE_WINDOW_MS,
  STATS_MAX_DRAIN_PASSES,
};
