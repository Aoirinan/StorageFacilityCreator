import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import '../services/facility_service.dart';
import '../services/superadmin_service.dart';
import '../services/tenant_service.dart';
import '../services/unit_service.dart';
import '../services/contract_service.dart';
import '../services/late_logic_service.dart';
import '../services/ledger_service.dart';
import '../services/facility_stats_service.dart';
import '../models/facility_model.dart';
import '../models/unit_model.dart';
import '../models/contract_model.dart';
import '../models/tenant_model.dart';
import '../providers/auth_provider.dart';
import '../providers/active_facility_provider.dart';
import '../utils/chunked_parallel.dart';

/// Dashboard statistics for all facilities
class DashboardStats {
  final int totalFacilities;
  final int totalTenants;
  /// Rentable units: non-archived and not staff-only. See
  /// [FacilityStatsService.countUnits].
  final int totalUnits;
  final int occupiedUnits;
  final int availableUnits;
  /// Every non-archived unit doc, staff-only included. "Has this owner added
  /// units yet?" checks use this: [totalUnits] leaves staff-only units out, so
  /// a facility of only office units would read as having none.
  final int totalUnitDocs;
  final double occupancyRate;
  final double monthlyRevenue;
  /// Subset of [monthlyRevenue] from tenants with autopay ON (cached stats field).
  final double autopayMonthlyRevenue;
  final int pastDueCount;
  final int openLeads;
  final List<TopDelinquentTenant> topDelinquentTenants; // Top 5
  final List<UpcomingMoveOut> upcomingMoveOuts; // Next 7 days

  DashboardStats({
    required this.totalFacilities,
    required this.totalTenants,
    required this.totalUnits,
    required this.occupiedUnits,
    required this.availableUnits,
    this.totalUnitDocs = 0,
    required this.occupancyRate,
    required this.monthlyRevenue,
    this.autopayMonthlyRevenue = 0.0,
    required this.pastDueCount,
    required this.openLeads,
    this.topDelinquentTenants = const [],
    this.upcomingMoveOuts = const [],
  });

  /// Staff-only units (office, manager residence, personal use) that exist but
  /// are left out of [totalUnits], [occupiedUnits] and [availableUnits].
  int get staffOnlyUnits {
    final n = totalUnitDocs - totalUnits;
    return n > 0 ? n : 0;
  }
}

/// Top delinquent tenant info for dashboard
class TopDelinquentTenant {
  final String tenantId;
  final String tenantName;
  final String facilityId;
  final String facilityName;
  final double balanceDue;
  final int daysLate;

  TopDelinquentTenant({
    required this.tenantId,
    required this.tenantName,
    required this.facilityId,
    required this.facilityName,
    required this.balanceDue,
    required this.daysLate,
  });
}

/// Upcoming move-out info for dashboard
class UpcomingMoveOut {
  final String contractId;
  final String tenantId;
  final String tenantName;
  final String facilityId;
  final String facilityName;
  final String unitNumber;
  final DateTime moveOutDate;
  final int daysUntil;

  UpcomingMoveOut({
    required this.contractId,
    required this.tenantId,
    required this.tenantName,
    required this.facilityId,
    required this.facilityName,
    required this.unitNumber,
    required this.moveOutDate,
    required this.daysUntil,
  });
}

DashboardStats _emptyStats() => DashboardStats(
      totalFacilities: 0,
      totalTenants: 0,
      totalUnits: 0,
      occupiedUnits: 0,
      availableUnits: 0,
      occupancyRate: 0.0,
      monthlyRevenue: 0.0,
      autopayMonthlyRevenue: 0.0,
      pastDueCount: 0,
      openLeads: 0,
    );

/// True while the saved facility selection has not been read yet.
///
/// The dashboard read that state as null ("All Facilities"), so every cold load
/// and every facility switch ran the whole load for all facilities, then threw
/// it away when the real id arrived a moment later.
bool dashboardWaitsForActiveFacility(AsyncValue<String?> activeFacilityId) =>
    activeFacilityId.isLoading && !activeFacilityId.hasValue;

