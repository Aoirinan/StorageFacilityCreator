import 'dart:async';
import 'dart:math';

import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/move_out_card_refund.dart';

/// A card payment on the tenant's ledger that its row's Refund can refund:
/// a posted payment naming a Stripe PaymentIntent, not taken for a card
/// dispute, with something left to refund. [left] is what was paid less the
/// refunds already on the ledger against it
/// ([MoveOutCardRefund.refundablePayments]).
class LedgerCardPayment {
  const LedgerCardPayment({
    required this.paymentIntentId,
    required this.paid,
    required this.left,
    required this.paidOn,
  });

  final String paymentIntentId;
  final double paid;
  final double left;
  final DateTime paidOn;

  /// What the ledger already shows refunded against it.
  double get alreadyRefunded => max(0.0, MoveOutCardRefund.cents(paid - left));
}

enum LedgerCardRefundStatus {
  /// processRefund refunded the card, or the ledger read again shows that a
  /// call which failed did.
  refunded,

  /// Nothing was refunded: refused before processRefund reached Stripe, no
  /// connected Stripe account, or Stripe handed back a refund already on the
  /// ledger.
  notRefunded,

  /// The call failed in a way that may still have refunded the card (a
  /// timeout, a dropped connection, a server error after Stripe was asked),
  /// and the ledger read again does not show it.
  unconfirmed,
}

/// What one press of the ledger's Refund came to.
class LedgerCardRefundOutcome {
  const LedgerCardRefundOutcome._({
    required this.status,
    required this.amount,
    this.stripeRefundId,
    this.failure,
    this.notConnected = false,
    this.knownRefundId,
  });

  const LedgerCardRefundOutcome.refunded(double amount, String stripeRefundId)
      : this._(status: LedgerCardRefundStatus.refunded, amount: amount, stripeRefundId: stripeRefundId);

  const LedgerCardRefundOutcome.notRefunded(
    double amount,
    String failure, {
    bool notConnected = false,
    String? knownRefundId,
  }) : this._(
          status: LedgerCardRefundStatus.notRefunded,
          amount: amount,
          failure: failure,
          notConnected: notConnected,
          knownRefundId: knownRefundId,
        );

  const LedgerCardRefundOutcome.unconfirmed(double amount, String failure)
      : this._(status: LedgerCardRefundStatus.unconfirmed, amount: amount, failure: failure);

  final LedgerCardRefundStatus status;
  final double amount;
  final String? stripeRefundId;

  /// Why it was not refunded, or not confirmed.
  final String? failure;

  /// processRefund answered "logged for processing" without touching the
  /// card: the facility has no connected Stripe account.
  final bool notConnected;

  /// processRefund answered with this Stripe refund, which was on the ledger
  /// before the dialog opened: nothing new was refunded.
  final String? knownRefundId;

  /// Pressing again with the same request id can change the answer. Not for
  /// a refund Stripe handed back from the ledger: it would hand it back again.
  bool get retryable => status != LedgerCardRefundStatus.refunded && knownRefundId == null;

  /// For the owner when it was not refunded, or not confirmed: what happened
  /// and what to do themselves. Null once refunded. An unconfirmed refund is
  /// never called not refunded: the call that failed may have made it, and an
  /// owner told it was not would refund it again.
  String? get ownerMessage {
    final money = MoveOutCardRefund.money(amount);
    switch (status) {
      case LedgerCardRefundStatus.refunded:
        return null;
      case LedgerCardRefundStatus.unconfirmed:
        return 'The app could not confirm this refund: $failure\n\n'
            'It may still have gone through, so check before refunding again: wait a minute, then '
            'look at this ledger for a new "Refund for charge …" row for $money. If one has appeared, '
            'the refund was made. If none has, find this payment in your Stripe dashboard and see '
            'whether it shows a refund.';
      case LedgerCardRefundStatus.notRefunded:
        if (knownRefundId != null) {
          return 'No new refund was made: Stripe answered with a refund that is already on this '
              'ledger ($knownRefundId). Look at the ledger\'s "Refund for charge …" rows, and refund '
              'again only what they do not cover.';
        }
        if (notConnected) {
          return 'Not refunded: $failure\n\nTo refund it: ${MoveOutCardRefund.refundSteps(money)}';
        }
        return 'Not refunded: $failure\n\nNothing was refunded. Try again in a minute. If it is '
            'refused again, ${MoveOutCardRefund.refundSteps(money)}';
    }
  }
}

