import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
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
    this.paidThroughBefore,
    this.invoicesToReview = const [],
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

  /// The tenant's paid-through date before the save.
  final DateTime? paidThroughBefore;

  /// Invoice numbers (or ids) the voided entries were on, for the owner to
  /// void in Invoices.
  final List<String> invoicesToReview;

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
      paidThroughBefore: data['paidThroughBefore'] is String
          ? DateTime.tryParse(data['paidThroughBefore'] as String)
          : null,
      invoicesToReview: [
        for (final i in (data['invoicesToReview'] as List?) ?? const [])
          if (i is Map) '${i['number'] ?? i['id']}',
      ],
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
    PaidThroughChoice? paidThroughChoice,
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
      // Unticked months: free rent, which counts as paid right after a paid month.
      'freeMonths': [
        for (final c in charges)
          if (!c.included) {'year': c.year, 'month': c.month},
      ],
      if (paidThroughChoice != null) 'paidThroughChoice': paidThroughChoice.name,
    });
    return PastHistoryResult.fromMap(Map<String, dynamic>.from(result.data as Map));
  }

  /// Invoice numbers for [invoiceIds] (the id itself when a doc has none or
  /// cannot be read), for the preview's "open Invoices and void them".
  static Future<List<String>> invoiceNumbers(String facilityId, List<String> invoiceIds) async {
    final out = <String>[];
    for (final id in invoiceIds) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('facilities')
            .doc(facilityId)
            .collection('invoices')
            .doc(id)
            .get();
        final number = doc.data()?['invoiceNumber'];
        out.add(number is String && number.isNotEmpty ? number : id);
      } catch (_) {
        out.add(id);
      }
    }
    return out;
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
