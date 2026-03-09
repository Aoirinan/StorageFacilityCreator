import 'package:cloud_firestore/cloud_firestore.dart';

/// Stripe payment record (facilities/{fId}/tenants/{tId}/payments/{pId})
class TenantStripePaymentModel {
  final String id;
  final String facilityId;
  final String tenantId;
  final String type; // "one_time" | "invoice" | "subscription"
  final int amountCents;
  final String currency;
  final String? stripeObjectId;
  final String status;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? failureCode;
  final String? failureMessage;

  const TenantStripePaymentModel({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    required this.type,
    required this.amountCents,
    required this.currency,
    this.stripeObjectId,
    required this.status,
    this.createdAt,
    this.updatedAt,
    this.failureCode,
    this.failureMessage,
  });

  factory TenantStripePaymentModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return TenantStripePaymentModel(
      id: doc.id,
      facilityId: data['facilityId'] as String? ?? '',
      tenantId: data['tenantId'] as String? ?? '',
      type: data['type'] as String? ?? 'one_time',
      amountCents: (data['amountCents'] as num?)?.toInt() ?? 0,
      currency: data['currency'] as String? ?? 'usd',
      stripeObjectId: data['stripeObjectId'] as String?,
      status: data['status'] as String? ?? 'processing',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      failureCode: data['failureCode'] as String?,
      failureMessage: data['failureMessage'] as String?,
    );
  }

  double get amount => amountCents / 100.0;
  String get formattedAmount => '\$${amount.toStringAsFixed(2)}';
  bool get isSucceeded => status == 'succeeded';
  bool get isFailed => status == 'failed';
  bool get isProcessing => status == 'processing';
}
