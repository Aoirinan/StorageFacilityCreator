import 'package:cloud_firestore/cloud_firestore.dart';
import 'tenant_model.dart';
import 'tenant_autopay_model.dart';
import 'tenant_stripe_model.dart';
import 'payment_model.dart';

/// Cloud Functions return Firestore Timestamps as plain Maps with _seconds/_nanoseconds.
/// This helper handles both native Timestamp objects and the serialized Map form.
DateTime? _parseTimestamp(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is Map) {
    final seconds = (value['_seconds'] ?? value['seconds']) as int?;
    final nanoseconds = (value['_nanoseconds'] ?? value['nanoseconds']) as int? ?? 0;
    if (seconds != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000 + nanoseconds ~/ 1000000,
      );
    }
  }
  return null;
}

/// Optional insurance referral from `facilities/{id}/settings/insurance` (staff-configured).
class PortalInsuranceReferral {
  final String? referralUrl;
  final String? referralName;
  final String? referralNotes;

  const PortalInsuranceReferral({
    this.referralUrl,
    this.referralName,
    this.referralNotes,
  });

  bool get hasLink => referralUrl != null && referralUrl!.trim().isNotEmpty;

  factory PortalInsuranceReferral.fromMap(Map<String, dynamic> data) {
    String? s(String? v) {
      final t = v?.trim();
      return (t != null && t.isNotEmpty) ? t : null;
    }

    return PortalInsuranceReferral(
      referralUrl: s(data['referralUrl'] as String?),
      referralName: s(data['referralName'] as String?),
      referralNotes: s(data['referralNotes'] as String?),
    );
  }
}

class PortalFacilitySummary {
  final String id;
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? logoUrl;
  final Map<String, dynamic>? stripeStatus;
  final PortalInsuranceReferral? insuranceReferral;

  const PortalFacilitySummary({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    this.address,
    this.logoUrl,
    this.stripeStatus,
    this.insuranceReferral,
  });

  String? get stripeState => stripeStatus?['state'] as String?;
  bool get paymentsEnabled => stripeState == 'ENABLED';

  factory PortalFacilitySummary.fromMap(Map<String, dynamic> data) {
    return PortalFacilitySummary(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Facility',
      phone: data['phone'] as String?,
      email: data['email'] as String?,
      address: data['address'] as String?,
      logoUrl: data['logoUrl'] as String?,
      stripeStatus: data['stripeStatus'] != null ? Map<String, dynamic>.from(data['stripeStatus'] as Map) : null,
      insuranceReferral: data['insuranceReferral'] != null
          ? PortalInsuranceReferral.fromMap(
              Map<String, dynamic>.from(data['insuranceReferral'] as Map),
            )
          : null,
    );
  }
}

class PortalPaymentSummary {
  final String id;
  final String? tenantId;
  final String? unitNumber;
  final double amount;
  final DateTime dueDate;
  final PaymentStatus status;
  final DateTime? paidAt;
  final String? method;

  const PortalPaymentSummary({
    required this.id,
    this.tenantId,
    this.unitNumber,
    required this.amount,
    required this.dueDate,
    required this.status,
    this.paidAt,
    this.method,
  });

  factory PortalPaymentSummary.fromMap(Map<String, dynamic> data) {
    final amountValue = (data['amount'] ?? 0).toDouble();
    final statusName = data['status'] as String? ?? PaymentStatus.pending.name;
    return PortalPaymentSummary(
      id: data['id'] as String,
      tenantId: data['tenantId'] as String?,
      unitNumber: data['unitNumber'] as String?,
      amount: amountValue,
      dueDate: _parseTimestamp(data['dueDate']) ?? DateTime.now(),
      status: PaymentStatus.values.firstWhere(
        (status) => status.name == statusName,
        orElse: () => PaymentStatus.pending,
      ),
      paidAt: _parseTimestamp(data['paidAt']),
      method: data['method'] as String?,
    );
  }
}

