import 'package:cloud_firestore/cloud_firestore.dart';

enum ReminderType {
  rentDue,
  rentOverdue,
  contractExpiring,
  contractExpired,
  paymentFailed,
  maintenanceDue,
  inspectionDue,
  custom,
}

enum ReminderStatus {
  pending,
  sent,
  failed,
  cancelled,
}

enum ReminderChannel {
  email,
  sms,
  push,
  inApp,
}

enum ReminderSendMode {
  immediate,
  digest,
}

class ReminderModel {
  final String id;
  final String tenantId;
  final String facilityId;
  final String? contractId;
  final String? paymentId;
  final String? tenantEmail;
  final String? tenantPhone;
  final ReminderType type;
  final ReminderStatus status;
  final List<ReminderChannel> channels;
  final String title;
  final String message;
  final DateTime scheduledFor;
  final DateTime? sentAt;
  final DateTime? readAt;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;
  final bool isActive;

  const ReminderModel({
    required this.id,
    required this.tenantId,
    required this.facilityId,
    this.contractId,
    this.paymentId,
    this.tenantEmail,
    this.tenantPhone,
    required this.type,
    required this.status,
    required this.channels,
    required this.title,
    required this.message,
    required this.scheduledFor,
    this.sentAt,
    this.readAt,
    this.metadata,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
    this.isActive = true,
  });

  factory ReminderModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ReminderModel(
      id: doc.id,
      tenantId: data['tenantId'] ?? '',
      facilityId: data['facilityId'] ?? '',
      contractId: data['contractId'],
      paymentId: data['paymentId'],
      tenantEmail: data['tenantEmail'],
      tenantPhone: data['tenantPhone'],
      type: ReminderType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => ReminderType.custom,
      ),
      status: ReminderStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => ReminderStatus.pending,
      ),
      channels: (data['channels'] as List<dynamic>?)
          ?.map((e) => ReminderChannel.values.firstWhere(
                (channel) => channel.name == e,
                orElse: () => ReminderChannel.inApp,
              ))
          .toList() ?? [ReminderChannel.inApp],
      title: data['title'] ?? '',
      message: data['message'] ?? '',
      scheduledFor: (data['scheduledFor'] as Timestamp).toDate(),
      sentAt: data['sentAt'] != null 
          ? (data['sentAt'] as Timestamp).toDate()
          : null,
      readAt: data['readAt'] != null 
          ? (data['readAt'] as Timestamp).toDate()
          : null,
      metadata: data['metadata'] != null 
          ? Map<String, dynamic>.from(data['metadata'])
          : null,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      createdBy: data['createdBy'] ?? '',
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'tenantId': tenantId,
      'facilityId': facilityId,
      'contractId': contractId,
      'paymentId': paymentId,
      'tenantEmail': tenantEmail,
      'tenantPhone': tenantPhone,
      'type': type.name,
      'status': status.name,
      'channels': channels.map((e) => e.name).toList(),
      'title': title,
      'message': message,
      'scheduledFor': Timestamp.fromDate(scheduledFor),
      'sentAt': sentAt != null ? Timestamp.fromDate(sentAt!) : null,
      'readAt': readAt != null ? Timestamp.fromDate(readAt!) : null,
      'metadata': metadata,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'createdBy': createdBy,
      'isActive': isActive,
    };
  }

  ReminderModel copyWith({
    String? id,
    String? tenantId,
    String? facilityId,
    String? contractId,
    String? paymentId,
    String? tenantEmail,
    String? tenantPhone,
    ReminderType? type,
    ReminderStatus? status,
    List<ReminderChannel>? channels,
    String? title,
    String? message,
    DateTime? scheduledFor,
    DateTime? sentAt,
    DateTime? readAt,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    bool? isActive,
  }) {
    return ReminderModel(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      facilityId: facilityId ?? this.facilityId,
      contractId: contractId ?? this.contractId,
      paymentId: paymentId ?? this.paymentId,
      tenantEmail: tenantEmail ?? this.tenantEmail,
      tenantPhone: tenantPhone ?? this.tenantPhone,
      type: type ?? this.type,
      status: status ?? this.status,
      channels: channels ?? this.channels,
      title: title ?? this.title,
      message: message ?? this.message,
      scheduledFor: scheduledFor ?? this.scheduledFor,
      sentAt: sentAt ?? this.sentAt,
      readAt: readAt ?? this.readAt,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }

  // Helper getters
  bool get isOverdue => 
      status == ReminderStatus.pending && 
      DateTime.now().isAfter(scheduledFor);
  
  bool get isSent => status == ReminderStatus.sent;
  
  bool get isRead => readAt != null;
  
  int get daysUntilDue {
    final now = DateTime.now();
    if (scheduledFor.isBefore(now)) return 0;
    return scheduledFor.difference(now).inDays;
  }

  /// Days past the scheduled send date (for pending reminders only).
  int get daysOverdue {
    if (!isOverdue) return 0;
    return DateTime.now().difference(scheduledFor).inDays;
  }
  
  String get statusDisplayName {
    switch (status) {
      case ReminderStatus.pending:
        return isOverdue ? 'Overdue' : 'Pending';
      case ReminderStatus.sent:
        return 'Sent';
      case ReminderStatus.failed:
        return 'Failed';
      case ReminderStatus.cancelled:
        return 'Cancelled';
    }
  }
  
  String get channelsDisplayName {
    return channels.map((e) => e.displayName).join(', ');
  }
}

// Extension for enum display names
extension ReminderTypeExtension on ReminderType {
  String get displayName {
    switch (this) {
      case ReminderType.rentDue:
        return 'Rent Due';
      case ReminderType.rentOverdue:
        return 'Rent Overdue';
      case ReminderType.contractExpiring:
        return 'Contract Expiring';
      case ReminderType.contractExpired:
        return 'Contract Expired';
      case ReminderType.paymentFailed:
        return 'Payment Failed';
      case ReminderType.maintenanceDue:
        return 'Maintenance Due';
      case ReminderType.inspectionDue:
        return 'Inspection Due';
      case ReminderType.custom:
        return 'Custom';
    }
  }
}

extension ReminderStatusExtension on ReminderStatus {
  String get displayName {
    switch (this) {
      case ReminderStatus.pending:
        return 'Pending';
      case ReminderStatus.sent:
        return 'Sent';
      case ReminderStatus.failed:
        return 'Failed';
      case ReminderStatus.cancelled:
        return 'Cancelled';
    }
  }
}

extension ReminderChannelExtension on ReminderChannel {
  String get displayName {
    switch (this) {
      case ReminderChannel.email:
        return 'Email';
      case ReminderChannel.sms:
        return 'SMS';
      case ReminderChannel.push:
        return 'Push Notification';
      case ReminderChannel.inApp:
        return 'In-App';
    }
  }
}
