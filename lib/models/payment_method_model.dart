import 'package:cloud_firestore/cloud_firestore.dart';

enum PaymentMethodType {
  creditCard,
  debitCard,
  ach,
  other,
}

enum AutopayFrequency {
  monthly,
  weekly,
  quarterly,
  annually,
}

class PaymentMethod {
  final String id;
  final String tenantId;
  final String facilityId;
  final PaymentMethodType type;
  final String? stripePaymentMethodId; // Tokenized payment method ID from Stripe
  final String? stripeCustomerId; // Stripe customer ID
  final String? last4; // Last 4 digits of card/account
  final String? brand; // Visa, Mastercard, etc. (for cards)
  final String? bankName; // Bank name (for ACH)
  final String? accountType; // checking, savings (for ACH)
  final DateTime? expiryMonth; // Card expiry (if applicable)
  final DateTime? expiryYear; // Card expiry (if applicable)
  final bool isDefault;
  final bool autopayEnabled;
  final AutopaySchedule? autopaySchedule;
  final DateTime? autopayNextRun;
  final DateTime? autopayLastRun;
  final String? autopayLastResult; // success, failed, skipped
  final String? autopayLastError;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final bool isActive;

  const PaymentMethod({
    required this.id,
    required this.tenantId,
    required this.facilityId,
    required this.type,
    this.stripePaymentMethodId,
    this.stripeCustomerId,
    this.last4,
    this.brand,
    this.bankName,
    this.accountType,
    this.expiryMonth,
    this.expiryYear,
    this.isDefault = false,
    this.autopayEnabled = false,
    this.autopaySchedule,
    this.autopayNextRun,
    this.autopayLastRun,
    this.autopayLastResult,
    this.autopayLastError,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
    this.isActive = true,
  });