class PortalUnitAccountItem {
  final String tenantId;
  final String unitNumber;
  final String tenantName;
  final double monthlyRate;
  final bool isDelinquent;
  final double outstandingBalance;
  final double? nextAmountDue;
  final DateTime? nextDueDate;
  final TenantAutopayModel autopay;
  final TenantStripeModel stripe;

  const PortalUnitAccountItem({
    required this.tenantId,
    required this.unitNumber,
    required this.tenantName,
    required this.monthlyRate,
    required this.isDelinquent,
    required this.outstandingBalance,
    this.nextAmountDue,
    this.nextDueDate,
    this.autopay = const TenantAutopayModel(),
    this.stripe = const TenantStripeModel(),
  });

  factory PortalUnitAccountItem.fromMap(Map<String, dynamic> data) {
    return PortalUnitAccountItem(
      tenantId: data['tenantId'] as String? ?? '',
      unitNumber: data['unitNumber'] as String? ?? '',
      tenantName: data['tenantName'] as String? ?? 'Tenant',
      monthlyRate: (data['monthlyRate'] ?? 0).toDouble(),
      isDelinquent: data['isDelinquent'] as bool? ?? false,
      outstandingBalance: (data['outstandingBalance'] ?? 0).toDouble(),
      nextAmountDue: data['nextAmountDue'] != null
          ? (data['nextAmountDue'] as num).toDouble()
          : null,
      nextDueDate: _parseTimestamp(data['nextDueDate']),
      autopay: data['autopay'] != null
          ? TenantAutopayModel.fromMap(
              Map<String, dynamic>.from(data['autopay'] as Map),
            )
          : const TenantAutopayModel(),
      stripe: data['stripe'] != null
          ? TenantStripeModel.fromMap(
              Map<String, dynamic>.from(data['stripe'] as Map),
            )
          : const TenantStripeModel(),
    );
  }
}

class PortalTenantSummary {
  final String id;
  final String name;
  final String? email;
  final String? phone;
  final String unitNumber;
  final double monthlyRate;
  final DateTime? paidThrough;
  final bool isDelinquent;
  final String? welcomeMessage;
  final List<TenantContact> contacts;
  final List<TenantVehicle> vehicles;
  final TenantAutopayModel autopay;
  final TenantStripeModel stripe;
  final bool overlockIsActive;

  /// Expiration date of the tenant's active lease/contract, if set.
  final DateTime? contractExpiresAt;

  /// Expiration date of the tenant's insurance coverage (TPP or external proof).
  final DateTime? insuranceExpiresAt;

  /// Scheduled move-out date, if the tenant has initiated a move-out.
  final DateTime? scheduledMoveOutDate;

  const PortalTenantSummary({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    required this.unitNumber,
    required this.monthlyRate,
    this.paidThrough,
    this.isDelinquent = false,
    this.welcomeMessage,
    this.contacts = const [],
    this.vehicles = const [],
    this.autopay = const TenantAutopayModel(),
    this.stripe = const TenantStripeModel(),
    this.overlockIsActive = false,
    this.contractExpiresAt,
    this.insuranceExpiresAt,
    this.scheduledMoveOutDate,
  });