/// The ledger's Refund on a card payment row: refunds that payment, or part
/// of it, to the tenant's card through the processRefund callable
/// (functions-integrations), as the move-out's card refund does
/// ([MoveOutCardRefund]). processRefund refunds on the facility's connected
/// Stripe account under an idempotency key of the charge, the amount and the
/// request id sent here, and posts the refund to the ledger as
/// `refund_<Stripe refund id>`, the row Stripe's charge.refunded webhook
/// converges on, so it is counted once and the ledger shows it as it lands.
class LedgerCardRefund {
  /// [entry] as the ledger row [MoveOutCardRefund] reads.
  static Map<String, dynamic> rowOf(LedgerEntry entry) => {
        '_id': entry.id,
        'type': entry.storedType ?? entry.type.name,
        'status': entry.status.name,
        'amount': entry.amount,
        'referenceId': entry.referenceId,
        'metadata': entry.metadata,
        'entryDate': entry.entryDate,
        'createdAt': entry.createdAt,
      };

  /// The rows of [entries] that show Refund, by ledger entry id: posted
  /// payments naming a Stripe PaymentIntent, not taken for a card dispute
  /// (refunding one reopens the dispute), with something left to refund
  /// once the refund rows already on the ledger against that PaymentIntent
  /// are taken off. Cash and check payments name none and do not show it.
  static Map<String, LedgerCardPayment> refundableRows(List<LedgerEntry> entries) {
    final rows = [for (final entry in entries) rowOf(entry)];
    final left = {
      for (final p in MoveOutCardRefund.refundablePayments(rows)) p.paymentIntentId: p.refundable,
    };
    final out = <String, LedgerCardPayment>{};
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final row = rows[i];
      if (row['type'] != 'payment' || entry.status != LedgerEntryStatus.posted) continue;
      if (entry.metadata?['disputeId'] != null) continue;
      final paymentIntentId = MoveOutCardRefund.paymentIntentOf(row);
      final remaining = paymentIntentId == null ? null : left[paymentIntentId];
      if (remaining == null || remaining <= 0) continue;
      out[entry.id] = LedgerCardPayment(
        paymentIntentId: paymentIntentId!,
        paid: MoveOutCardRefund.cents(entry.amount.abs()),
        left: remaining,
        paidOn: entry.entryDate,
      );
    }
    return out;
  }

  static final _random = Random.secure();

  /// A new processRefund request id (letters, digits, `_` and `-`, 8 to 64
  /// long, or processRefund ignores it). One per Refund dialog, sent on every
  /// press of it, so a retry of a press whose answer was lost is the same
  /// Stripe refund, while a second refund from a new dialog is a new one.
  static String newRequestId() =>
      'lr_${List.generate(24, (_) => _random.nextInt(36).toRadixString(36)).join()}';

  /// processRefund's payload: the shape [MoveOutCardRefund.refund] sends.
  static Map<String, dynamic> payload({
    required String facilityId,
    required String tenantId,
    required String paymentIntentId,
    required double amount,
    required String requestId,
  }) =>
      {
        'facilityId': facilityId,
        'tenantId': tenantId,
        'amount': MoveOutCardRefund.cents(amount),
        'refundMethod': 'creditCard',
        'referenceId': paymentIntentId,
        'requestId': requestId,
      };

  /// Refunds [amount] of the card payment [paymentIntentId] through [call]
  /// (processRefund), under [requestId]. [known] is the Stripe refund ids on
  /// the ledger when the dialog opened ([MoveOutCardRefund.recordedRefundIds]):
  /// an answer naming one of them made nothing new. A call that may still
  /// have refunded ([MoveOutCardRefund.mayHaveRefunded]) is checked against
  /// the ledger read again ([reread]); a refund it made after all
  /// ([MoveOutCardRefund.landedRefund]) counts as made, and otherwise it is
  /// unconfirmed, never not refunded. A refusal before Stripe is not read
  /// again: nothing this press sent was refunded, and a refund someone else
  /// made in the meantime is not this one. What happened, with the owner's
  /// [note], goes to the audit log. Never throws.
  static Future<LedgerCardRefundOutcome> refund({
    required String facilityId,
    required String tenantId,
    required String paymentIntentId,
    required double amount,
    required String requestId,
    required Set<String> known,
    String? note,
    ProcessRefundCall? call,
    Future<List<Map<String, dynamic>>> Function()? reread,
  }) async {
    final value = MoveOutCardRefund.cents(amount);
    final outcome = await _refund(
      payload(
        facilityId: facilityId,
        tenantId: tenantId,
        paymentIntentId: paymentIntentId,
        amount: value,
        requestId: requestId,
      ),
      paymentIntentId: paymentIntentId,
      amount: value,
      known: known,
      call: call ?? MoveOutCardRefund.callProcessRefund,
      reread: reread ??
          () => MoveOutCardRefund.postedLedgerRows(facilityId: facilityId, tenantId: tenantId),
    );
    // Not awaited: the owner's answer does not wait on the audit log, which
    // never throws.
    unawaited(AuditService.logEvent(
      facilityId: facilityId,
      eventType: 'ledger.cardRefund',
      targetType: 'payment',
      targetId: paymentIntentId,
      tenantId: tenantId,
      after: {
        'status': outcome.status.name,
        'amount': outcome.amount,
        'paymentIntentId': paymentIntentId,
        'requestId': requestId,
        if (outcome.stripeRefundId != null) 'stripeRefundId': outcome.stripeRefundId,
        if (outcome.failure != null) 'failure': outcome.failure,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      },
    ));
    return outcome;
  }

  static Future<LedgerCardRefundOutcome> _refund(
    Map<String, dynamic> payload, {
    required String paymentIntentId,
    required double amount,
    required Set<String> known,
    required ProcessRefundCall call,
    required Future<List<Map<String, dynamic>>> Function() reread,
  }) async {
    final Map<String, dynamic> answer;
    try {
      answer = await call(payload);
    } catch (e) {
      final failure = MoveOutCardRefund.failureText(e);
      if (!MoveOutCardRefund.mayHaveRefunded(e)) {
        return LedgerCardRefundOutcome.notRefunded(amount, failure);
      }
      CardRefundMade? landed;
      try {
        landed = MoveOutCardRefund.landedRefund(
          await reread(),
          slice: (paymentIntentId: paymentIntentId, amount: amount, paidOn: null),
          known: known,
        );
      } catch (_) {
        landed = null;
      }
      return landed != null
          ? LedgerCardRefundOutcome.refunded(amount, landed.stripeRefundId)
          : LedgerCardRefundOutcome.unconfirmed(amount, failure);
    }
    final raw = answer['stripeRefundId'];
    final refundId = raw is String && raw.trim().isNotEmpty ? raw.trim() : null;
    if (refundId == null) {
      // processRefund answers "logged for processing" without touching the
      // card when the facility has no connected Stripe account.
      return LedgerCardRefundOutcome.notRefunded(
        amount,
        "this facility's Stripe account is not connected, so the app could not refund the card.",
        notConnected: true,
      );
    }
    if (known.contains(refundId)) {
      return LedgerCardRefundOutcome.notRefunded(
        amount,
        'Stripe answered with a refund already on the ledger ($refundId).',
        knownRefundId: refundId,
      );
    }
    return LedgerCardRefundOutcome.refunded(amount, refundId);
  }
}
