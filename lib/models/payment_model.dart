import 'package:cloud_firestore/cloud_firestore.dart';

enum PaymentStatus {
  pending,
  paid,
  completed,
  failed,
  refunded,
  cancelled,
}

enum PaymentMethod {
  creditCard,
  debitCard,
  bankTransfer,
  check,
  cash,
  square,
  stripe,
}

enum BillingCycle {
  monthly,
  quarterly,
  annually,
  weekly,
}

class PaymentModel {
  final String id;
  final String tenantId;
  final String facilityId;
  final String contractId;
  final double amount;
  final PaymentStatus status;
  final PaymentMethod method;
  final DateTime dueDate;
  final DateTime? paidDate;
  final String? transactionId;
  final String? externalPaymentId; // Square/Stripe transaction ID
  final String? notes;
  final String? receiptUrl;
  final String? depositId; // Link to deposit if included in a deposit
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;
  final bool isActive;

  const PaymentModel({
    required this.id,
    required this.tenantId,
    required this.facilityId,
    required this.contractId,
    required this.amount,
    required this.status,
    required this.method,
    required this.dueDate,
    this.paidDate,
    this.transactionId,
    this.externalPaymentId,
    this.notes,
    this.receiptUrl,
    this.depositId,
    this.metadata,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
    this.isActive = true,
  });

  factory PaymentModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    DateTime? _readTimestamp(dynamic value) {
      if (value is Timestamp) {
        return value.toDate();
      }
      return null;
    }

    final paidDateValue = _readTimestamp(data['paidDate']) ?? _readTimestamp(data['paidAt']);
    final dueDateValue = _readTimestamp(data['dueDate']) ??
        paidDateValue ??
        _readTimestamp(data['createdAt']) ??
        DateTime.now();
    final createdAtValue = _readTimestamp(data['createdAt']) ?? DateTime.now();
    final updatedAtValue = _readTimestamp(data['updatedAt']) ?? createdAtValue;

    return PaymentModel(
      id: doc.id,
      tenantId: data['tenantId'] ?? '',
      facilityId: data['facilityId'] ?? '',
      contractId: data['contractId'] ?? '',
      amount: (data['amount'] ?? 0.0).toDouble(),
      status: PaymentStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => PaymentStatus.pending,
      ),
      method: PaymentMethod.values.firstWhere(
        (e) => e.name == data['method'],
        orElse: () => PaymentMethod.cash,
      ),
      dueDate: dueDateValue,
      paidDate: paidDateValue,
      transactionId: data['transactionId'],
      externalPaymentId: data['externalPaymentId'],
      notes: data['notes'],
      receiptUrl: data['receiptUrl'],
      depositId: data['depositId'],
      metadata: data['metadata'] != null 
          ? Map<String, dynamic>.from(data['metadata'])
          : null,
      createdAt: createdAtValue,
      updatedAt: updatedAtValue,
      createdBy: data['createdBy'] ?? data['createdByUid'] ?? '',
      isActive: data['isActive'] ?? true,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'tenantId': tenantId,
      'facilityId': facilityId,
      'contractId': contractId,
      'amount': amount,
      'status': status.name,
      'method': method.name,
      'dueDate': Timestamp.fromDate(dueDate),
      'paidDate': paidDate != null ? Timestamp.fromDate(paidDate!) : null,
      'transactionId': transactionId,
      'externalPaymentId': externalPaymentId,
      'notes': notes,
      'receiptUrl': receiptUrl,
      if (depositId != null && depositId!.isNotEmpty) 'depositId': depositId,
      'metadata': metadata,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'createdBy': createdBy,
      'isActive': isActive,
    };
  }

  PaymentModel copyWith({
    String? id,
    String? tenantId,
    String? facilityId,
    String? contractId,
    double? amount,
    PaymentStatus? status,
    PaymentMethod? method,
    DateTime? dueDate,
    DateTime? paidDate,
    String? transactionId,
    String? externalPaymentId,
    String? notes,
    String? receiptUrl,
    String? depositId,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    bool? isActive,
  }) {
    return PaymentModel(
      id: id ?? this.id,
      tenantId: tenantId ?? this.tenantId,
      facilityId: facilityId ?? this.facilityId,
      contractId: contractId ?? this.contractId,
      amount: amount ?? this.amount,
      status: status ?? this.status,
      method: method ?? this.method,
      dueDate: dueDate ?? this.dueDate,
      paidDate: paidDate ?? this.paidDate,
      transactionId: transactionId ?? this.transactionId,
      externalPaymentId: externalPaymentId ?? this.externalPaymentId,
      notes: notes ?? this.notes,
      receiptUrl: receiptUrl ?? this.receiptUrl,
      depositId: depositId ?? this.depositId,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }

  // Helper getters
  String get formattedAmount => '\$${amount.toStringAsFixed(2)}';
  
  bool get isOverdue => 
      status == PaymentStatus.pending && 
      DateTime.now().isAfter(dueDate);
  
  bool get isPaid => status == PaymentStatus.completed || status == PaymentStatus.paid;
  
  int get daysOverdue {
    if (!isOverdue) return 0;
    return DateTime.now().difference(dueDate).inDays;
  }
  
  String get statusDisplayName {
    switch (status) {
      case PaymentStatus.pending:
        return isOverdue ? 'Overdue' : 'Pending';
      case PaymentStatus.paid:
        return 'Paid';
      case PaymentStatus.completed:
        return 'Completed';
      case PaymentStatus.failed:
        return 'Failed';
      case PaymentStatus.refunded:
        return 'Refunded';
      case PaymentStatus.cancelled:
        return 'Cancelled';
    }
  }
  
  String get methodDisplayName {
    switch (method) {
      case PaymentMethod.creditCard:
        return 'Credit Card';
      case PaymentMethod.debitCard:
        return 'Debit Card';
      case PaymentMethod.bankTransfer:
        return 'Bank Transfer';
      case PaymentMethod.check:
        return 'Check';
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.square:
        return 'Square';
      case PaymentMethod.stripe:
        return 'Stripe';
    }
  }
}

// Extension for enum display names
extension PaymentStatusExtension on PaymentStatus {
  String get displayName {
    switch (this) {
      case PaymentStatus.pending:
        return 'Pending';
      case PaymentStatus.paid:
        return 'Paid';
      case PaymentStatus.completed:
        return 'Completed';
      case PaymentStatus.failed:
        return 'Failed';
      case PaymentStatus.refunded:
        return 'Refunded';
      case PaymentStatus.cancelled:
        return 'Cancelled';
    }
  }
}

extension PaymentMethodExtension on PaymentMethod {
  String get displayName {
    switch (this) {
      case PaymentMethod.creditCard:
        return 'Credit Card';
      case PaymentMethod.debitCard:
        return 'Debit Card';
      case PaymentMethod.bankTransfer:
        return 'Bank Transfer';
      case PaymentMethod.check:
        return 'Check';
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.square:
        return 'Square';
      case PaymentMethod.stripe:
        return 'Stripe';
    }
  }
}

extension BillingCycleExtension on BillingCycle {
  String get displayName {
    switch (this) {
      case BillingCycle.monthly:
        return 'Monthly';
      case BillingCycle.quarterly:
        return 'Quarterly';
      case BillingCycle.annually:
        return 'Annually';
      case BillingCycle.weekly:
        return 'Weekly';
    }
  }
}
