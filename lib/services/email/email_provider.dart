import 'package:flutter/foundation.dart';

/// Abstract interface for email providers (SES, SendGrid, etc.)
abstract class EmailProvider {
  /// Send a single email
  Future<void> sendEmail({
    required String to,
    required String subject,
    String? html,
    String? text,
    String? from,
  });

  /// Send multiple emails in batch
  Future<BulkEmailResult> sendBulk({
    required List<EmailMessage> messages,
  });

  /// Get provider name for logging
  String get providerName;
}

/// Email message model
class EmailMessage {
  final String to;
  final String subject;
  final String? html;
  final String? text;
  final String? from;
  final Map<String, dynamic>? metadata;

  const EmailMessage({
    required this.to,
    required this.subject,
    this.html,
    this.text,
    this.from,
    this.metadata,
  });

  Map<String, dynamic> toJson() {
    return {
      'to': to,
      'subject': subject,
      'html': html,
      'text': text,
      'from': from,
      'metadata': metadata,
    };
  }

  factory EmailMessage.fromJson(Map<String, dynamic> json) {
    return EmailMessage(
      to: json['to'],
      subject: json['subject'],
      html: json['html'],
      text: json['text'],
      from: json['from'],
      metadata: json['metadata'],
    );
  }
}

/// Result of bulk email operation
class BulkEmailResult {
  final int totalSent;
  final int totalFailed;
  final List<EmailError> errors;
  final Duration processingTime;

  const BulkEmailResult({
    required this.totalSent,
    required this.totalFailed,
    required this.errors,
    required this.processingTime,
  });

  bool get isSuccess => totalFailed == 0;
  
  double get successRate => totalSent + totalFailed > 0 
      ? totalSent / (totalSent + totalFailed) 
      : 0.0;
}

/// Email error details
class EmailError {
  final String recipient;
  final String error;
  final String? code;
  final DateTime timestamp;

  const EmailError({
    required this.recipient,
    required this.error,
    this.code,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'recipient': recipient,
      'error': error,
      'code': code,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}

/// Mock email provider for development/testing
class MockEmailProvider extends EmailProvider {
  @override
  String get providerName => 'Mock';

  @override
  Future<void> sendEmail({
    required String to,
    required String subject,
    String? html,
    String? text,
    String? from,
  }) async {
    if (kDebugMode) {
      print('📧 [MOCK] Email sent to: $to');
      print('📧 [MOCK] Subject: $subject');
      print('📧 [MOCK] From: ${from ?? 'noreply@facility.com'}');
      print('📧 [MOCK] Text: ${text ?? 'No text content'}');
      if (html != null) {
        print('📧 [MOCK] HTML: ${html.length > 100 ? '${html.substring(0, 100)}...' : html}');
      }
    }
    
    // Simulate network delay
    await Future.delayed(const Duration(milliseconds: 100));
  }

  @override
  Future<BulkEmailResult> sendBulk({
    required List<EmailMessage> messages,
  }) async {
    final startTime = DateTime.now();
    
    if (kDebugMode) {
      print('📧 [MOCK] Bulk email sending ${messages.length} messages');
    }
    
    final errors = <EmailError>[];
    int sentCount = 0;
    
    for (final message in messages) {
      try {
        await sendEmail(
          to: message.to,
          subject: message.subject,
          html: message.html,
          text: message.text,
          from: message.from,
        );
        sentCount++;
      } catch (e) {
        errors.add(EmailError(
          recipient: message.to,
          error: e.toString(),
          timestamp: DateTime.now(),
        ));
      }
    }
    
    final processingTime = DateTime.now().difference(startTime);
    
    if (kDebugMode) {
      print('📧 [MOCK] Bulk email completed: $sentCount sent, ${errors.length} failed');
    }
    
    return BulkEmailResult(
      totalSent: sentCount,
      totalFailed: errors.length,
      errors: errors,
      processingTime: processingTime,
    );
  }
}
