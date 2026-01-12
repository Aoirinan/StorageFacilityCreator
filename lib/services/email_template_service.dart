import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart';

/// Service for rendering HTML email templates with dynamic variables
class EmailTemplateService {
  /// Render an HTML template by replacing placeholders with provided variables
  /// Placeholders in the template should be in the format {{variableName}}
  static Future<TemplateRenderResult> renderTemplate({
    required String templateId,
    required Map<String, dynamic> variables,
  }) async {
    try {
      final String templatePath = 'lib/templates/emails/$templateId.html';
      if (kDebugMode) {
        print('🔄 [EmailTemplateService] Loading template from: $templatePath');
      }
      
      final String htmlTemplate = await rootBundle.loadString(templatePath);

      String renderedHtml = htmlTemplate;
      String renderedText = htmlTemplate; // Simple text fallback

      // Replace all placeholders with actual values
      variables.forEach((key, value) {
        final placeholder = '{{$key}}';
        final replacement = value?.toString() ?? '';
        renderedHtml = renderedHtml.replaceAll(placeholder, replacement);
        renderedText = renderedText.replaceAll(placeholder, replacement);
      });

      // Remove any remaining placeholders that weren't replaced
      renderedHtml = renderedHtml.replaceAll(RegExp(r'\{\{.*?\}\}'), '');
      renderedText = renderedText.replaceAll(RegExp(r'\{\{.*?\}\}'), '');

      if (kDebugMode) {
        print('✅ [EmailTemplateService] Template "$templateId" rendered successfully.');
        print('📧 [EmailTemplateService] HTML length: ${renderedHtml.length} characters');
      }
      
      return TemplateRenderResult(
        success: true, 
        html: renderedHtml, 
        text: renderedText,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [EmailTemplateService] Error rendering template "$templateId": $e');
      }
      return TemplateRenderResult(
        success: false, 
        error: e.toString(),
      );
    }
  }

