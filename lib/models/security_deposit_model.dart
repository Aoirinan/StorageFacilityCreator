import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/payment_model.dart';

/// Whether the facility still holds the deposit, or has given it back
/// (applied to the balance, refunded, or both).
enum SecurityDepositStatus { held, settled }

/// A security deposit the facility holds for a tenant, stored as the
/// `securityDeposit` map on the tenant doc. No field means no deposit on
/// file. A settled deposit stays there until a new one is recorded over it
/// (a tenant who came back), when it moves to the `securityDepositHistory`
/// list ([historyFromStored]).
///
/// A held deposit is money the facility owes the tenant back, so it is never
/// a ledger row: the ledger balance feeds autopay, delinquency, the rent job
/// and statements, and a deposit written there as a credit would be spent on
/// the next month's rent. The ledger changes only when, and by how much, the
/// deposit is applied at settlement (SecurityDepositService.settle).
class SecurityDeposit {
  final double amount;

  /// The day the deposit was received, or null when nobody knows (an old
  /// tenant whose paperwork is gone). Stored at noon UTC, like past history,
  /// so it reads as the same calendar day in every US time zone.
  final DateTime? receivedDate;
  final PaymentMethod method;

  /// A check number or Venmo/Zelle reference.
  final String? reference;
  final String? note;
  final SecurityDepositStatus status;
  final DateTime? recordedAt;
  final String? recordedBy;
  final DateTime? updatedAt;

  // Set once settled.
  final DateTime? settledAt;
  final String? settledBy;

  /// How much went against the tenant's balance (posted as a ledger credit).
  final double? appliedAmount;

  /// How much was handed back to the tenant. Recorded here only, never on
  /// the ledger.
  final double? refundedAmount;
  final PaymentMethod? refundMethod;
  final String? refundReference;

  /// The 'Security deposit applied' ledger row, when [appliedAmount] > 0.
  final String? appliedLedgerEntryId;

  const SecurityDeposit({
    required this.amount,
    this.receivedDate,
    required this.method,
    this.reference,
    this.note,
    this.status = SecurityDepositStatus.held,
    this.recordedAt,
    this.recordedBy,
    this.updatedAt,
    this.settledAt,
    this.settledBy,
    this.appliedAmount,
    this.refundedAmount,
    this.refundMethod,
    this.refundReference,
    this.appliedLedgerEntryId,
  });

  bool get isHeld => status == SecurityDepositStatus.held;

  /// [value] rounded to cents, so $24.999 and $25.00 are the same deposit.
  static double toCents(num value) => (value * 100).round() / 100;

  /// [day] as the calendar day it names, at noon UTC (see [receivedDate]).
  static DateTime noonUtc(DateTime day) =>
      DateTime.utc(day.year, day.month, day.day, 12);

  /// The facility's usual deposit, `billingSettings.securityDeposit` (the
  /// key the online move-in quote already falls back to), for prefilling
  /// the dialogs. Null when unset, blank or not above $0.
  static double? facilityDefault(Map<String, dynamic>? billingSettings) {
    final value = billingSettings?['securityDeposit'];
    if (value is num && value > 0) return toCents(value);
    if (value is String) {
      final parsed = double.tryParse(value.trim());
      if (parsed != null && parsed > 0) return toCents(parsed);
    }
    return null;
  }

  /// The tenant doc's `securityDepositHistory`: deposits settled before the
  /// one now on file, oldest first. Missing on every tenant who never had a
  /// second deposit, so anything but a list of maps reads as empty.
  static List<SecurityDeposit> historyFromStored(Object? raw) => [
        if (raw is List)
          for (final entry in raw)
            if (entry is Map)
              SecurityDeposit.fromMap(Map<String, dynamic>.from(entry)),
      ];

  static double? _amount(Object? value) =>
      value is num ? toCents(value) : null;

