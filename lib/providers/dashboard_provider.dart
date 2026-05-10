import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import '../services/facility_service.dart';
import '../services/superadmin_service.dart';
import '../services/tenant_service.dart';
import '../services/unit_service.dart';
import '../services/payment_service.dart';
import '../services/contract_service.dart';
import '../services/late_logic_service.dart';
import '../services/ledger_service.dart';
import '../services/facility_stats_service.dart';
import '../models/unit_model.dart';
import '../models/contract_model.dart';
import '../models/tenant_model.dart';
import '../providers/auth_provider.dart';
import '../providers/active_facility_provider.dart';

/// Dashboard statistics for all facilities
class DashboardStats {
  final int totalFacilities;
  final int totalTenants;
  final int totalUnits;
  final int occupiedUnits;
  final int availableUnits;
  final double occupancyRate;
  final double monthlyRevenue;
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
    required this.occupancyRate,
    required this.monthlyRevenue,
    required this.pastDueCount,
    required this.openLeads,
    this.topDelinquentTenants = const [],
    this.upcomingMoveOuts = const [],
  });
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

/// Provider for dashboard statistics
/// Filters by activeFacilityId if set, otherwise shows all facilities
final dashboardStatsProvider = FutureProvider<DashboardStats>((ref) async {
  final userId = ref.watch(authStateProvider).whenOrNull(data: (d) => d)?.uid;
  if (userId == null) {
    if (kDebugMode) {
      print('🔍 [Dashboard] No user ID - returning zeros');
    }
    return DashboardStats(
      totalFacilities: 0,
      totalTenants: 0,
      totalUnits: 0,
      occupiedUnits: 0,
      availableUnits: 0,
      occupancyRate: 0.0,
      monthlyRevenue: 0.0,
      pastDueCount: 0,
      openLeads: 0,
    );
  }

  final fbUser = FirebaseAuth.instance.currentUser;
  if (fbUser != null &&
      !fbUser.emailVerified &&
      !SuperAdminService.isSuperAdmin(fbUser)) {
    if (kDebugMode) {
      print('🔍 [Dashboard] User not verified — skip Firestore (verify-email flow)');
    }
    return DashboardStats(
      totalFacilities: 0,
      totalTenants: 0,
      totalUnits: 0,
      occupiedUnits: 0,
      availableUnits: 0,
      occupancyRate: 0.0,
      monthlyRevenue: 0.0,
      pastDueCount: 0,
      openLeads: 0,
    );
  }

  if (kDebugMode) {
    print('🔍 [Dashboard] User ID: $userId');
  }

  // Get active facility ID (null = All Facilities)
  final activeFacilityIdState = ref.watch(activeFacilityIdProvider);
  final activeFacilityId = activeFacilityIdState.whenOrNull(data: (d) => d);

  if (kDebugMode) {
    print('🔍 [Dashboard] Active facility ID from provider: $activeFacilityId');
    print('🔍 [Dashboard] Active facility state: ${activeFacilityIdState.toString()}');
  }

  // Get all facilities for user
  final allFacilities = await FacilityService.getUserFacilities();
  
  if (kDebugMode) {
    print('🔍 [Dashboard] Total facilities for user: ${allFacilities.length}');
    for (final f in allFacilities) {
      print('   - ${f.name} (${f.id})');
    }
  }
  
  // null = "All Facilities" (aggregate across all). Non-null = single facility.
  final facilities = activeFacilityId == null
      ? allFacilities
      : allFacilities.where((f) => f.id == activeFacilityId).toList();
  
  if (kDebugMode) {
    print('🔍 [Dashboard] Querying ${facilities.length} facilities for stats');
  }
  
  if (facilities.isEmpty) {
    if (kDebugMode) {
      print('🔍 [Dashboard] No facilities to query - returning zeros');
    }
    return DashboardStats(
      totalFacilities: 0,
      totalTenants: 0,
      totalUnits: 0,
      occupiedUnits: 0,
      availableUnits: 0,
      occupancyRate: 0.0,
      monthlyRevenue: 0.0,
      pastDueCount: 0,
      openLeads: 0,
    );
  }
  
  int totalTenants = 0;
  int totalUnits = 0;
  int occupiedUnits = 0;
  double monthlyRevenue = 0.0;
  int pastDueCount = 0;

  // Aggregate data across all facilities using FacilityStatsService
  for (final facility in facilities) {
    if (kDebugMode) {
      print('🔍 [Dashboard] Processing facility: ${facility.name} (${facility.id})');
    }
    
    // Try to get precomputed stats first (fast path)
    final stats = await FacilityStatsService.getFacilityStats(facility.id);
    
    if (stats != null) {
      // Cached stats now hold the actual unit-document count (not the user-set
      // capacity max). Trust them directly — `FacilityStatsService` keeps them
      // in sync with the unit list.
      final statsActive = (stats['totalTenantsActive'] as int?) ?? 0;
      final statsUnits = (stats['totalUnits'] as int?) ?? 0;
      final statsOccupiedRaw = (stats['occupiedUnits'] as int?) ?? 0;
      final statsOccupied =
          statsOccupiedRaw > statsUnits ? statsUnits : statsOccupiedRaw;
      final statsRevenue = (stats['scheduledMonthlyRevenue'] as num?)?.toDouble() ?? 0.0;
      final statsPastDue = (stats['totalPastDue'] as int?) ?? 0;

      totalTenants += statsActive;
      totalUnits += statsUnits;
      occupiedUnits += statsOccupied;
      monthlyRevenue += statsRevenue;
      pastDueCount += statsPastDue;
      
      if (kDebugMode) {
        print('📊 [Dashboard] Using cached stats for ${facility.name}:');
        print('   - Tenants: $statsActive');
        print('   - Units: $statsUnits (occupied: $statsOccupied)');
        print('   - Revenue: \$${statsRevenue.toStringAsFixed(2)}');
        print('   - Past due: $statsPastDue');
      }
    } else {
      // Fallback to computing on-the-fly (slower)
      if (kDebugMode) {
        print('⚠️ [Dashboard] No cached stats for ${facility.name}, computing on-the-fly...');
        print('   Query path: facilities/${facility.id}/tenants');
      }
      
      // Get active tenants only (isActive = true)
      final tenants = await TenantService.getTenantsForFacility(facility.id);
      if (kDebugMode) {
        print('   - Raw tenants count: ${tenants.length}');
      }
      
      final activeTenants = tenants.where((t) => t.isActive == true).toList();
      if (kDebugMode) {
        print('   - Active tenants count: ${activeTenants.length}');
        if (tenants.isNotEmpty && activeTenants.isEmpty) {
          print('   ⚠️ WARNING: Have tenants but NONE are active! Check isActive field.');
          print('   First tenant isActive value: ${tenants.first.isActive}');
        }
      }
      
      totalTenants += activeTenants.length;
      
      // Calculate monthly revenue from active tenants only
      double facilityRevenue = 0.0;
      for (final tenant in activeTenants) {
        facilityRevenue += tenant.monthlyRate;
      }
      monthlyRevenue += facilityRevenue;
      
      if (kDebugMode) {
        print('   - Facility revenue: \$${facilityRevenue.toStringAsFixed(2)}');
      }
      
      // Get units - use canonical occupancy (only count occupied if tenant exists)
      final units = await UnitService.getUnitsForFacility(facility.id);
      final tenantIds = activeTenants.map((t) => t.id).toSet();
      final facilityOccupied = units.where((u) =>
        u.status == UnitStatus.occupied &&
        u.tenantId != null &&
        tenantIds.contains(u.tenantId),
      ).length;
      // Total units = actual count of unit documents (capacity max is editable
      // metadata; the dashboard reflects what's been built/added).
      totalUnits += units.length;
      occupiedUnits += facilityOccupied;
      
      if (kDebugMode) {
        print('   - Units: ${units.length} (occupied: $facilityOccupied)');
      }
      
      // Count past due tenants using facility's grace period (Billing Settings)
      final grace = facility.billingSettings?['gracePeriodDays'];
      final graceDays = (grace is int) ? grace : (grace != null ? int.tryParse(grace.toString()) : null) ?? 3;
      int facilityPastDue = 0;
      for (final tenant in activeTenants) {
        if (LateLogicService.isTenantLate(tenant, gracePeriodDays: graceDays)) {
          facilityPastDue++;
          if (kDebugMode && facilityPastDue <= 3) {
            final tenantDaysLate = LateLogicService.getTenantDaysLate(tenant, gracePeriodDays: graceDays);
            print('   - Late tenant: ${tenant.name}, Days late: $tenantDaysLate, Paid through: ${tenant.paidThrough}');
          }
        }
      }
      pastDueCount += facilityPastDue;
      
      if (kDebugMode) {
        print('   - Past due: $facilityPastDue');
        if (facilityPastDue == 0 && activeTenants.isNotEmpty) {
          // Sample first tenant to check paidThrough logic
          final sample = activeTenants.first;
          print('   - Sample tenant: ${sample.name}, paidThrough: ${sample.paidThrough}, daysLate: ${sample.daysLate}');
        }
      }
      
      // Trigger stats update in background for next time
      FacilityStatsService.updateFacilityStats(facility.id);
    }
  }
  
  if (kDebugMode) {
    print('📊 [Dashboard] FINAL TOTALS:');
    print('   - Total tenants: $totalTenants');
    print('   - Total units: $totalUnits (occupied: $occupiedUnits)');
    print('   - Monthly revenue: \$${monthlyRevenue.toStringAsFixed(2)}');
    print('   - Past due: $pastDueCount');
  }

  final rawAvailable = totalUnits - occupiedUnits;
  final availableUnits = rawAvailable < 0 ? 0 : rawAvailable;
  final occupancyRate = totalUnits > 0 ? (occupiedUnits / totalUnits) : 0.0;

  // Get top 5 delinquent tenants across all facilities
  final topDelinquentTenants = <TopDelinquentTenant>[];
  final now = DateTime.now();
  final next7Days = now.add(const Duration(days: 7));

  for (final facility in facilities) {
    try {
      // Get tenants with overdue payments
      final overdueTenants = await LateLogicService.getTenantsWithOverduePayments(facility.id);
      
      for (final overdueInfo in overdueTenants) {
        final balance = await LedgerService.getLedgerBalance(
          tenantId: overdueInfo.tenant.id,
          facilityId: facility.id,
        );

        if (balance > 0) {
          topDelinquentTenants.add(TopDelinquentTenant(
            tenantId: overdueInfo.tenant.id,
            tenantName: overdueInfo.tenant.name,
            facilityId: facility.id,
            facilityName: facility.name,
            balanceDue: balance,
            daysLate: overdueInfo.maxDaysOverdue,
          ));
        }
      }
    } catch (e) {
      // Continue if error getting delinquent tenants for one facility
      if (kDebugMode) {
        print('Error getting delinquent tenants for facility ${facility.id}: $e');
      }
    }
  }

  // Sort by balance due (descending) and take top 5
  topDelinquentTenants.sort((a, b) => b.balanceDue.compareTo(a.balanceDue));
  final top5Delinquent = topDelinquentTenants.take(5).toList();

  // Get upcoming move-outs (next 7 days) - check units with moveOutNoticeDate
  final upcomingMoveOuts = <UpcomingMoveOut>[];
  
  for (final facility in facilities) {
    try {
      // Get all occupied units
      final units = await UnitService.getUnitsForFacility(facility.id);
      final occupiedUnits = units.where((u) => u.status == UnitStatus.occupied && u.tenantId != null);
      
      for (final unit in occupiedUnits) {
        // Check if unit has a move-out notice date
        if (unit.moveOutNoticeDate != null) {
          final noticeDate = unit.moveOutNoticeDate!;
          // Calculate expected move-out date (typically 30 days after notice, but could vary)
          // For now, use notice date + 30 days, or we could add a field for scheduled move-out date
          final expectedMoveOutDate = noticeDate.add(const Duration(days: 30));
          
          if (expectedMoveOutDate.isAfter(now) && expectedMoveOutDate.isBefore(next7Days)) {
            // Get tenant info
            if (unit.tenantId != null) {
              final tenant = await TenantService.getTenantById(facility.id, unit.tenantId!);
              if (tenant != null) {
                // Get active contract for this tenant (optional - contractId can be empty if not found)
                String contractId = '';
                try {
                  final contracts = await ContractService.getContractsForFacility(facility.id);
                  final activeContract = contracts.where(
                    (c) => c.tenantId == tenant.id && c.isActive && c.status != ContractStatus.cancelled,
                  ).firstOrNull;
                  contractId = activeContract?.id ?? '';
                } catch (e) {
                  // Ignore contract lookup errors
                }
                
                final daysUntil = expectedMoveOutDate.difference(now).inDays;
                upcomingMoveOuts.add(UpcomingMoveOut(
                  contractId: contractId,
                  tenantId: tenant.id,
                  tenantName: tenant.name,
                  facilityId: facility.id,
                  facilityName: facility.name,
                  unitNumber: unit.unitNumber,
                  moveOutDate: expectedMoveOutDate,
                  daysUntil: daysUntil,
                ));
              }
            }
          }
        }
      }
    } catch (e) {
      // Continue if error getting move-outs for one facility
      print('Error getting move-outs for facility ${facility.id}: $e');
    }
  }

  // Sort upcoming move-outs by date (ascending)
  upcomingMoveOuts.sort((a, b) => a.moveOutDate.compareTo(b.moveOutDate));

  return DashboardStats(
    totalFacilities: facilities.length,
    totalTenants: totalTenants,
    totalUnits: totalUnits,
    occupiedUnits: occupiedUnits,
    availableUnits: availableUnits,
    occupancyRate: occupancyRate,
    monthlyRevenue: monthlyRevenue,
    pastDueCount: pastDueCount,
    openLeads: await _getOpenLeadsCount(facilities.map((f) => f.id).toList()),
    topDelinquentTenants: top5Delinquent,
    upcomingMoveOuts: upcomingMoveOuts,
  );
});

/// Helper function to count open leads (active reservations)
Future<int> _getOpenLeadsCount(List<String> facilityIds) async {
  try {
    if (facilityIds.isEmpty) return 0;
    
    // Count reservations with status pending or confirmed that haven't expired
    int totalLeads = 0;
    final now = DateTime.now();
    
    for (final facilityId in facilityIds) {
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('publicReservations')
            .where('facilityId', isEqualTo: facilityId)
            .where('status', whereIn: ['pending', 'confirmed'])
            .get();
        
        // Filter out expired reservations
        final activeLeads = snapshot.docs.where((doc) {
          final data = doc.data();
          final expiresAt = data['expiresAt'] as Timestamp?;
          if (expiresAt != null && now.isAfter(expiresAt.toDate())) {
            return false;
          }
          return true;
        }).length;
        
        totalLeads += activeLeads;
      } catch (e) {
        // Skip facilities with errors, continue with others
        if (kDebugMode) {
          print('⚠️ Error counting leads for facility $facilityId: $e');
        }
      }
    }
    
    return totalLeads;
  } catch (e) {
    if (kDebugMode) {
      print('⚠️ Error getting open leads count: $e');
    }
    return 0; // Return 0 on error to not break dashboard
  }
}