  factory PaymentMethod.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('PaymentMethod data is null');
    }

    AutopaySchedule? schedule;
    if (data['autopaySchedule'] != null) {
      final scheduleData = data['autopaySchedule'] as Map<String, dynamic>;
      schedule = AutopaySchedule(
        frequency: AutopayFrequency.values.firstWhere(
          (e) => e.name == scheduleData['frequency'],
          orElse: () => AutopayFrequency.monthly,
        ),
        dayOfMonth: scheduleData['dayOfMonth'] as int?,
        dayOfWeek: scheduleData['dayOfWeek'] as int?,
        amount: (scheduleData['amount'] as num?)?.toDouble(),
        includeInsurance: scheduleData['includeInsurance'] ?? false,
      );
    }

    return PaymentMethod(
      id: doc.id,
      tenantId: data['tenantId'] ?? '',
      facilityId: data['facilityId'] ?? '',
      type: PaymentMethodType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => PaymentMethodType.other,
      ),
      stripePaymentMethodId: data['stripePaymentMethodId'],
      stripeCustomerId: data['stripeCustomerId'],
      last4: data['last4'],
      brand: data['brand'],
      bankName: data['bankName'],
      accountType: data['accountType'],
      expiryMonth: data['expiryMonth'] != null
          ? DateTime(2000, (data['expiryMonth'] as num).toInt(), 1)
          : null,
      expiryYear: data['expiryYear'] != null
          ? DateTime((data['expiryYear'] as num).toInt(), 1, 1)
          : null,
      isDefault: data['isDefault'] ?? false,
      autopayEnabled: data['autopayEnabled'] ?? false,
      autopaySchedule: schedule,
      autopayNextRun: data['autopayNextRun'] != null
          ? (data['autopayNextRun'] as Timestamp).toDate()
          : null,
      autopayLastRun: data['autopayLastRun'] != null
          ? (data['autopayLastRun'] as Timestamp).toDate()
          : null,
      autopayLastResult: data['autopayLastResult'],
      autopayLastError: data['autopayLastError'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
      createdBy: data['createdBy'] ?? '',
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'tenantId': tenantId,
      'facilityId': facilityId,
      'type': type.name,
      if (stripePaymentMethodId != null && stripePaymentMethodId!.isNotEmpty)
        'stripePaymentMethodId': stripePaymentMethodId,
      if (stripeCustomerId != null && stripeCustomerId!.isNotEmpty)
        'stripeCustomerId': stripeCustomerId,
      if (last4 != null && last4!.isNotEmpty) 'last4': last4,
      if (brand != null && brand!.isNotEmpty) 'brand': brand,
      if (bankName != null && bankName!.isNotEmpty) 'bankName': bankName,
      if (accountType != null && accountType!.isNotEmpty) 'accountType': accountType,
      if (expiryMonth != null) 'expiryMonth': expiryMonth!.month,
      if (expiryYear != null) 'expiryYear': expiryYear!.year,
      'isDefault': isDefault,
      'autopayEnabled': autopayEnabled,
      if (autopaySchedule != null)
        'autopaySchedule': {
          'frequency': autopaySchedule!.frequency.name,
          if (autopaySchedule!.dayOfMonth != null)
            'dayOfMonth': autopaySchedule!.dayOfMonth,
          if (autopaySchedule!.dayOfWeek != null)
            'dayOfWeek': autopaySchedule!.dayOfWeek,
          if (autopaySchedule!.amount != null) 'amount': autopaySchedule!.amount,
          'includeInsurance': autopaySchedule!.includeInsurance,
        },
      if (autopayNextRun != null)
        'autopayNextRun': Timestamp.fromDate(autopayNextRun!),
      if (autopayLastRun != null)
        'autopayLastRun': Timestamp.fromDate(autopayLastRun!),
      if (autopayLastResult != null && autopayLastResult!.isNotEmpty)
        'autopayLastResult': autopayLastResult,
      if (autopayLastError != null && autopayLastError!.isNotEmpty)
        'autopayLastError': autopayLastError,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'createdBy': createdBy,
      'isActive': isActive,
    };
  }

  String get displayName {
    if (type == PaymentMethodType.creditCard || type == PaymentMethodType.debitCard) {
      final brandStr = brand ?? 'Card';
      final last4Str = last4 ?? '****';
      return '$brandStr •••• $last4Str';
    } else if (type == PaymentMethodType.ach) {
      final bankStr = bankName ?? 'Bank';
      final last4Str = last4 ?? '****';
      return '$bankStr •••• $last4Str';
    }
    return type.name;
  }

  String get typeDisplayName {
    switch (type) {
      case PaymentMethodType.creditCard:
        return 'Credit Card';
      case PaymentMethodType.debitCard:
        return 'Debit Card';
      case PaymentMethodType.ach:
        return 'ACH/Bank Transfer';
      case PaymentMethodType.other:
        return 'Other';
    }
  }

  bool get isExpired {
    if (expiryYear == null || expiryMonth == null) return false;
    final now = DateTime.now();
    return now.year > expiryYear!.year ||
        (now.year == expiryYear!.year && now.month > expiryMonth!.month);
  }

  PaymentMethod copyWith({
    String? id,
    String? tenantId,
    String? facilityId,
    PaymentMethodType? type,
    String? stripePaymentMethodId,
    String? stripeCustomerId,
    String? last4,
    String? brand,
    String? bankName,
    String? accountType,
    DateTime? expiryMonth,
    DateTime? expiryYear,
    bool? isDefault,
    bool? autopayEnabled,
    AutopaySchedule? autopaySchedule,
    DateTime? autopayNextRun,
    DateTime? autopayLastRun,
    String? autopayLastResult,
    String? autopayLastError,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    bool? isActive,
  }) {
    return PaymentMethod(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      facilityId: facilityId ?? this.facilityId,
      type: type ?? this.type,
      stripePaymentMethodId: stripePaymentMethodId ?? this.stripePaymentMethodId,
      stripeCustomerId: stripeCustomerId ?? this.stripeCustomerId,
      last4: last4 ?? this.last4,
      brand: brand ?? this.brand,
      bankName: bankName ?? this.bankName,
      accountType: accountType ?? this.accountType,
      expiryMonth: expiryMonth ?? this.expiryMonth,
      expiryYear: expiryYear ?? this.expiryYear,
      isDefault: isDefault ?? this.isDefault,
      autopayEnabled: autopayEnabled ?? this.autopayEnabled,
      autopaySchedule: autopaySchedule ?? this.autopaySchedule,
      autopayNextRun: autopayNextRun ?? this.autopayNextRun,
      autopayLastRun: autopayLastRun ?? this.autopayLastRun,
      autopayLastResult: autopayLastResult ?? this.autopayLastResult,
      autopayLastError: autopayLastError ?? this.autopayLastError,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }
}

class AutopaySchedule {
  final AutopayFrequency frequency;
  final int? dayOfMonth; // For monthly/quarterly/annually (1-31)
  final int? dayOfWeek; // For weekly (0-6, Sunday = 0)
  final double? amount; // Fixed amount, or null for full balance
  final bool includeInsurance; // Include insurance in autopay

  const AutopaySchedule({
    required this.frequency,
    this.dayOfMonth,
    this.dayOfWeek,
    this.amount,
    this.includeInsurance = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'frequency': frequency.name,
      if (dayOfMonth != null) 'dayOfMonth': dayOfMonth,
      if (dayOfWeek != null) 'dayOfWeek': dayOfWeek,
      if (amount != null) 'amount': amount,
      'includeInsurance': includeInsurance,
    };
  }

  String get displayName {
    switch (frequency) {
      case AutopayFrequency.monthly:
        return 'Monthly${dayOfMonth != null ? ' (Day $dayOfMonth)' : ''}';
      case AutopayFrequency.weekly:
        return 'Weekly${dayOfWeek != null ? ' (${_dayName(dayOfWeek!)})' : ''}';
      case AutopayFrequency.quarterly:
        return 'Quarterly${dayOfMonth != null ? ' (Day $dayOfMonth)' : ''}';
      case AutopayFrequency.annually:
        return 'Annually${dayOfMonth != null ? ' (Day $dayOfMonth)' : ''}';
    }
  }

  String _dayName(int day) {
    const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
    return days[day % 7];
  }
}

