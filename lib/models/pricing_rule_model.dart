import 'package:cloud_firestore/cloud_firestore.dart';

/// Type of pricing rule
enum PricingRuleType {
  occupancyBased, // Adjust based on facility occupancy percentage
  seasonal, // Adjust based on time of year
  unitType, // Adjust based on unit type
  demandBased, // Adjust based on demand for specific unit sizes
  marketRate, // Adjust to match market rates
}

/// Pricing adjustment method
enum PricingAdjustmentMethod {
  percentage, // Adjust by percentage (e.g., +10% or -5%)
  fixedAmount, // Adjust by fixed dollar amount
  multiplier, // Multiply by factor (e.g., 1.1 = 10% increase)
  setPrice, // Set to specific price
}

/// Pricing rule for dynamic rate adjustments
class PricingRule {
  final String id;
  final String facilityId;
  final String name;
  final String? description;
  final PricingRuleType type;
  final PricingAdjustmentMethod adjustmentMethod;
  final double adjustmentValue; // Percentage, amount, multiplier, or price
  final bool isActive;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final Map<String, dynamic>? conditions; // Rule-specific conditions
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;

  const PricingRule({
    required this.id,
    required this.facilityId,
    required this.name,
    this.description,
    required this.type,
    required this.adjustmentMethod,
    required this.adjustmentValue,
    this.isActive = true,
    this.validFrom,
    this.validUntil,
    this.conditions,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'name': name,
      'description': description,
      'type': type.name,
      'adjustmentMethod': adjustmentMethod.name,
      'adjustmentValue': adjustmentValue,
      'isActive': isActive,
      'validFrom': validFrom != null ? Timestamp.fromDate(validFrom!) : null,
      'validUntil': validUntil != null ? Timestamp.fromDate(validUntil!) : null,
      'conditions': conditions,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'createdBy': createdBy,
    };
  }

  factory PricingRule.fromMap(String id, Map<String, dynamic> map) {
    return PricingRule(
      id: id,
      facilityId: map['facilityId'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      type: PricingRuleType.values.firstWhere(
        (t) => t.name == map['type'],
        orElse: () => PricingRuleType.occupancyBased,
      ),
      adjustmentMethod: PricingAdjustmentMethod.values.firstWhere(
        (m) => m.name == map['adjustmentMethod'],
        orElse: () => PricingAdjustmentMethod.percentage,
      ),
      adjustmentValue: (map['adjustmentValue'] as num?)?.toDouble() ?? 0.0,
      isActive: map['isActive'] as bool? ?? true,
      validFrom: (map['validFrom'] as Timestamp?)?.toDate(),
      validUntil: (map['validUntil'] as Timestamp?)?.toDate(),
      conditions: map['conditions'] as Map<String, dynamic>?,
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: map['createdBy'] as String,
    );
  }

  /// Check if rule is currently valid
  bool get isValid {
    if (!isActive) return false;
    final now = DateTime.now();
    if (validFrom != null && now.isBefore(validFrom!)) return false;
    if (validUntil != null && now.isAfter(validUntil!)) return false;
    return true;
  }

  /// Calculate adjusted price from base price
  double calculateAdjustedPrice(double basePrice) {
    if (!isValid) return basePrice;

    switch (adjustmentMethod) {
      case PricingAdjustmentMethod.percentage:
        return basePrice * (1 + (adjustmentValue / 100));
      case PricingAdjustmentMethod.fixedAmount:
        return basePrice + adjustmentValue;
      case PricingAdjustmentMethod.multiplier:
        return basePrice * adjustmentValue;
      case PricingAdjustmentMethod.setPrice:
        return adjustmentValue;
    }
  }

  /// Get adjustment description
  String get adjustmentDescription {
    switch (adjustmentMethod) {
      case PricingAdjustmentMethod.percentage:
        return '${adjustmentValue >= 0 ? '+' : ''}${adjustmentValue.toStringAsFixed(1)}%';
      case PricingAdjustmentMethod.fixedAmount:
        return '\$${adjustmentValue >= 0 ? '+' : ''}${adjustmentValue.toStringAsFixed(2)}';
      case PricingAdjustmentMethod.multiplier:
        final percent = ((adjustmentValue - 1) * 100);
        return '${percent >= 0 ? '+' : ''}${percent.toStringAsFixed(1)}%';
      case PricingAdjustmentMethod.setPrice:
        return 'Set to \$${adjustmentValue.toStringAsFixed(2)}';
    }
  }
}

/// Pricing recommendation for a unit
class PricingRecommendation {
  final String unitId;
  final String unitNumber;
  final double currentPrice;
  final double recommendedPrice;
  final double adjustmentAmount;
  final double adjustmentPercentage;
  final List<String> appliedRules; // Rule names that influenced this recommendation
  final String? reason; // Explanation of recommendation

  const PricingRecommendation({
    required this.unitId,
    required this.unitNumber,
    required this.currentPrice,
    required this.recommendedPrice,
    required this.adjustmentAmount,
    required this.adjustmentPercentage,
    required this.appliedRules,
    this.reason,
  });

  Map<String, dynamic> toMap() {
    return {
      'unitId': unitId,
      'unitNumber': unitNumber,
      'currentPrice': currentPrice,
      'recommendedPrice': recommendedPrice,
      'adjustmentAmount': adjustmentAmount,
      'adjustmentPercentage': adjustmentPercentage,
      'appliedRules': appliedRules,
      'reason': reason,
    };
  }

  factory PricingRecommendation.fromMap(Map<String, dynamic> map) {
    return PricingRecommendation(
      unitId: map['unitId'] as String,
      unitNumber: map['unitNumber'] as String,
      currentPrice: (map['currentPrice'] as num?)?.toDouble() ?? 0.0,
      recommendedPrice: (map['recommendedPrice'] as num?)?.toDouble() ?? 0.0,
      adjustmentAmount: (map['adjustmentAmount'] as num?)?.toDouble() ?? 0.0,
      adjustmentPercentage: (map['adjustmentPercentage'] as num?)?.toDouble() ?? 0.0,
      appliedRules: List<String>.from(map['appliedRules'] ?? []),
      reason: map['reason'] as String?,
    );
  }
}

