import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/audit_service.dart';

/// A card payment of the tenant's that a move-out card refund can go
/// against: a posted payment row carrying a Stripe PaymentIntent id.
/// [refundable] is what was paid less the refunds already on the ledger
/// against it.
class RefundableCardPayment {
  const RefundableCardPayment({
    required this.paymentIntentId,
    required this.refundable,
    this.paidOn,
  });

  final String paymentIntentId;
  final double refundable;
  final DateTime? paidOn;
}

/// One refund against one card payment.
typedef CardRefundSlice = ({String paymentIntentId, double amount, DateTime? paidOn});

/// How a move-out's card refund would be split across the tenant's card
/// payments, newest first. [uncovered] is what their card payments cannot
/// take, which stays on the ledger as their credit.
class CardRefundPlan {
  const CardRefundPlan({required this.requested, required this.slices});

  final double requested;
  final List<CardRefundSlice> slices;

  double get covered => MoveOutCardRefund.cents(slices.fold(0.0, (total, s) => total + s.amount));
  double get uncovered => MoveOutCardRefund.cents(requested - covered);
}

/// One refund processRefund made.
typedef CardRefundMade = ({String paymentIntentId, String stripeRefundId, double amount});

enum CardRefundStatus { refunded, partial, notMade }

/// What a move-out's card refund came to.
class CardRefundOutcome {
  const CardRefundOutcome({
    required this.requested,
    this.refunds = const [],
    this.failure,
    this.noRefundablePayment = false,
  });

  final double requested;
  final List<CardRefundMade> refunds;

  /// Why the rest was not refunded, when a refund failed or could not be
  /// confirmed. Null when every planned refund was made.
  final String? failure;

  /// The app found no card payment of the tenant's it could refund.
  final bool noRefundablePayment;

  double get refunded => MoveOutCardRefund.cents(refunds.fold(0.0, (total, r) => total + r.amount));
  double get leftOnLedger => MoveOutCardRefund.cents(requested - refunded);

  CardRefundStatus get status => leftOnLedger <= 0
      ? CardRefundStatus.refunded
      : refunded > 0
          ? CardRefundStatus.partial
          : CardRefundStatus.notMade;

  /// For the owner once the move-out is done, when not all of it was
  /// refunded: what happened and what to do, in words that stay on screen
  /// until they close them. Null when it was all refunded.
  String? get ownerAlert {
    if (status == CardRefundStatus.refunded) return null;
    final left = MoveOutCardRefund.money(leftOnLedger);
    final record = 'record it on their ledger with Add entry, type Refund, amount $left';
    final done = refunded > 0
        ? 'The app refunded ${MoveOutCardRefund.money(refunded)} to their card through Stripe. '
        : '';
    if (failure != null) {
      return '${done}The other $left was not refunded: $failure\n\n'
          'It stays on their ledger as a credit. Before refunding it, look up their payment in '
          'your Stripe dashboard: if a refund of it already shows there, only $record. '
          'If not, refund $left to their card in Stripe, then $record.';
    }
    final why = noRefundablePayment || refunded == 0
        ? 'The app found no card payment from this tenant that it can refund (only payments '
            'made online through your Stripe account and recorded on their ledger can be), '
            'so nothing was refunded to their card. '
        : 'Their card payments the app can refund came to ${MoveOutCardRefund.money(refunded)}. ';
    return '$done$why'
        'The ${refunded > 0 ? 'other ' : ''}$left stays on their ledger as a credit.\n\n'
        'To refund it: refund $left to their card in your Stripe dashboard, then $record.';
  }

  /// The contract's `moveOutCardRefund` (processMoveOut left it 'pending').
  Map<String, dynamic> contractRecord() => {
        'status': status.name,
        'requested': requested,
        'refunded': refunded,
        'leftOnLedger': leftOnLedger,
        'refunds': [
          for (final r in refunds)
            {
              'paymentIntentId': r.paymentIntentId,
              'stripeRefundId': r.stripeRefundId,
              'amount': r.amount,
            },
        ],
        'reason': failure ?? (status == CardRefundStatus.refunded ? null : 'no refundable card payment'),
      };
}