  static DateTime? _date(Object? value) =>
      value is Timestamp ? value.toDate() : null;

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  factory SecurityDeposit.fromMap(Map<String, dynamic> data) {
    final refundMethod = data['refundMethod'];
    return SecurityDeposit(
      amount: _amount(data['amount']) ?? 0,
      receivedDate: _date(data['receivedDate']),
      method: paymentMethodFromStored(data['method']),
      reference: _text(data['reference']),
      note: _text(data['note']),
      status: data['status'] == SecurityDepositStatus.settled.name
          ? SecurityDepositStatus.settled
          : SecurityDepositStatus.held,
      recordedAt: _date(data['recordedAt']),
      recordedBy: _text(data['recordedBy']),
      updatedAt: _date(data['updatedAt']),
      settledAt: _date(data['settledAt']),
      settledBy: _text(data['settledBy']),
      appliedAmount: _amount(data['appliedAmount']),
      refundedAmount: _amount(data['refundedAmount']),
      refundMethod: refundMethod is String && refundMethod.isNotEmpty
          ? paymentMethodFromStored(refundMethod)
          : null,
      refundReference: _text(data['refundReference']),
      appliedLedgerEntryId: _text(data['appliedLedgerEntryId']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'amount': toCents(amount),
      'receivedDate':
          receivedDate != null ? Timestamp.fromDate(receivedDate!) : null,
      'method': method.name,
      if (reference != null && reference!.trim().isNotEmpty)
        'reference': reference!.trim(),
      if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
      'status': status.name,
      if (recordedAt != null) 'recordedAt': Timestamp.fromDate(recordedAt!),
      if (recordedBy != null) 'recordedBy': recordedBy,
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      if (settledAt != null) 'settledAt': Timestamp.fromDate(settledAt!),
      if (settledBy != null) 'settledBy': settledBy,
      if (appliedAmount != null) 'appliedAmount': toCents(appliedAmount!),
      if (refundedAmount != null) 'refundedAmount': toCents(refundedAmount!),
      if (refundMethod != null) 'refundMethod': refundMethod!.name,
      if (refundReference != null && refundReference!.trim().isNotEmpty)
        'refundReference': refundReference!.trim(),
      if (appliedLedgerEntryId != null)
        'appliedLedgerEntryId': appliedLedgerEntryId,
    };
  }

  SecurityDeposit copyWith({
    double? amount,
    DateTime? receivedDate,
    bool clearReceivedDate = false,
    PaymentMethod? method,
    String? reference,
    String? note,
    SecurityDepositStatus? status,
    DateTime? recordedAt,
    String? recordedBy,
    DateTime? updatedAt,
    DateTime? settledAt,
    String? settledBy,
    double? appliedAmount,
    double? refundedAmount,
    PaymentMethod? refundMethod,
    String? refundReference,
    String? appliedLedgerEntryId,
  }) {
    return SecurityDeposit(
      amount: amount ?? this.amount,
      receivedDate:
          clearReceivedDate ? null : (receivedDate ?? this.receivedDate),
      method: method ?? this.method,
      reference: reference ?? this.reference,
      note: note ?? this.note,
      status: status ?? this.status,
      recordedAt: recordedAt ?? this.recordedAt,
      recordedBy: recordedBy ?? this.recordedBy,
      updatedAt: updatedAt ?? this.updatedAt,
      settledAt: settledAt ?? this.settledAt,
      settledBy: settledBy ?? this.settledBy,
      appliedAmount: appliedAmount ?? this.appliedAmount,
      refundedAmount: refundedAmount ?? this.refundedAmount,
      refundMethod: refundMethod ?? this.refundMethod,
      refundReference: refundReference ?? this.refundReference,
      appliedLedgerEntryId: appliedLedgerEntryId ?? this.appliedLedgerEntryId,
    );
  }

  static String _money(double value) => '\$${value.toStringAsFixed(2)}';

  static String _day(DateTime d) => '${d.month}/${d.day}/${d.year}';

  /// One line for the tenant page: "$25.00 held · received 9/1/2026 ·
  /// Check #1234", or "Settled 10/3/2026: $10.00 applied, $15.00 refunded".
  String get summary {
    if (isHeld) {
      final parts = [
        '${_money(amount)} held',
        if (receivedDate != null) 'received ${_day(receivedDate!)}',
        paymentMethodWithReference(method, reference: reference),
      ];
      return parts.join(' · ');
    }
    final settled = settledAt != null ? 'Settled ${_day(settledAt!)}' : 'Settled';
    return '$settled: ${_money(appliedAmount ?? 0)} applied, '
        '${_money(refundedAmount ?? 0)} refunded';
  }
}
