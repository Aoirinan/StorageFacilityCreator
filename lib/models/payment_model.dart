import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sfcapp/models/facility_doc_path.dart';

enum PaymentStatus {
  pending,
  paid,
  completed,
  failed,
  refunded,
  cancelled,
  /// The charge is disputed (stripeWebhookDisputeCreated writes it).
  disputed,
  /// Part of the charge was refunded (stripeWebhookChargeRefunded writes
  /// `partially_refunded`).
  partiallyRefunded,
  /// A status this app has no name for; [PaymentModel.storedStatus] has it.
  other,
}

/// The status a payment stored with [stored] has.
///
/// Statuses this app did not name used to read as pending, so a disputed or
/// part-refunded Stripe payment showed as pending with a Process button, and
/// processing it overwrote the dispute with paid and moved the tenant's
/// paidThrough on a month nobody paid for. Now they read as what they are,
/// and anything unknown as [PaymentStatus.other]. Only a missing status
/// still reads as pending, as a payment created without one is still owed.
PaymentStatus paymentStatusFromStored(Object? stored) {
  if (stored == null) return PaymentStatus.pending;
  if (stored == 'partially_refunded') return PaymentStatus.partiallyRefunded;
  for (final status in PaymentStatus.values) {
    if (status != PaymentStatus.other && status.name == stored) return status;
  }
  return PaymentStatus.other;
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

  /// The status as stored, for a [PaymentStatus.other] payment (null for
  /// the rest): shown instead of a guess, and written back unchanged.
  final String? storedStatus;
  final PaymentMethod method;
  final DateTime dueDate;
  final DateTime? paidDate;
  final String? transactionId;
  final String? externalPaymentId; // Square/Stripe transaction ID
  final String? notes;
  final String? receiptUrl;
  final String? depositId; // Link to deposit if included in a deposit
  final Map<String, dynamic>? metadata;
  /// Denormalized from tenant at payment time (`tenantName` / `unitNumber` in Firestore).
  final String? snapshotTenantName;
  final String? snapshotUnitNumber;
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
    this.storedStatus,
    required this.method,
    required this.dueDate,
    this.paidDate,
    this.transactionId,
    this.externalPaymentId,
    this.notes,
    this.receiptUrl,
    this.depositId,
    this.metadata,
    this.snapshotTenantName,
    this.snapshotUnitNumber,
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

    String? readTrimmed(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    final snapName = readTrimmed(data['tenantName']) ?? readTrimmed(data['payerName']);
    final snapUnit = readTrimmed(data['unitNumber']) ?? readTrimmed(data['payerUnit']);
    final status = paymentStatusFromStored(data['status']);

    return PaymentModel(
      id: doc.id,
      tenantId: data['tenantId'] ?? '',
      facilityId: facilityIdOf(doc, data['facilityId']),
      contractId: data['contractId'] ?? '',
      amount: (data['amount'] ?? 0.0).toDouble(),
      status: status,
      storedStatus:
          status == PaymentStatus.other ? '${data['status']}' : null,
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
      snapshotTenantName: snapName,
      snapshotUnitNumber: snapUnit,
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
      'status': status == PaymentStatus.other
          ? storedStatus
          : status.storedValue,
      'method': method.name,
      'dueDate': Timestamp.fromDate(dueDate),
      'paidDate': paidDate != null ? Timestamp.fromDate(paidDate!) : null,
      'transactionId': transactionId,
      'externalPaymentId': externalPaymentId,
      'notes': notes,
      'receiptUrl': receiptUrl,
      if (depositId != null && depositId!.isNotEmpty) 'depositId': depositId,
      'metadata': metadata,
      if (snapshotTenantName != null && snapshotTenantName!.trim().isNotEmpty)
        'tenantName': snapshotTenantName!.trim(),
      if (snapshotUnitNumber != null && snapshotUnitNumber!.trim().isNotEmpty)
        'unitNumber': snapshotUnitNumber!.trim(),
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
    String? storedStatus,
    PaymentMethod? method,
    DateTime? dueDate,
    DateTime? paidDate,
    String? transactionId,
    String? externalPaymentId,
    String? notes,
    String? receiptUrl,
    String? depositId,
    Map<String, dynamic>? metadata,
    String? snapshotTenantName,
    String? snapshotUnitNumber,
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
      storedStatus: storedStatus ?? this.storedStatus,
      method: method ?? this.method,
      dueDate: dueDate ?? this.dueDate,
      paidDate: paidDate ?? this.paidDate,
      transactionId: transactionId ?? this.transactionId,
      externalPaymentId: externalPaymentId ?? this.externalPaymentId,
      notes: notes ?? this.notes,
      receiptUrl: receiptUrl ?? this.receiptUrl,
      depositId: depositId ?? this.depositId,
      metadata: metadata ?? this.metadata,
      snapshotTenantName: snapshotTenantName ?? this.snapshotTenantName,
      snapshotUnitNumber: snapshotUnitNumber ?? this.snapshotUnitNumber,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      isActive: isActive ?? this.isActive,
    );
  }

  // Helper getters
  String get formattedAmount => '\$${amount.toStringAsFixed(2)}';

  /// Name and unit as recorded on the payment (preferred for display).
  String? get snapshotPayerLine {
    final n = snapshotTenantName?.trim();
    if (n == null || n.isEmpty) return null;
    final u = snapshotUnitNumber?.trim();
    if (u != null && u.isNotEmpty) return '$n · Unit $u';
    return n;
  }
  
  bool get isOverdue => 
      status == PaymentStatus.pending && 
      DateTime.now().isAfter(dueDate);
  
  bool get isPaid => status == PaymentStatus.completed || status == PaymentStatus.paid;

  /// Stripe/Square/card reference when present; null for cash/check with no external id.
  String? get effectiveTransactionReference {
    final txn = transactionId?.trim();
    if (txn != null && txn.isNotEmpty) return txn;
    final ext = externalPaymentId?.trim();
    if (ext != null && ext.isNotEmpty) return ext;
    return null;
  }

  /// Primary date label for list/detail display.
  String get displayDateLabel => isPaid ? 'Paid' : 'Due';

  /// Primary date for list/detail display.
  DateTime get displayDate {
    if (isPaid && paidDate != null) return paidDate!;
    return dueDate;
  }
  
  int get daysOverdue {
    if (!isOverdue) return 0;
    return DateTime.now().difference(dueDate).inDays;
  }
  
  String get statusDisplayName {
    switch (status) {
      case PaymentStatus.pending:
        return isOverdue ? 'Overdue' : 'Pending';
      case PaymentStatus.other:
        return _humanStatus(storedStatus);
      case PaymentStatus.paid:
      case PaymentStatus.completed:
      case PaymentStatus.failed:
      case PaymentStatus.refunded:
      case PaymentStatus.cancelled:
      case PaymentStatus.disputed:
      case PaymentStatus.partiallyRefunded:
        return status.displayName;
    }
  }

  /// `requires_action` as "Requires action"; "Unknown" when blank.
  static String _humanStatus(String? stored) {
    final words = (stored ?? '').replaceAll('_', ' ').trim();
    if (words.isEmpty) return 'Unknown';
    return words[0].toUpperCase() + words.substring(1);
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
      case PaymentStatus.disputed:
        return 'Disputed';
      case PaymentStatus.partiallyRefunded:
        return 'Partially refunded';
      case PaymentStatus.other:
        return 'Other';
    }
  }

  /// The value stored in a payment doc's `status` for this status.
  /// [PaymentStatus.other] has none of its own: write the doc's
  /// [PaymentModel.storedStatus] back instead.
  String get storedValue =>
      this == PaymentStatus.partiallyRefunded ? 'partially_refunded' : name;
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
