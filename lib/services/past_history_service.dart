import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';

import 'package:sfcapp/utils/past_history_math.dart';

/// What recordTenantPastHistory saved (or had already saved, for a repeat
/// of the same request).
class PastHistoryResult {
  const PastHistoryResult({
    required this.requestId,
    required this.alreadyApplied,
    required this.totalCharges,
    required this.totalPayments,
    required this.balance,
    required this.paidThrough,
    required this.credit,
    required this.warnings,
    this.existingVoided = 0,
    this.moveInDateSaved = false,
  });

  final String requestId;
  final bool alreadyApplied;
  final double totalCharges;
  final double totalPayments;
  final double balance;
  final DateTime? paidThrough;
  final double credit;
  final List<String> warnings;

  /// Entries already on the ledger that this save voided.
  final int existingVoided;
  final bool moveInDateSaved;

  static double _num(Object? v) => v is num ? v.toDouble() : 0.0;

  factory PastHistoryResult.fromMap(Map<String, dynamic> data) {
    final pt = data['paidThrough'];
    return PastHistoryResult(
      requestId: '${data['requestId'] ?? ''}',
      alreadyApplied: data['alreadyApplied'] == true,
      totalCharges: _num(data['totalCharges']),
      totalPayments: _num(data['totalPayments']),
      balance: _num(data['balance']),
      paidThrough: pt is String ? DateTime.tryParse(pt) : null,
      credit: _num(data['credit']),
      warnings: (data['warnings'] as List?)?.map((w) => '$w').toList() ?? const [],
      existingVoided: (data['existingVoided'] as num?)?.toInt() ?? 0,
      moveInDateSaved: data['moveInDateSaved'] == true,
    );
  }
}

/// Enter past history and its undo, both server-side
/// (functions-automation/src/tenantPastHistoryCallable.ts): the client
/// rules only let a payment be dated now.
class PastHistoryService {
  static final Random _random = Random.secure();

  /// A fresh id for one history entry. The screen makes one when it opens
  /// and sends it with every save, so a double press or a retry after a
  /// dropped connection saves once.
  static String newRequestId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return 'hist-${List.generate(20, (_) => chars[_random.nextInt(chars.length)]).join()}';
  }

  static Future<PastHistoryResult> record({
    required String facilityId,
    required String tenantId,
    required String requestId,
    required List<ProposedHistoryCharge> charges,
    required List<HistoryPaymentInput> payments,
    DateTime? moveInDate,
    List<String> voidLedgerEntryIds = const [],
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('recordTenantPastHistory');
    final result = await callable.call(<String, dynamic>{
      'facilityId': facilityId,
      'tenantId': tenantId,
      'requestId': requestId,
      'charges': charges.where((c) => c.included).map((c) => c.toPayload()).toList(),
      'payments': payments.map((p) => p.toPayload()).toList(),
      if (moveInDate != null)
        'moveInDate':
            '${moveInDate.year.toString().padLeft(4, '0')}-${moveInDate.month.toString().padLeft(2, '0')}-${moveInDate.day.toString().padLeft(2, '0')}',
      if (voidLedgerEntryIds.isNotEmpty) 'voidLedgerEntryIds': voidLedgerEntryIds,
    });
    return PastHistoryResult.fromMap(Map<String, dynamic>.from(result.data as Map));
  }

  /// Voids every entry and payment of history entry [requestId] and puts
  /// the tenant's paid-through date back. Returns the server's warnings.
  static Future<List<String>> undo({
    required String facilityId,
    required String tenantId,
    required String requestId,
  }) async {
    final callable = FirebaseFunctions.instance.httpsCallable('undoTenantPastHistory');
    final result = await callable.call(<String, dynamic>{
      'facilityId': facilityId,
      'tenantId': tenantId,
      'requestId': requestId,
    });
    final data = Map<String, dynamic>.from(result.data as Map);
    return (data['warnings'] as List?)?.map((w) => '$w').toList() ?? const [];
  }
}
