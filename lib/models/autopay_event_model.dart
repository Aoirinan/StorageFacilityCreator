import 'package:cloud_firestore/cloud_firestore.dart';

enum AutopayEventAction {
  requested,
  enabled,
  disabled,
  cardAdded,
  cardRemoved,
  paymentFailed,
  paymentSucceeded,
}

extension AutopayEventActionX on AutopayEventAction {
  String get value {
    switch (this) {
      case AutopayEventAction.requested:
        return 'REQUESTED';
      case AutopayEventAction.enabled:
        return 'ENABLED';
      case AutopayEventAction.disabled:
        return 'DISABLED';
      case AutopayEventAction.cardAdded:
        return 'CARD_ADDED';
      case AutopayEventAction.cardRemoved:
        return 'CARD_REMOVED';
      case AutopayEventAction.paymentFailed:
        return 'PAYMENT_FAILED';
      case AutopayEventAction.paymentSucceeded:
        return 'PAYMENT_SUCCEEDED';
    }
  }

  String get displayLabel {
    switch (this) {
      case AutopayEventAction.requested:
        return 'Requested';
      case AutopayEventAction.enabled:
        return 'Enabled';
      case AutopayEventAction.disabled:
        return 'Disabled';
      case AutopayEventAction.cardAdded:
        return 'Card Added';
      case AutopayEventAction.cardRemoved:
        return 'Card Removed';
      case AutopayEventAction.paymentFailed:
        return 'Payment Failed';
      case AutopayEventAction.paymentSucceeded:
        return 'Payment Succeeded';
    }
  }

  static AutopayEventAction fromString(String? v) {
    switch (v) {
      case 'REQUESTED':
        return AutopayEventAction.requested;
      case 'ENABLED':
        return AutopayEventAction.enabled;
      case 'DISABLED':
        return AutopayEventAction.disabled;
      case 'CARD_ADDED':
        return AutopayEventAction.cardAdded;
      case 'CARD_REMOVED':
        return AutopayEventAction.cardRemoved;
      case 'PAYMENT_FAILED':
        return AutopayEventAction.paymentFailed;
      case 'PAYMENT_SUCCEEDED':
        return AutopayEventAction.paymentSucceeded;
      default:
        return AutopayEventAction.disabled;
    }
  }
}

enum AutopayEventSource {
  tenant,
  facility,
  system,
}

extension AutopayEventSourceX on AutopayEventSource {
  String get value {
    switch (this) {
      case AutopayEventSource.tenant:
        return 'TENANT';
      case AutopayEventSource.facility:
        return 'FACILITY';
      case AutopayEventSource.system:
        return 'SYSTEM';
    }
  }

  static AutopayEventSource fromString(String? v) {
    switch (v) {
      case 'TENANT':
        return AutopayEventSource.tenant;
      case 'FACILITY':
        return AutopayEventSource.facility;
      case 'SYSTEM':
        return AutopayEventSource.system;
      default:
        return AutopayEventSource.system;
    }
  }
}

/// Facilities/{facilityId}/AutopayEvents/{eventId}
class AutopayEventModel {
  final String id;
  final String facilityId;
  final String? tenantId;
  final String? tenantName;
  final AutopayEventAction action;
  final AutopayEventSource source;
  final String? reason;
  final DateTime createdAt;

  const AutopayEventModel({
    required this.id,
    required this.facilityId,
    this.tenantId,
    this.tenantName,
    required this.action,
    required this.source,
    this.reason,
    required this.createdAt,
  });

  factory AutopayEventModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return AutopayEventModel(
      id: doc.id,
      facilityId: data['facilityId'] as String? ?? '',
      tenantId: data['tenantId'] as String?,
      tenantName: data['tenantName'] as String?,
      action: AutopayEventActionX.fromString(data['action'] as String?),
      source: AutopayEventSourceX.fromString(data['source'] as String?),
      reason: data['reason'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