/// Provider for dashboard statistics
/// Filters by activeFacilityId if set, otherwise shows all facilities
///
/// autoDispose so each visit to the dashboard loads fresh numbers. It used to
/// load once per session and keep showing those numbers after units, tenants
/// and payments changed, until a browser reload.
final dashboardStatsProvider = FutureProvider.autoDispose<DashboardStats>((ref) async {
  final userId = ref.watch(authStateProvider).whenOrNull(data: (d) => d)?.uid;
  if (userId == null) {
    if (kDebugMode) {
      print('🔍 [Dashboard] No user ID - returning zeros');
    }
    return _emptyStats();
  }

  // Get active facility ID (null = All Facilities)
  final activeFacilityIdState = ref.watch(activeFacilityIdProvider);
  if (dashboardWaitsForActiveFacility(activeFacilityIdState)) {
    // Rebuilt as soon as the id resolves.
    return Completer<DashboardStats>().future;
  }
  final activeFacilityId = activeFacilityIdState.whenOrNull(data: (d) => d);

  final fbUser = FirebaseAuth.instance.currentUser;
  if (fbUser != null &&
      !fbUser.emailVerified &&
      !SuperAdminService.isSuperAdmin(fbUser)) {
    if (kDebugMode) {
      print('🔍 [Dashboard] User not verified — skip Firestore (verify-email flow)');
    }
    return _emptyStats();
  }

  if (kDebugMode) {
    print('🔍 [Dashboard] User ID: $userId, active facility: $activeFacilityId');
  }

  // Get all facilities for user
  final allFacilities = await FacilityService.getUserFacilities();

  // null = "All Facilities" (aggregate across all). Non-null = single facility.
  final facilities = activeFacilityId == null
      ? allFacilities
      : allFacilities.where((f) => f.id == activeFacilityId).toList();

  if (facilities.isEmpty) {
    if (kDebugMode) {
      print('🔍 [Dashboard] No facilities to query - returning zeros');
    }
    return _emptyStats();
  }

  return loadDashboardStats(facilities, DateTime.now());
});

/// The dashboard numbers for [facilities]; [dashboardStatsProvider] picks
/// which (the active facility, or all). Tests call this so the real tenant
/// and unit reads and the real per-facility counting run against fake
/// collections.
@visibleForTesting
Future<DashboardStats> loadDashboardStats(
  List<FacilityModel> facilities,
  DateTime now,
) async {
  // Facilities load side by side rather than one after another.
  final perFacility = await Future.wait(
    facilities.map((facility) => _loadFacilityDashboard(facility, now)),
  );

  int totalTenants = 0;
  int totalUnits = 0;
  int occupiedUnits = 0;
  int totalUnitDocs = 0;
  double monthlyRevenue = 0.0;
  double autopayMonthlyRevenue = 0.0;
  int pastDueCount = 0;
  int openLeads = 0;
  final topDelinquentTenants = <TopDelinquentTenant>[];
  final upcomingMoveOuts = <UpcomingMoveOut>[];
  for (final f in perFacility) {
    totalTenants += f.activeTenants;
    totalUnits += f.totalUnits;
    occupiedUnits += f.occupiedUnits;
    totalUnitDocs += f.unitDocs;
    monthlyRevenue += f.monthlyRevenue;
    autopayMonthlyRevenue += f.autopayMonthlyRevenue;
    pastDueCount += f.pastDue;
    openLeads += f.openLeads;
    topDelinquentTenants.addAll(f.delinquent);
    upcomingMoveOuts.addAll(f.moveOuts);
  }

  if (kDebugMode) {
    print('📊 [Dashboard] FINAL TOTALS:');
    print('   - Total tenants: $totalTenants');
    print('   - Total units: $totalUnits (occupied: $occupiedUnits, unit docs: $totalUnitDocs)');
    print(
      '   - Monthly revenue: \$${monthlyRevenue.toStringAsFixed(2)} (autopay \$${autopayMonthlyRevenue.toStringAsFixed(2)})',
    );
    print('   - Past due: $pastDueCount');
  }

  final rawAvailable = totalUnits - occupiedUnits;
  final availableUnits = rawAvailable < 0 ? 0 : rawAvailable;
  final occupancyRate = totalUnits > 0 ? (occupiedUnits / totalUnits) : 0.0;

  // Sort by balance due (descending) and take top 5
  topDelinquentTenants.sort((a, b) => b.balanceDue.compareTo(a.balanceDue));
  final top5Delinquent = topDelinquentTenants.take(5).toList();

  // Sort upcoming move-outs by date (ascending)
  upcomingMoveOuts.sort((a, b) => a.moveOutDate.compareTo(b.moveOutDate));

  return DashboardStats(
    totalFacilities: facilities.length,
    totalTenants: totalTenants,
    totalUnits: totalUnits,
    occupiedUnits: occupiedUnits,
    availableUnits: availableUnits,
    totalUnitDocs: totalUnitDocs,
    occupancyRate: occupancyRate,
    monthlyRevenue: monthlyRevenue,
    autopayMonthlyRevenue: autopayMonthlyRevenue,
    pastDueCount: pastDueCount,
    openLeads: openLeads,
    topDelinquentTenants: top5Delinquent,
    upcomingMoveOuts: upcomingMoveOuts,
  );
}

