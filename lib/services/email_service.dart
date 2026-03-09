import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'contact_log_service.dart';
import '../models/contact_log_model.dart';
import 'app_check_service.dart';

/// Service for sending emails via Firebase Cloud Functions
class EmailService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Send a single email via Cloud Functions
  static Future<EmailResult> sendEmail({
    required String to,
    required String subject,
    String? html,
    String? text,
    required String facilityId,
    String? templateId,
    Map<String, dynamic>? variables,
    String? tenantId, // Optional: for contact log auto-entry
    String? relatedEntityId, // Optional: link to related entity (reminder, payment, etc.)
    String? relatedEntityType, // Optional: type of related entity
    String? fromName, // Optional: override default From name (e.g., "{FacilityName} via Storage Facility Creator")
  }) async {
    try {
      // Always log for debugging (works in web console)
      print('📧 [EmailService] Sending email to: $to');
      print('📧 [EmailService] Subject: $subject');
      print('📧 [EmailService] Facility ID: $facilityId');
      print('📧 [EmailService] Current user: ${FirebaseAuth.instance.currentUser?.email ?? "null"}');

      final callable = _functions.httpsCallable('sendEmail');
      print('📧 [EmailService] Calling Firebase Function sendEmail...');
      
      final payload = {
        'to': to,
        'subject': subject,
        'html': html,
        'text': text,
        'facilityId': facilityId,
        'templateId': templateId,
        'variables': variables,
        if (fromName != null) 'fromName': fromName,
        if (tenantId != null) 'tenantId': tenantId,
        // Determine source based on relatedEntityType
        'source': relatedEntityType == 'reminder' || relatedEntityType == 'automation'
            ? 'automation'
            : relatedEntityType == 'bulk'
                ? 'bulk'
                : 'manual',
      };
      
      // #region agent log
      // Log exact payload being sent to compare with working invite emails
      print('📧 [EmailService:H9] Payload to sendEmail function:');
      print('   to: ${payload['to']}');
      print('   subject: ${payload['subject']}');
      print('   facilityId: ${payload['facilityId']}');
      print('   hasHtml: ${payload['html'] != null} (length: ${(payload['html'] as String?)?.length ?? 0})');
      print('   hasText: ${payload['text'] != null} (length: ${(payload['text'] as String?)?.length ?? 0})');
      print('   fromName: ${payload['fromName'] ?? 'null (will use default)'}');
      print('   templateId: ${payload['templateId'] ?? 'null'}');
      // #endregion
      
      final result = await callable.call(payload);
      
      print('📧 [EmailService] Function call completed, processing result...');

      final data = result.data as Map<String, dynamic>;
      
      if (kDebugMode) {
        print('✅ [EmailService] Email sent successfully');
        print('📧 [EmailService] Message ID: ${data['messageId']}');
        if (data['usageWarning'] != null) {
          print('⚠️ [EmailService] Usage Warning: ${data['usageWarning']}');
        }
      }

      // Auto-create contact log if tenantId is provided
      if (tenantId != null && tenantId.isNotEmpty) {
        try {
          await ContactLogService.autoCreateFromCommunication(
            tenantId: tenantId,
            facilityId: facilityId,
            type: ContactLogType.email,
            subject: subject,
            message: text ?? html,
            contactMethod: to,
            relatedEntityId: relatedEntityId,
            relatedEntityType: relatedEntityType,
            metadata: {
              'messageId': data['messageId'],
              'templateId': templateId,
              ...?variables,
            },
          );
        } catch (e) {
          // Don't fail email sending if contact log creation fails
          if (kDebugMode) {
            print('⚠️ [EmailService] Failed to create contact log: $e');
          }
        }
      }

      return EmailResult(
        success: true,
        messageId: data['messageId'],
        usageCount: data['usageCount'], // May be null if not returned
      );

    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [EmailService] Firebase Functions error: ${e.code} - ${e.message}');
      }

      // Check if this is an App Check error
      if (e.code == 'failed-precondition' && 
          (e.message?.contains('App Check') == true || 
           e.message?.contains('app check') == true ||
           e.message?.contains('appCheck') == true)) {
        // Log App Check status for debugging
        if (kDebugMode) {
          final appCheckStats = AppCheckService.getMonitoringStats();
          print('⚠️ [EmailService] App Check error detected');
          print('   App Check activated: ${appCheckStats['isActivated']}');
          print('   Provider: ${appCheckStats['currentProvider']}');
          print('   Hostname: ${appCheckStats['hostname']}');
        }

        // Provide helpful error message
        if (!AppCheckService.isActivated) {
          return EmailResult(
            success: false,
            error: 'App Check is not enabled. The app needs to be rebuilt with App Check enabled to send emails.',
            errorCode: e.code,
          );
        } else {
          return EmailResult(
            success: false,
            error: 'App Check verification failed. Please ensure App Check is properly configured.',
            errorCode: e.code,
          );
        }
      }

      return EmailResult(
        success: false,
        error: _getErrorMessage(e),
        errorCode: e.code,
      );

    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailService] Unexpected error: $e');
      }

      return EmailResult(
        success: false,
        error: 'Failed to send email: $e',
      );
    }
  }

  /// Send a digest email via Cloud Functions
  static Future<EmailResult> sendDigest({
    required String facilityId,
    required String digestId,
    required List<String> recipients,
    String? subject,
    List<Map<String, dynamic>>? items,
  }) async {
    try {
      if (kDebugMode) {
        print('📧 [EmailService] Sending digest to ${recipients.length} recipients');
        print('📧 [EmailService] Facility ID: $facilityId');
        print('📧 [EmailService] Digest ID: $digestId');
      }

      final callable = _functions.httpsCallable('sendDigest');
      final result = await callable.call({
        'facilityId': facilityId,
        'digestId': digestId,
        'recipients': recipients,
        'subject': subject,
        'items': items,
      });

      final data = result.data as Map<String, dynamic>;
      
      if (kDebugMode) {
        print('✅ [EmailService] Digest sent successfully');
        print('📧 [EmailService] Message ID: ${data['messageId']}');
        print('📧 [EmailService] Recipient count: ${data['recipientCount']}');
        print('📧 [EmailService] Usage count: ${data['usageCount']}');
      }

      return EmailResult(
        success: true,
        messageId: data['messageId'],
        usageCount: data['usageCount'],
        recipientCount: data['recipientCount'],
      );

    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [EmailService] Firebase Functions error: ${e.code} - ${e.message}');
      }

      return EmailResult(
        success: false,
        error: _getErrorMessage(e),
        errorCode: e.code,
      );

    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailService] Unexpected error: $e');
      }

      return EmailResult(
        success: false,
        error: 'Failed to send digest: $e',
      );
    }
  }

  /// Get user-friendly error message from Firebase Functions exception
  static String _getErrorMessage(FirebaseFunctionsException e) {
    switch (e.code) {
      case 'unauthenticated':
        return 'You must be logged in to send emails';
      case 'permission-denied':
        return 'You do not have permission to send emails for this facility';
      case 'invalid-argument':
        return 'Invalid email parameters: ${e.message}';
      case 'resource-exhausted':
        return 'Email quota exceeded: ${e.message}';
      case 'failed-precondition':
        // App Check errors are handled separately above, but fallback here if needed
        if (e.message?.contains('App Check') == true || 
            e.message?.contains('app check') == true ||
            e.message?.contains('appCheck') == true) {
          return 'App Check verification failed. Please update your app or contact support.';
        }
        return e.message ?? 'A precondition failed. Please try again.';
      case 'internal':
        return 'Email service temporarily unavailable. Please try again later.';
      default:
        return e.message ?? 'An unknown error occurred while sending the email';
    }
  }
}

/// Result of an email sending operation
class EmailResult {
  final bool success;
  final String? messageId;
  final int? usageCount;
  final int? recipientCount;
  final String? error;
  final String? errorCode;

  const EmailResult({
    required this.success,
    this.messageId,
    this.usageCount,
    this.recipientCount,
    this.error,
    this.errorCode,
  });

  @override
  String toString() {
    if (success) {
      return 'EmailResult(success: true, messageId: $messageId, usageCount: $usageCount)';
    } else {
      return 'EmailResult(success: false, error: $error, errorCode: $errorCode)';
    }
  }
}
