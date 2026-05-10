import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/unit_model.dart';
import '../services/unit_service.dart';
import '../services/tenant_service.dart';
import '../services/facility_service.dart';
import '../models/tenant_model.dart';

/// Service for computing facility statistics on-the-fly and storing in facilityStats document
/// Delinquency Rules (consistent across app):
/// - "current": no unpaid invoices past due date (or all invoices paid on time)
/// - "late": tenant has unpaid balance 1-9 days past due
/// - "overdue": tenant has unpaid balance 10-29 days past due  
/// - "severely_overdue": tenant has unpaid balance 30+ days past due
///
/// Occupancy (canonical rule): A unit is "occupied" ONLY if unit.tenantId is set AND that
/// tenant exists in this facility. If unit.status says occupied but tenant missing → not occupied.
import '../utils/count_helpers.dart' as count_helpers;
import 'late_logic_service.dart';

class FacilityStatsService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Portion of [scheduledMonthlyRevenue] that is on autopay (`autopay.status == ON`).
  static double sumAutopayMonthlyRevenue(Iterable<TenantModel> activeTenants) {
    var sum = 0.0;
    for (final t in activeTenants) {
      if (t.autopay.isOn) sum += t.monthlyRate;
    }
    return sum;
  }

  /// True if the facility has at least one unit document (cheap `limit(1)` probe).
  static Future<bool> facilityHasAnyUnitDoc(String facilityId) async {
    try {
      final snap = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('units')
          .limit(1)
          .get();
      return snap.docs.isNotEmpty;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [FacilityStatsService] facilityHasAnyUnitDoc failed: $e');
      }
      return false;
    }
  }

  /// Set of tenant IDs that exist for the facility (used for canonical occupancy).
  static Future<Set<String>> _getTenantIdsForFacility(String facilityId) async {
    final tenants = await TenantService.getTenantsForFacility(facilityId);
    return tenants.map((t) => t.id).toSet();
  }

  /// Canonical occupied count: only units with status==occupied AND tenantId in existing tenants.
  static int _canonicalOccupiedCount(List<UnitModel> units, Set<String> tenantIds) {
    return units.where((u) =>
      u.status == UnitStatus.occupied &&
      u.tenantId != null &&
      tenantIds.contains(u.tenantId),
    ).length;
  }

  /// Orphan units: status==occupied but tenantId null or tenant does not exist. These are healed.
  static List<UnitModel> _orphanOccupiedUnits(List<UnitModel> units, Set<String> tenantIds) {
    return units.where((u) =>
      u.status == UnitStatus.occupied &&
      (u.tenantId == null || !tenantIds.contains(u.tenantId!)),
    ).toList();
  }

  /// Compute total and occupied unit counts using canonical rule (no heal).
  /// Returns (totalUnits, occupiedUnits). `totalUnits` is the count of unit
  /// documents that actually exist for the facility — the user-set capacity max
  /// is never used here.
  static Future<({int totalUnits, int occupiedUnits})> computeUnitCounts(String facilityId) async {
    try {
      final units = await UnitService.getUnitsForFacility(facilityId);
      final tenantIds = await _getTenantIdsForFacility(facilityId);
      final totalUnits = count_helpers.effectiveTotalUnits(0, units.length);
      final occupiedUnits = _canonicalOccupiedCount(units, tenantIds);
      return (totalUnits: totalUnits, occupiedUnits: occupiedUnits);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Error computing unit counts: $e');
      }
      return (totalUnits: 0, occupiedUnits: 0);
    }
  }

  /// Heal orphaned occupancy: units with status==occupied but missing tenant → available, clear tenantId.
  /// Idempotent; safe to run multiple times. Call before recompute when doing backfill.
  static Future<int> healOrphanedOccupancy(String facilityId) async {
    try {
      final units = await UnitService.getUnitsForFacility(facilityId);
      final tenantIds = await _getTenantIdsForFacility(facilityId);
      final orphans = _orphanOccupiedUnits(units, tenantIds);
      if (orphans.isEmpty) return 0;
      await UnitService.clearTenantFromUnitsBatch(
        facilityId: facilityId,
        unitIds: orphans.map((u) => u.id).toList(),
      );
      if (kDebugMode) {
        print('🔧 [FacilityStatsService] Healed ${orphans.length} orphan unit(s) for $facilityId');
      }
      return orphans.length;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Error healing orphans: $e');
      }
      return 0;
    }
  }

  /// Compute comprehensive facility statistics including tenants, revenue, and delinquency.
  /// Uses canonical occupancy. If [healFirst] is true (default when called from updateFacilityStats),
  /// heals orphan units before counting so stored stats and DB stay in sync.
  static Future<Map<String, dynamic>> computeFacilityStats(String facilityId, {bool healFirst = false}) async {
    try {
      if (healFirst) {
        await healOrphanedOccupancy(facilityId);
      }

      final facility = await FacilityService.getFacility(facilityId);
      final units = await UnitService.getUnitsForFacility(facilityId);
      final tenantIds = await _getTenantIdsForFacility(facilityId);
      final occupiedUnits = _canonicalOccupiedCount(units, tenantIds);
      final totalUnits = count_helpers.effectiveTotalUnits(0, units.length);
      final availableUnits = (totalUnits - occupiedUnits).clamp(0, totalUnits);

      final tenants = await TenantService.getTenantsForFacility(facilityId);
      final activeTenants = tenants.where((t) => t.isActive == true).toList();
      final totalTenantsActive = activeTenants.length;
      
      // Scheduled revenue = all active tenants; autopay subset uses Firestore `autopay.status` (ON).
      double scheduledMonthlyRevenue = 0.0;
      for (final tenant in activeTenants) {
        scheduledMonthlyRevenue += tenant.monthlyRate;
      }
      final autopayMonthlyRevenue = sumAutopayMonthlyRevenue(activeTenants);
      
      // Count delinquent tenants using facility's grace period (Billing Settings)
      final grace = facility?.billingSettings?['gracePeriodDays'];
      final graceDays = (grace is int) ? grace : (grace != null ? int.tryParse(grace.toString()) : null) ?? 3;
      int tenantsLate = 0;
      int tenantsOverdue = 0;
      int tenantsSeverelyOverdue = 0;

      for (final tenant in activeTenants) {
        if (!LateLogicService.isTenantLate(tenant, gracePeriodDays: graceDays)) continue;
        final daysLate = LateLogicService.getTenantDaysLate(tenant, gracePeriodDays: graceDays);
        if (daysLate >= 30) {
          tenantsSeverelyOverdue++;
        } else if (daysLate >= 10) {
          tenantsOverdue++;
        } else if (daysLate >= 1) {
          tenantsLate++;
        }
      }
      
      final totalPastDue = tenantsLate + tenantsOverdue + tenantsSeverelyOverdue;
      
      if (kDebugMode) {
        print('✅ [FacilityStatsService] Computed stats for $facilityId:');
        print('   - Total units: $totalUnits (occupied: $occupiedUnits, available: $availableUnits)');
        print('   - Active tenants: $totalTenantsActive');
        print('   - Scheduled monthly revenue: \$${scheduledMonthlyRevenue.toStringAsFixed(2)} '
            '(autopay: \$${autopayMonthlyRevenue.toStringAsFixed(2)})');
        print('   - Past due: $totalPastDue (late: $tenantsLate, overdue: $tenantsOverdue, severe: $tenantsSeverelyOverdue)');
      }
      
      return {
        'totalUnits': totalUnits,
        'occupiedUnits': occupiedUnits,
        'availableUnits': availableUnits,
        'totalTenantsActive': totalTenantsActive,
        'scheduledMonthlyRevenue': scheduledMonthlyRevenue,
        'autopayMonthlyRevenue': autopayMonthlyRevenue,
        'tenantsLate': tenantsLate,
        'tenantsOverdue': tenantsOverdue,
        'tenantsSeverelyOverdue': tenantsSeverelyOverdue,
        'totalPastDue': totalPastDue,
        'updatedAt': FieldValue.serverTimestamp(),
      };
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Error computing facility stats: $e');
      }
      return {
        'totalUnits': 0,
        'occupiedUnits': 0,
        'availableUnits': 0,
        'totalTenantsActive': 0,
        'scheduledMonthlyRevenue': 0.0,
        'autopayMonthlyRevenue': 0.0,
        'tenantsLate': 0,
        'tenantsOverdue': 0,
        'tenantsSeverelyOverdue': 0,
        'totalPastDue': 0,
        'updatedAt': FieldValue.serverTimestamp(),
      };
    }
  }

  /// Update facilityStats document with computed statistics (heals orphans first, then recomputes).
  /// Also mirrors the canonical unit counts (`occupiedUnits`, `unitDocCount`) onto the
  /// facility document so the super admin metrics stream and other consumers can read
  /// the actual unit-doc total without a sub-collection query.
  static Future<void> updateFacilityStats(String facilityId) async {
    try {
      final stats = await computeFacilityStats(facilityId, healFirst: true);
      final occupied = (stats['occupiedUnits'] as int?) ?? 0;
      final unitDocCount = (stats['totalUnits'] as int?) ?? 0;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('stats')
          .doc('current')
          .set(stats, SetOptions(merge: true));

      await _firestore.collection('facilities').doc(facilityId).update({
        'occupiedUnits': occupied,
        'unitDocCount': unitDocCount,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [FacilityStatsService] Updated facility stats + occupied=$occupied unitDocCount=$unitDocCount for $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Error updating facility stats: $e');
      }
      // Don't throw - this is a background sync operation
    }
  }

  /// Update facility document with canonical occupied + unit-doc count mirrors.
  /// Does not change `totalUnits` on the facility doc — that field remains the
  /// user-set capacity max. Mirrors actual unit-document totals to `unitDocCount`.
  static Future<void> refreshFacilityCounts(String facilityId) async {
    try {
      final counts = await computeUnitCounts(facilityId);
      
      await _firestore.collection('facilities').doc(facilityId).update({
        'occupiedUnits': counts.occupiedUnits,
        'unitDocCount': counts.totalUnits,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      
      if (kDebugMode) {
        print('✅ [FacilityStatsService] Updated facility occupied: ${counts.occupiedUnits}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Error refreshing facility counts: $e');
      }
      // Don't throw - this is a background sync operation
    }
  }
  
  /// Get facility stats from Firestore (fast read from cached document).
  /// Forces recompute when cache is inconsistent: 0 tenants but occupied > 0 (ghost occupancy).
  static Future<Map<String, dynamic>?> getFacilityStats(String facilityId) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('stats')
          .doc('current')
          .get();

      if (doc.exists) {
        final cached = doc.data()!;
        final cachedOccupied = (cached['occupiedUnits'] as int?) ?? 0;
        final cachedTenants = (cached['totalTenantsActive'] as int?) ?? 0;

        // Stale cache: stats show no tenants/occupancy while tenant docs exist
        // (e.g. after imports or partial writes) → recompute.
        if (cachedTenants == 0 && cachedOccupied == 0) {
          final anyTenantSnap = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('tenants')
              .limit(1)
              .get();
          if (anyTenantSnap.docs.isNotEmpty) {
            if (kDebugMode) {
              print(
                '🔄 [FacilityStatsService] Stale cache (0 tenants/occupied in stats but tenant docs exist), recomputing...',
              );
            }
            await updateFacilityStats(facilityId);
            return (await _firestore
                    .collection('facilities')
                    .doc(facilityId)
                    .collection('stats')
                    .doc('current')
                    .get())
                .data();
          }
        }

        // Ghost occupancy: 0 tenants but occupied > 0 → stale cache, recompute and heal
        if (cachedTenants == 0 && cachedOccupied > 0) {
          if (kDebugMode) {
            print('🔄 [FacilityStatsService] Stale cache (0 tenants but $cachedOccupied occupied), recomputing + healing...');
          }
          await updateFacilityStats(facilityId);
          return (await _firestore
                  .collection('facilities')
                  .doc(facilityId)
                  .collection('stats')
                  .doc('current')
                  .get())
              .data();
        }

        // Cached `totalUnits` now reflects the actual count of unit documents.
        // Compare against the live count and refresh if the cache drifted (e.g.
        // unit docs were added/removed without triggering a recompute yet).
        final cachedTotalUnits = (cached['totalUnits'] as int?) ?? 0;
        final units = await UnitService.getUnitsForFacility(facilityId);
        if (cachedTotalUnits != units.length) {
          if (kDebugMode) {
            print(
              '🔄 [FacilityStatsService] Cached totalUnits $cachedTotalUnits != ${units.length} unit docs, recomputing...',
            );
          }
          await updateFacilityStats(facilityId);
          return (await _firestore
                  .collection('facilities')
                  .doc(facilityId)
                  .collection('stats')
                  .doc('current')
                  .get())
              .data();
        }
        return cached;
      }

      if (kDebugMode) {
        print('⚠️ [FacilityStatsService] Stats not found, computing on-the-fly for $facilityId');
      }
      await updateFacilityStats(facilityId);
      return (await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection('stats')
              .doc('current')
              .get())
          .data();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Error getting facility stats: $e');
      }
      return null;
    }
  }

  /// Idempotent recompute for one facility: heal orphans, recompute stats, write stats + facility.occupiedUnits.
  static Future<void> recomputeFacilityStats(String facilityId) async {
    await updateFacilityStats(facilityId);
  }

  /// Recompute stats for all facilities: heal orphan occupancy, then refresh stats. Does not create placeholder units.
  static Future<void> recomputeAllFacilitiesStats() async {
    final facilities = await FacilityService.getUserFacilities();
    for (final f in facilities) {
      try {
        await reconcileUnitsToCapacity(f.id);
      } catch (e) {
        if (kDebugMode) {
          print('❌ [FacilityStatsService] recomputeAll: failed for ${f.id}: $e');
        }
        try {
          await updateFacilityStats(f.id);
        } catch (_) {}
      }
    }
    if (kDebugMode) {
      print('✅ [FacilityStatsService] recomputeAllFacilitiesStats done for ${facilities.length} facilities');
    }
  }

  /// Heal orphan occupancy and refresh stats. **Does not** create empty unit documents up to [FacilityModel.totalUnits].
  /// Capacity stays on the facility document; add units explicitly in the unit list / map as you build or rent.
  static Future<({int created, int healed})> reconcileUnitsToCapacity(String facilityId) async {
    final healed = await healOrphanedOccupancy(facilityId);
    await updateFacilityStats(facilityId);
    if (kDebugMode) {
      print('✅ [FacilityStatsService] reconcileUnitsToCapacity: heal-only, healed=$healed for $facilityId');
    }
    return (created: 0, healed: healed);
  }

  /// Optional: create empty `units` documents (001, 002, …) until document count matches [FacilityModel.totalUnits].
  /// Use after CSV import or when you intentionally want one row per slot. Not run from Sync counts or facility save.
  static Future<({int created, int healed})> materializeMissingUnitDocumentsUpToCapacity(
    String facilityId,
  ) async {
    int created = 0;
    final healed = await healOrphanedOccupancy(facilityId);
    final facility = await FacilityService.getFacility(facilityId);
    final capacity = facility?.totalUnits ?? 0;
    if (capacity <= 0) return (created: 0, healed: healed);
    var units = await UnitService.getUnitsForFacility(facilityId);
    if (units.length >= capacity) {
      await updateFacilityStats(facilityId);
      return (created: 0, healed: healed);
    }
    final existingNumbers = units.map((u) => u.unitNumber).toSet();
    final useThreeDigit = existingNumbers.any((s) => s.length >= 3);
    int nextNum = 1;
    for (var k = 0; k < capacity - units.length; k++) {
      String unitNumber;
      do {
        unitNumber = useThreeDigit ? nextNum.toString().padLeft(3, '0') : nextNum.toString();
        nextNum++;
      } while (existingNumbers.contains(unitNumber));
      existingNumbers.add(unitNumber);
      try {
        await UnitService.createUnit(
          facilityId: facilityId,
          unitNumber: unitNumber,
          unitType: 'standard',
          monthlyRate: 0,
        );
        created++;
      } catch (e) {
        if (kDebugMode) {
          print('❌ [FacilityStatsService] materialize: failed to create unit $unitNumber: $e');
        }
      }
    }
    await updateFacilityStats(facilityId);
    if (kDebugMode) {
      print('✅ [FacilityStatsService] materializeMissingUnitDocumentsUpToCapacity: created=$created, healed=$healed');
    }
    return (created: created, healed: healed);
  }
}