/// One facility's share of the dashboard.
class _FacilityDashboard {
  final int activeTenants;
  final double monthlyRevenue;
  final double autopayMonthlyRevenue;
  final int totalUnits;
  final int occupiedUnits;
  final int unitDocs;
  final int pastDue;
  final int openLeads;
  final List<TopDelinquentTenant> delinquent;
  final List<UpcomingMoveOut> moveOuts;

  const _FacilityDashboard({
    required this.activeTenants,
    required this.monthlyRevenue,
    required this.autopayMonthlyRevenue,
    required this.totalUnits,
    required this.occupiedUnits,
    required this.unitDocs,
    required this.pastDue,
    required this.openLeads,
    required this.delinquent,
    required this.moveOuts,
  });
}

/// Loads one facility in one wave, then its ledger balances and move-outs in
/// a second. This used to be a dozen or more round trips in series, reading
/// tenants and units twice, plus one ledger sum per overdue tenant.
///
/// Totals are computed from the tenant and unit lists, which is what
/// production always showed: the cached stats doc it tried first is
/// unreadable from the client (no rule covers it). The two background stats
/// refreshes it fired are gone too; their writes were always denied and
/// their only effect was a client-side orphan heal that could free rented
/// units from a short tenant list.
Future<_FacilityDashboard> _loadFacilityDashboard(
  FacilityModel facility,
  DateTime now,
) async {
  final tenantsFuture = TenantService.getTenantsForFacility(facility.id);
  final wave = await Future.wait<Object>([
    tenantsFuture,
    UnitService.getUnitsForFacility(facility.id),
    _countOpenLeads(facility.id),
    _overdueTenants(facility, tenantsFuture),
  ]);
  final tenants = wave[0] as List<TenantModel>;
  final units = wave[1] as List<UnitModel>;
  final openLeads = wave[2] as int;
  final overdue = wave[3] as List<TenantOverdueInfo>;

  final activeTenants = tenants.where((t) => t.isActive == true).toList();
  double facilityRevenue = 0.0;
  for (final tenant in activeTenants) {
    facilityRevenue += tenant.monthlyRate;
  }

  final counts = facilityUnitCounts(units, tenants);

  // Count past due tenants using facility's grace period (Billing Settings)
  final graceDays = LateLogicService.gracePeriodDaysFromBillingSettings(
    facility.billingSettings,
  );
  final pastDue = LateLogicService.countLateTenants(
    activeTenants,
    gracePeriodDays: graceDays,
  );

  final second = await Future.wait<Object>([
    _delinquentWithBalances(facility, overdue),
    _upcomingMoveOuts(facility, units, tenants, now),
  ]);

  if (kDebugMode) {
    print('📊 [Dashboard] ${facility.name}: ${activeTenants.length} active tenants, '
        '${counts.occupiedUnits}/${counts.totalUnits} rentable units occupied '
        '(${counts.unitDocs} unit docs), past due $pastDue');
  }

  return _FacilityDashboard(
    activeTenants: activeTenants.length,
    monthlyRevenue: facilityRevenue,
    autopayMonthlyRevenue:
        FacilityStatsService.sumAutopayMonthlyRevenue(activeTenants),
    totalUnits: counts.totalUnits,
    occupiedUnits: counts.occupiedUnits,
    unitDocs: counts.unitDocs,
    pastDue: pastDue,
    openLeads: openLeads,
    delinquent: second[0] as List<TopDelinquentTenant>,
    moveOuts: second[1] as List<UpcomingMoveOut>,
  );
}

