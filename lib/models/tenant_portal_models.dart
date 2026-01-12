import 'package:cloud_firestore/cloud_firestore.dart';
import 'tenant_model.dart';
import 'payment_model.dart';

class PortalFacilitySummary {
  final String id;
  final String name;
  final String? phone;
  final String? email;
  final String? address;
  final String? logoUrl;

  const PortalFacilitySummary({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    this.address,
    this.logoUrl,
  });

  factory PortalFacilitySummary.fromMap(Map<String, dynamic> data) {
    return PortalFacilitySummary(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Facility',
      phone: data['phone'] as String?,
      email: data['email'] as String?,
      address: data['address'] as String?,
      logoUrl: data['logoUrl'] as String?,
    );
  }
}

class PortalPaymentSummary {
  final String id;
  final double amount;
  final DateTime dueDate;
  final PaymentStatus status;
  final DateTime? paidAt;
  final String? method;

  const PortalPaymentSummary({
    required this.id,
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
      amount: amountValue,
      dueDate: (data['dueDate'] as Timestamp).toDate(),
      status: PaymentStatus.values.firstWhere(
        (status) => status.name == statusName,
        orElse: () => PaymentStatus.pending,
      ),
      paidAt: (data['paidAt'] as Timestamp?)?.toDate(),
      method: data['method'] as String?,
    );
  }
}

class PortalTenantSummary {
  final String id;
  final String name;
  final String unitNumber;
  final double monthlyRate;
  final DateTime? paidThrough;
  final bool isDelinquent;
  final String? welcomeMessage;
  final List<TenantContact> contacts;
  final List<TenantVehicle> vehicles;

  const PortalTenantSummary({
    required this.id,
    required this.name,
    required this.unitNumber,
    required this.monthlyRate,
    this.paidThrough,
    this.isDelinquent = false,
    this.welcomeMessage,
    this.contacts = const [],
    this.vehicles = const [],
  });

  factory PortalTenantSummary.fromMap(Map<String, dynamic> data) {
    final contactsRaw = data['contacts'] as List<dynamic>? ?? const [];
    final vehiclesRaw = data['vehicles'] as List<dynamic>? ?? const [];
    return PortalTenantSummary(
      id: data['id'] as String,
      name: data['name'] as String? ?? 'Tenant',
      unitNumber: data['unitNumber'] as String? ?? '',
      monthlyRate: (data['monthlyRate'] ?? 0).toDouble(),
      paidThrough: data['paidThrough'] != null
          ? (data['paidThrough'] as Timestamp).toDate()
          : null,
      isDelinquent: data['isDelinquent'] as bool? ?? false,
      welcomeMessage: data['welcomeMessage'] as String?,
      contacts: contactsRaw
          .map((item) => TenantContact.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList(),
      vehicles: vehiclesRaw
          .map((item) => TenantVehicle.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList(),
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
      nextDueDate:
          data['nextDueDate'] != null ? (data['nextDueDate'] as Timestamp).toDate() : null,
    );
  }
}

class TenantPortalData {
  final PortalFacilitySummary facility;
  final PortalTenantSummary tenant;
  final List<PortalPaymentSummary> recentPayments;
  final TenantPortalStats stats;

  const TenantPortalData({
    required this.facility,
    required this.tenant,
    required this.recentPayments,
    required this.stats,
  });

  factory TenantPortalData.fromMap(Map<String, dynamic> data) {
    final paymentsRaw = data['payments'] as List<dynamic>? ?? const [];
    return TenantPortalData(
      facility: PortalFacilitySummary.fromMap(Map<String, dynamic>.from(data['facility'] as Map)),
      tenant: PortalTenantSummary.fromMap(Map<String, dynamic>.from(data['tenant'] as Map)),
      recentPayments: paymentsRaw
          .map((item) => PortalPaymentSummary.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList(),
      stats: TenantPortalStats.fromMap(Map<String, dynamic>.from(data['stats'] as Map)),
    );
  }
}
