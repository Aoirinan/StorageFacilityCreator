import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'package:sfcapp/constants/email_monthly_limits.dart';
import 'facility_creator_account_service.dart';

/// Service for tracking email usage and limits per facility
class EmailUsageService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  
  /// Default monthly cap when Firestore has no `emailMonthlyLimit` yet.
  static Future<int> _getEmailLimitForFacility(String facilityId) async {
    try {
      // Check if facility has email limit set
      final now = DateTime.now();
      final monthKey = '${now.year}-${_padMonth(now.month)}';
      
      final usageDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailUsage')
          .doc(monthKey)
          .get();

      if (usageDoc.exists) {
        final limit = usageDoc.data()?['emailMonthlyLimit'];
        if (limit != null) {
          return limit as int;
        }
      }
      
      // If no limit set, check account subscription status
      final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
      if (facilityDoc.exists) {
        final ownerUid = facilityDoc.data()?['ownerUid'] as String?;
        if (ownerUid != null) {
          final account = await FacilityCreatorAccountService.getAccountByOwnerUid(ownerUid);
          
          if (account != null) {
            return emailMonthlyLimitForAccount(isTrialing: account.hasTrial);
          }
        }
      }

      return kEmailMonthlyLimitPaid;
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [EmailUsageService] Error getting email limit, using default: $e');
      }
      return kEmailMonthlyLimitPaid;
    }
  }

  /// Helper to pad month to 2 digits
  static String _padMonth(int month) {
    return month.toString().padLeft(2, '0');
  }

  /// Get current email usage for a facility
  static Future<EmailUsage> getEmailUsage(String facilityId) async {
    try {
      final now = DateTime.now();
      final monthKey = '${now.year}-${_padMonth(now.month)}';
      
      final usageDoc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailUsage')
          .doc(monthKey)
          .get();

      if (usageDoc.exists) {
        final data = usageDoc.data()!;
        final limit = data['emailMonthlyLimit'] ?? await _getEmailLimitForFacility(facilityId);
        return EmailUsage(
          currentCount: data['emailMonthlyCount'] ?? 0,
          monthlyLimit: limit,
          month: data['emailMonth'] ?? monthKey,
          lastUpdated: data['lastUpdated']?.toDate(),
        );
      } else {
        // Initialize with limit based on subscription status
        final limit = await _getEmailLimitForFacility(facilityId);
        return EmailUsage(
          currentCount: 0,
          monthlyLimit: limit,
          month: monthKey,
          lastUpdated: null,
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailUsageService] Error getting email usage: $e');
      }
      // Return default values on error
      final now = DateTime.now();
      final monthKey = '${now.year}-${_padMonth(now.month)}';
      final limit = await _getEmailLimitForFacility(facilityId);
      return EmailUsage(
        currentCount: 0,
        monthlyLimit: limit,
        month: monthKey,
        lastUpdated: null,
      );
    }
  }

  /// Check if facility can send more emails
  static Future<EmailUsageCheck> canSendEmail(String facilityId, {int additionalEmails = 1}) async {
    try {
      final usage = await getEmailUsage(facilityId);
      final newCount = usage.currentCount + additionalEmails;
      
      final canSend = newCount <= usage.monthlyLimit;
      final warningThreshold = (usage.monthlyLimit * 0.8).round();
      final warning = newCount >= warningThreshold ? 
        'Email usage at ${((newCount / usage.monthlyLimit) * 100).round()}% of monthly limit (${newCount}/${usage.monthlyLimit})' : 
        null;

      return EmailUsageCheck(
        canSend: canSend,
        currentCount: usage.currentCount,
        monthlyLimit: usage.monthlyLimit,
        warning: warning,
        percentage: (usage.currentCount / usage.monthlyLimit) * 100,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailUsageService] Error checking email usage: $e');
      }
      // Try to get limit for facility even on error
      final limit = await _getEmailLimitForFacility(facilityId);
      return EmailUsageCheck(
        canSend: false,
        currentCount: 0,
        monthlyLimit: limit,
        warning: 'Unable to check email usage',
        percentage: 0,
      );
    }
  }

  /// Set email limit for a facility
  static Future<void> setEmailLimit(String facilityId, int monthlyLimit) async {
    try {
      final now = DateTime.now();
      final monthKey = '${now.year}-${_padMonth(now.month)}';
      
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('emailUsage')
          .doc(monthKey)
          .set({
        'emailMonthlyLimit': monthlyLimit,
        'emailMonth': monthKey,
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (kDebugMode) {
        print('✅ [EmailUsageService] Email limit set to $monthlyLimit for facility $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailUsageService] Error setting email limit: $e');
      }
      rethrow;
    }
  }

  /// Stream email usage for real-time updates
  static Stream<EmailUsage> streamEmailUsage(String facilityId) {
    final now = DateTime.now();
    final monthKey = '${now.year}-${_padMonth(now.month)}';
    
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('emailUsage')
        .doc(monthKey)
        .snapshots()
        .asyncMap((doc) async {
      if (doc.exists) {
        final data = doc.data()!;
        final limit = data['emailMonthlyLimit'] ?? await _getEmailLimitForFacility(facilityId);
        return EmailUsage(
          currentCount: data['emailMonthlyCount'] ?? 0,
          monthlyLimit: limit,
          month: data['emailMonth'] ?? monthKey,
          lastUpdated: data['lastUpdated']?.toDate(),
        );
      } else {
        final limit = await _getEmailLimitForFacility(facilityId);
        return EmailUsage(
          currentCount: 0,
          monthlyLimit: limit,
          month: monthKey,
          lastUpdated: null,
        );
      }
    });
  }
}

/// Model for email usage data
class EmailUsage {
  final int currentCount;
  final int monthlyLimit;
  final String month;
  final DateTime? lastUpdated;

  EmailUsage({
    required this.currentCount,
    required this.monthlyLimit,
    required this.month,
    this.lastUpdated,
  });

  /// Creates a placeholder usage record for the current month with zero counts.
  factory EmailUsage.placeholder() {
    final now = DateTime.now();
    final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    return EmailUsage(
      currentCount: 0,
      monthlyLimit: 1000,
      month: monthKey,
      lastUpdated: null,
    );
  }

  double get percentage => (currentCount / monthlyLimit) * 100;
  bool get isNearLimit => percentage >= 80;
  bool get isAtLimit => currentCount >= monthlyLimit;
  int get remaining => monthlyLimit - currentCount;

  @override
  String toString() {
    return 'EmailUsage(current: $currentCount, limit: $monthlyLimit, percentage: ${percentage.toStringAsFixed(1)}%)';
  }
}

/// Model for email usage check result
class EmailUsageCheck {
  final bool canSend;
  final int currentCount;
  final int monthlyLimit;
  final String? warning;
  final double percentage;

  EmailUsageCheck({
    required this.canSend,
    required this.currentCount,
    required this.monthlyLimit,
    this.warning,
    required this.percentage,
  });

  @override
  String toString() {
    return 'EmailUsageCheck(canSend: $canSend, current: $currentCount/$monthlyLimit, warning: $warning)';
  }
}
