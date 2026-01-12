import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Service for sending emails via Firebase Cloud Functions with SendGrid
class EmailCloudService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Send a single email via Cloud Function
  static Future<EmailSendResult> sendEmail({
    required String to,
    required String subject,
    required String html,
    String? text,
    required String facilityId,
    String? templateId,
    Map<String, dynamic>? variables,
  }) async {
    try {
      if (kDebugMode) {
        print('📧 [EmailCloudService] Calling sendEmail Cloud Function...');
        print('📧 [EmailCloudService] To: $to');
        print('📧 [EmailCloudService] Subject: $subject');
        print('📧 [EmailCloudService] Facility ID: $facilityId');
      }

      final HttpsCallable callable = _functions.httpsCallable('sendEmail');
      final result = await callable.call(<String, dynamic>{
        'to': to,
        'subject': subject,
        'html': html,
        'text': text,
        'facilityId': facilityId,
        'templateId': templateId,
        'variables': variables,
      });

      if (kDebugMode) {
        print('✅ [EmailCloudService] Email sent successfully!');
        print('📧 [EmailCloudService] Message ID: ${result.data['messageId']}');
        if (result.data['usageWarning'] != null) {
          print('⚠️ [EmailCloudService] Usage Warning: ${result.data['usageWarning']}');
        }
      }

      return EmailSendResult(
        success: result.data['success'] ?? false,
        messageId: result.data['messageId'],
        error: result.data['error'],
        usageWarning: result.data['usageWarning'],
      );
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [EmailCloudService] FirebaseFunctionsException: ${e.code} - ${e.message}');
      }
      return EmailSendResult(
        success: false, 
        error: 'Cloud Function Error: ${e.code} - ${e.message}',
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailCloudService] Unexpected error: $e');
      }
      return EmailSendResult(
        success: false, 
        error: 'Unexpected error: $e',
      );
    }
  }

  /// Send a digest email via Cloud Function
  static Future<EmailSendResult> sendDigest({
    required String facilityId,
    required String digestId,
    required String to,
    required String subject,
    required String html,
    String? text,
    String? templateId,
    Map<String, dynamic>? variables,
  }) async {
    try {
      if (kDebugMode) {
        print('📧 [EmailCloudService] Calling sendDigest Cloud Function...');
        print('📧 [EmailCloudService] To: $to');
        print('📧 [EmailCloudService] Digest ID: $digestId');
        print('📧 [EmailCloudService] Facility ID: $facilityId');
      }

      final HttpsCallable callable = _functions.httpsCallable('sendDigest');
      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'digestId': digestId,
        'to': to,
        'subject': subject,
        'html': html,
        'text': text,
        'templateId': templateId,
        'variables': variables,
      });

      if (kDebugMode) {
        print('✅ [EmailCloudService] Digest email sent successfully!');
        print('📧 [EmailCloudService] Message ID: ${result.data['messageId']}');
        if (result.data['usageWarning'] != null) {
          print('⚠️ [EmailCloudService] Usage Warning: ${result.data['usageWarning']}');
        }
      }

      return EmailSendResult(
        success: result.data['success'] ?? false,
        messageId: result.data['messageId'],
        error: result.data['error'],
        usageWarning: result.data['usageWarning'],
      );
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [EmailCloudService] FirebaseFunctionsException: ${e.code} - ${e.message}');
      }
      return EmailSendResult(
        success: false, 
        error: 'Cloud Function Error: ${e.code} - ${e.message}',
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailCloudService] Unexpected error: $e');
      }
      return EmailSendResult(
        success: false, 
        error: 'Unexpected error: $e',
      );
    }
  }
}

/// Result model for email sending operations
class EmailSendResult {
  final bool success;
  final String? messageId;
  final String? error;
  final String? usageWarning;

  EmailSendResult({
    required this.success, 
    this.messageId, 
    this.error,
    this.usageWarning,
  });

  @override
  String toString() {
    return 'EmailSendResult(success: $success, messageId: $messageId, error: $error, warning: $usageWarning)';
  }
}