/// One facility's unit numbers for the dashboard: rentable total and
/// occupied by [FacilityStatsService.countUnits], plus every unit doc.
///
/// [tenants] is every tenant doc, archived included: archiving a tenant does
/// not free the unit. The dashboard used to count only units held by active
/// tenants, and staff-only units too, so it disagreed with the Units list and
/// the facility cards (82/74 against 78/72 at one facility).
({int totalUnits, int occupiedUnits, int unitDocs}) facilityUnitCounts(
  List<UnitModel> units,
  List<TenantModel> tenants,
) {
  final counts = FacilityStatsService.countUnits(
    units,
    {for (final t in tenants) t.id},
  );
  return (
    totalUnits: counts.totalUnits,
    occupiedUnits: counts.occupiedUnits,
    unitDocs: units.length,
  );
}

Future<List<TenantOverdueInfo>> _overdueTenants(
  FacilityModel facility,
  Future<List<TenantModel>> tenants,
) async {
  try {
    return await LateLogicService.getTenantsWithOverduePayments(
      facility.id,
      facility: facility,
      tenants: tenants,
    );
  } catch (e) {
    // Continue if error getting delinquent tenants for one facility
    if (kDebugMode) {
      print('Error getting delinquent tenants for facility ${facility.id}: $e');
    }
    return const [];
  }
}

Future<List<TopDelinquentTenant>> _delinquentWithBalances(
  FacilityModel facility,
  List<TenantOverdueInfo> overdue,
) async {
  final withBalances = await positiveBalances<TenantOverdueInfo>(
    overdue,
    // The uncapped server sum: a balance must never be a partial sum.
    (info) => LedgerService.getLedgerBalance(
      tenantId: info.tenant.id,
      facilityId: facility.id,
    ),
  );
  return [
    for (final (info, balance) in withBalances)
      TopDelinquentTenant(
        tenantId: info.tenant.id,
        tenantName: info.tenant.name,
        facilityId: facility.id,
        facilityName: facility.name,
        balanceDue: balance,
        daysLate: info.maxDaysOverdue,
      ),
  ];
}

/// [items] paired with their balance from [fetch], keeping only balances above
/// zero, in the order of [items].
///
/// Fetched [chunkSize] at a time rather than one after another. An item whose
/// fetch throws is logged and left out; it used to abandon the rest of that
/// facility's list.
Future<List<(T, double)>> positiveBalances<T>(
  List<T> items,
  Future<double> Function(T item) fetch, {
  int chunkSize = 10,
}) async {
  final balances = await mapInChunks<T, double?>(
    items,
    (item) async {
      try {
        return await fetch(item);
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ [Dashboard] Balance lookup failed, leaving it out: $e');
        }
        return null;
      }
    },
    chunkSize: chunkSize,
  );
  return [
    for (var i = 0; i < items.length; i++)
      if (balances[i] != null && balances[i]! > 0) (items[i], balances[i]!),
  ];
}

