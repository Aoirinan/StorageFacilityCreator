import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/billing_model.dart';

/// Service for managing facility billing and email usage tracking
class BillingService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Get current month's billing info for a facility
  static Future<FacilityBillingModel> getCurrentBilling(String facilityId) async {
    try {
      final now = DateTime.now();
      final monthKey = _formatMonthKey(now);
      
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('billing')
          .doc(monthKey)
          .get();

      if (doc.exists) {
        return FacilityBillingModel.fromFirestore(doc);
      } else {
        // Create new billing record with default values
        return await _createDefaultBilling(facilityId, monthKey);
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error getting billing: $e');
      }
      rethrow;
    }
  }

  /// Create default billing record for a facility
  static Future<FacilityBillingModel> _createDefaultBilling(String facilityId, String monthKey) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final now = DateTime.now();
      final config = await getSystemBillingConfig();
      
      final billing = FacilityBillingModel(
        facilityId: facilityId,
        monthKey: monthKey,
        emailCount: 0,
        emailFreeTier: config.defaultFacilityMonthlyFree,
        emailOverageRate: config.defaultOverageRate,
        lastReset: now,
        updatedAt: now,
      );

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('billing')
          .doc(monthKey)
          .set(billing.toFirestore());

      if (kDebugMode) {
        print('✅ [Billing] Created default billing for facility: $facilityId');
      }

      return billing;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error creating default billing: $e');
      }
      rethrow;
    }
  }

  /// Increment email count for a facility
  static Future<void> incrementEmailCount(String facilityId, {int count = 1}) async {
    try {
      final now = DateTime.now();
      final monthKey = _formatMonthKey(now);
      
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('billing')
          .doc(monthKey)
          .update({
        'emailCount': FieldValue.increment(count),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (kDebugMode) {
        print('✅ [Billing] Incremented email count for $facilityId by $count');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error incrementing email count: $e');
      }
      rethrow;
    }
  }

  /// Get system billing configuration
  static Future<SystemBillingConfig> getSystemBillingConfig() async {
    try {
      final doc = await _firestore
          .collection('configs')
          .doc('system')
          .get();

      if (doc.exists) {
        return SystemBillingConfig.fromFirestore(doc);
      } else {
        // Create default config
        final defaultConfig = SystemBillingConfig.defaultConfig();
        await _firestore
            .collection('configs')
            .doc('system')
            .set(defaultConfig.toFirestore());
        
        if (kDebugMode) {
          print('✅ [Billing] Created default system billing config');
        }
        
        return defaultConfig;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error getting system config: $e');
      }
      // Return default config on error
      return SystemBillingConfig.defaultConfig();
    }
  }

  /// Update system billing configuration
  static Future<void> updateSystemBillingConfig(SystemBillingConfig config) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final updatedConfig = SystemBillingConfig(
        globalRatePerMinute: config.globalRatePerMinute,
        defaultFacilityMonthlyFree: config.defaultFacilityMonthlyFree,
        defaultOverageRate: config.defaultOverageRate,
        updatedAt: DateTime.now(),
      );

      await _firestore
          .collection('configs')
          .doc('system')
          .set(updatedConfig.toFirestore());

      if (kDebugMode) {
        print('✅ [Billing] Updated system billing config');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error updating system config: $e');
      }
      rethrow;
    }
  }

  /// Get billing history for a facility (last 12 months)
  static Future<List<FacilityBillingModel>> getBillingHistory(String facilityId) async {
    try {
      final now = DateTime.now();
      
      // Get last 12 months
      final startDate = DateTime(now.year, now.month - 11, 1);
      final startMonthKey = _formatMonthKey(startDate);
      
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('billing')
          .where('monthKey', isGreaterThanOrEqualTo: startMonthKey)
          .orderBy('monthKey', descending: true)
          .get();

      final billingHistory = snapshot.docs
          .map((doc) => FacilityBillingModel.fromFirestore(doc))
          .toList();

      // Ensure we have billing records for all months (create missing ones)
      final allMonths = <String>[];
      for (int i = 0; i < 12; i++) {
        final month = DateTime(now.year, now.month - i, 1);
        allMonths.add(_formatMonthKey(month));
      }

      final existingMonths = billingHistory.map((b) => b.monthKey).toSet();
      final missingMonths = allMonths.where((month) => !existingMonths.contains(month));

      for (final monthKey in missingMonths) {
        final monthDate = DateTime(
          int.parse(monthKey.substring(0, 4)),
          int.parse(monthKey.substring(4, 6)),
          1,
        );
        
        final config = await getSystemBillingConfig();
        final billing = FacilityBillingModel(
          facilityId: facilityId,
          monthKey: monthKey,
          emailCount: 0,
          emailFreeTier: config.defaultFacilityMonthlyFree,
          emailOverageRate: config.defaultOverageRate,
          lastReset: monthDate,
          updatedAt: monthDate,
        );
        
        billingHistory.add(billing);
      }

      // Sort by month key descending
      billingHistory.sort((a, b) => b.monthKey.compareTo(a.monthKey));

      if (kDebugMode) {
        print('✅ [Billing] Retrieved billing history for $facilityId: ${billingHistory.length} months');
      }

      return billingHistory;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error getting billing history: $e');
      }
      rethrow;
    }
  }

  /// Get billing statistics for a facility
  static Future<BillingStatistics> getBillingStatistics(String facilityId) async {
    try {
      final history = await getBillingHistory(facilityId);
      
      if (history.isEmpty) {
        return BillingStatistics.empty();
      }

      final currentMonth = history.first;
      final totalEmails = history.map((b) => b.emailCount).reduce((a, b) => a + b);
      final totalOverage = history.map((b) => b.overageAmount).reduce((a, b) => a + b);
      final averageMonthly = totalEmails / history.length;
      
      return BillingStatistics(
        currentMonth: currentMonth,
        totalEmailsThisYear: totalEmails,
        totalOverageThisYear: totalOverage,
        averageMonthlyEmails: averageMonthly,
        monthsWithUsage: history.where((b) => b.emailCount > 0).length,
        totalMonths: history.length,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error getting billing statistics: $e');
      }
      return BillingStatistics.empty();
    }
  }

  /// Check if facility can send more emails (within limits)
  static Future<bool> canSendEmails(String facilityId, {int count = 1}) async {
    try {
      final billing = await getCurrentBilling(facilityId);
      return (billing.emailCount + count) <= (billing.emailFreeTier * 1.2); // Allow 20% overage
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error checking email limits: $e');
      }
      return true; // Allow sending on error to avoid blocking
    }
  }

  /// Get usage warning message for facility
  static Future<String?> getUsageWarning(String facilityId) async {
    try {
      final billing = await getCurrentBilling(facilityId);
      
      if (billing.hasOverage) {
        return 'You have exceeded your monthly email limit. Overage: \$${billing.overageAmount.toStringAsFixed(2)}';
      } else if (billing.isAtWarningLevel) {
        final percentage = (billing.usagePercentage * 100).toInt();
        return 'You have used $percentage% of your monthly email limit. Consider using digest emails to reduce usage.';
      }
      
      return null;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Billing] Error getting usage warning: $e');
      }
      return null;
    }
  }

  static String _formatMonthKey(DateTime date) {
    return '${date.year}${date.month.toString().padLeft(2, '0')}';
  }
}

/// Billing statistics for a facility
class BillingStatistics {
  final FacilityBillingModel currentMonth;
  final int totalEmailsThisYear;
  final double totalOverageThisYear;
  final double averageMonthlyEmails;
  final int monthsWithUsage;
  final int totalMonths;

  const BillingStatistics({
    required this.currentMonth,
    required this.totalEmailsThisYear,
    required this.totalOverageThisYear,
    required this.averageMonthlyEmails,
    required this.monthsWithUsage,
    required this.totalMonths,
  });

  factory BillingStatistics.empty() {
    final now = DateTime.now();
    return BillingStatistics(
      currentMonth: FacilityBillingModel(
        facilityId: '',
        monthKey: '',
        emailCount: 0,
        emailFreeTier: 5000,
        emailOverageRate: 0.0001,
        lastReset: now,
        updatedAt: now,
      ),
      totalEmailsThisYear: 0,
      totalOverageThisYear: 0.0,
      averageMonthlyEmails: 0.0,
      monthsWithUsage: 0,
      totalMonths: 0,
    );
  }

  double get averageUsagePercentage => 
      totalMonths > 0 ? (monthsWithUsage / totalMonths) : 0.0;
}
