import 'package:cloud_firestore/cloud_firestore.dart';

enum FacilityNotificationType {
  autopayDisabled,
  autopayEnabled,
  autopayRequested,
  stripeActionRequired,
}

extension FacilityNotificationTypeX on FacilityNotificationType {
  String get value {
    switch (this) {
      case FacilityNotificationType.autopayDisabled:
        return 'AUTOPAY_DISABLED';
      case FacilityNotificationType.autopayEnabled:
        return 'AUTOPAY_ENABLED';
      case FacilityNotificationType.autopayRequested:
        return 'AUTOPAY_REQUESTED';
      case FacilityNotificationType.stripeActionRequired:
        return 'STRIPE_ACTION_REQUIRED';
    }
  }

  static FacilityNotificationType fromString(String? v) {
    switch (v) {
      case 'AUTOPAY_DISABLED':
        return FacilityNotificationType.autopayDisabled;
      case 'AUTOPAY_ENABLED':
        return FacilityNotificationType.autopayEnabled;
      case 'AUTOPAY_REQUESTED':
        return FacilityNotificationType.autopayRequested;
      case 'STRIPE_ACTION_REQUIRED':
        return FacilityNotificationType.stripeActionRequired;
      default:
        return FacilityNotificationType.autopayRequested;
    }
  }
}

/// Facilities/{facilityId}/Notifications/{notificationId}
class FacilityNotificationModel {
  final String id;
  final String facilityId;
  final FacilityNotificationType type;
  final String? tenantId;
  final String? tenantName;
  final DateTime createdAt;
  final DateTime? readAt;
  final String message;
  final Map<String, dynamic>? metadata;

  const FacilityNotificationModel({
    required this.id,
    required this.facilityId,
    required this.type,
    this.tenantId,
    this.tenantName,
    required this.createdAt,
    this.readAt,
    required this.message,
    this.metadata,
  });

  bool get isUnread => readAt == null;

  factory FacilityNotificationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return FacilityNotificationModel(
      id: doc.id,
      facilityId: data['facilityId'] as String? ?? '',
      type: FacilityNotificationTypeX.fromString(data['type'] as String?),
      tenantId: data['tenantId'] as String?,
      tenantName: data['tenantName'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      readAt: (data['readAt'] as Timestamp?)?.toDate(),
      message: data['message'] as String? ?? '',
      metadata: data['metadata'] != null ? Map<String, dynamic>.from(data['metadata'] as Map) : null,
    );
  }
}
