import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/lead_source_model.dart';
import 'package:sfcapp/models/tenant_model.dart';

/// Service for lead source analytics and reporting
class LeadSourceService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Get lead source statistics for a facility
  static Future<List<LeadSourceStats>> getLeadSourceStats({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final now = DateTime.now();
      final periodStart = startDate ?? DateTime(now.year - 1, 1, 1);
      final periodEnd = endDate ?? now;

      // Get all tenants for this facility
      final tenantsSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(periodStart))
          .where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(periodEnd))
          .get();

      // Group tenants by lead source
      final sourceCounts = <String, int>{};
      final convertedCounts = <String, int>{};

      for (final doc in tenantsSnapshot.docs) {
        final tenantData = doc.data();
        final leadSource = tenantData['leadSource'] as String?;
        
        if (leadSource != null && leadSource.isNotEmpty) {
          // Count total tenants with this lead source
          sourceCounts[leadSource] = (sourceCounts[leadSource] ?? 0) + 1;
          
          // Count converted (active tenants)
          final isActive = tenantData['isActive'] ?? true;
          if (isActive) {
            convertedCounts[leadSource] = (convertedCounts[leadSource] ?? 0) + 1;
          }
        }
      }

      // Build statistics list
      final stats = <LeadSourceStats>[];
      
      // Process each lead source
      for (final sourceName in sourceCounts.keys) {
        try {
          final source = LeadSource.values.firstWhere(
            (s) => s.name == sourceName,
            orElse: () => LeadSource.other,
          );
          
          final count = sourceCounts[sourceName] ?? 0;
          final convertedCount = convertedCounts[sourceName] ?? 0;
          final conversionRate = count > 0 ? (convertedCount / count) * 100 : 0.0;

          stats.add(LeadSourceStats(
            source: source,
            count: count,
            convertedCount: convertedCount,
            conversionRate: conversionRate,
          ));
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Error processing lead source $sourceName: $e');
          }
        }
      }

      // Also add sources with no data (for completeness)
      for (final source in LeadSource.values) {
        if (!sourceCounts.containsKey(source.name)) {
          stats.add(LeadSourceStats(
            source: source,
            count: 0,
            convertedCount: 0,
            conversionRate: 0.0,
          ));
        }
      }

      // Sort by count (descending)
      stats.sort((a, b) => b.count.compareTo(a.count));

      return stats;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting lead source stats: $e');
      }
      return [];
    }
  }

  /// Get lead source statistics summary
  static Future<LeadSourceSummary> getLeadSourceSummary({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final stats = await getLeadSourceStats(
        facilityId: facilityId,
        startDate: startDate,
        endDate: endDate,
      );

      final totalTenants = stats.fold<int>(0, (sum, stat) => sum + stat.count);
      final totalConverted = stats.fold<int>(0, (sum, stat) => sum + stat.convertedCount);
      final overallConversionRate = totalTenants > 0 ? (totalConverted / totalTenants) * 100 : 0.0;

      // Top sources
      final topSources = stats.where((s) => s.count > 0).take(5).toList();

      // Category breakdown
      final categoryBreakdown = <String, int>{};
      for (final stat in stats) {
        if (stat.count > 0) {
          final category = stat.source.category;
          categoryBreakdown[category] = (categoryBreakdown[category] ?? 0) + stat.count;
        }
      }

      return LeadSourceSummary(
        totalTenants: totalTenants,
        totalConverted: totalConverted,
        overallConversionRate: overallConversionRate,
        topSources: topSources,
        categoryBreakdown: categoryBreakdown,
        stats: stats,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting lead source summary: $e');
      }
      return LeadSourceSummary(
        totalTenants: 0,
        totalConverted: 0,
        overallConversionRate: 0.0,
        topSources: [],
        categoryBreakdown: {},
        stats: [],
      );
    }
  }

  /// Get tenants by lead source
  static Future<List<TenantModel>> getTenantsByLeadSource({
    required String facilityId,
    required LeadSource leadSource,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final now = DateTime.now();
      final periodStart = startDate ?? DateTime(now.year - 1, 1, 1);
      final periodEnd = endDate ?? now;

      final tenantsSnapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('leadSource', isEqualTo: leadSource.name)
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(periodStart))
          .where('createdAt', isLessThanOrEqualTo: Timestamp.fromDate(periodEnd))
          .orderBy('createdAt', descending: true)
          .get();

      return tenantsSnapshot.docs
          .map((doc) => TenantModel.fromFirestore(doc))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting tenants by lead source: $e');
      }
      return [];
    }
  }
}

/// Lead source summary statistics
class LeadSourceSummary {
  final int totalTenants;
  final int totalConverted;
  final double overallConversionRate;
  final List<LeadSourceStats> topSources;
  final Map<String, int> categoryBreakdown;
  final List<LeadSourceStats> stats;

  const LeadSourceSummary({
    required this.totalTenants,
    required this.totalConverted,
    required this.overallConversionRate,
    required this.topSources,
    required this.categoryBreakdown,
    required this.stats,
  });
}