/// Occupied units whose expected move-out (notice date + 30 days) falls in
/// the next 7 days after [now], paired with that date.
List<({UnitModel unit, DateTime moveOutDate})> upcomingMoveOutUnits(
  Iterable<UnitModel> units,
  DateTime now,
) {
  final next7Days = now.add(const Duration(days: 7));
  final due = <({UnitModel unit, DateTime moveOutDate})>[];
  for (final unit in units) {
    if (unit.status != UnitStatus.occupied || unit.tenantId == null) continue;
    final noticeDate = unit.moveOutNoticeDate;
    if (noticeDate == null) continue;
    // Calculate expected move-out date (typically 30 days after notice, but could vary)
    // For now, use notice date + 30 days, or we could add a field for scheduled move-out date
    final expectedMoveOutDate = noticeDate.add(const Duration(days: 30));
    if (expectedMoveOutDate.isAfter(now) && expectedMoveOutDate.isBefore(next7Days)) {
      due.add((unit: unit, moveOutDate: expectedMoveOutDate));
    }
  }
  return due;
}

Future<List<UpcomingMoveOut>> _upcomingMoveOuts(
  FacilityModel facility,
  List<UnitModel> units,
  List<TenantModel> tenants,
  DateTime now,
) async {
  try {
    final due = upcomingMoveOutUnits(units, now);
    if (due.isEmpty) return const [];

    // Tenants from the list already loaded; read by id only for one the
    // capped list missed. It used to read each tenant doc again.
    final tenantsById = {for (final t in tenants) t.id: t};
    final dueTenants = await Future.wait(due.map((d) async =>
        tenantsById[d.unit.tenantId] ??
        await TenantService.getTenantById(facility.id, d.unit.tenantId!)));
    if (dueTenants.every((t) => t == null)) return const [];

    // Contracts once per facility, and only when something is due. This used
    // to re-read every contract inside the loop, once per unit.
    List<ContractModel> contracts = const [];
    try {
      contracts = await ContractService.getContractsForFacility(facility.id);
    } catch (e) {
      // Ignore contract lookup errors (contractId can be empty if not found)
    }

    final moveOuts = <UpcomingMoveOut>[];
    for (var i = 0; i < due.length; i++) {
      final tenant = dueTenants[i];
      if (tenant == null) continue;
      final activeContract = contracts
          .where(
            (c) => c.tenantId == tenant.id && c.isActive && c.status != ContractStatus.cancelled,
          )
          .firstOrNull;
      moveOuts.add(UpcomingMoveOut(
        contractId: activeContract?.id ?? '',
        tenantId: tenant.id,
        tenantName: tenant.name,
        facilityId: facility.id,
        facilityName: facility.name,
        unitNumber: due[i].unit.unitNumber,
        moveOutDate: due[i].moveOutDate,
        daysUntil: due[i].moveOutDate.difference(now).inDays,
      ));
    }
    return moveOuts;
  } catch (e) {
    // Continue if error getting move-outs for one facility
    if (kDebugMode) {
      print('Error getting move-outs for facility ${facility.id}: $e');
    }
    return const [];
  }
}

/// Open leads (active reservations) for one facility; 0 on error so the
/// dashboard still loads.
Future<int> _countOpenLeads(String facilityId) async {
  try {
    // Count reservations with status pending or confirmed that haven't expired
    final now = DateTime.now();
    final snapshot = await FirebaseFirestore.instance
        .collection('publicReservations')
        .where('facilityId', isEqualTo: facilityId)
        .where('status', whereIn: ['pending', 'confirmed'])
        .get();

    // Filter out expired reservations
    return snapshot.docs.where((doc) {
      final data = doc.data();
      final expiresAt = data['expiresAt'] as Timestamp?;
      if (expiresAt != null && now.isAfter(expiresAt.toDate())) {
        return false;
      }
      return true;
    }).length;
  } catch (e) {
    // Skip facilities with errors, continue with others
    if (kDebugMode) {
      print('⚠️ Error counting leads for facility $facilityId: $e');
    }
    return 0;
  }
}
