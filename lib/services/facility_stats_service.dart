import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/facility_model.dart';
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
///
/// Stats docs and the facility-doc mirror (`occupiedUnits`, `unitDocCount`) are
/// written only by the Cloud Function (functions-facility-ops facility_stats.ts)
/// on every unit and tenant write, nightly, and on "Sync counts". The client
/// never frees units: see [updateFacilityStats].
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

  /// True if the facility has at least one active tenant (cheap `limit(1)`
  /// probe). For the onboarding checklist, which only needs yes or no.
  static Future<bool> facilityHasAnyActiveTenant(String facilityId) async {
    try {
      final snap = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();
      return snap.docs.isNotEmpty;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [FacilityStatsService] facilityHasAnyActiveTenant failed: $e');
      }
      return false;
    }
  }

  /// Whether counts read for a facility agree with the counts the Cloud
  /// Function mirrors onto its doc (`unitDocCount`, `occupiedUnits`), which
  /// use the same rule as [countUnits].
  ///
  /// [computeUnitCounts] turns a failed read into (0, 0), and a failed tenant
  /// read into 0 occupied. A facility card that kept such a result until the
  /// mirror changed showed it long after the read recovered.
  static bool countsMatchFacilityMirror(
    ({int totalUnits, int occupiedUnits}) counts,
    FacilityModel facility,
  ) {
    return counts.totalUnits == facility.unitDocCount &&
        counts.occupiedUnits == facility.occupiedUnits;
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

  /// Units that count toward rentable-inventory stats (Total/Occupied/Vacant/
  /// Available Units). Excludes staff-only spaces (manager residence, office,
  /// personal-use) that have `publicListingEnabled == false` — the same flag
  /// that already keeps them off the public map/website, so an operator's
  /// internal-use tracking entries don't inflate their own dashboard numbers.
  static List<UnitModel> _rentableUnits(List<UnitModel> units) {
    return units.where((u) => u.publicListingEnabled).toList();
  }

  /// The one definition of Total and Occupied units, used by every screen.
  ///
  /// - TOTAL: [nonArchivedUnits] that are not staff-only
  ///   (`publicListingEnabled != false`, see [_rentableUnits]).
  /// - OCCUPIED: of those, status occupied with a tenantId in [allTenantIds].
  ///   Pass every tenant doc id, active or archived: archiving a tenant does
  ///   not free their unit, so the unit still reads Occupied in the list.
  /// - VACANT is TOTAL − OCCUPIED (reserved and maintenance count as vacant).
  ///
  /// The dashboard used to count staff-only units and only active tenants, so
  /// it disagreed with the Units list and the facility cards (82/74 against
  /// 78/72 at one facility). The Cloud Function applies the same rule to the
  /// facility-doc mirror (`isRentableUnit` in facility_stats.ts).
  static ({int totalUnits, int occupiedUnits}) countUnits(
    List<UnitModel> nonArchivedUnits,
    Set<String> allTenantIds,
  ) {
    final rentable = _rentableUnits(nonArchivedUnits);
    return (
      totalUnits: rentable.length,
      occupiedUnits: _canonicalOccupiedCount(rentable, allTenantIds),
    );
  }

  /// Whether a cached stats `totalUnits` disagrees with the live unit list.
  ///
  /// Compares against the rentable count, which is what the writer stores.
  /// Comparing with every unit meant any facility with a staff-only unit
  /// looked stale on every read and recomputed forever.
  static bool cachedUnitTotalDrifted(
    int cachedTotalUnits,
    List<UnitModel> nonArchivedUnits,
  ) {
    return cachedTotalUnits != _rentableUnits(nonArchivedUnits).length;
  }

  /// Compute total and occupied unit counts with [countUnits] (no heal).
  /// `totalUnits` is the count of rentable unit documents that actually exist
  /// for the facility — the user-set capacity max is never used here.
  static Future<({int totalUnits, int occupiedUnits})> computeUnitCounts(String facilityId) async {
    try {
      final results = await Future.wait<Object>([
        UnitService.getUnitsForFacility(facilityId),
        _getTenantIdsForFacility(facilityId),
      ]);
      return countUnits(
        results[0] as List<UnitModel>,
        results[1] as Set<String>,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Error computing unit counts: $e');
      }
      return (totalUnits: 0, occupiedUnits: 0);
    }
  }

  /// Kept so existing callers compile; does nothing, on purpose.
  ///
  /// It used to heal orphan units and then write the stats doc and the
  /// facility-doc mirror from the client. The writes were always denied (no
  /// rule covers `facilities/{id}/stats`), so its only effect was the heal —
  /// and that heal trusted [TenantService.getTenantsForFacility], which was
  /// then capped at 250 and dropped tenant docs with no `name`, and still
  /// returns `[]` on any error. One failed or truncated tenant read marked
  /// every occupied unit available. Callers awaited all of that on tenant and
  /// unit saves.
  ///
  /// The Cloud Function already recomputes and heals on every unit and tenant
  /// write (and nightly), from uncapped reads that must all succeed before it
  /// touches a unit, so the write that prompted this call has already queued
  /// that. For an explicit refresh use [recomputeFacilityStats].
  static Future<void> updateFacilityStats(
    String facilityId, {
    /// Ignored; kept for source compatibility.
    bool force = false,
  }) async {}

  /// Ask the server to heal and recompute one facility's stats
  /// (`updateFacilityStatsManual` in functions-facility-ops). The server
  /// checks the caller's access to the facility, reads every unit and tenant
  /// with no cap, heals only after every read succeeds, and writes the stats
  /// doc and the facility-doc mirror.
  ///
  /// Throws if the server did not finish, so a caller can never report a sync
  /// that did not happen.
  static Future<void> recomputeFacilityStats(String facilityId) async {
    await FirebaseFunctions.instance
        .httpsCallable('updateFacilityStatsManual')
        .call(<String, dynamic>{'facilityId': facilityId});
  }

  /// [recomputeFacilityStats] for every facility the user can see, in
  /// parallel. Counts failures instead of stopping at the first, so "Sync
  /// counts" can say exactly how many facilities were not updated.
  static Future<({int synced, int failed})> recomputeAllFacilitiesStats() async {
    final facilities = await FacilityService.getUserFacilities();
    return runForEachFacility(
      facilities.map((f) => f.id).toList(),
      recomputeFacilityStats,
    );
  }

  /// Runs [task] for every id at once and tallies how many threw. Split out
  /// of [recomputeAllFacilitiesStats] so the tally is testable.
  static Future<({int synced, int failed})> runForEachFacility(
    List<String> facilityIds,
    Future<void> Function(String facilityId) task,
  ) async {
    var failed = 0;
    await Future.wait(facilityIds.map((id) async {
      try {
        await task(id);
      } catch (e) {
        failed++;
        if (kDebugMode) {
          print('❌ [FacilityStatsService] Stats sync failed for $id: $e');
        }
      }
    }));
    return (synced: facilityIds.length - failed, failed: failed);
  }

  /// The message "Sync counts" shows for a result, and whether it is an error.
  ///
  /// Both buttons used to report "Counts synced" unconditionally, even though
  /// every stats write behind them was denied.
  static ({String message, bool isError}) syncCountsMessage(
    ({int synced, int failed}) result,
  ) {
    final total = result.synced + result.failed;
    if (total == 0) {
      // The button only shows for an owner with facilities, and
      // getUserFacilities returns [] when its read fails, so an empty list
      // here is a failed load. It used to read as a green "nothing to do".
      return (
        message: 'Could not load your facilities to sync. Try again in a moment.',
        isError: true,
      );
    }
    if (result.failed > 0) {
      // "Could not finish", not "nothing was changed": the server can heal
      // units before a later step of the same pass fails.
      return (
        message: result.failed == total
            ? 'Could not finish syncing counts. Try again in a moment.'
            : 'Could not finish syncing counts for ${result.failed} of $total facilities. Try again in a moment.',
        isError: true,
      );
    }
    return (
      message: total == 1
          ? 'Counts rechecked and updated.'
          : 'Counts rechecked and updated for all $total facilities.',
      isError: false,
    );
  }

  static Future<void> _tryServerRecompute(String facilityId) async {
    try {
      await recomputeFacilityStats(facilityId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [FacilityStatsService] Server recompute failed for $facilityId: $e');
      }
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
            await _tryServerRecompute(facilityId);
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
          await _tryServerRecompute(facilityId);
          return (await _firestore
                  .collection('facilities')
                  .doc(facilityId)
                  .collection('stats')
                  .doc('current')
                  .get())
              .data();
        }

        // Cached `totalUnits` is the rentable unit-document count. Compare
        // against the live count and refresh if the cache drifted (e.g. unit
        // docs were added/removed without triggering a recompute yet).
        final cachedTotalUnits = (cached['totalUnits'] as int?) ?? 0;
        final units = await UnitService.getUnitsForFacility(facilityId);
        if (cachedUnitTotalDrifted(cachedTotalUnits, units)) {
          if (kDebugMode) {
            print(
              '🔄 [FacilityStatsService] Cached totalUnits $cachedTotalUnits != live rentable count, recomputing...',
            );
          }
          await _tryServerRecompute(facilityId);
          return (await _firestore
                  .collection('facilities')
                  .doc(facilityId)
                  .collection('stats')
                  .doc('current')
                  .get())
              .data();
        }

        // Stale past-due count (e.g. cloud stats written before a payment landed).
        final cachedPastDue = (cached['totalPastDue'] as int?) ?? 0;
        if (cachedPastDue > 0) {
          final facility = await FacilityService.getFacility(facilityId);
          final graceDays = LateLogicService.gracePeriodDaysFromBillingSettings(
            facility?.billingSettings,
          );
          final tenants = await TenantService.getTenantsForFacility(facilityId);
          final livePastDue = LateLogicService.countLateTenants(
            tenants.where((t) => t.isActive == true),
            gracePeriodDays: graceDays,
          );
          if (livePastDue != cachedPastDue) {
            if (kDebugMode) {
              print(
                '🔄 [FacilityStatsService] Stale past due ($cachedPastDue cached, $livePastDue live), recomputing...',
              );
            }
            await _tryServerRecompute(facilityId);
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
      await _tryServerRecompute(facilityId);
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
}
