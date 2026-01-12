import 'package:cloud_firestore/cloud_firestore.dart';
import 'sms_conversation_model.dart';

/// Model for individual SMS message
class SMSMessageModel {
  final String id;
  final String conversationId;
  final String facilityId;
  final SMSDirection direction;
  final String phoneNumber;
  final String body;
  final SMSStatus status;
  final String? messageSid; // Twilio message SID
  final DateTime timestamp;
  final bool read;
  final DateTime? readAt;

  SMSMessageModel({
    required this.id,
    required this.conversationId,
    required this.facilityId,
    required this.direction,
    required this.phoneNumber,
    required this.body,
    required this.status,
    this.messageSid,
    required this.timestamp,
    required this.read,
    this.readAt,
  });

  /// Create from Firestore document
  factory SMSMessageModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    return SMSMessageModel(
      id: doc.id,
      conversationId: doc.reference.parent.parent?.id ?? '',
      facilityId: doc.reference.parent.parent?.parent?.parent?.id ?? '',
      direction: _parseDirection(data?['direction']),
      phoneNumber: data?['phoneNumber'] ?? '',
      body: data?['body'] ?? '',
      status: _parseStatus(data?['status']),
      messageSid: data?['messageSid'],
      timestamp: (data?['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      read: data?['read'] ?? false,
      readAt: (data?['readAt'] as Timestamp?)?.toDate(),
    );
  }

  /// Convert to Firestore map
  Map<String, dynamic> toFirestore() {
    return {
      'direction': direction.name,
      'phoneNumber': phoneNumber,
      'body': body,
      'status': status.name,
      if (messageSid != null) 'messageSid': messageSid,
      'timestamp': Timestamp.fromDate(timestamp),
      'read': read,
      if (readAt != null) 'readAt': Timestamp.fromDate(readAt!),
    };
  }

  /// Parse direction from string
  static SMSDirection _parseDirection(dynamic value) {
    if (value == null) return SMSDirection.incoming;
    if (value.toString().toLowerCase() == 'outgoing') return SMSDirection.outgoing;
    return SMSDirection.incoming;
  }

  /// Parse status from string
  static SMSStatus _parseStatus(dynamic value) {
    if (value == null) return SMSStatus.received;
    final statusStr = value.toString().toLowerCase();
    switch (statusStr) {
      case 'sent':
        return SMSStatus.sent;
      case 'delivered':
        return SMSStatus.delivered;
      case 'failed':
        return SMSStatus.failed;
      default:
        return SMSStatus.received;
    }
  }

  /// Copy with method
  SMSMessageModel copyWith({
    String? id,
    String? conversationId,
    String? facilityId,
    SMSDirection? direction,
    String? phoneNumber,
    String? body,
    SMSStatus? status,
    String? messageSid,
    DateTime? timestamp,
    bool? read,
    DateTime? readAt,
  }) {
    return SMSMessageModel(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      facilityId: facilityId ?? this.facilityId,
      direction: direction ?? this.direction,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      body: body ?? this.body,
      status: status ?? this.status,
      messageSid: messageSid ?? this.messageSid,
      timestamp: timestamp ?? this.timestamp,
      read: read ?? this.read,
      readAt: readAt ?? this.readAt,
    );
  }
}

/// SMS message status
enum SMSStatus {
  sent,
  received,
  delivered,
  failed,
}

/// Extension for display names and colors
extension SMSStatusExtension on SMSStatus {
  String get displayName {
    switch (this) {
      case SMSStatus.sent:
        return 'Sent';
      case SMSStatus.received:
        return 'Received';
      case SMSStatus.delivered:
        return 'Delivered';
      case SMSStatus.failed:
        return 'Failed';
    }
  }
}

