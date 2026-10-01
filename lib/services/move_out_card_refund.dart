import 'dart:math';

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

/// A card refund a finished move-out left pending (processMoveOut's
/// `pendingCardRefund`, answered to a second press of Complete): what was
/// [requested], and [since], when the move-out was committed (null when the
/// server did not say).
typedef PendingCardRefund = ({double requested, DateTime? since});

/// What the move-out screen does with a [PendingCardRefund]
/// ([MoveOutCardRefund.pendingChoiceFrom]): offer [plan], or, when it is
/// null, show [alert] under [title] and record [reason] on the contract.
/// [reason] is null when nothing is recorded: the app could not read their
/// ledger, so the refund stays 'pending' for a later press to check again.
typedef PendingCardRefundChoice = ({CardRefundPlan? plan, String? title, String? alert, String? reason});

/// What a press found on the contract's card refund record when it went to
/// take it ([MoveOutCardRefund.claim]) or write it
/// ([MoveOutCardRefund.recordLeftToOwner], [MoveOutCardRefund.record]).
enum CardRefundClaim {
  /// Still 'pending', and taken by no press but this one: it is this
  /// press's to make, or to write.
  ours,

  /// Still 'pending', but another press took it to make the refund and has
  /// not recorded what it did: it may be making it now, or it stopped
  /// partway.
  claimed,

  /// No longer 'pending': another press recorded it, as refunded, not made,
  /// or left to the owner to make in Stripe.
  settled,

  /// The contract could not be read or written.
  unknown,
}

/// What a move-out's card refund came to.
class CardRefundOutcome {
  const CardRefundOutcome({
    required this.requested,
    this.refunds = const [],
    this.failure,
    this.uncertain = false,
    this.noRefundablePayment = false,
    this.knownRefundId,
    this.refundSinceOffer = false,
    this.refundSinceMoveOut = false,
    this.notClaimed,
  });

  /// Not made because the contract's record of it was not this press's to
  /// take ([found], [MoveOutCardRefund.claim]).
  factory CardRefundOutcome.notClaimedAs(double requested, CardRefundClaim found, {Object? error}) =>
      CardRefundOutcome(
        requested: requested,
        failure: MoveOutCardRefund._notClaimedReason(found, error),
        notClaimed: found,
      );

  final double requested;
  final List<CardRefundMade> refunds;

  /// Why the rest was not refunded, when a refund failed or could not be
  /// confirmed. Null when every planned refund was made.
  final String? failure;

  /// The call behind [failure] may still have refunded the card (a timeout,
  /// a dropped connection, a server error after Stripe was asked), and the
  /// ledger read again did not show it yet.
  final bool uncertain;

  /// The app found no card payment of the tenant's it could refund.
  final bool noRefundablePayment;

  /// processRefund answered with this Stripe refund, which was on the
  /// ledger already: no new refund was made.
  final String? knownRefundId;

  /// A pending refund the owner was offered was not made: a refund reached
  /// their ledger between the offer and the press (another press of
  /// Complete, on this device or another), so part of it may be made.
  final bool refundSinceOffer;

  /// The first press's refund was not made: a refund reached their ledger
  /// after processMoveOut committed the move-out and before this press read
  /// it (a second session, answered "already completed", was offered the
  /// pending refund and made it), so part of it may be made.
  final bool refundSinceMoveOut;

  /// Not made because the contract's record of it was not this press's to
  /// take ([MoveOutCardRefund.claim]): another press had taken it
  /// ([CardRefundClaim.claimed]) or recorded it ([CardRefundClaim.settled]),
  /// or the contract could not be read ([CardRefundClaim.unknown]). Null
  /// when it was this press's.
  final CardRefundClaim? notClaimed;

  /// Not made because a refund reached the ledger first
  /// ([refundSinceOffer], [refundSinceMoveOut]).
  bool get refundLandedFirst => refundSinceOffer || refundSinceMoveOut;

  double get refunded => MoveOutCardRefund.cents(refunds.fold(0.0, (total, r) => total + r.amount));
  double get leftOnLedger => MoveOutCardRefund.cents(requested - refunded);

  CardRefundStatus get status => leftOnLedger <= 0
      ? CardRefundStatus.refunded
      : refunded > 0
          ? CardRefundStatus.partial
          : CardRefundStatus.notMade;

  bool get _unconfirmed => failure != null && uncertain;

