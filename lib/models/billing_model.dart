import 'package:cloud_firestore/cloud_firestore.dart';

/// Billing model for facility email usage tracking
class FacilityBillingModel {
  final String facilityId;
  final String monthKey; // Format: yyyyMM (e.g., "202412")
  final int emailCount;
  final int emailFreeTier;
  final double emailOverageRate; // USD per extra email
  final DateTime lastReset;
  final DateTime updatedAt;
  final Map<String, dynamic>? metadata;

  const FacilityBillingModel({
    required this.facilityId,
    required this.monthKey,
    required this.emailCount,
    required this.emailFreeTier,
    required this.emailOverageRate,
    required this.lastReset,
    required this.updatedAt,
    this.metadata,
  });

  factory FacilityBillingModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return FacilityBillingModel(
      facilityId: data['facilityId'] ?? '',
      monthKey: data['monthKey'] ?? '',
      emailCount: data['emailCount'] ?? 0,
      emailFreeTier: data['emailFreeTier'] ?? 5000,
      emailOverageRate: (data['emailOverageRate'] ?? 0.0001).toDouble(),
      lastReset: (data['lastReset'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      metadata: data['metadata'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'monthKey': monthKey,
      'emailCount': emailCount,
      'emailFreeTier': emailFreeTier,
      'emailOverageRate': emailOverageRate,
      'lastReset': Timestamp.fromDate(lastReset),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'metadata': metadata,
    };
  }

  FacilityBillingModel copyWith({
    String? facilityId,
    String? monthKey,
    int? emailCount,
    int? emailFreeTier,
    double? emailOverageRate,
    DateTime? lastReset,
    DateTime? updatedAt,
    Map<String, dynamic>? metadata,
  }) {
    return FacilityBillingModel(
      facilityId: facilityId ?? this.facilityId,
      monthKey: monthKey ?? this.monthKey,
      emailCount: emailCount ?? this.emailCount,
      emailFreeTier: emailFreeTier ?? this.emailFreeTier,
      emailOverageRate: emailOverageRate ?? this.emailOverageRate,
      lastReset: lastReset ?? this.lastReset,
      updatedAt: updatedAt ?? this.updatedAt,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Calculate overage amount in USD
  double get overageAmount {
    final overage = emailCount - emailFreeTier;
    return overage > 0 ? overage * emailOverageRate : 0.0;
  }

  /// Get usage percentage (0.0 to 1.0+)
  double get usagePercentage => emailFreeTier > 0 ? emailCount / emailFreeTier : 0.0;

  /// Check if usage is at warning level (80%)
  bool get isAtWarningLevel => usagePercentage >= 0.8;

  /// Check if usage exceeds free tier
  bool get hasOverage => emailCount > emailFreeTier;

  /// Get usage status for UI
  BillingStatus get status {
    if (hasOverage) return BillingStatus.overage;
    if (isAtWarningLevel) return BillingStatus.warning;
    return BillingStatus.normal;
  }
}

/// Billing status for UI display
enum BillingStatus {
  normal,   // < 80% usage
  warning,  // 80-100% usage
  overage,  // > 100% usage
}

/// System configuration for email billing
class SystemBillingConfig {
  final int globalRatePerMinute;
  final int defaultFacilityMonthlyFree;
  final double defaultOverageRate;
  final DateTime updatedAt;

  const SystemBillingConfig({
    required this.globalRatePerMinute,
    required this.defaultFacilityMonthlyFree,
    required this.defaultOverageRate,
    required this.updatedAt,
  });

  factory SystemBillingConfig.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return SystemBillingConfig(
      globalRatePerMinute: data['globalRatePerMinute'] ?? 300,
      defaultFacilityMonthlyFree: data['defaultFacilityMonthlyFree'] ?? 5000,
      defaultOverageRate: (data['defaultOverageRate'] ?? 0.0001).toDouble(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'globalRatePerMinute': globalRatePerMinute,
      'defaultFacilityMonthlyFree': defaultFacilityMonthlyFree,
      'defaultOverageRate': defaultOverageRate,
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  factory SystemBillingConfig.defaultConfig() {
    return SystemBillingConfig(
      globalRatePerMinute: 300,
      defaultFacilityMonthlyFree: 5000,
      defaultOverageRate: 0.0001, // $0.10 per 1000 emails
      updatedAt: DateTime.now(),
    );
  }
}
