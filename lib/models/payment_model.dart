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
  venmo,
  zelle,
  /// Money received some other way. Also what a stored method this app has
  /// no name for reads as (see [paymentMethodFromStored]).
  other,
}

/// The methods an operator can record for money taken outside the card
/// flow: the Record payment dialog, the Create Payment screen and Enter past
/// history. Kept in step with HISTORY_PAYMENT_METHODS in
/// functions-automation/src/tenantPastHistory.ts and the method regex in
/// firestore-rules-src/01-shared-functions.rules.
const List<PaymentMethod> manualPaymentMethods = [
  PaymentMethod.cash,
  PaymentMethod.check,
  PaymentMethod.venmo,
  PaymentMethod.zelle,
  PaymentMethod.bankTransfer,
  PaymentMethod.other,
];

/// The method a payment stored with [stored] has.
///
/// A missing method still reads as cash, as it always has. A method this
/// app has no name for (one added after this build) reads as
/// [PaymentMethod.other] rather than cash: it used to read as cash, and
/// processing such a payment then rewrote it to cash.
PaymentMethod paymentMethodFromStored(Object? stored) {
  if (stored == null || stored == '') return PaymentMethod.cash;
  for (final method in PaymentMethod.values) {
    if (method.name == stored) return method;
  }
  return PaymentMethod.other;
}

/// "Payment - Check #1234", "Payment - Venmo: June rent": the ledger line for
/// money received. recordTenantPastHistory builds the same line.
String receivedPaymentDescription(
  PaymentMethod method, {
  String? reference,
  String? notes,
}) {
  final ref = reference?.trim() ?? '';
  final note = notes?.trim() ?? '';
  return 'Payment - ${method.displayName}'
      '${ref.isNotEmpty ? ' #$ref' : ''}'
      '${note.isNotEmpty ? ': $note' : ''}';
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
  /// Check number or Venmo/Zelle reference the operator typed in.
  final String? reference;
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
    this.reference,
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
      method: paymentMethodFromStored(data['method']),
      dueDate: dueDateValue,
      paidDate: paidDateValue,
      transactionId: data['transactionId'],
      externalPaymentId: data['externalPaymentId'],
      notes: data['notes'],
      reference: readTrimmed(data['reference']),
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
      if (reference != null && reference!.trim().isNotEmpty)
        'reference': reference!.trim(),
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
    String? reference,
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
      reference: reference ?? this.reference,
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
  
  String get methodDisplayName => method.displayName;
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
      case PaymentMethod.venmo:
        return 'Venmo';
      case PaymentMethod.zelle:
        return 'Zelle';
      case PaymentMethod.other:
        return 'Other';
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
