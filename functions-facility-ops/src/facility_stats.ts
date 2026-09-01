import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getFirestore } from '@sfc/functions-shared/firestoreLazy';

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
}

/**
 * Units that count toward rentable-inventory stats (Total/Occupied/Vacant/
 * Available Units). Excludes staff-only spaces (manager residence, office,
 * personal-use) that have `publicListingEnabled === false` — the same flag
 * that already keeps them off the public map/website (mirrors Flutter
 * FacilityStatsService._rentableUnits), so an operator's internal-use
 * tracking entries don't inflate their own dashboard numbers. Orphan healing
 * below deliberately still scans every unit, rentable or not.
 */
function isRentableUnit(unit: UnitInput): boolean {
  return unit.publicListingEnabled !== false;
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

export const facilityStatsTestUtils = {
  tenantAutopayOn,
  isTenantLate,
  calculateDaysLate,
  countCanonicalOccupied,
  isRentableUnit,
};

/**
 * Canonical occupancy: unit is occupied ONLY if status===occupied AND tenantId exists in facility.
 * Heals orphan units (status=occupied but tenant missing) by setting available and clearing tenantId.
 */
async function getCanonicalOccupiedCountAndHeal(
  facilityId: string,
  unitsSnapshot: admin.firestore.QuerySnapshot,
  tenantIds: Set<string>,
): Promise<{ occupiedUnits: number; orphanIds: string[] }> {
  const units = unitsSnapshot.docs.map((doc) => ({
    id: doc.id,
    ...(doc.data() as { status: string; tenantId?: string | null; publicListingEnabled?: boolean }),
  }));
  // Healing scans every unit (rentable or not) so a stale tenantId on an
  // office/staff unit still gets cleared; only the returned occupiedUnits
  // count (a dashboard metric) excludes non-rentable units.
  const { orphanIds } = countCanonicalOccupied(units, tenantIds);
  const { occupiedUnits } = countCanonicalOccupied(units.filter(isRentableUnit), tenantIds);
  const BATCH_LIMIT = 500;
  if (orphanIds.length > 0) {
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
  return { occupiedUnits, orphanIds };
}

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
 */
async function computeFacilityStats(facilityId: string): Promise<Record<string, any>> {
  try {
    const facilityDoc = await getFirestore().collection('facilities').doc(facilityId).get();
    const billingSettings = facilityDoc.data()?.billingSettings as
      | { gracePeriodDays?: number | string }
      | undefined;
    const rawGrace = billingSettings?.gracePeriodDays;
    const gracePeriodDays =
      typeof rawGrace === 'number'
        ? rawGrace
        : parseInt(String(rawGrace ?? ''), 10) || 3;

    const unitsSnapshot = await getFirestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('units')
      .get();
    const rentableUnitCount = unitsSnapshot.docs.filter((doc) =>
      isRentableUnit(doc.data() as UnitInput),
    ).length;

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

    // Occupancy/healing: include archived tenants so their units are not freed incorrectly.
    const tenantIds = new Set(allTenantsSnapshot.docs.map((d) => d.id));
    const { occupiedUnits } = await getCanonicalOccupiedCountAndHeal(
      facilityId,
      unitsSnapshot,
      tenantIds,
    );

    const totalUnits = rentableUnitCount;
    const availableUnits = Math.max(0, totalUnits - occupiedUnits);
    const totalTenantsActive = activeTenantsSnapshot.size;

    // Calculate revenue and delinquency (active tenants only)
    let scheduledMonthlyRevenue = 0;
    let autopayMonthlyRevenue = 0;
    let tenantsLate = 0; // 1-9 days
    let tenantsOverdue = 0; // 10-29 days
    let tenantsSeverelyOverdue = 0; // 30+ days

    for (const doc of activeTenantsSnapshot.docs) {
      const tenant = doc.data() as TenantData;
      const rate = tenant.monthlyRate || 0;
      scheduledMonthlyRevenue += rate;
      if (tenantAutopayOn(tenant)) {
        autopayMonthlyRevenue += rate;
      }

      const daysLate = calculateDaysLate(tenant, gracePeriodDays);
      if (daysLate >= 30) {
        tenantsSeverelyOverdue++;
      } else if (daysLate >= 10) {
        tenantsOverdue++;
      } else if (daysLate >= 1) {
        tenantsLate++;
      }
    }

    const totalPastDue = tenantsLate + tenantsOverdue + tenantsSeverelyOverdue;

    return {
      totalUnits,
      occupiedUnits,
      availableUnits,
      totalTenantsActive,
      scheduledMonthlyRevenue,
      autopayMonthlyRevenue,
      tenantsLate,
      tenantsOverdue,
      tenantsSeverelyOverdue,
      totalPastDue,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
  } catch (error) {
    console.error(`❌ Error computing stats for facility ${facilityId}:`, error);
    return {
      totalUnits: 0,
      occupiedUnits: 0,
      availableUnits: 0,
      totalTenantsActive: 0,
      scheduledMonthlyRevenue: 0,
      autopayMonthlyRevenue: 0,
      tenantsLate: 0,
      tenantsOverdue: 0,
      tenantsSeverelyOverdue: 0,
      totalPastDue: 0,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
  }
}

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

    if (now - claimedAt < STATS_COALESCE_WINDOW_MS) {
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

/**
 * Recompute and persist a facility's stats, collapsing concurrent writes into a
 * single pass. Errors are logged rather than thrown: a stats refresh must never
 * fail the tenant or unit write that triggered it.
 */
async function recomputeFacilityStatsCoalesced(facilityId: string, reason: string): Promise<void> {
  try {
    if (!(await claimStatsRecompute(facilityId))) {
      console.log(`⏭️ Stats recompute for ${facilityId} coalesced into an in-flight pass (${reason})`);
      return;
    }

    for (let pass = 0; pass < STATS_MAX_DRAIN_PASSES; pass++) {
      const stats = await computeFacilityStats(facilityId);
      await persistFacilityStats(facilityId, stats);
      if (!(await consumeStatsDirtyFlag(facilityId))) break;
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
      const updatePromises = [];

      for (const facilityDoc of facilitiesSnapshot.docs) {
        const facilityId = facilityDoc.id;
        const promise = computeFacilityStats(facilityId).then((stats) =>
          persistFacilityStats(facilityId, stats),
        );
        updatePromises.push(promise);
      }

      await Promise.all(updatePromises);
      console.log(`✅ Nightly stats update complete for ${facilitiesSnapshot.size} facilities`);
    } catch (error) {
      console.error('❌ Error in nightly stats update:', error);
    }
  });

/**
 * Callable function: Manually trigger stats update for a specific facility
 * Can be called from the app when needed
 */
export const updateFacilityStatsManual = functions.https.onCall(async (data, context) => {
  // Verify authentication
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const facilityId = data.facilityId;
  if (!facilityId || typeof facilityId !== 'string') {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId is required');
  }

  try {
    console.log(`📊 Manual stats update requested for facility ${facilityId}`);
    const stats = await computeFacilityStats(facilityId);
    await persistFacilityStats(facilityId, stats);

    console.log(`✅ Manual stats update complete for facility ${facilityId}`);
    return { success: true, stats };
  } catch (error) {
    console.error(`❌ Error in manual stats update for facility ${facilityId}:`, error);
    throw new functions.https.HttpsError('internal', 'Failed to update stats');
  }
});