  factory PortalTenantSummary.fromMap(Map<String, dynamic> data) {
    final contactsRaw = data['contacts'] as List<dynamic>? ?? const [];
    final vehiclesRaw = data['vehicles'] as List<dynamic>? ?? const [];
    return PortalTenantSummary(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Tenant',
      email: data['email'] as String?,
      phone: data['phone'] as String?,
      unitNumber: data['unitNumber'] as String? ?? '',
      monthlyRate: (data['monthlyRate'] ?? 0).toDouble(),
      paidThrough: _parseTimestamp(data['paidThrough']),
      isDelinquent: data['isDelinquent'] as bool? ?? false,
      welcomeMessage: data['welcomeMessage'] as String?,
      contacts: contactsRaw
          .map((item) => TenantContact.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList(),
      vehicles: vehiclesRaw
          .map((item) => TenantVehicle.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList(),
      autopay: data['autopay'] != null ? TenantAutopayModel.fromMap(Map<String, dynamic>.from(data['autopay'] as Map)) : const TenantAutopayModel(),
      stripe: data['stripe'] != null ? TenantStripeModel.fromMap(Map<String, dynamic>.from(data['stripe'] as Map)) : const TenantStripeModel(),
      overlockIsActive: data['overlockIsActive'] == true,
      contractExpiresAt: _parseTimestamp(data['contractExpiresAt']),
      insuranceExpiresAt: _parseTimestamp(data['insuranceExpiresAt']),
      scheduledMoveOutDate: _parseTimestamp(data['scheduledMoveOutDate']),
    );
  }
}

class TenantPortalStats {
  final double outstandingBalance;
  final double? nextAmountDue;
  final DateTime? nextDueDate;

  const TenantPortalStats({
    required this.outstandingBalance,
    this.nextAmountDue,
    this.nextDueDate,
  });

  factory TenantPortalStats.fromMap(Map<String, dynamic> data) {
    return TenantPortalStats(
      outstandingBalance: (data['outstandingBalance'] ?? 0).toDouble(),
      nextAmountDue: data['nextAmountDue'] != null
          ? (data['nextAmountDue'] as num).toDouble()
          : null,
      nextDueDate: _parseTimestamp(data['nextDueDate']),
    );
  }
}

class TenantPortalData {
  final PortalFacilitySummary facility;
  final PortalTenantSummary tenant;
  final List<PortalUnitAccountItem> units;
  final List<PortalPaymentSummary> recentPayments;
  final TenantPortalStats stats;

  const TenantPortalData({
    required this.facility,
    required this.tenant,
    this.units = const [],
    required this.recentPayments,
    required this.stats,
  });

  factory TenantPortalData.fromMap(Map<String, dynamic> data) {
    final paymentsRaw = data['payments'] as List<dynamic>? ?? const [];
    final unitsRaw = data['units'] as List<dynamic>? ?? const [];
    final tenant = PortalTenantSummary.fromMap(
      Map<String, dynamic>.from(data['tenant'] as Map),
    );
    final stats = TenantPortalStats.fromMap(
      Map<String, dynamic>.from(data['stats'] as Map),
    );
    final units = unitsRaw
        .map((item) => PortalUnitAccountItem.fromMap(
            Map<String, dynamic>.from(item as Map)))
        .toList();
    return TenantPortalData(
      facility: PortalFacilitySummary.fromMap(Map<String, dynamic>.from(data['facility'] as Map)),
      tenant: tenant,
      units: units.isNotEmpty
          ? units
          : [
              PortalUnitAccountItem(
                tenantId: tenant.id,
                unitNumber: tenant.unitNumber,
                tenantName: tenant.name,
                monthlyRate: tenant.monthlyRate,
                isDelinquent: tenant.isDelinquent,
                outstandingBalance: stats.outstandingBalance,
                nextAmountDue: stats.nextAmountDue,
                nextDueDate: stats.nextDueDate,
                autopay: tenant.autopay,
                stripe: tenant.stripe,
              ),
            ],
      recentPayments: paymentsRaw
          .map((item) => PortalPaymentSummary.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList(),
      stats: stats,
    );
  }
}

/// One row from [TenantPortalService.listAvailableUnitsForAdditionalRental] for unit picker UI.
class TenantPortalAvailableUnit {
  final String id;
  final String unitNumber;
  final String unitType;
  final double monthlyRate;

  const TenantPortalAvailableUnit({
    required this.id,
    required this.unitNumber,
    required this.unitType,
    required this.monthlyRate,
  });

  factory TenantPortalAvailableUnit.fromMap(Map<String, dynamic> data) {
    return TenantPortalAvailableUnit(
      id: data['id']?.toString() ?? '',
      unitNumber: data['unitNumber']?.toString() ?? '',
      unitType: data['unitType']?.toString() ?? 'standard',
      monthlyRate: (data['monthlyRate'] as num?)?.toDouble() ?? 0,
    );
  }
}
