import 'package:cloud_firestore/cloud_firestore.dart';

enum DepositStatus {
  pending, // Created but not yet deposited
  deposited, // Deposited to bank
  reconciled, // Reconciled with bank statement
  cancelled, // Cancelled deposit
}

enum DepositMethod {
  cash,
  check,
  creditCard,
  ach,
  mixed, // Multiple payment methods
}

class DepositModel {
  final String id;
  final String facilityId;
  final String depositNumber; // Auto-generated (e.g., "DEP-2025-001")
  final DepositStatus status;
  final DepositMethod method;
  final DateTime depositDate; // Date deposit was made
  final DateTime? bankDepositDate; // Date deposit was made to bank
  final double totalAmount;
  final double? cashAmount;
  final double? checkAmount;
  final int? checkCount;
  final double? creditCardAmount;
  final double? achAmount;
  final List<String> paymentIds; // Payments included in this deposit
  final String? bankAccount; // Bank account name/number
  final String? referenceNumber; // Bank reference number
  final String? notes;
  final double? overShort; // Over/short amount (positive = over, negative = short)
  final String? reconciledBy;
  final DateTime? reconciledAt;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final bool isActive;

  const DepositModel({
    required this.id,
    required this.facilityId,
    required this.depositNumber,
    required this.status,
    required this.method,
    required this.depositDate,
    this.bankDepositDate,
    required this.totalAmount,
    this.cashAmount,
    this.checkAmount,
    this.checkCount,
    this.creditCardAmount,
    this.achAmount,
    required this.paymentIds,
    this.bankAccount,
    this.referenceNumber,
    this.notes,
    this.overShort,
    this.reconciledBy,
    this.reconciledAt,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
    this.isActive = true,
  });

  factory DepositModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('DepositModel data is null');
    }

    return DepositModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      depositNumber: data['depositNumber'] ?? '',
      status: DepositStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => DepositStatus.pending,
      ),
      method: DepositMethod.values.firstWhere(
        (e) => e.name == data['method'],
        orElse: () => DepositMethod.mixed,
      ),
      depositDate: (data['depositDate'] as Timestamp?)?.toDate() ?? DateTime.now(),
      bankDepositDate: data['bankDepositDate'] != null
          ? (data['bankDepositDate'] as Timestamp).toDate()
          : null,
      totalAmount: (data['totalAmount'] ?? 0.0).toDouble(),
      cashAmount: data['cashAmount'] != null ? (data['cashAmount'] as num).toDouble() : null,
      checkAmount: data['checkAmount'] != null ? (data['checkAmount'] as num).toDouble() : null,
      checkCount: data['checkCount'],
      creditCardAmount: data['creditCardAmount'] != null ? (data['creditCardAmount'] as num).toDouble() : null,
      achAmount: data['achAmount'] != null ? (data['achAmount'] as num).toDouble() : null,
      paymentIds: List<String>.from(data['paymentIds'] ?? []),
      bankAccount: data['bankAccount'],
      referenceNumber: data['referenceNumber'],
      notes: data['notes'],
      overShort: data['overShort'] != null ? (data['overShort'] as num).toDouble() : null,
      reconciledBy: data['reconciledBy'],
      reconciledAt: data['reconciledAt'] != null
          ? (data['reconciledAt'] as Timestamp).toDate()
          : null,
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
      'depositNumber': depositNumber,
      'status': status.name,
      'method': method.name,
      'depositDate': Timestamp.fromDate(depositDate),
      if (bankDepositDate != null) 'bankDepositDate': Timestamp.fromDate(bankDepositDate!),
      'totalAmount': totalAmount,
      if (cashAmount != null) 'cashAmount': cashAmount,
      if (checkAmount != null) 'checkAmount': checkAmount,
      if (checkCount != null) 'checkCount': checkCount,
      if (creditCardAmount != null) 'creditCardAmount': creditCardAmount,
      if (achAmount != null) 'achAmount': achAmount,
      'paymentIds': paymentIds,
      if (bankAccount != null && bankAccount!.isNotEmpty) 'bankAccount': bankAccount,
      if (referenceNumber != null && referenceNumber!.isNotEmpty) 'referenceNumber': referenceNumber,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      if (overShort != null) 'overShort': overShort,
      if (reconciledBy != null) 'reconciledBy': reconciledBy,
      if (reconciledAt != null) 'reconciledAt': Timestamp.fromDate(reconciledAt!),
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'createdBy': createdBy,
      'isActive': isActive,
    };
  }

  DepositModel copyWith({
    String? id,
    String? facilityId,
    String? depositNumber,
    DepositStatus? status,
    DepositMethod? method,
    DateTime? depositDate,
    DateTime? bankDepositDate,
    double? totalAmount,
    double? cashAmount,
    double? checkAmount,
    int? checkCount,
    double? creditCardAmount,
    double? achAmount,
    List<String>? paymentIds,
    String? bankAccount,
    String? referenceNumber,
    String? notes,
    double? overShort,
    String? reconciledBy,
    DateTime? reconciledAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    bool? isActive,
  }) {
    return DepositModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      depositNumber: depositNumber ?? this.depositNumber,
      status: status ?? this.status,
      method: method ?? this.method,
      depositDate: depositDate ?? this.depositDate,
      bankDepositDate: bankDepositDate ?? this.bankDepositDate,
      totalAmount: totalAmount ?? this.totalAmount,
      cashAmount: cashAmount ?? this.cashAmount,
      checkAmount: checkAmount ?? this.checkAmount,
      checkCount: checkCount ?? this.checkCount,
      creditCardAmount: creditCardAmount ?? this.creditCardAmount,
      achAmount: achAmount ?? this.achAmount,
      paymentIds: paymentIds ?? this.paymentIds,
      bankAccount: bankAccount ?? this.bankAccount,
      referenceNumber: referenceNumber ?? this.referenceNumber,
      notes: notes ?? this.notes,
      overShort: overShort ?? this.overShort,
      reconciledBy: reconciledBy ?? this.reconciledBy,
      reconciledAt: reconciledAt ?? this.reconciledAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }

  String get statusDisplayName {
    switch (status) {
      case DepositStatus.pending:
        return 'Pending';
      case DepositStatus.deposited:
        return 'Deposited';
      case DepositStatus.reconciled:
        return 'Reconciled';
      case DepositStatus.cancelled:
        return 'Cancelled';
    }
  }

  String get methodDisplayName {
    switch (method) {
      case DepositMethod.cash:
        return 'Cash';
      case DepositMethod.check:
        return 'Check';
      case DepositMethod.creditCard:
        return 'Credit Card';
      case DepositMethod.ach:
        return 'ACH';
      case DepositMethod.mixed:
        return 'Mixed';
    }
  }

  String get formattedTotal => '\$${totalAmount.toStringAsFixed(2)}';
  String? get formattedOverShort => overShort != null 
      ? '\$${overShort!.abs().toStringAsFixed(2)} ${overShort! > 0 ? "Over" : "Short"}' 
      : null;
}

