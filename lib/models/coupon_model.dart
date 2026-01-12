import 'package:cloud_firestore/cloud_firestore.dart';

enum CouponType {
  percentage, // Discount percentage (e.g., 10% off)
  fixedAmount, // Fixed dollar amount off (e.g., $50 off)
  freeMonth, // Free month of rent
}

enum CouponStatus {
  active,
  inactive,
  expired,
  usedUp,
}

class CouponModel {
  final String id;
  final String facilityId;
  final String code; // Coupon code (e.g., "SUMMER2025")
  final String name; // Display name
  final String? description;
  final CouponType type;
  final double value; // Percentage (0-100) or fixed amount
  final CouponStatus status;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final int? maxUses; // Maximum number of times this coupon can be used
  final int currentUses; // Current number of times used
  final double? minPurchaseAmount; // Minimum purchase amount to use this coupon
  final bool appliesToRent;
  final bool appliesToFees;
  final bool appliesToInsurance;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final bool isActive;

  const CouponModel({
    required this.id,
    required this.facilityId,
    required this.code,
    required this.name,
    this.description,
    required this.type,
    required this.value,
    required this.status,
    this.validFrom,
    this.validUntil,
    this.maxUses,
    this.currentUses = 0,
    this.minPurchaseAmount,
    this.appliesToRent = true,
    this.appliesToFees = true,
    this.appliesToInsurance = false,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
    this.isActive = true,
  });

  factory CouponModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('CouponModel data is null');
    }

    return CouponModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      code: data['code'] ?? '',
      name: data['name'] ?? '',
      description: data['description'],
      type: CouponType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => CouponType.percentage,
      ),
      value: (data['value'] ?? 0.0).toDouble(),
      status: CouponStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => CouponStatus.active,
      ),
      validFrom: data['validFrom'] != null
          ? (data['validFrom'] as Timestamp).toDate()
          : null,
      validUntil: data['validUntil'] != null
          ? (data['validUntil'] as Timestamp).toDate()
          : null,
      maxUses: data['maxUses'],
      currentUses: data['currentUses'] ?? 0,
      minPurchaseAmount: data['minPurchaseAmount'] != null
          ? (data['minPurchaseAmount'] as num).toDouble()
          : null,
      appliesToRent: data['appliesToRent'] ?? true,
      appliesToFees: data['appliesToFees'] ?? true,
      appliesToInsurance: data['appliesToInsurance'] ?? false,
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
      'facilityId': facilityId,
      'code': code.toUpperCase(), // Store in uppercase
      'name': name,
      if (description != null && description!.isNotEmpty) 'description': description,
      'type': type.name,
      'value': value,
      'status': status.name,
      if (validFrom != null) 'validFrom': Timestamp.fromDate(validFrom!),
      if (validUntil != null) 'validUntil': Timestamp.fromDate(validUntil!),
      if (maxUses != null) 'maxUses': maxUses,
      'currentUses': currentUses,
      if (minPurchaseAmount != null) 'minPurchaseAmount': minPurchaseAmount,
      'appliesToRent': appliesToRent,
      'appliesToFees': appliesToFees,
      'appliesToInsurance': appliesToInsurance,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'createdBy': createdBy,
      'isActive': isActive,
    };
  }

  CouponModel copyWith({
    String? id,
    String? facilityId,
    String? code,
    String? name,
    String? description,
    CouponType? type,
    double? value,
    CouponStatus? status,
    DateTime? validFrom,
    DateTime? validUntil,
    int? maxUses,
    int? currentUses,
    double? minPurchaseAmount,
    bool? appliesToRent,
    bool? appliesToFees,
    bool? appliesToInsurance,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    bool? isActive,
  }) {
    return CouponModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      code: code ?? this.code,
      name: name ?? this.name,
      description: description ?? this.description,
      type: type ?? this.type,
      value: value ?? this.value,
      status: status ?? this.status,
      validFrom: validFrom ?? this.validFrom,
      validUntil: validUntil ?? this.validUntil,
      maxUses: maxUses ?? this.maxUses,
      currentUses: currentUses ?? this.currentUses,
      minPurchaseAmount: minPurchaseAmount ?? this.minPurchaseAmount,
      appliesToRent: appliesToRent ?? this.appliesToRent,
      appliesToFees: appliesToFees ?? this.appliesToFees,
      appliesToInsurance: appliesToInsurance ?? this.appliesToInsurance,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }

  /// Check if coupon is currently valid
  bool get isValid {
    if (status != CouponStatus.active) return false;
    if (!isActive) return false;
    
    final now = DateTime.now();
    if (validFrom != null && now.isBefore(validFrom!)) return false;
    if (validUntil != null && now.isAfter(validUntil!)) return false;
    if (maxUses != null && currentUses >= (maxUses as num).toInt()) return false;
    
    return true;
  }

  /// Calculate discount amount for a given purchase amount
  double calculateDiscount(double purchaseAmount) {
    if (!isValid) return 0.0;
    if (minPurchaseAmount != null && purchaseAmount < minPurchaseAmount!) return 0.0;

    switch (type) {
      case CouponType.percentage:
        return purchaseAmount * (value / 100);
      case CouponType.fixedAmount:
        return value; // Don't exceed purchase amount
      case CouponType.freeMonth:
        // This would need to know the monthly rent amount
        // For now, return 0 and handle separately
        return 0.0;
    }
  }

  String get formattedValue {
    switch (type) {
      case CouponType.percentage:
        return '${value.toStringAsFixed(0)}%';
      case CouponType.fixedAmount:
        return '\$${value.toStringAsFixed(2)}';
      case CouponType.freeMonth:
        return '1 Free Month';
    }
  }

  String get statusDisplayName {
    switch (status) {
      case CouponStatus.active:
        return 'Active';
      case CouponStatus.inactive:
        return 'Inactive';
      case CouponStatus.expired:
        return 'Expired';
      case CouponStatus.usedUp:
        return 'Used Up';
    }
  }
}

