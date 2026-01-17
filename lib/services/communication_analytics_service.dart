import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/communication_analytics_model.dart';
import 'package:sfcapp/services/email_tracking_service.dart';
import 'package:sfcapp/services/email_usage_service.dart';
import 'package:sfcapp/services/sms_usage_service.dart';

/// Service for communication analytics and cost tracking
class CommunicationAnalyticsService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Cost constants (from COST_ANALYSIS_AND_PRICING.md)
  static const double emailCostPerMessage = 0.0004; // $0.0004 per email (beyond free tier)
  static const double smsCostPerMessage = 0.0075; // $0.0075 per SMS
  static const int freeEmailTier = 3000; // Free tier: 3,000 emails/month

  /// Get communication analytics for a facility
  static Future<CommunicationAnalytics> getAnalytics({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final now = DateTime.now();
      final periodStart = startDate ?? DateTime(now.year, now.month, 1);
      final periodEnd = endDate ?? now;

      // Get email usage
      final emailUsage = await EmailUsageService.getEmailUsage(facilityId);
      
      // Get SMS usage
      final smsUsage = await SMSUsageService.getSMSUsage(facilityId);

      // Get email tracking stats
      final emailStats = await EmailTrackingService.getFacilityStats(
        facilityId: facilityId,
        startDate: periodStart,
        endDate: periodEnd,
      );

      // Calculate email metrics
      final emailsSent = emailStats['totalSent'] as int? ?? emailUsage.currentCount;
      final emailsOpened = emailStats['totalOpened'] as int? ?? 0;
      final emailsClicked = emailStats['totalClicked'] as int? ?? 0;
      final emailsBounced = emailStats['totalBounced'] as int? ?? 0;
      final emailsFailed = emailStats['totalFailed'] as int? ?? 0;
      final emailsDelivered = emailsSent - emailsBounced - emailsFailed;
      
      final emailOpenRate = emailsSent > 0 ? (emailsOpened / emailsSent) * 100 : 0.0;
      final emailClickRate = emailsSent > 0 ? (emailsClicked / emailsSent) * 100 : 0.0;
      final emailDeliveryRate = emailsSent > 0 ? (emailsDelivered / emailsSent) * 100 : 0.0;

      // Calculate SMS metrics (assuming delivery if sent, unless failed)
      final smsSent = smsUsage.currentCount;
      final smsDelivered = smsSent; // Assume delivered unless we have failure tracking
      final smsFailed = 0; // Would need SMS delivery tracking
      final smsDeliveryRate = smsSent > 0 ? ((smsDelivered - smsFailed) / smsSent) * 100 : 0.0;

      // Calculate costs
      final emailCost = _calculateEmailCost(emailsSent);
      final smsCost = _calculateSMSCost(smsSent);
      final totalCost = emailCost + smsCost;

      // Calculate usage percentages
      final emailUsagePercentage = emailUsage.monthlyLimit > 0
          ? (emailUsage.currentCount / emailUsage.monthlyLimit) * 100
          : 0.0;
      final smsUsagePercentage = smsUsage.monthlyLimit > 0
          ? (smsUsage.currentCount / smsUsage.monthlyLimit) * 100
          : 0.0;

      return CommunicationAnalytics(
        facilityId: facilityId,
        periodStart: periodStart,
        periodEnd: periodEnd,
        emailsSent: emailsSent,
        emailsDelivered: emailsDelivered,
        emailsOpened: emailsOpened,
        emailsClicked: emailsClicked,
        emailsBounced: emailsBounced,
        emailsFailed: emailsFailed,
        emailOpenRate: emailOpenRate,
        emailClickRate: emailClickRate,
        emailDeliveryRate: emailDeliveryRate,
        smsSent: smsSent,
        smsDelivered: smsDelivered,
        smsFailed: smsFailed,
        smsDeliveryRate: smsDeliveryRate,
        emailCost: emailCost,
        smsCost: smsCost,
        totalCost: totalCost,
        emailLimit: emailUsage.monthlyLimit,
        smsLimit: smsUsage.monthlyLimit,
        emailUsagePercentage: emailUsagePercentage,
        smsUsagePercentage: smsUsagePercentage,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [CommunicationAnalytics] Error getting analytics: $e');
      }
      rethrow;
    }
  }

  /// Calculate email cost based on usage
  static double _calculateEmailCost(int emailsSent) {
    if (emailsSent <= freeEmailTier) {
      return 0.0; // Free tier
    }
    final paidEmails = emailsSent - freeEmailTier;
    return paidEmails * emailCostPerMessage;
  }

  /// Calculate SMS cost based on usage
  static double _calculateSMSCost(int smsSent) {
    return smsSent * smsCostPerMessage;
  }

  /// Get cost breakdown for a facility
  static Future<CostBreakdown> getCostBreakdown({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final analytics = await getAnalytics(
        facilityId: facilityId,
        startDate: startDate,
        endDate: endDate,
      );

      final costPerEmail = analytics.emailsSent > 0
          ? analytics.emailCost / analytics.emailsSent
          : 0.0;
      final costPerSMS = analytics.smsSent > 0
          ? analytics.smsCost / analytics.smsSent
          : 0.0;

      return CostBreakdown(
        emailCost: analytics.emailCost,
        smsCost: analytics.smsCost,
        totalCost: analytics.totalCost,
        emailCount: analytics.emailsSent,
        smsCount: analytics.smsSent,
        costPerEmail: costPerEmail,
        costPerSMS: costPerSMS,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [CommunicationAnalytics] Error getting cost breakdown: $e');
      }
      return const CostBreakdown();
    }
  }

  /// Get analytics for multiple facilities (account-level)
  static Future<Map<String, CommunicationAnalytics>> getAccountAnalytics({
    required List<String> facilityIds,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final analyticsMap = <String, CommunicationAnalytics>{};

    for (final facilityId in facilityIds) {
      try {
        final analytics = await getAnalytics(
          facilityId: facilityId,
          startDate: startDate,
          endDate: endDate,
        );
        analyticsMap[facilityId] = analytics;
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ [CommunicationAnalytics] Error getting analytics for facility $facilityId: $e');
        }
      }
    }

    return analyticsMap;
  }

  /// Get aggregated account-level analytics
  static Future<CommunicationAnalytics> getAggregatedAnalytics({
    required List<String> facilityIds,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final facilityAnalytics = await getAccountAnalytics(
        facilityIds: facilityIds,
        startDate: startDate,
        endDate: endDate,
      );

      if (facilityAnalytics.isEmpty) {
        final now = DateTime.now();
        return CommunicationAnalytics(
          facilityId: 'aggregated',
          periodStart: startDate ?? DateTime(now.year, now.month, 1),
          periodEnd: endDate ?? now,
        );
      }

      // Aggregate all facilities
      int totalEmailsSent = 0;
      int totalEmailsDelivered = 0;
      int totalEmailsOpened = 0;
      int totalEmailsClicked = 0;
      int totalEmailsBounced = 0;
      int totalEmailsFailed = 0;
      int totalSMSSent = 0;
      int totalSMSDelivered = 0;
      int totalSMSFailed = 0;
      double totalEmailCost = 0.0;
      double totalSMSCost = 0.0;

      for (final analytics in facilityAnalytics.values) {
        totalEmailsSent += analytics.emailsSent;
        totalEmailsDelivered += analytics.emailsDelivered;
        totalEmailsOpened += analytics.emailsOpened;
        totalEmailsClicked += analytics.emailsClicked;
        totalEmailsBounced += analytics.emailsBounced;
        totalEmailsFailed += analytics.emailsFailed;
        totalSMSSent += analytics.smsSent;
        totalSMSDelivered += analytics.smsDelivered;
        totalSMSFailed += analytics.smsFailed;
        totalEmailCost += analytics.emailCost;
        totalSMSCost += analytics.smsCost;
      }

      final totalEmailOpenRate = totalEmailsSent > 0
          ? (totalEmailsOpened / totalEmailsSent) * 100
          : 0.0;
      final totalEmailClickRate = totalEmailsSent > 0
          ? (totalEmailsClicked / totalEmailsSent) * 100
          : 0.0;
      final totalEmailDeliveryRate = totalEmailsSent > 0
          ? (totalEmailsDelivered / totalEmailsSent) * 100
          : 0.0;
      final totalSMSDeliveryRate = totalSMSSent > 0
          ? ((totalSMSDelivered - totalSMSFailed) / totalSMSSent) * 100
          : 0.0;

      final now = DateTime.now();
      return CommunicationAnalytics(
        facilityId: 'aggregated',
        periodStart: startDate ?? DateTime(now.year, now.month, 1),
        periodEnd: endDate ?? now,
        emailsSent: totalEmailsSent,
        emailsDelivered: totalEmailsDelivered,
        emailsOpened: totalEmailsOpened,
        emailsClicked: totalEmailsClicked,
        emailsBounced: totalEmailsBounced,
        emailsFailed: totalEmailsFailed,
        emailOpenRate: totalEmailOpenRate,
        emailClickRate: totalEmailClickRate,
        emailDeliveryRate: totalEmailDeliveryRate,
        smsSent: totalSMSSent,
        smsDelivered: totalSMSDelivered,
        smsFailed: totalSMSFailed,
        smsDeliveryRate: totalSMSDeliveryRate,
        emailCost: totalEmailCost,
        smsCost: totalSMSCost,
        totalCost: totalEmailCost + totalSMSCost,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [CommunicationAnalytics] Error getting aggregated analytics: $e');
      }
      rethrow;
    }
  }
}