  /// The heading for [ownerAlert]. Not "not made" when the call that failed
  /// may still have refunded, or when a refund reached the ledger first, or
  /// another press had it: an owner who reads only the heading would refund
  /// it again.
  String? get alertTitle => switch (status) {
        CardRefundStatus.refunded => null,
        _ when refundLandedFirst || notClaimed != null => MoveOutCardRefund.mayAlreadyBeMade,
        CardRefundStatus.partial when _unconfirmed => 'Card refund only partly confirmed',
        CardRefundStatus.notMade when _unconfirmed => 'Card refund not confirmed',
        CardRefundStatus.partial => 'Card refund only partly made',
        CardRefundStatus.notMade => 'Card refund not made',
      };

  /// For the owner once the move-out is done, when not all of it was
  /// refunded: what happened and what to do, in words that stay on screen
  /// until they close them. Null when it was all refunded.
  ///
  /// It never tells them to record a refund they find in Stripe. processRefund
  /// could hand back an earlier refund (another unit's move-out, the same
  /// amount on the same payment) as this one, and "if a refund already shows
  /// there, only record it" then recorded a refund never made. A refund the
  /// app or Stripe did make is on the ledger already, as a "Refund for charge
  /// …" row, so that is where they look before adding one.
  String? get ownerAlert {
    if (status == CardRefundStatus.refunded) return null;
    if (refundSinceOffer) {
      return MoveOutCardRefund.pendingAlert(requested, reason: MoveOutCardRefund._refundSinceOffer);
    }
    if (refundSinceMoveOut) return MoveOutCardRefund._refundSinceMoveOutAlert(requested);
    if (notClaimed != null) {
      return 'The move-out is done, but the app did not refund the ${MoveOutCardRefund.money(requested)} to '
          'their card, rather than risk refunding it twice: $failure\n\n'
          '${MoveOutCardRefund._finishSteps(requested)}';
    }
    final left = MoveOutCardRefund.money(leftOnLedger);
    final other = refunded > 0 ? 'other ' : '';
    final done = refunded > 0
        ? 'The app refunded ${MoveOutCardRefund.money(refunded)} to their card through Stripe. '
        : '';
    final besides = refunded > 0 ? ' besides the refunds above' : '';
    if (knownRefundId != null) {
      // The refund Stripe handed back may be this move-out's, made by an
      // earlier press, or (from a processRefund that keys by charge and
      // amount) another unit's: the ledger says which rows are new.
      return '${done}No new refund was made for the $other$left: Stripe answered with a refund that '
          'is already on their ledger ($knownRefundId).\n\n'
          'It stays on their ledger as a credit. Before refunding anything by hand, look at their '
          'ledger for "Refund for charge …" rows from the move-out on$besides. Whatever of the $left '
          'they do not cover is still owed (a row you have already counted for another move-out does '
          'not cover this one): refund that to their card in your Stripe dashboard. Wait a minute, then '
          'look at their ledger again: Stripe records some card refunds there itself, as a new "Refund '
          'for charge …" row. Only if none has appeared, record it with Add entry, type Refund.';
    }
    if (_unconfirmed) {
      return '${done}The $other$left may not have been refunded: $failure\n\n'
          'It stays on their ledger as a credit. The call that failed may still have refunded their '
          'card, so check before refunding anything: wait a minute, then look at their ledger for a '
          '"Refund for charge …" row from today$besides. '
          'If there is one, that refund was made and is already recorded: take it off the $left, and '
          'do not record it again. Then refund what is still owed to their card in your Stripe '
          'dashboard, wait a minute, and look at their ledger again: Stripe records some card refunds '
          'there itself, as a new "Refund for charge …" row. Only if none has appeared, record it with '
          'Add entry, type Refund.';
    }
    if (failure != null) {
      return '${done}The $other$left was not refunded: $failure\n\n'
          'It stays on their ledger as a credit. To refund it: ${MoveOutCardRefund.refundSteps(left)}';
    }
    final why = noRefundablePayment || refunded == 0
        ? 'The app found no card payment from this tenant that it can refund (only payments '
            'made online through your Stripe account and recorded on their ledger can be), '
            'so nothing was refunded to their card. '
        : 'Their card payments the app can refund came to ${MoveOutCardRefund.money(refunded)}. ';
    return '$done$why'
        'The $other$left stays on their ledger as a credit.\n\n'
        'To refund it: ${MoveOutCardRefund.refundSteps(left)}';
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
/// type Refund, unless Stripe has recorded it ([refundSteps]). Before this,
/// the move-out told the owner Stripe's webhook would record a refund they
/// made in Stripe, which it does not for an online move-in payment (no
/// tenantId on its PaymentIntent) or a checkout-link payment (no metadata
/// on it at all).
class MoveOutCardRefund {
  static double cents(double value) => (value * 100).round() / 100;

  static String money(double value) => '\$${value.toStringAsFixed(2)}';

  /// What the owner does with [amount] the app did not refund: refund it in
  /// Stripe, then record it only if Stripe has not. Stripe's charge.refunded
  /// webhook records a refund made in the dashboard on the tenant's ledger
  /// itself when the payment names the tenant (autopay, a saved card, the
  /// portal), and an Add entry on top of that counted it twice; for an
  /// online move-in or a checkout-link payment it does not.
  static String refundSteps(String amount) =>
      'refund $amount to their card in your Stripe dashboard. Wait a minute, then look at their '
      'ledger: Stripe records some card refunds there itself, as a new "Refund for charge …" row '
      'for that amount. Only if none has appeared, record it with Add entry, type Refund, amount $amount.';

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
  /// refund by the request id this sends ([requestId]); a server from before
  /// that keys it by charge and amount, so a second refund of the same
  /// amount on the same charge within a day (another unit's move-out) came
  /// back as the first. Either way an id already here means nothing new was
  /// refunded.
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

  /// "$30.00 to their card payment of Sep 3, 2026, $5.00 to a card payment":
  /// where each refund of [plan] goes.
  static String _refundParts(CardRefundPlan plan) {
    final dates = DateFormat('MMM d, yyyy');
    String payment(CardRefundSlice s) =>
        s.paidOn == null ? 'a card payment' : 'their card payment of ${dates.format(s.paidOn!)}';
    return [for (final s in plan.slices) '${money(s.amount)} to ${payment(s)}'].join(', ');
  }

  static String _uncovered(CardRefundPlan plan) => plan.uncovered <= 0
      ? ''
      : ' Their card payments cannot take the other ${money(plan.uncovered)}: it stays on '
          'their ledger as a credit for you to refund in Stripe.';

  /// What the move-out screen says under the refund method before the owner
  /// completes: what the app will refund to their card, and what it cannot.
  static String preview(CardRefundPlan plan) {
    if (plan.slices.isEmpty) {
      return 'The app found no card payment from this tenant that it can refund. '
          'The ${money(plan.requested)} will stay on their ledger as a credit: refund it in your '
          'Stripe dashboard, and record it on their ledger (Add entry, type Refund) if Stripe has '
          'not recorded it there within a minute.';
    }
    return 'When you complete the move-out, the app refunds ${_refundParts(plan)} through Stripe.'
        '${_uncovered(plan)}';
  }

  /// Whether the app may offer to make a [pending] refund now, from the
  /// tenant's posted ledger [rows]: only when no refund has reached the
  /// ledger since the move-out ([pending]'s since). One that has may be part
  /// of this refund, made by a press that never reported back, and refunding
  /// the whole amount again would pay it twice. Stripe forgets a request id
  /// after a day, so the same id alone does not rule that out. Any refund
  /// row counts, one naming no Stripe payment too: an Add entry refund has
  /// none, and it is the row the app's alerts ask the owner to add after
  /// refunding in Stripe. Without a time, nothing is offered. The first
  /// press's refund is checked the same way ([refund]'s since).
  @visibleForTesting
  static bool mayOfferPending(PendingCardRefund pending, Iterable<Map<String, dynamic>> rows) {
    final since = pending.since;
    if (since == null) return false;
    for (final row in rows) {
      if (row['type'] != 'refund' || !_posted(row)) continue;
      final at = _date(row['createdAt']) ?? _date(row['entryDate']);
      if (at == null || !at.isBefore(since)) return false;
    }
    return true;
  }

  /// The heading of an alert for a card refund the app did not make
  /// because part of it may be made already. "Card refund not made", read
  /// on its own, sends the owner to refund it again.
  static const mayAlreadyBeMade = 'Card refund may already be made';

  /// A pending refund the app does not make: [title], the [alert] saying how
  /// the owner finishes it in Stripe, and [reason], why, which
  /// [recordLeftToOwner] writes on the contract unless it is not [recorded].
  static PendingCardRefundChoice _leftToOwner(
    PendingCardRefund pending, {
    required String title,
    required String reason,
    bool recorded = true,
  }) =>
      (
        plan: null,
        title: title,
        alert: pendingAlert(pending.requested, reason: reason),
        reason: recorded ? reason : null,
      );

  /// What the screen offers for a [pending] refund, from the tenant's posted
  /// ledger [rows]: the [plan] the app would make now, or, when it should not
  /// make one ([mayOfferPending], or no card payment to refund), the [alert]
  /// saying how the owner finishes it in Stripe, under [title]. A refund the
  /// ledger may show part of is titled [mayAlreadyBeMade], as the alert at
  /// the press is: its body says part may be made, but the heading is what
  /// an owner who skims reads.
  @visibleForTesting
  static PendingCardRefundChoice pendingChoiceFrom(
    PendingCardRefund pending,
    Iterable<Map<String, dynamic>> rows,
  ) {
    if (!mayOfferPending(pending, rows)) {
      return _leftToOwner(
        pending,
        title: mayAlreadyBeMade,
        reason: 'A refund has reached their ledger since the move-out, or the app cannot tell '
            'whether one has, so part of it may already be made, and the app will not refund it on '
            'its own.',
      );
    }
    final plan = MoveOutCardRefund.plan(amount: pending.requested, payments: refundablePayments(rows));
    if (plan.slices.isEmpty) {
      return _leftToOwner(
        pending,
        title: 'Card refund not made',
        reason: 'The app found no card payment from this tenant that it can refund.',
      );
    }
    return (plan: plan, title: null, alert: null, reason: null);
  }

  /// [pendingChoiceFrom] on the tenant's ledger as it is now. A ledger that
  /// cannot be read is not offered, and not recorded either: recorded as
  /// left to the owner, a backend blip made it a refund they make by hand
  /// for good, where left 'pending' a later press checks again.
  static Future<PendingCardRefundChoice> pendingChoice({
    required String facilityId,
    required String tenantId,
    required PendingCardRefund pending,
    FirebaseFirestore? firestore,
  }) async {
    try {
      final rows = await postedLedgerRows(facilityId: facilityId, tenantId: tenantId, firestore: firestore);
      return pendingChoiceFrom(pending, rows);
    } catch (e) {
      return _leftToOwner(
        pending,
        title: mayAlreadyBeMade,
        reason: 'The app could not read their ledger ($e), so it cannot tell whether part of it has '
            'been made.',
        recorded: false,
      );
    }
  }

  /// The screen's question for a pending refund it can make: what happened,
  /// and what the app would refund now ([plan]) if the owner says so.
  static String pendingOffer(CardRefundPlan plan) =>
      'This move-out was completed earlier, but its ${money(plan.requested)} card refund was not '
      'made: the answer to the first press never reached the app, so it did not refund the card, and '
      'no refund has reached their ledger since.\n\n'
      'The app can make it now: it refunds ${_refundParts(plan)} through Stripe.${_uncovered(plan)}';

  /// For a pending refund the app does not make: what happened, [reason]
  /// (why it is not offered), and how the owner finishes it in Stripe.
  static String pendingAlert(double requested, {String? reason}) =>
      'This move-out was completed earlier, but the app has no record that its ${money(requested)} '
      'card refund was made: most likely the answer to the first press never reached the app. '
      '${reason == null ? '' : '$reason '}Nothing was refunded just now.\n\n'
      '${_finishSteps(requested)}';

  /// How the owner finishes a card refund of [requested] that the app did
  /// not make and that part of may be made already. Any refund row from the
  /// move-out on stops the app making it ([mayOfferPending]): an Add entry
  /// refund, carrying the owner's own words, or another unit's "Move-out
  /// refund", as much as a "Refund for charge …" row. So they are sent to
  /// all of them, and told that a row they have counted for another
  /// move-out is not this one's: taken for this one, a refund still owed
  /// was never made.
  static String _finishSteps(double requested) =>
      'To finish it: look at their ledger for refund rows from the move-out on: "Refund for charge …" '
      'rows, and any you added with Add entry. Whatever of the ${money(requested)} they do not cover is '
      'still owed (a row you have already counted for another move-out does not cover this one): refund '
      'that to their card in your Stripe dashboard. Wait a minute, then look at their ledger again: '
      'Stripe records some card refunds there itself, as a new "Refund for charge …" row. Only if none '
      'has appeared, record it with Add entry, type Refund.';

  /// [pendingAlert]'s reason when a refund reached the ledger between the
  /// offer and the press ([CardRefundOutcome.refundSinceOffer]).
  static const _refundSinceOffer = 'A refund has reached their ledger since the app offered to make '
      'it: another press of Complete, on this device or another, may have made it.';

  /// For a first press's refund not made because a refund reached the
  /// ledger after the move-out was committed
  /// ([CardRefundOutcome.refundSinceMoveOut]).
  static String _refundSinceMoveOutAlert(double requested) =>
      'The move-out is done, but the app did not refund the ${money(requested)} to their card: a '
      'refund reached their ledger after the move-out was completed and before the app made this one. '
      'Another press of Complete, on this device or another, may have made it, so the app made none '
      'rather than refund it twice.\n\n'
      '${_finishSteps(requested)}';

  /// Why a press made no refund, from what it [found] on the contract
  /// ([claim]; [error], when it could not read it).
  static String _notClaimedReason(CardRefundClaim found, [Object? error]) => switch (found) {
        CardRefundClaim.claimed => 'another press of Complete, on this device or another, has taken this '
            'refund to make it and has not yet recorded what it did. It may be making it right now, so wait a '
            'minute before you look at their ledger.',
        CardRefundClaim.settled => 'another press of Complete, on this device or another, has dealt with this '
            'refund since: it may have made it, or left it to you to make in Stripe.',
        _ => 'the app could not check its record of this refund on the contract'
            '${error == null ? '' : ' ($error)'}, so it cannot tell whether another press of Complete has '
            'made it.',
      };

  /// What the screen shows in place of its own alert when a pending refund
  /// it went to leave to the owner ([recordLeftToOwner]) was another
  /// press's ([CardRefundClaim.claimed], [CardRefundClaim.settled]): that
  /// alert says to refund it in Stripe, and the other press may have made
  /// it. Null when the record was this press's, or could not be read.
  static ({String title, String alert})? takenAlert(CardRefundClaim found, double requested) =>
      found == CardRefundClaim.claimed || found == CardRefundClaim.settled
          ? (
              title: mayAlreadyBeMade,
              alert: 'Before you refund the ${money(requested)} yourself: ${_notClaimedReason(found)}\n\n'
                  '${_finishSteps(requested)}',
            )
          : null;

  /// processRefund's per-refund request id (letters, digits, _ and -, at
  /// most 64): the same for a retry of this move-out's refund of this
  /// payment, so it cannot be made twice, and different for another
  /// move-out's. processRefund servers that do not read it ignore it.
  @visibleForTesting
  static String requestId(String contractId, String paymentIntentId) {
    final raw = 'mo_${contractId}_$paymentIntentId'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return raw.length <= 64 ? raw : raw.substring(0, 64);
  }

  /// The refund of [slice] that a call which failed made after all: a posted
  /// refund row in [rows] (the ledger read again) against its PaymentIntent,
  /// for its amount, whose Stripe refund id was not on the ledger before
  /// ([known]). processRefund writes that row once Stripe has refunded, so a
  /// timeout or a dropped answer after it still left the refund made. Null
  /// when there is none.
  static CardRefundMade? landedRefund(
    Iterable<Map<String, dynamic>> rows, {
    required CardRefundSlice slice,
    required Set<String> known,
  }) {
    for (final row in rows) {
      if (row['type'] != 'refund' || !_posted(row)) continue;
      if (paymentIntentOf(row) != slice.paymentIntentId) continue;
      final id = _refundId(row);
      if (id == null || known.contains(id)) continue;
      final amount = _amount(row['amount']);
      if (amount == null || cents(amount.abs()) != cents(slice.amount)) continue;
      return (paymentIntentId: slice.paymentIntentId, stripeRefundId: id, amount: slice.amount);
    }
    return null;
  }

  /// What a processRefund call that failed with [error] said, for the owner.
  /// Shared with the ledger's card refund (ledger_card_refund.dart).
  static String failureText(Object error) {
    if (error is FirebaseFunctionsException) {
      final message = error.message?.trim();
      return message != null && message.isNotEmpty ? message : error.code;
    }
    return '$error';
  }

  /// Whether a call that failed with [error] may still have refunded. Only
  /// a refusal before processRefund reaches Stripe rules it out: signed
  /// out, App Check, its rate limit, a bad request, or no callable to run.
  /// Everything it answers after that, its "No refund was issued" included,
  /// comes back 'internal', and a refund Stripe made whose ledger row then
  /// failed to write comes back that way too. Its own facility and
  /// permission checks run inside that catch, so they come back 'internal'
  /// as well. Shared with the ledger's card refund.
  static bool mayHaveRefunded(Object error) =>
      error is! FirebaseFunctionsException ||
      !const {
        'unauthenticated',
        'failed-precondition',
        'resource-exhausted',
        'invalid-argument',
        'permission-denied',
        'not-found',
      }.contains(error.code);

  /// Makes [amount] of refund to the tenant's card through [call]
  /// (processRefund), against the payments in [rows] (their posted ledger).
  /// A call that fails is checked against the ledger read again ([reread]):
  /// a refund it made after all ([landedRefund]) counts as made. Otherwise
  /// it stops there and refunds nothing more: a call that timed out may
  /// still have refunded, and refunding the next payment as well would pay
  /// the tenant twice.
  ///
  /// [since] is when processMoveOut committed the move-out: its
  /// `cardRefundSince` for the first press, the pending record's time for
  /// a refund offered later. With it, the refund is made only if
  /// [mayOfferPending] holds on [rows], the read the plan is made from. A
  /// refund that reached the ledger since then (another press of Complete,
  /// made while the first press waited for its answer, or while an offer
  /// was open) leaves the plan putting the rest on another payment, or at
  /// another amount, under another request id, which Stripe refunds a
  /// second time. [offered] marks a pending refund the owner was offered on
  /// an earlier read ([pendingChoice]): that one is never made without
  /// [since]. A first press with neither (answered by a processMoveOut from
  /// before `cardRefundSince`) skips this ledger check, as it did before;
  /// the contract is still checked ([refundAfterMoveOut]'s [claim]).
  static Future<CardRefundOutcome> refund({
    required String facilityId,
    required String tenantId,
    required String contractId,
    required double amount,
    required List<Map<String, dynamic>> rows,
    required ProcessRefundCall call,
    Future<List<Map<String, dynamic>>> Function()? reread,
    DateTime? since,
    bool offered = false,
  }) async {
    if ((since != null || offered) && !mayOfferPending((requested: cents(amount), since: since), rows)) {
      return CardRefundOutcome(
        requested: cents(amount),
        failure: offered
            ? 'a refund reached their ledger after the app offered to make this one, so it made none.'
            : 'a refund reached their ledger after the move-out was completed, so it made none.',
        refundSinceOffer: offered,
        refundSinceMoveOut: !offered,
      );
    }
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
      } catch (e) {
        CardRefundMade? landed;
        if (reread != null) {
          try {
            landed = landedRefund(await reread(), slice: slice, known: known);
          } catch (_) {
            landed = null;
          }
        }
        if (landed != null) {
          known.add(landed.stripeRefundId);
          made.add(landed);
          continue;
        }
        return CardRefundOutcome(
          requested: plan.requested,
          refunds: made,
          failure: failureText(e),
          uncertain: mayHaveRefunded(e),
        );
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
          failure: 'no new refund was made: Stripe answered with a refund already on their ledger '
              '($refundId).',
          knownRefundId: refundId,
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

  /// processRefund (functions-integrations), called. Shared with the
  /// ledger's card refund.
  static Future<Map<String, dynamic>> callProcessRefund(Map<String, dynamic> payload) async {
    final result = await FirebaseFunctions.instance.httpsCallable('processRefund').call<dynamic>(payload);
    final data = result.data;
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  /// Makes the card refund and records it: takes the contract's pending
  /// record of it ([claim]), reads the tenant's ledger, calls processRefund
  /// ([refund], which reads the ledger again after a call that fails), then
  /// writes the outcome to the contract (`moveOutCardRefund`, and
  /// `moveOutRefund` as what was refunded) and the audit log. Never throws:
  /// the move-out is done by now, so anything that goes wrong is the owner's
  /// to finish, and they are told. Nothing is refunded unless the record was
  /// this press's to take: another press may have made it, or left it to the
  /// owner, and neither shows on the ledger in time. [since] is when the
  /// move-out was committed: the first press's refund, and a pending one a
  /// second press makes ([offered]), is not made when a refund has reached
  /// the ledger since ([refund]). The second press goes through here with
  /// the same [contractId], so its processRefund request ids are the ones
  /// the first press would have sent. [readLedger], [call] and [firestore]
  /// are for tests.
  static Future<CardRefundOutcome> refundAfterMoveOut({
    required String facilityId,
    required String tenantId,
    required String contractId,
    required double amount,
    DateTime? since,
    bool offered = false,
    Future<List<Map<String, dynamic>>> Function()? readLedger,
    ProcessRefundCall? call,
    FirebaseFirestore? firestore,
  }) async {
    final read = readLedger ??
        () => postedLedgerRows(facilityId: facilityId, tenantId: tenantId, firestore: firestore);
    final taken = await claim(facilityId: facilityId, contractId: contractId, firestore: firestore);
    CardRefundOutcome outcome;
    if (taken.found != CardRefundClaim.ours) {
      outcome = CardRefundOutcome.notClaimedAs(cents(amount), taken.found, error: taken.error);
    } else {
      try {
        outcome = await refund(
          facilityId: facilityId,
          tenantId: tenantId,
          contractId: contractId,
          amount: amount,
          rows: await read(),
          call: call ?? callProcessRefund,
          reread: read,
          since: since,
          offered: offered,
        );
      } catch (e) {
        outcome = CardRefundOutcome(
          requested: cents(amount),
          failure: "the app could not read the tenant's payments ($e).",
        );
      }
    }
    await record(
      facilityId: facilityId,
      tenantId: tenantId,
      contractId: contractId,
      outcome: outcome,
      claimId: taken.id,
      firestore: firestore,
    );
    return outcome;
  }

  static final _random = Random.secure();

  /// Takes the contract's pending card refund record for this press before
  /// it makes the refund. In a transaction, it is marked with a `claim` only
  /// this press holds ([id]) if it is still 'pending' and no other press
  /// has taken it ([CardRefundClaim.ours]); otherwise this says what it
  /// found, and the press makes nothing. The ledger alone could not tell: a
  /// second session that chose "Refund it in Stripe myself", or was shown a
  /// blocked offer, records 'manual' and leaves nothing on the ledger, and a
  /// first press whose answer arrived after that refunded the card the
  /// owner had just been told to refund by hand. The record stays 'pending'
  /// while taken, so processMoveOut still sends it back to a later press: a
  /// press that stops before recording what it did leaves it taken, and the
  /// later press is told another press may have made it, not nothing.
  static Future<({CardRefundClaim found, String? id, Object? error})> claim({
    required String facilityId,
    required String contractId,
    FirebaseFirestore? firestore,
  }) async {
    final id = List.generate(20, (_) => _random.nextInt(36).toRadixString(36)).join();
    try {
      final db = firestore ?? FirebaseFirestore.instance;
      final contract = _contract(db, facilityId, contractId);
      final found = await db.runTransaction((transaction) async {
        final found = claimFound((await transaction.get(contract)).data());
        if (found == CardRefundClaim.ours) {
          transaction.update(contract, {
            'moveOutCardRefund.claim': {'id': id, 'at': FieldValue.serverTimestamp(), 'by': _uid()},
          });
        }
        return found;
      });
      return (found: found, id: found == CardRefundClaim.ours ? id : null, error: null);
    } catch (e) {
      if (kDebugMode) print('⚠️ [MoveOut] Card refund not taken on the contract: $e');
      return (found: CardRefundClaim.unknown, id: null, error: e);
    }
  }

  /// What a press holding [claimId] (null: none) finds on the contract, read
  /// as [contract]: [CardRefundClaim.ours] when its card refund record is
  /// still 'pending' and taken by no press but this one.
  @visibleForTesting
  static CardRefundClaim claimFound(Map<String, dynamic>? contract, {String? claimId}) {
    if (!stillPending(contract)) return CardRefundClaim.settled;
    final claim = (contract!['moveOutCardRefund'] as Map)['claim'];
    final holder = claim is Map ? claim['id'] : null;
    return holder == claimId ? CardRefundClaim.ours : CardRefundClaim.claimed;
  }

  /// Writes [outcome] to the contract and the audit log, best effort. The
  /// contract is written only by the press holding [claimId] ([claim]), and
  /// only while it is still 'pending' ([writeRecord]): a press that never
  /// took it writes nothing there, so a refund another press made, or left
  /// to the owner, is not written over as not made, and one this press
  /// could not take (its contract unread) stays 'pending' for a later press.
  static Future<void> record({
    required String facilityId,
    required String tenantId,
    required String contractId,
    required CardRefundOutcome outcome,
    String? claimId,
    FirebaseFirestore? firestore,
  }) async {
    final details = outcome.contractRecord();
    final found = claimId == null
        ? null
        : await writeRecord(
            facilityId: facilityId,
            contractId: contractId,
            details: details,
            refunded: outcome.refunded,
            claimId: claimId,
            firestore: firestore,
          );
    await _audit(
      facilityId: facilityId,
      tenantId: tenantId,
      contractId: contractId,
      details: details,
      recorded: found == CardRefundClaim.ours,
    );
  }

  static const _ownerChose = 'the owner chose to refund it in Stripe themselves';

  /// The contract's `moveOutCardRefund` once a pending refund is left to
  /// the owner to make in Stripe: they chose to, or the app would not
  /// ([reason], [pendingChoiceFrom]). No longer 'pending', so a later press
  /// of Complete does not offer it, or show its alert, again
  /// (processMoveOut sends back only a 'pending' one).
  @visibleForTesting
  static Map<String, dynamic> leftToOwnerRecord(double requested, {String reason = _ownerChose}) => {
        'status': 'manual',
        'requested': cents(requested),
        'refunded': 0.0,
        'leftOnLedger': cents(requested),
        'refunds': const <Map<String, dynamic>>[],
        'reason': reason,
      };

  /// Records on the contract and the audit log that a pending refund of
  /// [requested] is left to the owner to make in Stripe
  /// ([leftToOwnerRecord]), best effort. Written to the contract only while
  /// it is still 'pending' and no press has taken it ([writeRecord]): a
  /// refund another press made, or is making, is not written over as left
  /// undone. Returns what it found ([CardRefundClaim.ours]: written); for
  /// another press's, the screen shows [takenAlert].
  static Future<CardRefundClaim> recordLeftToOwner({
    required String facilityId,
    required String tenantId,
    required String contractId,
    required double requested,
    String? reason,
    FirebaseFirestore? firestore,
  }) async {
    final details = leftToOwnerRecord(requested, reason: reason ?? _ownerChose);
    final found = await writeRecord(
      facilityId: facilityId,
      contractId: contractId,
      details: details,
      refunded: 0,
      firestore: firestore,
    );
    await _audit(
      facilityId: facilityId,
      tenantId: tenantId,
      contractId: contractId,
      details: details,
      recorded: found == CardRefundClaim.ours,
    );
    return found;
  }

  /// Whether the contract's card refund record, read as [contract], is still
  /// the 'pending' processMoveOut left.
  @visibleForTesting
  static bool stillPending(Map<String, dynamic>? contract) {
    final record = contract?['moveOutCardRefund'];
    return record is Map && record['status'] == 'pending';
  }

  /// Writes [details] as the contract's card refund record, in a
  /// transaction, only if [claimFound] finds it this press's: still
  /// 'pending', and taken by no press, or by the one holding [claimId].
  /// Every write of the record goes through here, so a press's 'refunded'
  /// is never written over as not made, and a refund one press is making is
  /// never written over as left to the owner. Returns what it found
  /// ([CardRefundClaim.ours]: written).
  @visibleForTesting
  static Future<CardRefundClaim> writeRecord({
    required String facilityId,
    required String contractId,
    required Map<String, dynamic> details,
    required double refunded,
    String? claimId,
    FirebaseFirestore? firestore,
  }) async {
    try {
      final db = firestore ?? FirebaseFirestore.instance;
      final contract = _contract(db, facilityId, contractId);
      return await db.runTransaction((transaction) async {
        final found = claimFound((await transaction.get(contract)).data(), claimId: claimId);
        if (found == CardRefundClaim.ours) {
          transaction.update(contract, {
            'moveOutCardRefund': {
              ...details,
              'recordedAt': FieldValue.serverTimestamp(),
              'recordedBy': _uid(),
            },
            'moveOutRefund': refunded,
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        return found;
      });
    } catch (e) {
      if (kDebugMode) print('⚠️ [MoveOut] Card refund not recorded on the contract: $e');
      return CardRefundClaim.unknown;
    }
  }

  static DocumentReference<Map<String, dynamic>> _contract(
    FirebaseFirestore firestore,
    String facilityId,
    String contractId,
  ) =>
      firestore.collection('facilities').doc(facilityId).collection('contracts').doc(contractId);

  /// The signed-in user, or null (none, or no Firebase app, as in tests).
  static String? _uid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  /// [details] in the audit log, with whether the contract was written
  /// ([recorded]): a press that found the record another press's logs what
  /// it did without changing the contract.
  static Future<void> _audit({
    required String facilityId,
    required String tenantId,
    required String contractId,
    required Map<String, dynamic> details,
    required bool recorded,
  }) =>
      AuditService.logEvent(
        facilityId: facilityId,
        eventType: 'moveout.cardRefund',
        targetType: 'moveOut',
        targetId: contractId,
        tenantId: tenantId,
        after: {...details, 'recordedOnContract': recorded},
      );
}
