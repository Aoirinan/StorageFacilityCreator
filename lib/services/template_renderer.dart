import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service for rendering HTML email templates with variable substitution
class TemplateRenderer {
  static final Map<String, String> _templateCache = {};

  /// Render a template with the given variables
  static Future<TemplateResult> renderTemplate({
    required String templateId,
    required Map<String, dynamic> variables,
  }) async {
    try {
      // Get template content
      final templateContent = await _getTemplateContent(templateId);
      
      // Render HTML
      final html = _renderContent(templateContent.html, variables);
      
      // Render text version
      final text = _renderContent(templateContent.text, variables);

      if (kDebugMode) {
        print('✅ [TemplateRenderer] Rendered template: $templateId');
        print('📧 [TemplateRenderer] Variables used: ${variables.keys.join(', ')}');
      }

      return TemplateResult(
        success: true,
        html: html,
        text: text,
      );

    } catch (e) {
      if (kDebugMode) {
        print('❌ [TemplateRenderer] Error rendering template $templateId: $e');
      }

      return TemplateResult(
        success: false,
        error: 'Failed to render template: $e',
      );
    }
  }

  /// Get template content from assets or cache
  static Future<TemplateContent> _getTemplateContent(String templateId) async {
    // Check cache first
    if (_templateCache.containsKey(templateId)) {
      return TemplateContent.fromJson(
        jsonDecode(_templateCache[templateId]!),
      );
    }

    try {
      // Load from assets
      final assetPath = 'lib/templates/reminders/${templateId}.html';
      final htmlContent = await rootBundle.loadString(assetPath);
      
      // Extract text version from HTML (simple conversion)
      final textContent = _extractTextFromHtml(htmlContent);
      
      final content = TemplateContent(
        html: htmlContent,
        text: textContent,
      );

      // Cache the content
      _templateCache[templateId] = jsonEncode(content.toJson());

      return content;

    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [TemplateRenderer] Template $templateId not found in assets, using default');
      }

      // Return default template
      return _getDefaultTemplate();
    }
  }

  /// Render content with variable substitution
  static String _renderContent(String content, Map<String, dynamic> variables) {
    String result = content;

    // Replace variables in format {{variableName}}
    variables.forEach((key, value) {
      final placeholder = '{{$key}}';
      final replacement = value?.toString() ?? '';
      result = result.replaceAll(placeholder, replacement);
    });

    // Replace any remaining undefined variables with empty string
    result = result.replaceAll(RegExp(r'\{\{[^}]+\}\}'), '');

    return result;
  }

  /// Extract text content from HTML (simple implementation)
  static String _extractTextFromHtml(String html) {
    // Remove HTML tags and decode entities
    String text = html
        .replaceAll(RegExp(r'<[^>]*>'), '') // Remove HTML tags
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");

    // Clean up whitespace
    text = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return text;
  }

  /// Get default template when specific template is not found
  static TemplateContent _getDefaultTemplate() {
    return TemplateContent(
      html: '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>{{title}}</title>
</head>
<body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;">
  <div style="background-color: #f8f9fa; padding: 20px; border-radius: 8px; margin-bottom: 20px;">
    <h2 style="color: #007bff; margin: 0;">{{title}}</h2>
  </div>
  <p>{{message}}</p>
  <div style="margin-top: 30px; padding-top: 20px; border-top: 1px solid #eee; font-size: 14px; color: #666;">
    <p>{{footer}}</p>
  </div>
</body>
</html>
      ''',
      text: '''
{{title}}

{{message}}

{{footer}}
      ''',
    );
  }
}

/// Template content model
class TemplateContent {
  final String html;
  final String text;

  const TemplateContent({
    required this.html,
    required this.text,
  });

  Map<String, dynamic> toJson() {
    return {
      'html': html,
      'text': text,
    };
  }

  factory TemplateContent.fromJson(Map<String, dynamic> json) {
    return TemplateContent(
      html: json['html'],
      text: json['text'],
    );
  }
}

/// Result of template rendering
class TemplateResult {
  final bool success;
  final String? html;
  final String? text;
  final String? error;

  const TemplateResult({
    required this.success,
    this.html,
    this.text,
    this.error,
  });

  @override
  String toString() {
    if (success) {
      return 'TemplateResult(success: true, html: ${html?.length} chars, text: ${text?.length} chars)';
    } else {
      return 'TemplateResult(success: false, error: $error)';
    }
  }
}
