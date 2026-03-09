/// Saved payment method (from listSavedPaymentMethods callable)
class SavedPaymentMethodModel {
  final String brand;
  final String last4;
  final int expMonth;
  final int expYear;
  final String paymentMethodId;
  final bool isDefault;

  const SavedPaymentMethodModel({
    required this.brand,
    required this.last4,
    required this.expMonth,
    required this.expYear,
    required this.paymentMethodId,
    required this.isDefault,
  });

  factory SavedPaymentMethodModel.fromMap(Map<String, dynamic> map) {
    return SavedPaymentMethodModel(
      brand: map['brand'] as String? ?? 'card',
      last4: map['last4'] as String? ?? '****',
      expMonth: (map['expMonth'] as num?)?.toInt() ?? 0,
      expYear: (map['expYear'] as num?)?.toInt() ?? 0,
      paymentMethodId: map['paymentMethodId'] as String? ?? '',
      isDefault: map['isDefault'] == true,
    );
  }

  String get displayLabel => '${brand.toUpperCase()} •••• $last4';
}
