import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import '../services/facility_service.dart';
import '../services/tenant_service.dart';
import '../services/unit_service.dart';
import '../services/payment_service.dart';
import '../services/contract_service.dart';
import '../services/late_logic_service.dart';
import '../services/ledger_service.dart';
import '../models/unit_model.dart';
import '../models/contract_model.dart';
import '../models/tenant_model.dart';
import '../providers/auth_provider.dart';

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

/// Provider for dashboard statistics across all facilities
final dashboardStatsProvider = FutureProvider<DashboardStats>((ref) async {
  final userId = ref.watch(authStateProvider).value?.uid;
  if (userId == null) {
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

  // Get all facilities for user
  final facilities = await FacilityService.getUserFacilities();
  
  int totalTenants = 0;
  int totalUnits = 0;
  int occupiedUnits = 0;
  double monthlyRevenue = 0.0;
  int pastDueCount = 0;

  // Aggregate data across all facilities
  for (final facility in facilities) {
    // Get tenants
    final tenants = await TenantService.getTenantsForFacility(facility.id);
    totalTenants += tenants.length;
    
    // Calculate monthly revenue
    for (final tenant in tenants) {
      monthlyRevenue += tenant.monthlyRate;
    }
    
    // Get units
    final units = await UnitService.getUnitsForFacility(facility.id);
    totalUnits += units.length;
    occupiedUnits += units.where((u) => u.status == UnitStatus.occupied).length;
    
    // Get past due payments
    final payments = await PaymentService.getPaymentsForFacility(facility.id);
    pastDueCount += payments.where((p) => p.isOverdue).length;
  }

  final availableUnits = totalUnits - occupiedUnits;
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
      print('Error getting delinquent tenants for facility ${facility.id}: $e');
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
