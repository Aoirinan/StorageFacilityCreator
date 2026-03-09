import 'package:cloud_firestore/cloud_firestore.dart';

/// Tenant Stripe billing state (facilities/{fId}/tenants/{tId}/billing/default)
class TenantBillingModel {
  final String facilityId;
  final String tenantId;
  final String? stripeCustomerId;
  final String? defaultPaymentMethodId;
  final bool autopayEnabled;
  final String? stripeSubscriptionId;
  final String? lastPaymentStatus; // "succeeded" | "failed" | "requires_action" | "processing" | null
  final DateTime? lastPaymentAt;
  final String? lastFailureCode;
  final String? lastFailureMessage;
  final DateTime? nextDueAt;
  final DateTime? updatedAt;

  const TenantBillingModel({
    required this.facilityId,
    required this.tenantId,
    this.stripeCustomerId,
    this.defaultPaymentMethodId,
    this.autopayEnabled = false,
    this.stripeSubscriptionId,
    this.lastPaymentStatus,
    this.lastPaymentAt,
    this.lastFailureCode,
    this.lastFailureMessage,
    this.nextDueAt,
    this.updatedAt,
  });

  factory TenantBillingModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return TenantBillingModel(
      facilityId: data['facilityId'] as String? ?? '',
      tenantId: data['tenantId'] as String? ?? '',
      stripeCustomerId: data['stripeCustomerId'] as String?,
      defaultPaymentMethodId: data['defaultPaymentMethodId'] as String?,
      autopayEnabled: data['autopayEnabled'] == true,
      stripeSubscriptionId: data['stripeSubscriptionId'] as String?,
      lastPaymentStatus: data['lastPaymentStatus'] as String?,
      lastPaymentAt: (data['lastPaymentAt'] as Timestamp?)?.toDate(),
      lastFailureCode: data['lastFailureCode'] as String?,
      lastFailureMessage: data['lastFailureMessage'] as String?,
      nextDueAt: (data['nextDueAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  bool get hasCard => defaultPaymentMethodId != null && defaultPaymentMethodId!.isNotEmpty;
  bool get canEnableAutopay => hasCard && !autopayEnabled;
}
