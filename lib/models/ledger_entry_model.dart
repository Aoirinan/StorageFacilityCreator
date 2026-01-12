import 'package:cloud_firestore/cloud_firestore.dart';

enum LedgerEntryType {
  // Charges (positive amounts)
  rentCharge,
  insuranceCharge,
  lateFee,
  adminFee,
  lockCutFee,
  moveInFee,
  moveOutFee,
  transferFee,
  otherCharge,
  
  // Payments/Credits (negative amounts)
  payment,
  credit,
  adjustment,
  refund,
}

enum LedgerEntryStatus {
  pending,
  posted,
  voided,
}

class LedgerEntry {
  final String id;
  final String tenantId;
  final String facilityId;
  final LedgerEntryType type;
  final double amount; // Positive for charges, negative for payments/credits
  final String? description;
  final String? referenceId; // paymentId, invoiceId, contractId, etc.
  final DateTime entryDate;
  final DateTime? dueDate; // For charges
  final LedgerEntryStatus status;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final String createdBy;
  final DateTime? voidedAt;
  final String? voidedBy;

  const LedgerEntry({
    required this.id,
    required this.tenantId,
    required this.facilityId,
    required this.type,
    required this.amount,
    this.description,
    this.referenceId,
    required this.entryDate,
    this.dueDate,
    required this.status,
    this.metadata,
    required this.createdAt,
    required this.createdBy,
    this.voidedAt,
    this.voidedBy,
  });

  factory LedgerEntry.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('LedgerEntry data is null');
    }
    
    return LedgerEntry(
      id: doc.id,
      tenantId: data['tenantId'] ?? '',
      facilityId: data['facilityId'] ?? '',
      type: LedgerEntryType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => LedgerEntryType.otherCharge,
      ),
      amount: (data['amount'] ?? 0.0).toDouble(),
      description: data['description'],
      referenceId: data['referenceId'],
      entryDate: (data['entryDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      dueDate: data['dueDate'] != null ? (data['dueDate'] as Timestamp).toDate() : null,
      status: LedgerEntryStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => LedgerEntryStatus.posted,
      ),
      metadata: data['metadata'] != null ? Map<String, dynamic>.from(data['metadata']) : null,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] ?? '',
      voidedAt: data['voidedAt'] != null ? (data['voidedAt'] as Timestamp).toDate() : null,
      voidedBy: data['voidedBy'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'tenantId': tenantId,
      'facilityId': facilityId,
      'type': type.name,
      'amount': amount,
      if (description != null && description!.isNotEmpty) 'description': description,
      if (referenceId != null && referenceId!.isNotEmpty) 'referenceId': referenceId,
      'entryDate': Timestamp.fromDate(entryDate),
      if (dueDate != null) 'dueDate': Timestamp.fromDate(dueDate!),
      'status': status.name,
      if (metadata != null) 'metadata': metadata,
      'createdAt': Timestamp.fromDate(createdAt),
      'createdBy': createdBy,
      if (voidedAt != null) 'voidedAt': Timestamp.fromDate(voidedAt!),
      if (voidedBy != null) 'voidedBy': voidedBy,
    };
  }

  LedgerEntry copyWith({
    String? id,
    String? tenantId,
    String? facilityId,
    LedgerEntryType? type,
    double? amount,
    String? description,
    String? referenceId,
    DateTime? entryDate,
    DateTime? dueDate,
    LedgerEntryStatus? status,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    String? createdBy,
    DateTime? voidedAt,
    String? voidedBy,
  }) {
    return LedgerEntry(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      facilityId: facilityId ?? this.facilityId,
      type: type ?? this.type,
      amount: amount ?? this.amount,
      description: description ?? this.description,
      referenceId: referenceId ?? this.referenceId,
      entryDate: entryDate ?? this.entryDate,
      dueDate: dueDate ?? this.dueDate,
      status: status ?? this.status,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      createdBy: createdBy ?? this.createdBy,
      voidedAt: voidedAt ?? this.voidedAt,
      voidedBy: voidedBy ?? this.voidedBy,
    );
  }

  // Helper getters
  bool get isCharge => amount > 0;
  bool get isPayment => amount < 0;
  bool get isActive => status == LedgerEntryStatus.posted;
  
  String get formattedAmount {
    if (isCharge) {
      return '\$${amount.toStringAsFixed(2)}';
    } else {
      return '(\$${amount.abs().toStringAsFixed(2)})';
    }
  }

  String get typeDisplayName {
    switch (type) {
      case LedgerEntryType.rentCharge:
        return 'Rent';
      case LedgerEntryType.insuranceCharge:
        return 'Insurance';
      case LedgerEntryType.lateFee:
        return 'Late Fee';
      case LedgerEntryType.adminFee:
        return 'Admin Fee';
      case LedgerEntryType.lockCutFee:
        return 'Lock Cut Fee';
      case LedgerEntryType.moveInFee:
        return 'Move-In Fee';
      case LedgerEntryType.moveOutFee:
        return 'Move-Out Fee';
      case LedgerEntryType.transferFee:
        return 'Transfer Fee';
      case LedgerEntryType.otherCharge:
        return 'Other Charge';
      case LedgerEntryType.payment:
        return 'Payment';
      case LedgerEntryType.credit:
        return 'Credit';
      case LedgerEntryType.adjustment:
        return 'Adjustment';
      case LedgerEntryType.refund:
        return 'Refund';
    }
  }

  String get statusDisplayName {
    switch (status) {
      case LedgerEntryStatus.pending:
        return 'Pending';
      case LedgerEntryStatus.posted:
        return 'Posted';
      case LedgerEntryStatus.voided:
        return 'Voided';
    }
  }
}

// Extension for enum display names
extension LedgerEntryTypeExtension on LedgerEntryType {
  String get displayName {
    switch (this) {
      case LedgerEntryType.rentCharge:
        return 'Rent';
      case LedgerEntryType.insuranceCharge:
        return 'Insurance';
      case LedgerEntryType.lateFee:
        return 'Late Fee';
      case LedgerEntryType.adminFee:
        return 'Admin Fee';
      case LedgerEntryType.lockCutFee:
        return 'Lock Cut Fee';
      case LedgerEntryType.moveInFee:
        return 'Move-In Fee';
      case LedgerEntryType.moveOutFee:
        return 'Move-Out Fee';
      case LedgerEntryType.transferFee:
        return 'Transfer Fee';
      case LedgerEntryType.otherCharge:
        return 'Other Charge';
      case LedgerEntryType.payment:
        return 'Payment';
      case LedgerEntryType.credit:
        return 'Credit';
      case LedgerEntryType.adjustment:
        return 'Adjustment';
      case LedgerEntryType.refund:
        return 'Refund';
    }
  }
}

extension LedgerEntryStatusExtension on LedgerEntryStatus {
  String get displayName {
    switch (this) {
      case LedgerEntryStatus.pending:
        return 'Pending';
      case LedgerEntryStatus.posted:
        return 'Posted';
      case LedgerEntryStatus.voided:
        return 'Voided';
    }
  }
}

