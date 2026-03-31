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
  /// Returns (totalUnits, occupiedUnits). Used by Facilities card and any live display.
  static Future<({int totalUnits, int occupiedUnits})> computeUnitCounts(String facilityId) async {
    try {
      final units = await UnitService.getUnitsForFacility(facilityId);
      final tenantIds = await _getTenantIdsForFacility(facilityId);
      final facility = await FacilityService.getFacility(facilityId);
      final facilityCapacity = facility?.totalUnits ?? 0;
      final totalUnits = count_helpers.effectiveTotalUnits(facilityCapacity, units.length);
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
      final facilityCapacity = facility?.totalUnits ?? 0;
      final units = await UnitService.getUnitsForFacility(facilityId);
      final tenantIds = await _getTenantIdsForFacility(facilityId);
      final occupiedUnits = _canonicalOccupiedCount(units, tenantIds);
      final totalUnits = count_helpers.effectiveTotalUnits(facilityCapacity, units.length);
      final availableUnits = (totalUnits - occupiedUnits).clamp(0, totalUnits);

      final tenants = await TenantService.getTenantsForFacility(facilityId);
      final activeTenants = tenants.where((t) => t.isActive == true).toList();
      final totalTenantsActive = activeTenants.length;
      
      // Calculate scheduled monthly revenue (sum of all active tenant monthlyRate)
      double scheduledMonthlyRevenue = 0.0;
      double autopayMonthlyRevenue = 0.0;
      
      for (final tenant in activeTenants) {
        scheduledMonthlyRevenue += tenant.monthlyRate;
        
        // For autopay revenue, check if tenant has autopay enabled
        // (This would require checking payment methods - for now, assume based on field if it exists)
        // You may need to query Stripe customer metadata or a separate autopay field
        // For now, we'll just track scheduled revenue
      }
      
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
        print('   - Scheduled monthly revenue: \$${scheduledMonthlyRevenue.toStringAsFixed(2)}');
        print('   - Past due: $totalPastDue (late: $tenantsLate, overdue: $tenantsOverdue, severe: $tenantsSeverelyOverdue)');
      }
      
      return {
        'totalUnits': totalUnits,
        'occupiedUnits': occupiedUnits,
        'availableUnits': availableUnits,
        'totalTenantsActive': totalTenantsActive,
        'scheduledMonthlyRevenue': scheduledMonthlyRevenue,
        'autopayMonthlyRevenue': autopayMonthlyRevenue, // TODO: Implement autopay detection
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
  /// Also updates facility.occupiedUnits so facility doc and stats stay in sync.
  static Future<void> updateFacilityStats(String facilityId) async {
    try {
      final stats = await computeFacilityStats(facilityId, healFirst: true);
      final occupied = (stats['occupiedUnits'] as int?) ?? 0;

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('stats')
          .doc('current')
          .set(stats, SetOptions(merge: true));

      await _firestore.collection('facilities').doc(facilityId).update({
        'occupiedUnits': occupied,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [FacilityStatsService] Updated facility stats + occupied=$occupied for $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Error updating facility stats: $e');
      }
      // Don't throw - this is a background sync operation
    }
  }

  /// Update facility document with occupied count only.
  /// Does NOT overwrite totalUnits - that is the user-set capacity.
  static Future<void> refreshFacilityCounts(String facilityId) async {
    try {
      final counts = await computeUnitCounts(facilityId);
      
      // Only update occupiedUnits - totalUnits is user-set capacity and must not be overwritten
      await _firestore.collection('facilities').doc(facilityId).update({
        'occupiedUnits': counts.occupiedUnits,
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

        // Cache often has unit capacity pre-seeded (e.g. imports) while tenant aggregates
        // were never recomputed → dashboard shows 0 tenants but Tenants list has rows.
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

        final facility = await FacilityService.getFacility(facilityId);
        final facilityCapacity = facility?.totalUnits ?? 0;
        final cachedTotalUnits = (cached['totalUnits'] as int?) ?? 0;
        if (facilityCapacity > 0 && cachedTotalUnits != facilityCapacity) {
          if (kDebugMode) {
            print('🔄 [FacilityStatsService] Cached stats stale (capacity $cachedTotalUnits != facility $facilityCapacity), recomputing...');
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

        // Capacity unset (0): effective total is unit-document count — refresh if cache drifted.
        if (facilityCapacity == 0 && cachedTotalUnits > 0) {
          final units = await UnitService.getUnitsForFacility(facilityId);
          if (cachedTotalUnits != units.length) {
            if (kDebugMode) {
              print(
                '🔄 [FacilityStatsService] Cached totalUnits $cachedTotalUnits != ${units.length} unit docs (capacity 0), recomputing...',
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

  /// Recompute stats for all facilities; reconciles unit docs to capacity then updates stats. Idempotent.
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

  /// Ensure unit doc count matches facility.totalUnits (capacity). Creates missing units; does not delete.
  /// Call from "Sync counts" or after facility totalUnits edit. Idempotent.
  static Future<({int created, int healed})> reconcileUnitsToCapacity(String facilityId) async {
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
          print('❌ [FacilityStatsService] reconcile: failed to create unit $unitNumber: $e');
        }
      }
    }
    await updateFacilityStats(facilityId);
    if (kDebugMode) {
      print('✅ [FacilityStatsService] reconcileUnitsToCapacity: created=$created, healed=$healed for $facilityId');
    }
    return (created: created, healed: healed);
  }
}
