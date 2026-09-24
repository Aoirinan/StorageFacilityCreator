import 'package:cloud_firestore/cloud_firestore.dart';

enum FacilityNotificationType {
  autopayDisabled,
  autopayEnabled,
  autopayRequested,
  stripeActionRequired,
  // Stays (short-term rentals), in-app only.
  stayBookingImported,
  stayBookingChanged,
  stayBookingRemoved,
  stayBookingNeedsReview,
  stayConflict,
  stayFeedFirstSync,
  stayFeedFailing,
  stayFeedSuspicious,
  stayTurnoverDone,
  stayTurnoverIssue,
  stayTurnoverUnassigned,
  stayDailyBrief,

  /// A type this app does not know (or the doc has none). It used to read as
  /// autopayRequested; it still looks the same on screen.
  other,
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
      case FacilityNotificationType.stayBookingImported:
        return 'STAY_BOOKING_IMPORTED';
      case FacilityNotificationType.stayBookingChanged:
        return 'STAY_BOOKING_CHANGED';
      case FacilityNotificationType.stayBookingRemoved:
        return 'STAY_BOOKING_REMOVED';
      case FacilityNotificationType.stayBookingNeedsReview:
        return 'STAY_BOOKING_NEEDS_REVIEW';
      case FacilityNotificationType.stayConflict:
        return 'STAY_CONFLICT';
      case FacilityNotificationType.stayFeedFirstSync:
        return 'STAY_FEED_FIRST_SYNC';
      case FacilityNotificationType.stayFeedFailing:
        return 'STAY_FEED_FAILING';
      case FacilityNotificationType.stayFeedSuspicious:
        return 'STAY_FEED_SUSPICIOUS';
      case FacilityNotificationType.stayTurnoverDone:
        return 'STAY_TURNOVER_DONE';
      case FacilityNotificationType.stayTurnoverIssue:
        return 'STAY_TURNOVER_ISSUE';
      case FacilityNotificationType.stayTurnoverUnassigned:
        return 'STAY_TURNOVER_UNASSIGNED';
      case FacilityNotificationType.stayDailyBrief:
        return 'STAY_DAILY_BRIEF';
      case FacilityNotificationType.other:
        return 'OTHER';
    }
  }

  /// A Stays notification (its metadata.route opens the stay or task).
  bool get isStay => value.startsWith('STAY_');

  static FacilityNotificationType fromString(String? v) {
    for (final type in FacilityNotificationType.values) {
      if (type != FacilityNotificationType.other && type.value == v) return type;
    }
    return FacilityNotificationType.other;
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
