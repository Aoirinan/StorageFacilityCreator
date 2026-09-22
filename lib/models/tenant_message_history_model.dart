import 'package:cloud_firestore/cloud_firestore.dart';

/// Unified model for all messages sent to tenants (Email + SMS from messageLogs)
class TenantMessageHistoryModel {
  final String id;
  final String facilityId;
  final String? tenantId; // Nullable for facility-wide messages
  final String? tenantName;
  final String? tenantPhone;
  final String? tenantEmail;
  final TenantMessageType type; // 'email' or 'sms'
  final String title; // Subject for email, "SMS Message" for SMS
  final String message; // Preview text
  final DateTime sentAt;
  final DateTime createdAt;
  final TenantMessageStatus status;
  final String? statusMessage;
  final List<String> channels; // ['email'] or ['sms']
  final String? messageId; // Provider message ID (SendGrid x-message-id or Twilio SID)
  final String? conversationId; // For SMS messages (legacy)
  final String? relatedEntityId; // Contract ID, payment ID, etc.
  final String? relatedEntityType; // 'contract', 'payment', 'reminder', etc.
  
  // New fields from unified messageLogs
  final String channel; // 'email' | 'sms'
  final String direction; // 'outbound'
  final String source; // 'manual' | 'bulk' | 'automation'
  final String? templateId;
  final String? subject; // Email only
  final String? previewText;
  final String provider; // 'sendgrid' | 'twilio'
  final String? providerMessageId;
  final String? errorCode;
  final String? errorMessage;
  final String? createdByUid;
  final String? createdByEmail;

  const TenantMessageHistoryModel({
    required this.id,
    required this.facilityId,
    this.tenantId,
    this.tenantName,
    this.tenantPhone,
    this.tenantEmail,
    required this.type,
    required this.title,
    required this.message,
    required this.sentAt,
    required this.createdAt,
    required this.status,
    this.statusMessage,
    required this.channels,
    this.messageId,
    this.conversationId,
    this.relatedEntityId,
    this.relatedEntityType,
    required this.channel,
    required this.direction,
    required this.source,
    this.templateId,
    this.subject,
    this.previewText,
    required this.provider,
    this.providerMessageId,
    this.errorCode,
    this.errorMessage,
    this.createdByUid,
    this.createdByEmail,
  });

  /// Create from Firestore messageLog document
  factory TenantMessageHistoryModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final channel = (data['channel'] as String? ?? 'email').toLowerCase();
    final statusStr = (data['status'] as String? ?? 'sent').toLowerCase();
    final createdAt = (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
    final sentAt = (data['sentAt'] as Timestamp?)?.toDate() ?? createdAt;

    return TenantMessageHistoryModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      tenantId: data['tenantId'],
      tenantName: data['tenantName'],
      tenantPhone: data['tenantPhone'],
      tenantEmail: data['tenantEmail'],
      type: channel == 'sms' ? TenantMessageType.sms : TenantMessageType.email,
      title: data['subject'] ?? (channel == 'sms' ? 'SMS Message' : 'Email'),
      message: data['previewText'] ?? '',
      sentAt: sentAt,
      createdAt: createdAt,
      status: _messageLogStatusToTenantStatus(statusStr),
      statusMessage: data['errorMessage'],
      channels: [channel],
      messageId: data['providerMessageId'],
      conversationId: null,
      relatedEntityId: null,
      relatedEntityType: null,
      channel: channel,
      direction: data['direction'] ?? 'outbound',
      source: data['source'] ?? 'manual',
      templateId: data['templateId'],
      subject: data['subject'],
      previewText: data['previewText'],
      provider: data['provider'] ?? (channel == 'sms' ? 'twilio' : 'sendgrid'),
      providerMessageId: data['providerMessageId'],
      errorCode: data['errorCode'],
      errorMessage: data['errorMessage'],
      createdByUid: data['createdByUid'],
      createdByEmail: data['createdByEmail'],
    );
  }

  static TenantMessageStatus _messageLogStatusToTenantStatus(String status) {
    switch (status.toLowerCase()) {
      case 'queued':
        return TenantMessageStatus.pending;
      case 'sent':
        return TenantMessageStatus.sent;
      case 'failed':
        return TenantMessageStatus.failed;
      default:
        return TenantMessageStatus.sent;
    }
  }
}

/// Type of tenant message
enum TenantMessageType {
  sms,
  reminder,
  email,
}

/// Status of tenant message
enum TenantMessageStatus {
  pending,
  sent,
  delivered,
  failed,
}

/// Extension for status display
extension TenantMessageStatusExtension on TenantMessageStatus {
  String get displayName {
    switch (this) {
      case TenantMessageStatus.pending:
        return 'Pending';
      case TenantMessageStatus.sent:
        return 'Sent';
      case TenantMessageStatus.delivered:
        return 'Delivered';
      case TenantMessageStatus.failed:
        return 'Failed';
    }
  }

  String get color {
    switch (this) {
      case TenantMessageStatus.pending:
        return '#FF9800'; // Orange
      case TenantMessageStatus.sent:
        return '#2196F3'; // Blue
      case TenantMessageStatus.delivered:
        return '#4CAF50'; // Green
      case TenantMessageStatus.failed:
        return '#F44336'; // Red
    }
  }
}

/// Extension for message type display
extension TenantMessageTypeExtension on TenantMessageType {
  String get displayName {
    switch (this) {
      case TenantMessageType.sms:
        return 'SMS';
      case TenantMessageType.reminder:
        return 'Reminder';
      case TenantMessageType.email:
        return 'Email';
    }
  }
}
