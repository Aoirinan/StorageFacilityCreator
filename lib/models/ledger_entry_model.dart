import 'dart:math' as math;

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

/// Ledger types the Stripe webhook writes for a card dispute: the money
/// taken back (+amount) and, if the facility wins, returned (-amount). The
/// app has no enum value for either, so they read as [LedgerEntryType.otherCharge];
/// [LedgerEntry.storedType] keeps the stored name.
const disputeLedgerType = 'dispute';
const disputeReversalLedgerType = 'dispute_reversal';

/// Whether a stored ledger row belongs to a card dispute: either dispute
/// type, or any row carrying a `metadata.disputeId` (the webhook stamps it on
/// both, and it survives a save that re-labels the type).
///
/// Autopay, the delinquency job and the reminders leave these rows out of
/// what they collect: charging a disputed amount back to the same card is
/// re-billing without consent, and paid twice when the facility wins. Staff
/// collect it by hand. Same rule as functions-shared
/// src/ledger/disputeEntries.ts; both run
/// functions-shared/src/test/fixtures/disputeLedgerParity.json.
bool isDisputeLedgerRow(Map<String, dynamic>? row) {
  if (row == null) return false;
  final type = row['type'];
  if (type == disputeLedgerType || type == disputeReversalLedgerType) return true;
  final metadata = row['metadata'];
  if (metadata is Map) {
    final disputeId = metadata['disputeId'];
    if (disputeId is String && disputeId.trim().isNotEmpty) return true;
  }
  return false;
}

/// A posted balance split into what automation may collect and the part
/// that is card disputes, rounded to cents.
class LedgerBalanceSplit {
  /// Every row: what the tenant owes, as staff see it.
  final double total;

  /// What open card disputes still have out (never negative): staff
  /// collect it by hand.
  final double disputed;

  /// The rest: the most autopay may charge. A dispute the tenant has paid
  /// twice (collected by hand, then won) is a credit here.
  final double collectible;

  const LedgerBalanceSplit({
    required this.total,
    required this.disputed,
    required this.collectible,
  });
}

double _cents(double value) => (value * 100).round() / 100;

double _amountOf(Map<String, dynamic> row) {
  final raw = row['amount'];
  return raw is num && raw.isFinite ? raw.toDouble() : 0.0;
}

/// The dispute a row belongs to: its trimmed `metadata.disputeId`, or '' for
/// an old id-less dispute row.
String _disputeKeyOf(Map<String, dynamic> row) {
  final metadata = row['metadata'];
  if (metadata is Map) {
    final disputeId = metadata['disputeId'];
    if (disputeId is String && disputeId.trim().isNotEmpty) return disputeId.trim();
  }
  return '';
}

/// One dispute's rows summed: [outstanding] is all of them (negative once
/// overpaid), [paid] only the rows staff added for it (payments taken by
/// hand, refunds of them), not the webhook's dispute and reversal.
class _DisputeGroup {
  double outstanding = 0;
  double paid = 0;

  /// Zero or negative: money the tenant paid for it beyond what it has
  /// out, never more than they actually paid for it. A reversal whose
  /// dispute row staff voided is not money anyone paid.
  double get credit {
    final out = _cents(outstanding);
    if (out >= 0) return 0;
    return math.min(0.0, math.max(out, _cents(paid)));
  }
}

Map<String, _DisputeGroup> _groupDisputeRows(Iterable<Map<String, dynamic>> rows) {
  final groups = <String, _DisputeGroup>{};
  for (final row in rows) {
    if (!isDisputeLedgerRow(row)) continue;
    final group = groups.putIfAbsent(_disputeKeyOf(row), _DisputeGroup.new);
    final amount = _amountOf(row);
    group.outstanding += amount;
    final type = row['type'];
    if (type != disputeLedgerType && type != disputeReversalLedgerType) {
      group.paid += amount;
    }
  }
  return groups;
}

/// Splits already-filtered (posted) rows; non-numeric amounts count as 0.
///
/// Each dispute is summed on its own: money still out on it is [disputed];
/// money the tenant paid for it beyond that (collected by hand or by link,
/// and then won or voided) is a credit in [collectible], so autopay does not
/// charge the next month in full on a $0 balance. The dispute webhook tells
/// staff to refund it.
LedgerBalanceSplit splitLedgerBalance(Iterable<Map<String, dynamic>> rows) {
  final list = rows.toList();
  var total = 0.0;
  var collectible = 0.0;
  for (final row in list) {
    final amount = _amountOf(row);
    total += amount;
    if (!isDisputeLedgerRow(row)) collectible += amount;
  }
  var disputed = 0.0;
  for (final group in _groupDisputeRows(list).values) {
    final outstanding = _cents(group.outstanding);
    if (outstanding > 0) {
      disputed += outstanding;
    } else {
      collectible += group.credit;
    }
  }
  return LedgerBalanceSplit(
    total: _cents(total),
    disputed: _cents(disputed),
    collectible: _cents(collectible),
  );
}

/// How much the tenant has paid for dispute [disputeId] beyond what it took
/// back (zero or positive): the refund staff owe them. Posted rows only.
/// Same rule as functions-shared ledger/disputeEntries.ts disputeCredit;
/// both run the fixture's `credit` cases.
double disputeCredit(Iterable<Map<String, dynamic>> rows, String disputeId) {
  final group = _groupDisputeRows([
    for (final row in rows)
      if (row['status'] == 'posted' && _disputeKeyOf(row) == disputeId) row,
  ])[disputeId];
  final credit = group == null ? 0.0 : -group.credit;
  return credit > 0 ? _cents(credit) : 0.0;
}

/// What dispute [disputeId] still has out: its posted rows (the dispute, a
/// reversal, payments already taken for it) summed. The most a payment for
/// it may be: more is money the tenant would have to be refunded. Same rule
/// as functions-shared ledger/disputePayment.ts disputeOutstanding, which
/// the charge-card and payment-link callables apply; both run the fixture's
/// `outstanding` cases.
double disputeOutstanding(Iterable<Map<String, dynamic>> rows, String disputeId) {
  var total = 0.0;
  for (final row in rows) {
    if (row['status'] != 'posted') continue;
    final metadata = row['metadata'];
    if (metadata is! Map || metadata['disputeId'] != disputeId) continue;
    final raw = row['amount'];
    if (raw is num && raw.isFinite) total += raw.toDouble();
  }
  return _cents(total);
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

  /// The `type` as stored, which [type] cannot always name (a card dispute
  /// reads as otherCharge). Null for an entry not read from Firestore.
  final String? storedType;

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
    this.storedType,
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
      storedType: data['type'] is String ? data['type'] as String : null,
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
    String? storedType,
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
      // A new type is a new entry kind; the stored name no longer applies.
      storedType: storedType ?? (type == null ? this.storedType : null),
    );
  }

  // Helper getters
  bool get isCharge => amount > 0;

  /// A card dispute's row (see [isDisputeLedgerRow]).
  bool get isCardDispute =>
      isDisputeLedgerRow({'type': storedType, 'metadata': metadata});

  /// The Stripe dispute id the webhook (or a payment taken for the dispute)
  /// stamped on this row, or null.
  String? get disputeId {
    final id = metadata?['disputeId'];
    return id is String && id.trim().isNotEmpty ? id.trim() : null;
  }
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
    // Both read as "Other Charge" before, even the negative reversal.
    if (storedType == disputeLedgerType) return 'Card dispute';
    if (storedType == disputeReversalLedgerType) return 'Card dispute reversed';
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

