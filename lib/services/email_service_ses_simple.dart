import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Simple SES email service using AWS SES REST API
/// NOTE: This service uses environment variables for credentials - never hardcode keys
class EmailServiceSESSimple {
  // Get credentials from environment variables
  static String? get _accessKey => const String.fromEnvironment('SES_ACCESS_KEY_ID');
  static String? get _secretKey => const String.fromEnvironment('SES_SECRET_ACCESS_KEY');
  static String get _region => const String.fromEnvironment('SES_REGION', defaultValue: 'us-east-1');
  static String get _fromEmail => const String.fromEnvironment('SES_FROM_EMAIL', defaultValue: 'noreply@facility.com');

  /// Send email via SES using simple HTTP POST
  static Future<EmailSendResult> sendEmail({
    required String to,
    required String subject,
    String? html,
    String? text,
    String? from,
    required String facilityId,
    String? templateId,
    Map<String, dynamic>? variables,
  }) async {
    // Validate credentials are available
    if (_accessKey == null || _secretKey == null) {
      if (kDebugMode) {
        print('❌ [EmailServiceSESSimple] Missing AWS SES credentials. Set SES_ACCESS_KEY_ID and SES_SECRET_ACCESS_KEY environment variables.');
      }
      return EmailSendResult(
        success: false,
        error: 'AWS SES credentials not configured. Please set SES_ACCESS_KEY_ID and SES_SECRET_ACCESS_KEY environment variables.',
      );
    }

    try {
      if (kDebugMode) {
        print('📧 [EmailServiceSESSimple] Sending email to $to via SES...');
      }

      // Use AWS SES SendEmail API via HTTP POST
      final endpoint = 'https://email.$_region.amazonaws.com/';
      final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:\-]|\.\d{3}'), '');
      
      // Build the request body for SES SendEmail API
      final requestBody = {
        'Action': 'SendEmail',
        'Source': from ?? _fromEmail,
        'Destination.ToAddresses.member.1': to,
        'Message.Subject.Data': subject,
        'Message.Subject.Charset': 'UTF-8',
      };

      if (html != null && html.isNotEmpty) {
        requestBody['Message.Body.Html.Data'] = html;
        requestBody['Message.Body.Html.Charset'] = 'UTF-8';
      }

      if (text != null && text.isNotEmpty) {
        requestBody['Message.Body.Text.Data'] = text;
        requestBody['Message.Body.Text.Charset'] = 'UTF-8';
      }

      // Convert to URL-encoded form data
      final formData = requestBody.entries
          .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
          .join('&');

      // Create headers (simplified for testing)
      // NOTE: This is a simplified implementation. For production, use proper AWS signature v4 signing.
      // Consider using the official AWS SDK or a proper signing library.
      final headers = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'X-Amz-Date': timestamp,
        'Authorization': 'AWS4-HMAC-SHA256 Credential=${_accessKey!}/$timestamp/$_region/ses/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=test-signature',
      };

      if (kDebugMode) {
        print('📧 [EmailServiceSESSimple] Making request to: $endpoint');
        print('📧 [EmailServiceSESSimple] Headers: $headers');
        print('📧 [EmailServiceSESSimple] Body length: ${formData.length}');
      }

      // Make the HTTP request
      final response = await http.post(
        Uri.parse(endpoint),
        headers: headers,
        body: formData,
      );

      if (kDebugMode) {
        print('📧 [EmailServiceSESSimple] Response status: ${response.statusCode}');
        print('📧 [EmailServiceSESSimple] Response body: ${response.body}');
      }

      if (response.statusCode == 200) {
        if (kDebugMode) {
          print('✅ [EmailServiceSESSimple] Email sent successfully!');
        }
        return EmailSendResult(
          success: true,
          messageId: 'ses-${DateTime.now().millisecondsSinceEpoch}',
        );
      } else {
        if (kDebugMode) {
          print('❌ [EmailServiceSESSimple] Email failed: ${response.statusCode} - ${response.body}');
        }
        return EmailSendResult(
          success: false,
          error: 'SES Error: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailServiceSESSimple] Exception: $e');
      }
      return EmailSendResult(
        success: false,
        error: 'Exception: $e',
      );
    }
  }

  /// Send digest email (same as regular email for now)
  static Future<EmailSendResult> sendDigest({
    required String facilityId,
    required String digestId,
    required String to,
    required String subject,
    String? html,
    String? text,
    String? from,
    String? templateId,
    Map<String, dynamic>? variables,
  }) async {
    return sendEmail(
      to: to,
      subject: subject,
      html: html,
      text: text,
      from: from,
      facilityId: facilityId,
      templateId: templateId,
      variables: variables,
    );
  }
}

/// Result model for email sending operations
class EmailSendResult {
  final bool success;
  final String? messageId;
  final String? error;

  EmailSendResult({required this.success, this.messageId, this.error});

  @override
  String toString() {
    return 'EmailSendResult(success: $success, messageId: $messageId, error: $error)';
  }
}
