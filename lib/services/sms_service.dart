import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'contact_log_service.dart';
import '../models/contact_log_model.dart';
import 'app_check_service.dart';

/// Service for sending SMS text messages via Firebase Cloud Functions
class SMSService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Send a single SMS via Cloud Functions
  static Future<SMSResult> sendSMS({
    required String to,
    required String message,
    required String facilityId,
    String? tenantId, // Optional: for contact log auto-entry
    String? relatedEntityId, // Optional: link to related entity (reminder, payment, etc.)
    String? relatedEntityType, // Optional: type of related entity
  }) async {
    try {
      if (kDebugMode) {
        print('📱 [SMSService] Sending SMS to: $to');
        print('📱 [SMSService] Message: $message');
        print('📱 [SMSService] Facility ID: $facilityId');
      }

      final callable = _functions.httpsCallable('sendSMS');
      final result = await callable.call({
        'to': to,
        'message': message,
        'facilityId': facilityId,
        if (tenantId != null) 'tenantId': tenantId,
        // Determine source based on relatedEntityType
        'source': relatedEntityType == 'reminder' || relatedEntityType == 'automation'
            ? 'automation'
            : relatedEntityType == 'bulk'
                ? 'bulk'
                : 'manual',
      });

      final data = result.data as Map<String, dynamic>;
      
      if (kDebugMode) {
        print('✅ [SMSService] SMS sent successfully');
        print('📱 [SMSService] Message ID: ${data['messageId']}');
        if (data['usage'] != null) {
          print('📱 [SMSService] Usage: ${data['usage']}');
        }
      }

      // Extract usage count from usage object if available
      final usage = data['usage'] as Map<String, dynamic>?;
      final usageCount = usage?['facility']?['count'] as int?;

      // Auto-create contact log if tenantId is provided
      if (tenantId != null && tenantId.isNotEmpty) {
        try {
          await ContactLogService.autoCreateFromCommunication(
            tenantId: tenantId,
            facilityId: facilityId,
            type: ContactLogType.sms,
            subject: 'SMS Message',
            message: message,
            contactMethod: to,
            relatedEntityId: relatedEntityId,
            relatedEntityType: relatedEntityType,
            metadata: {
              'messageId': data['messageId'],
            },
          );
        } catch (e) {
          // Don't fail SMS sending if contact log creation fails
          if (kDebugMode) {
            print('⚠️ [SMSService] Failed to create contact log: $e');
          }
        }
      }

      // Extract status information from response
      final twilioStatus = data['twilioStatus'] as String?;
      final statusMessage = data['statusMessage'] as String?;

      return SMSResult(
        success: true,
        messageId: data['messageId'],
        twilioStatus: twilioStatus,
        statusMessage: statusMessage,
        usageCount: usageCount ?? data['usageCount'],
      );

    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [SMSService] Firebase Functions error: ${e.code} - ${e.message}');
      }

      // Handle App Check errors specifically
      if (e.code == 'failed-precondition' && 
          (e.message?.contains('App Check') ?? false)) {
        // App Check token missing or invalid
        final appCheckStats = AppCheckService.getMonitoringStats();
        if (kDebugMode) {
          print('⚠️ [SMSService] App Check error - Stats: $appCheckStats');
        }
        
        return SMSResult(
          success: false,
          error: 'App Check verification failed. Please refresh the page and try again.',
          errorCode: 'app-check-failed',
        );
      }

      return SMSResult(
        success: false,
        error: _getErrorMessage(e),
        errorCode: e.code,
      );

    } catch (e) {
      if (kDebugMode) {
        print('❌ [SMSService] Unexpected error: $e');
      }

      return SMSResult(
        success: false,
        error: 'Failed to send SMS: $e',
      );
    }
  }

  /// Get user-friendly error message from Firebase Functions exception
  static String _getErrorMessage(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'unauthenticated':
        return 'You must be logged in to send SMS';
      case 'permission-denied':
        return 'You do not have permission to send SMS for this facility';
      case 'invalid-argument':
        return 'Invalid SMS parameters: ${e.message}';
      case 'resource-exhausted':
        return 'SMS quota exceeded: ${e.message}';
      case 'internal':
        return 'SMS service temporarily unavailable. Please try again later.';
      default:
        return e.message ?? 'An unknown error occurred while sending the SMS';
    }
  }
}

/// Result of an SMS sending operation
class SMSResult {
  final bool success;
  final String? messageId;
  final String? twilioStatus; // 'queued', 'sent', 'delivered', 'failed', 'undelivered'
  final String? statusMessage; // User-friendly status message
  final int? usageCount;
  final String? error;
  final String? errorCode;

  const SMSResult({
    required this.success,
    this.messageId,
    this.twilioStatus,
    this.statusMessage,
    this.usageCount,
    this.error,
    this.errorCode,
  });

  @override
  String toString() {
    if (success) {
      return 'SMSResult(success: true, messageId: $messageId, twilioStatus: $twilioStatus, statusMessage: $statusMessage, usageCount: $usageCount)';
    } else {
      return 'SMSResult(success: false, error: $error, errorCode: $errorCode)';
    }
  }
}

