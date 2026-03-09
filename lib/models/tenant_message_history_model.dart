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

  /// Create from SMS message (legacy support)
  factory TenantMessageHistoryModel.fromSMSMessage({
    required SMSMessageData smsMessage,
    String? tenantName,
  }) {
    return TenantMessageHistoryModel(
      id: smsMessage.id,
      facilityId: smsMessage.facilityId,
      tenantId: smsMessage.tenantId,
      tenantName: tenantName,
      tenantPhone: smsMessage.phoneNumber,
      type: TenantMessageType.sms,
      title: 'SMS Message',
      message: smsMessage.body,
      sentAt: smsMessage.timestamp,
      createdAt: smsMessage.timestamp,
      status: _smsStatusToTenantStatus(smsMessage.status),
      channels: ['sms'],
      messageId: smsMessage.messageSid,
      conversationId: smsMessage.conversationId,
      channel: 'sms',
      direction: 'outbound',
      source: 'manual',
      provider: 'twilio',
      providerMessageId: smsMessage.messageSid,
    );
  }

  /// Create from reminder (legacy support)
  factory TenantMessageHistoryModel.fromReminder({
    required ReminderData reminder,
    String? tenantName,
  }) {
    // Only include reminders sent via SMS or Email
    final relevantChannels = reminder.channels
        .where((c) => c == 'sms' || c == 'email')
        .toList();
    
    if (relevantChannels.isEmpty) {
      throw ArgumentError('Reminder must have at least one SMS or email channel');
    }

    final channel = relevantChannels.first; // Use first channel
    final sentAt = reminder.sentAt ?? reminder.createdAt;

    return TenantMessageHistoryModel(
      id: reminder.id,
      facilityId: reminder.facilityId,
      tenantId: reminder.tenantId,
      tenantName: tenantName,
      tenantPhone: reminder.tenantPhone,
      tenantEmail: reminder.tenantEmail,
      type: channel == 'sms' ? TenantMessageType.sms : TenantMessageType.email,
      title: reminder.title,
      message: reminder.message,
      sentAt: sentAt,
      createdAt: reminder.createdAt,
      status: _reminderStatusToTenantStatus(reminder.status),
      channels: relevantChannels,
      relatedEntityId: reminder.contractId ?? reminder.paymentId,
      relatedEntityType: reminder.contractId != null 
          ? 'contract' 
          : reminder.paymentId != null 
              ? 'payment' 
              : 'reminder',
      channel: channel,
      direction: 'outbound',
      source: 'automation',
      provider: channel == 'sms' ? 'twilio' : 'sendgrid',
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

  static TenantMessageStatus _smsStatusToTenantStatus(String status) {
    switch (status.toLowerCase()) {
      case 'sent':
        return TenantMessageStatus.sent;
      case 'delivered':
        return TenantMessageStatus.delivered;
      case 'failed':
        return TenantMessageStatus.failed;
      default:
        return TenantMessageStatus.sent;
    }
  }

  static TenantMessageStatus _reminderStatusToTenantStatus(String status) {
    switch (status.toLowerCase()) {
      case 'sent':
        return TenantMessageStatus.delivered; // Sent reminders are considered delivered
      case 'failed':
        return TenantMessageStatus.failed;
      case 'pending':
        return TenantMessageStatus.pending;
      default:
        return TenantMessageStatus.sent;
    }
  }
}

/// Data class for SMS message
class SMSMessageData {
  final String id;
  final String conversationId;
  final String facilityId;
  final String tenantId;
  final String phoneNumber;
  final String body;
  final String status;
  final String? messageSid;
  final DateTime timestamp;

  const SMSMessageData({
    required this.id,
    required this.conversationId,
    required this.facilityId,
    required this.tenantId,
    required this.phoneNumber,
    required this.body,
    required this.status,
    this.messageSid,
    required this.timestamp,
  });
}

/// Data class for reminder
class ReminderData {
  final String id;
  final String facilityId;
  final String tenantId;
  final String? contractId;
  final String? paymentId;
  final String? tenantEmail;
  final String? tenantPhone;
  final List<String> channels;
  final String title;
  final String message;
  final DateTime createdAt;
  final DateTime? sentAt;
  final String status;

  const ReminderData({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    this.contractId,
    this.paymentId,
    this.tenantEmail,
    this.tenantPhone,
    required this.channels,
    required this.title,
    required this.message,
    required this.createdAt,
    this.sentAt,
    required this.status,
  });
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