/// Calls processRefund with [payload] and returns its answer.
typedef ProcessRefundCall = Future<Map<String, dynamic>> Function(Map<String, dynamic> payload);

/// A move-out's refund to the tenant's card, which processMoveOut leaves to
/// the screen (its `cardRefundDue`).
///
/// It is made through the processRefund callable (functions-integrations),
/// one refund per card payment, newest payment first, never more than the
/// refund or than a payment has left: that refunds on the facility's
/// connected Stripe account and posts each refund to the ledger as
/// `refund_<Stripe refund id>`, the row Stripe's charge.refunded webhook
/// converges on, so it is counted once. Whatever is not refunded stays on
/// the ledger as the tenant's credit, and the owner is told, in words that
/// stay on screen, to refund it in Stripe and record it with Add entry,
/// type Refund. Before this, the move-out told the owner Stripe's webhook
/// would record a refund they made in Stripe, which it does not for an
/// online move-in payment (no tenantId on its PaymentIntent) or a
/// checkout-link payment (no metadata on it at all).
class MoveOutCardRefund {
  static double cents(double value) => (value * 100).round() / 100;

  static String money(double value) => '\$${value.toStringAsFixed(2)}';

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static double? _amount(Object? value) {
    if (value is num) return value.isFinite ? value.toDouble() : null;
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static DateTime? _date(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static Map<String, dynamic> _metadata(Map<String, dynamic> row) {
    final m = row['metadata'];
    return m is Map ? Map<String, dynamic>.from(m) : const {};
  }

  /// The Stripe PaymentIntent a ledger row names: `metadata.paymentIntentId`
  /// (the webhook, autopay, off-session charges, online move-in),
  /// `metadata.stripePaymentIntentId`, or a `referenceId` that is one
  /// (online move-in, autopay, processRefund's own refund rows).
  @visibleForTesting
  static String? paymentIntentOf(Map<String, dynamic> row) {
    final meta = _metadata(row);
    for (final candidate in [
      meta['paymentIntentId'],
      meta['stripePaymentIntentId'],
      row['referenceId'],
    ]) {
      final id = _text(candidate);
      if (id != null && id.startsWith('pi_')) return id;
    }
    return null;
  }

  static bool _posted(Map<String, dynamic> row) => (row['status'] ?? 'posted') == 'posted';

  /// The Stripe refund id of a refund row: processRefund's
  /// `metadata.stripeRefundId`, the webhook's `metadata.refundId`, else the
  /// `refund_<id>` document id either writes.
  static String? _refundId(Map<String, dynamic> row) {
    final meta = _metadata(row);
    final id = _text(meta['stripeRefundId']) ?? _text(meta['refundId']);
    if (id != null) return id;
    final docId = _text(row['_id']);
    return docId != null && docId.startsWith('refund_') ? docId.substring('refund_'.length) : null;
  }

  /// The tenant's card payments the app can refund, newest first, from their
  /// posted ledger [rows] (each with its document id as `_id`). A payment
  /// recorded twice (the webhook and autopay write one row, but another
  /// writer could add a second) counts once. A payment taken for a card
  /// dispute is left out: refunding it reopens the dispute.
  static List<RefundableCardPayment> refundablePayments(Iterable<Map<String, dynamic>> rows) {
    final paid = <String, double>{};
    final paidOn = <String, DateTime?>{};
    final refunded = <String, Map<String, double>>{};
    for (final row in rows) {
      if (!_posted(row)) continue;
      final pi = paymentIntentOf(row);
      if (pi == null) continue;
      final amount = _amount(row['amount']);
      if (amount == null) continue;
      final type = row['type'];
      if (type == 'payment') {
        if (_metadata(row)['disputeId'] != null) continue;
        final magnitude = amount.abs();
        if (magnitude > (paid[pi] ?? 0)) paid[pi] = magnitude;
        final on = _date(row['entryDate']) ?? _date(row['createdAt']);
        final known = paidOn[pi];
        if (known == null || (on != null && on.isAfter(known))) paidOn[pi] = on ?? known;
      } else if (type == 'refund') {
        final key = _refundId(row) ?? '${row['_id'] ?? refunded[pi]?.length ?? 0}';
        (refunded[pi] ??= {})[key] = amount.abs();
      }
    }
    final out = [
      for (final entry in paid.entries)
        RefundableCardPayment(
          paymentIntentId: entry.key,
          refundable: cents(entry.value -
              (refunded[entry.key]?.values.fold<double>(0, (total, a) => total + a) ?? 0)),
          paidOn: paidOn[entry.key],
        ),
    ].where((p) => p.refundable > 0).toList();
    out.sort((a, b) {
      final x = a.paidOn, y = b.paidOn;
      if (x == null && y == null) return a.paymentIntentId.compareTo(b.paymentIntentId);
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return out;
  }

  /// The Stripe refund ids already on the ledger. processRefund keys a card
  /// refund by charge and amount, so a second refund of the same amount on
  /// the same charge within a day can come back as the first: its id is
  /// already here, and nothing new was refunded.
  static Set<String> recordedRefundIds(Iterable<Map<String, dynamic>> rows) => {
        for (final row in rows)
          if (row['type'] == 'refund' && _refundId(row) != null) _refundId(row)!,
      };

  /// [amount] split across [payments] (newest first), each taking no more
  /// than it has left.
  static CardRefundPlan plan({required double amount, required List<RefundableCardPayment> payments}) {
    var remaining = cents(amount);
    final slices = <CardRefundSlice>[];
    for (final p in payments) {
      if (remaining <= 0) break;
      final take = cents(p.refundable < remaining ? p.refundable : remaining);
      if (take <= 0) continue;
      slices.add((paymentIntentId: p.paymentIntentId, amount: take, paidOn: p.paidOn));
      remaining = cents(remaining - take);
    }
    return CardRefundPlan(requested: cents(amount), slices: slices);
  }

  /// What the move-out screen says under the refund method before the owner
  /// completes: what the app will refund to their card, and what it cannot.
  static String preview(CardRefundPlan plan) {
    final dates = DateFormat('MMM d, yyyy');
    String payment(CardRefundSlice s) =>
        s.paidOn == null ? 'a card payment' : 'their card payment of ${dates.format(s.paidOn!)}';
    if (plan.slices.isEmpty) {
      return 'The app found no card payment from this tenant that it can refund. '
          'The ${money(plan.requested)} will stay on their ledger as a credit: refund it in your '
          'Stripe dashboard, then record it on their ledger (Add entry, type Refund).';
    }
    final parts = [
      for (final s in plan.slices) '${money(s.amount)} to ${payment(s)}',
    ];
    final lead = 'When you complete the move-out, the app refunds ${parts.join(', ')} through Stripe.';
    if (plan.uncovered <= 0) return lead;
    return '$lead Their card payments cannot take the other ${money(plan.uncovered)}: it stays on '
        'their ledger as a credit for you to refund in Stripe.';
  }

  /// processRefund's per-refund request id (letters, digits, _ and -, at
  /// most 64): the same for a retry of this move-out's refund of this
  /// payment, so it cannot be made twice, and different for another
  /// move-out's. processRefund servers that do not read it ignore it.
  @visibleForTesting
  static String requestId(String contractId, String paymentIntentId) {
    final raw = 'mo_${contractId}_$paymentIntentId'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return raw.length <= 64 ? raw : raw.substring(0, 64);
  }

  /// Makes [amount] of refund to the tenant's card through [call]
  /// (processRefund), against the payments in [rows] (their posted ledger).
  /// Stops at the first refund that fails or is not confirmed, and refunds
  /// nothing more: a call that timed out may still have refunded, and
  /// refunding the next payment as well would pay the tenant twice.
  static Future<CardRefundOutcome> refund({
    required String facilityId,
    required String tenantId,
    required String contractId,
    required double amount,
    required List<Map<String, dynamic>> rows,
    required ProcessRefundCall call,
  }) async {
    final plan = MoveOutCardRefund.plan(amount: amount, payments: refundablePayments(rows));
    if (plan.slices.isEmpty) {
      return CardRefundOutcome(requested: plan.requested, noRefundablePayment: true);
    }
    final known = recordedRefundIds(rows);
    final made = <CardRefundMade>[];
    for (final slice in plan.slices) {
      Map<String, dynamic> answer;
      try {
        answer = await call({
          'facilityId': facilityId,
          'tenantId': tenantId,
          'amount': slice.amount,
          'refundMethod': 'creditCard',
          'referenceId': slice.paymentIntentId,
          'requestId': requestId(contractId, slice.paymentIntentId),
        });
      } on FirebaseFunctionsException catch (e) {
        return CardRefundOutcome(
          requested: plan.requested,
          refunds: made,
          failure: e.message?.trim().isNotEmpty == true ? e.message!.trim() : e.code,
        );
      } catch (e) {
        return CardRefundOutcome(requested: plan.requested, refunds: made, failure: '$e');
      }
      final refundId = _text(answer['stripeRefundId']);
      if (refundId == null) {
        // processRefund answers "logged for processing" without touching
        // the card when the facility has no connected Stripe account.
        return CardRefundOutcome(
          requested: plan.requested,
          refunds: made,
          failure: "the facility's Stripe account is not connected, so the app could not refund "
              'the card.',
        );
      }
      if (known.contains(refundId)) {
        return CardRefundOutcome(
          requested: plan.requested,
          refunds: made,
          failure: 'Stripe answered with a refund already on their ledger ($refundId), so no new '
              'refund was made.',
        );
      }
      known.add(refundId);
      made.add((paymentIntentId: slice.paymentIntentId, stripeRefundId: refundId, amount: slice.amount));
    }
    return CardRefundOutcome(requested: plan.requested, refunds: made);
  }

  /// The tenant's posted ledger rows, each with its document id as `_id`.
  static Future<List<Map<String, dynamic>>> postedLedgerRows({
    required String facilityId,
    required String tenantId,
    FirebaseFirestore? firestore,
  }) async {
    final snapshot = await (firestore ?? FirebaseFirestore.instance)
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .where('tenantId', isEqualTo: tenantId)
        .where('status', isEqualTo: 'posted')
        .get();
    return [
      for (final doc in snapshot.docs) {...doc.data(), '_id': doc.id},
    ];
  }

  /// Makes the card refund and records it: reads the tenant's ledger, calls
  /// processRefund ([refund]), then writes the outcome to the contract
  /// (`moveOutCardRefund`, and `moveOutRefund` as what was refunded) and the
  /// audit log. Never throws: the move-out is done by now, so anything that
  /// goes wrong is the owner's to finish, and they are told.
  static Future<CardRefundOutcome> refundAfterMoveOut({
    required String facilityId,
    required String tenantId,
    required String contractId,
    required double amount,
  }) async {
    CardRefundOutcome outcome;
    try {
      final rows = await postedLedgerRows(facilityId: facilityId, tenantId: tenantId);
      final callable = FirebaseFunctions.instance.httpsCallable('processRefund');
      outcome = await refund(
        facilityId: facilityId,
        tenantId: tenantId,
        contractId: contractId,
        amount: amount,
        rows: rows,
        call: (payload) async {
          final result = await callable.call<dynamic>(payload);
          final data = result.data;
          return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
        },
      );
    } catch (e) {
      outcome = CardRefundOutcome(
        requested: cents(amount),
        failure: "the app could not read the tenant's payments ($e).",
      );
    }
    await record(facilityId: facilityId, tenantId: tenantId, contractId: contractId, outcome: outcome);
    return outcome;
  }

  /// Writes [outcome] to the contract and the audit log, best effort.
  static Future<void> record({
    required String facilityId,
    required String tenantId,
    required String contractId,
    required CardRefundOutcome outcome,
  }) async {
    final details = outcome.contractRecord();
    try {
      await FirebaseFirestore.instance
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .doc(contractId)
          .update({
        'moveOutCardRefund': {
          ...details,
          'recordedAt': FieldValue.serverTimestamp(),
          'recordedBy': FirebaseAuth.instance.currentUser?.uid,
        },
        'moveOutRefund': outcome.refunded,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) print('⚠️ [MoveOut] Card refund not recorded on the contract: $e');
    }
    await AuditService.logEvent(
      facilityId: facilityId,
      eventType: 'moveout.cardRefund',
      targetType: 'moveOut',
      targetId: contractId,
      tenantId: tenantId,
      after: details,
    );
  }
}
