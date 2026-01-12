import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import '../models/sms_usage_model.dart';

/// Service for tracking and checking SMS usage
class SMSUsageService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Get SMS usage status for a facility
  static Future<SMSUsageStatus> getUsageStatus({
    required String facilityId,
    String? tenantId,
    String? accountId,
  }) async {
    try {
      final callable = _functions.httpsCallable('getSMSUsageStatus');
      final result = await callable.call({
        'facilityId': facilityId,
        if (tenantId != null) 'tenantId': tenantId,
        if (accountId != null) 'accountId': accountId,
      });

      final data = result.data as Map<String, dynamic>;
      final usageData = data['usage'] as Map<String, dynamic>?;

      // Parse usage data
      SMSUsage? tenantUsage;
      if (usageData?['tenant'] != null) {
        final tenant = usageData!['tenant'] as Map<String, dynamic>;
        tenantUsage = SMSUsage(
          currentCount: tenant['count'] ?? 0,
          monthlyLimit: tenant['limit'] ?? 4,
          month: DateTime.now().toString().substring(0, 7),
        );
      }

      final facility = usageData?['facility'] as Map<String, dynamic>;
      final facilityUsage = SMSUsage(
        currentCount: facility['count'] ?? 0,
        monthlyLimit: facility['limit'] ?? 1000,
        month: DateTime.now().toString().substring(0, 7),
      );

      SMSUsage? accountUsage;
      if (usageData?['account'] != null) {
        final account = usageData!['account'] as Map<String, dynamic>;
        accountUsage = SMSUsage(
          currentCount: account['count'] ?? 0,
          monthlyLimit: account['limit'] ?? 3000,
          month: DateTime.now().toString().substring(0, 7),
        );
      }

      // Parse state
      final stateString = data['state'] as String? ?? 'normal';
      final state = SMSUsageState.values.firstWhere(
        (e) => e.name == stateString,
        orElse: () => SMSUsageState.normal,
      );

      // Generate warning message
      String? warningMessage;
      if (state == SMSUsageState.approaching) {
        warningMessage = 'You are approaching the monthly SMS fair-use threshold. '
            'Additional messages may be converted to email.';
      } else if (state == SMSUsageState.exceeded) {
        warningMessage = 'SMS fair-use limit exceeded. Messages will be sent via email instead.';
      } else if (state == SMSUsageState.extreme) {
        warningMessage = 'SMS usage is extremely high. SMS scheduling is disabled. '
            'Please contact support if you need to increase your limit.';
      }

      return SMSUsageStatus(
        state: state,
        tenantUsage: tenantUsage,
        facilityUsage: facilityUsage,
        accountUsage: accountUsage,
        canSendSMS: data['canSendSMS'] ?? true,
        shouldFallbackToEmail: data['shouldFallbackToEmail'] ?? false,
        warningMessage: warningMessage,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSUsageService] Error getting usage status: $e');
      }
      // Return default status on error
      return SMSUsageStatus(
        state: SMSUsageState.normal,
        facilityUsage: SMSUsage(
          currentCount: 0,
          monthlyLimit: 1000,
          month: DateTime.now().toString().substring(0, 7),
        ),
        canSendSMS: true,
        shouldFallbackToEmail: false,
      );
    }
  }

  /// Get SMS usage for a facility
  static Future<SMSUsage> getSMSUsage(String facilityId) async {
    try {
      final status = await getUsageStatus(facilityId: facilityId);
      return status.facilityUsage;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSUsageService] Error getting SMS usage: $e');
      }
      return SMSUsage(
        currentCount: 0,
        monthlyLimit: 1000,
        month: DateTime.now().toString().substring(0, 7),
      );
    }
  }
}

