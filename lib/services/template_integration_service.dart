import 'package:flutter/foundation.dart';
import '../services/template_service.dart';

/// Service for integrating templates with messaging services
/// Bridges the template system with email/SMS sending
class TemplateIntegrationService {
  /// Get and render email template for a category
  /// Returns rendered subject and body with variables replaced
  /// [language] - Optional language code (e.g., "en", "es", "fr") extracted from tenant's preferredLocale or facility's defaultLocale
  static Future<EmailTemplateResult?> getEmailTemplate({
    required String category,
    String? facilityId,
    required Map<String, String> variables,
    String? language, // Language code like "en", "es", "fr" - extracted from locale string
  }) async {
    try {
      final template = await TemplateService.getDefaultEmailTemplateByLanguage(
        category,
        facilityId,
        language,
      );
      if (template == null) {
        if (kDebugMode) {
          print('⚠️ [TemplateIntegration] No default email template found for category: $category, language: ${language ?? "default"}');
        }
        return null;
      }

      return EmailTemplateResult(
        subject: template.getSubject(variables),
        htmlBody: template.getHtmlBody(variables),
        textBody: template.getTextBody(variables),
        templateId: template.id,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TemplateIntegration] Error getting email template: $e');
      }
      return null;
    }
  }

  /// Get and render SMS template for a category
  /// Returns rendered message with variables replaced
  /// [language] - Optional language code (e.g., "en", "es", "fr") extracted from tenant's preferredLocale or facility's defaultLocale
  static Future<SMSTemplateResult?> getSMSTemplate({
    required String category,
    String? facilityId,
    required Map<String, String> variables,
    String? language, // Language code like "en", "es", "fr" - extracted from locale string
  }) async {
    try {
      final template = await TemplateService.getDefaultSMSTemplateByLanguage(
        category,
        facilityId,
        language,
      );
      if (template == null) {
        if (kDebugMode) {
          print('⚠️ [TemplateIntegration] No default SMS template found for category: $category, language: ${language ?? "default"}');
        }
        return null;
      }

      return SMSTemplateResult(
        message: template.getMessage(variables),
        templateId: template.id,
        characterCount: template.characterCount,
        requiresMultipleSMS: template.requiresMultipleSMS,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [TemplateIntegration] Error getting SMS template: $e');
      }
      return null;
    }
  }

  /// Extract language code from locale string
  /// Converts "es_ES" -> "es", "en_US" -> "en", etc.
  /// Returns null if locale string is null or invalid
  static String? extractLanguageCode(String? localeString) {
    if (localeString == null || localeString.isEmpty) {
      return null;
    }
    
    // Split by underscore and take first part (language code)
    final parts = localeString.split('_');
    if (parts.isNotEmpty && parts[0].isNotEmpty) {
      return parts[0].toLowerCase();
    }
    
    return null;
  }

  /// Build variables map from tenant and facility data
  static Map<String, String> buildVariables({
    required String tenantName,
    required String facilityName,
    String? amount,
    String? dueDate,
    String? unitNumber,
    String? balance,
    String? gateCode,
    String? paymentDate,
    String? receiptNumber,
    String? contractStartDate,
    String? contractEndDate,
    String? phoneNumber,
    String? emailAddress,
  }) {
    final vars = <String, String>{
      'tenantName': tenantName,
      'facilityName': facilityName,
    };

    if (amount != null) vars['amount'] = amount;
    if (dueDate != null) vars['dueDate'] = dueDate;
    if (unitNumber != null) vars['unitNumber'] = unitNumber;
    if (balance != null) vars['balance'] = balance;
    if (gateCode != null) vars['gateCode'] = gateCode;
    if (paymentDate != null) vars['paymentDate'] = paymentDate;
    if (receiptNumber != null) vars['receiptNumber'] = receiptNumber;
    if (contractStartDate != null) vars['contractStartDate'] = contractStartDate;
    if (contractEndDate != null) vars['contractEndDate'] = contractEndDate;
    if (phoneNumber != null) vars['phoneNumber'] = phoneNumber;
    if (emailAddress != null) vars['emailAddress'] = emailAddress;

    return vars;
  }
}

/// Result of email template rendering
class EmailTemplateResult {
  final String subject;
  final String htmlBody;
  final String textBody;
  final String templateId;

  const EmailTemplateResult({
    required this.subject,
    required this.htmlBody,
    required this.textBody,
    required this.templateId,
  });
}

/// Result of SMS template rendering
class SMSTemplateResult {
  final String message;
  final String templateId;
  final int characterCount;
  final bool requiresMultipleSMS;

  const SMSTemplateResult({
    required this.message,
    required this.templateId,
    required this.characterCount,
    required this.requiresMultipleSMS,
  });
}

