import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { getFirestore } from './firestore_lazy';

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

interface UnitData {
  status: string;
  tenantId?: string | null;
}

/**
 * Calculate days late for a tenant
 */
function calculateDaysLate(tenant: TenantData): number {
  const now = new Date();
  const startOfCurrentMonth = new Date(now.getFullYear(), now.getMonth(), 1);
  const gracePeriodDays = 3;
  const paidThrough = tenant.paidThrough?.toDate();

  // If tenant has never paid
  if (!paidThrough) {
    // If tenant was created recently (within 30 days), not late yet
    const daysSinceCreation = Math.floor(
      (now.getTime() - tenant.createdAt.toDate().getTime()) / (1000 * 60 * 60 * 24),
    );
    if (daysSinceCreation <= 30) {
      return 0;
    }
    // Tenant created more than 30 days ago with no payment - they are late
    return Math.floor(
      (now.getTime() - tenant.createdAt.toDate().getTime()) / (1000 * 60 * 60 * 24),
    );
  }

  // Tenant has paid - check if payment is still valid
  const graceBoundary = new Date(startOfCurrentMonth.getTime() - gracePeriodDays * 24 * 60 * 60 * 1000);
  if (paidThrough < graceBoundary) {
    const difference = Math.floor(
      (startOfCurrentMonth.getTime() - paidThrough.getTime()) / (1000 * 60 * 60 * 24) - gracePeriodDays,
    );
    return difference < 0 ? 0 : difference;
  }

  return 0;
}

/**
 * Canonical occupancy: unit is occupied ONLY if status===occupied AND tenantId exists in facility.
 * Heals orphan units (status=occupied but tenant missing) by setting available and clearing tenantId.
 */
async function getCanonicalOccupiedCountAndHeal(
  facilityId: string,
  unitsSnapshot: admin.firestore.QuerySnapshot,
  tenantIds: Set<string>,
): Promise<{ occupiedUnits: number; orphanIds: string[] }> {
  const orphanIds: string[] = [];
  let occupiedUnits = 0;
  for (const doc of unitsSnapshot.docs) {
    const data = doc.data() as UnitData;
    if (data.status !== 'occupied') continue;
    const tenantId = data.tenantId ?? null;
    const tenantExists = tenantId != null && tenantIds.has(tenantId);
    if (tenantExists) {
      occupiedUnits++;
    } else {
      orphanIds.push(doc.id);
    }
  }
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
    const unitsSnapshot = await getFirestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('units')
      .get();

    const tenantsSnapshot = await getFirestore()
      .collection('facilities')
      .doc(facilityId)
      .collection('tenants')
      .where('isActive', '==', true)
      .get();

    const tenantIds = new Set(tenantsSnapshot.docs.map((d) => d.id));
    const { occupiedUnits } = await getCanonicalOccupiedCountAndHeal(
      facilityId,
      unitsSnapshot,
      tenantIds,
    );

    const totalUnits = unitsSnapshot.size;
    const availableUnits = Math.max(0, totalUnits - occupiedUnits);
    const totalTenantsActive = tenantsSnapshot.size;

    // Calculate revenue and delinquency
    let scheduledMonthlyRevenue = 0;
    let autopayMonthlyRevenue = 0;
    let tenantsLate = 0; // 1-9 days
    let tenantsOverdue = 0; // 10-29 days
    let tenantsSeverelyOverdue = 0; // 30+ days

    for (const doc of tenantsSnapshot.docs) {
      const tenant = doc.data() as TenantData;
      const rate = tenant.monthlyRate || 0;
      scheduledMonthlyRevenue += rate;
      if (tenantAutopayOn(tenant)) {
        autopayMonthlyRevenue += rate;
      }

      const daysLate = calculateDaysLate(tenant);
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
 * Trigger: Update facility stats when a tenant is created, updated, or deleted
 */
export const onTenantWrite = functions.firestore
  .document('facilities/{facilityId}/tenants/{tenantId}')
  .onWrite(async (change, context) => {
    const facilityId = context.params.facilityId;
    
    try {
      console.log(`📊 Updating facility stats for ${facilityId} after tenant change`);
      const stats = await computeFacilityStats(facilityId);
      await persistFacilityStats(facilityId, stats);

      console.log(`✅ Stats updated for facility ${facilityId}`);
    } catch (error) {
      console.error(`❌ Error updating stats for facility ${facilityId}:`, error);
    }
  });

/**
 * Trigger: Update facility stats when a unit is created, updated, or deleted
 */
export const onUnitWrite = functions.firestore
  .document('facilities/{facilityId}/units/{unitId}')
  .onWrite(async (change, context) => {
    const facilityId = context.params.facilityId;
    
    try {
      console.log(`📊 Updating facility stats for ${facilityId} after unit change`);
      const stats = await computeFacilityStats(facilityId);
      await persistFacilityStats(facilityId, stats);

      console.log(`✅ Stats updated for facility ${facilityId}`);
    } catch (error) {
      console.error(`❌ Error updating stats for facility ${facilityId}:`, error);
    }
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
