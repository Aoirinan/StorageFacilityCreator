import 'package:cloud_firestore/cloud_firestore.dart';

/// Safe Stripe display summary (no PAN/CVC)
class PaymentMethodSummary {
  final String? brand;
  final String? last4;
  final int? expMonth;
  final int? expYear;

  const PaymentMethodSummary({
    this.brand,
    this.last4,
    this.expMonth,
    this.expYear,
  });

  factory PaymentMethodSummary.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const PaymentMethodSummary();
    return PaymentMethodSummary(
      brand: data['brand'] as String?,
      last4: data['last4'] as String?,
      expMonth: (data['expMonth'] as num?)?.toInt(),
      expYear: (data['expYear'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (brand != null) 'brand': brand,
      if (last4 != null) 'last4': last4,
      if (expMonth != null) 'expMonth': expMonth,
      if (expYear != null) 'expYear': expYear,
    };
  }

  String get displayLabel {
    final b = (brand ?? 'Card').toUpperCase();
    final l4 = last4 ?? '****';
    return '$b •••• $l4';
  }
}

/// Tenant Stripe data on connected account (stored on tenant doc)
class TenantStripeModel {
  final String? customerId;
  final String? defaultPaymentMethodId;
  final PaymentMethodSummary? paymentMethodSummary;

  const TenantStripeModel({
    this.customerId,
    this.defaultPaymentMethodId,
    this.paymentMethodSummary,
  });

  bool get hasPaymentMethod => defaultPaymentMethodId != null && defaultPaymentMethodId!.isNotEmpty;

  factory TenantStripeModel.fromMap(Map<String, dynamic>? data) {
    if (data == null) return const TenantStripeModel();
    return TenantStripeModel(
      customerId: data['customerId'] as String?,
      defaultPaymentMethodId: data['defaultPaymentMethodId'] as String?,
      paymentMethodSummary: data['paymentMethodSummary'] != null
          ? PaymentMethodSummary.fromMap(Map<String, dynamic>.from(data['paymentMethodSummary'] as Map))
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (customerId != null) 'customerId': customerId,
      if (defaultPaymentMethodId != null) 'defaultPaymentMethodId': defaultPaymentMethodId,
      if (paymentMethodSummary != null) 'paymentMethodSummary': paymentMethodSummary!.toMap(),
    };
  }
}