  /// Generate a welcome/onboarding email with portal and gate access information
  static String generateWelcomeEmailWithAccessCodes({
    required String facilityName,
    required String tenantName,
    String? unitNumber,
    String? portalAccessCode,
    String? gateAccessCode,
    String? welcomeMessage,
  }) {
    final hasPortalCode = portalAccessCode != null && portalAccessCode.isNotEmpty;
    final hasGateCode = gateAccessCode != null && gateAccessCode.isNotEmpty;
    
    String portalSection = '';
    if (hasPortalCode) {
      portalSection = '''
            <div class="info-section">
                <h3 style="color: #4CAF50; margin-top: 0; margin-bottom: 15px;">📱 Tenant Portal Access</h3>
                <p>You now have access to your personal tenant portal where you can:</p>
                <ul style="margin: 10px 0; padding-left: 20px;">
                    <li>View your unit details and rental information</li>
                    <li>Check your current balance and payment history</li>
                    <li>Access important documents and updates</li>
                </ul>
                <div class="code-box">
                    <p style="margin: 5px 0; font-weight: bold; font-size: 14px;">Your Portal Access Code:</p>
                    <p style="font-size: 28px; font-weight: bold; color: #4CAF50; letter-spacing: 3px; margin: 15px 0; font-family: monospace;">$portalAccessCode</p>
                    <p style="font-size: 13px; color: #666; margin: 10px 0; padding: 10px; background-color: #f9f9f9; border-radius: 4px;">
                        <strong>How to access:</strong> Visit the tenant portal login page and enter your email address along with this access code.
                    </p>
                </div>
            </div>
      ''';
    }
    
    String gateSection = '';
    if (hasGateCode) {
      gateSection = '''
            <div class="info-section">
                <h3 style="color: #2196F3; margin-top: 0; margin-bottom: 15px;">🚪 Gate Access Information</h3>
                <p>Use the following access code to enter the facility:</p>
                <div class="code-box" style="border-color: #2196F3;">
                    <p style="margin: 5px 0; font-weight: bold; font-size: 14px;">Your Gate Access Code:</p>
                    <p style="font-size: 28px; font-weight: bold; color: #2196F3; letter-spacing: 3px; margin: 15px 0; font-family: monospace;">$gateAccessCode</p>
                    <p style="font-size: 13px; color: #666; margin: 10px 0; padding: 10px; background-color: #f0f8ff; border-radius: 4px;">
                        <strong>Important:</strong> Enter this code at the facility gate keypad to gain entry. Please keep this code secure and do not share it with unauthorized individuals.
                    </p>
                </div>
            </div>
      ''';
    }

    return '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Welcome to $facilityName</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            background-color: #f4f4f4;
            margin: 0;
            padding: 0;
        }
        .container {
            max-width: 600px;
            margin: 20px auto;
            background-color: #ffffff;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 0 10px rgba(0, 0, 0, 0.1);
            border-top: 5px solid #4CAF50;
        }
        .header {
            text-align: center;
            padding-bottom: 20px;
            border-bottom: 2px solid #eee;
        }
        .header h2 {
            color: #4CAF50;
            margin: 0 0 10px 0;
            font-size: 28px;
        }
        .content {
            padding: 25px 0;
        }
        .content p {
            margin-bottom: 15px;
            font-size: 15px;
        }
        .highlight {
            font-weight: bold;
            color: #4CAF50;
        }
        .details {
            background-color: #f9f9f9;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
            border-left: 4px solid #4CAF50;
        }
        .info-section {
            background-color: #ffffff;
            padding: 25px;
            border-radius: 8px;
            margin: 25px 0;
            border: 2px solid #e0e0e0;
        }
        .info-section ul {
            line-height: 1.8;
        }
        .code-box {
            background-color: #ffffff;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            border: 2px solid #4CAF50;
            margin-top: 15px;
        }
        .footer {
            text-align: center;
            padding-top: 25px;
            border-top: 2px solid #eee;
            color: #777;
            font-size: 13px;
            margin-top: 30px;
        }
        .welcome-message {
            background-color: #fff9e6;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
            border-left: 4px solid #ffc107;
        }
        @media only screen and (max-width: 600px) {
            .container {
                width: 100%;
                margin: 0;
                border-radius: 0;
                box-shadow: none;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>Welcome to $facilityName!</h2>
            <p style="color: #666; margin: 0;">We're excited to have you as a tenant</p>
        </div>
        <div class="content">
            <p>Dear $tenantName,</p>
            <p>Thank you for choosing $facilityName! We're delighted to welcome you as a valued tenant. This email contains all the important information you'll need to get started.</p>
            
            ${unitNumber != null ? '<div class="details"><p style="margin: 5px 0;"><strong>Your Unit:</strong> <span class="highlight">Unit $unitNumber</span></p></div>' : ''}
            
            ${welcomeMessage != null && welcomeMessage.isNotEmpty ? '<div class="welcome-message"><p style="margin: 0; font-style: italic;">$welcomeMessage</p></div>' : ''}
            
            $portalSection
            
            $gateSection
            
            <div style="margin-top: 30px; padding: 15px; background-color: #f0f8ff; border-radius: 5px;">
                <p style="margin: 0; font-size: 14px;"><strong>Need Help?</strong></p>
                <p style="margin: 5px 0 0 0; font-size: 14px;">If you have any questions, concerns, or need assistance, please don't hesitate to reach out to our management team. We're here to help make your experience with us as smooth as possible.</p>
            </div>
        </div>
        <div class="footer">
            <p style="margin: 5px 0;"><strong>Best regards,</strong><br>$facilityName Management Team</p>
            <p style="margin: 10px 0 0 0; font-size: 11px; color: #999;">This is an automated onboarding message from $facilityName.</p>
        </div>
    </div>
</body>
</html>
    ''';
  }

  /// Generate a simple HTML email from plain text
  static String generateSimpleHtml({
    required String title,
    required String message,
    required String facilityName,
    String? tenantName,
    String? unitNumber,
    String? amount,
    String? dueDate,
  }) {
    return '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>$title</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            line-height: 1.6;
            color: #333;
            background-color: #f4f4f4;
            margin: 0;
            padding: 0;
        }
        .container {
            max-width: 600px;
            margin: 20px auto;
            background-color: #ffffff;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 0 10px rgba(0, 0, 0, 0.1);
            border-top: 5px solid #4CAF50;
        }
        .header {
            text-align: center;
            padding-bottom: 20px;
            border-bottom: 1px solid #eee;
        }
        .header h2 {
            color: #4CAF50;
            margin: 0;
            font-size: 24px;
        }
        .content {
            padding: 20px 0;
        }
        .content p {
            margin-bottom: 15px;
        }
        .highlight {
            font-weight: bold;
            color: #4CAF50;
        }
        .details {
            background-color: #f9f9f9;
            padding: 15px;
            border-radius: 5px;
            margin: 15px 0;
        }
        .footer {
            text-align: center;
            padding-top: 20px;
            border-top: 1px solid #eee;
            color: #777;
            font-size: 12px;
        }
        @media only screen and (max-width: 600px) {
            .container {
                width: 100%;
                margin: 0;
                border-radius: 0;
                box-shadow: none;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>$title</h2>
        </div>
        <div class="content">
            ${tenantName != null ? '<p>Dear $tenantName,</p>' : '<p>Hello,</p>'}
            <p>$message</p>
            <div class="details">
                ${unitNumber != null ? '<p><strong>Unit:</strong> <span class="highlight">$unitNumber</span></p>' : ''}
                ${amount != null ? '<p><strong>Amount:</strong> <span class="highlight">\$$amount</span></p>' : ''}
                ${dueDate != null ? '<p><strong>Due Date:</strong> <span class="highlight">$dueDate</span></p>' : ''}
            </div>
            <p>Please ensure your payment is made on time to avoid any late fees.</p>
            <p>If you have already made this payment, please disregard this reminder.</p>
            <p>Thank you for your prompt attention to this matter.</p>
        </div>
        <div class="footer">
            <p>Best regards,<br>$facilityName Management Team</p>
            <p>This is an automated message from the Storage Facility Creator system.</p>
        </div>
    </div>
</body>
</html>
    ''';
  }
}

/// Result model for template rendering operations
class TemplateRenderResult {
  final bool success;
  final String? html;
  final String? text;
  final String? error;

  TemplateRenderResult({
    required this.success, 
    this.html, 
    this.text, 
    this.error,
  });

  @override
  String toString() {
    return 'TemplateRenderResult(success: $success, html: ${html?.length ?? 0} chars, text: ${text?.length ?? 0} chars, error: $error)';
  }
}
