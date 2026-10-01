import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/services/ledger_card_refund.dart';
import 'package:sfcapp/services/move_out_card_refund.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Makes one press of the dialog's refund: [amount] under the dialog's one
/// [requestId], with the owner's [note] (null when they left none).
typedef CardRefundPress = Future<LedgerCardRefundOutcome> Function(
  double amount,
  String requestId,
  String? note,
);

/// What the dialog adds to an unconfirmed refund's message while it is open.
const String cardRefundRetryNote =
    'Try again repeats this same refund, so it cannot refund the card twice.';

/// The ledger's Refund on a card payment row ([LedgerCardRefund]).
///
/// The amount starts at what is left to refund on the payment and can be
/// lowered for a partial refund, never raised past that. The owner reviews
/// it and confirms before anything is sent. The refund is made with the
/// dialog still open ([onRefund]), under one request id made when it opens,
/// so pressing again after a failure is the same Stripe refund, and the
/// dialog closes on its own only once it is refunded. A press that may have
/// refunded but cannot be confirmed locks the amount: a retry at another
/// amount would be another refund.
///
/// The confirm names the payment, not the card's last four digits: the
/// ledger row does not record which card paid, and the tenant's card on file
/// may be another one.
class CardRefundDialog extends StatefulWidget {
  const CardRefundDialog({
    super.key,
    required this.payment,
    required this.onRefund,
    this.unconfirmedEarlier,
  });

  final LedgerCardPayment payment;
  final CardRefundPress onRefund;

  /// A refund of this payment pressed earlier, in another dialog, that was
  /// not confirmed. This dialog's request id is a new one, so the owner is
  /// asked to check before refunding again.
  final double? unconfirmedEarlier;

  @override
  State<CardRefundDialog> createState() => _CardRefundDialogState();
}

class _CardRefundDialogState extends State<CardRefundDialog> {
  late final TextEditingController _amountController =
      TextEditingController(text: widget.payment.left.toStringAsFixed(2));
  final _noteController = TextEditingController();

  /// One id for every press of this dialog.
  final String _requestId = LedgerCardRefund.newRequestId();

  /// The owner has reviewed the amount and is asked to confirm it.
  bool _confirming = false;

  /// A press is in flight.
  bool _busy = false;

  String? _amountError;

  /// The amount reviewed, in cents.
  double? _amount;

  /// The last press's outcome, when it was not refunded or not confirmed.
  LedgerCardRefundOutcome? _last;

  /// The last press may have refunded: the amount stays as it was.
  bool get _locked => _last?.status == LedgerCardRefundStatus.unconfirmed;

  String get _money => MoveOutCardRefund.money(_amount ?? 0);

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _review() {
    final text = _amountController.text.trim().replaceAll(r'$', '').replaceAll(',', '');
    final parsed = double.tryParse(text);
    final cents = parsed == null || !parsed.isFinite ? null : MoveOutCardRefund.cents(parsed);
    final left = widget.payment.left;
    final String? error;
    if (cents == null || cents < 0.01) {
      error = 'Enter the amount to refund.';
    } else if (cents > left) {
      error = 'At most ${MoveOutCardRefund.money(left)} is left to refund on this payment.';
    } else {
      error = null;
    }
    setState(() {
      _amountError = error;
      if (error == null) {
        _amount = cents;
        _confirming = true;
      }
    });
  }

  String? get _note {
    final note = _noteController.text.trim();
    return note.isEmpty ? null : note;
  }

  Future<void> _refund() async {
    final amount = _amount;
    if (_busy || amount == null) return;
    setState(() => _busy = true);
    LedgerCardRefundOutcome outcome;
    try {
      outcome = await widget.onRefund(amount, _requestId, _note);
    } catch (e) {
      // [LedgerCardRefund.refund] never throws; anything else that does
      // cannot say the card was not refunded.
      outcome = LedgerCardRefundOutcome.unconfirmed(amount, '$e');
    }
    if (!mounted) return;
    if (outcome.status == LedgerCardRefundStatus.refunded) {
      Navigator.pop<LedgerCardRefundOutcome>(context, outcome);
      return;
    }
    setState(() {
      _busy = false;
      _last = outcome;
    });
  }

  void _close() => Navigator.pop<LedgerCardRefundOutcome>(context, _last);

  @override
  Widget build(BuildContext context) {
    // The system or browser back closes it as Close does, with the last
    // outcome, so an unconfirmed refund is not dropped on the way out; not
    // while a press is in flight.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _close();
      },
      child: AlertDialog(
        title: const Text('Refund card payment'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _confirming ? _confirmContent(context) : _formContent(context),
          ),
        ),
        actions: _confirming ? _confirmActions() : _formActions(),
      ),
    );
  }

  String get _paidOn => DateFormat('MMM d, yyyy').format(widget.payment.paidOn);

  List<Widget> _formContent(BuildContext context) {
    final p = widget.payment;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textTertiary);
    final earlier = widget.unconfirmedEarlier;
    return [
      Text('Paid ${MoveOutCardRefund.money(p.paid)} by card on $_paidOn.'),
      if (p.alreadyRefunded > 0) ...[
        const SizedBox(height: 4),
        Text('${MoveOutCardRefund.money(p.alreadyRefunded)} of it is already refunded on this ledger.'),
      ],
      const SizedBox(height: 4),
      Text('Up to ${MoveOutCardRefund.money(p.left)} can be refunded to their card.'),
      if (earlier != null) ...[
        const SizedBox(height: 12),
        Text(
          'A refund of ${MoveOutCardRefund.money(earlier)} on this payment was not confirmed '
          'earlier. Before refunding again, look at this ledger for a new "Refund for charge …" '
          'row, and find this payment in your Stripe dashboard to see whether it shows a refund.',
          key: const ValueKey('card-refund-unconfirmed-earlier'),
          style: TextStyle(color: AppTheme.warning, fontWeight: FontWeight.w600),
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('card-refund-amount'),
        controller: _amountController,
        decoration: InputDecoration(
          labelText: 'Amount to refund',
          prefixText: '\$ ',
          border: const OutlineInputBorder(),
          errorText: _amountError,
          errorMaxLines: 3,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('card-refund-note'),
        controller: _noteController,
        decoration: const InputDecoration(
          labelText: 'Reason or note (optional)',
          border: OutlineInputBorder(),
        ),
        maxLength: 200,
        maxLines: 2,
      ),
      Text(
        'The refund goes back through Stripe to the card that made this payment. '
        'The note is kept with it in the audit log.',
        style: muted,
      ),
    ];
  }

  List<Widget> _formActions() => [
        TextButton(onPressed: _close, child: const Text('Cancel')),
        ElevatedButton(
          key: const ValueKey('card-refund-review'),
          onPressed: _review,
          child: const Text('Review refund'),
        ),
      ];

  List<Widget> _confirmContent(BuildContext context) {
    final theme = Theme.of(context);
    final last = _last;
    final note = _note;
    return [
      Text(
        'Refund $_money to their card?',
        key: const ValueKey('card-refund-question'),
        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Text(
        'It goes back to the card that paid ${MoveOutCardRefund.money(widget.payment.paid)} on '
        '$_paidOn. A refund cannot be undone.',
      ),
      if (note != null) ...[
        const SizedBox(height: 8),
        Text('Note: $note', style: theme.textTheme.bodySmall),
      ],
      if (_busy) ...[
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        const Text('Refunding…'),
      ] else if (last != null) ...[
        const SizedBox(height: 16),
        Text(
          _locked ? '${last.ownerMessage}\n\n$cardRefundRetryNote' : last.ownerMessage ?? '',
          key: const ValueKey('card-refund-message'),
          style: TextStyle(
            color: _locked ? AppTheme.warning : AppTheme.error,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ];
  }

  List<Widget> _confirmActions() {
    final last = _last;
    return [
      // Not once a press may have refunded: the amount is locked. After a
      // refusal nothing was refunded, so the owner may change it.
      if (!_locked)
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _confirming = false;
                    _last = null;
                  }),
          child: const Text('Back'),
        ),
      TextButton(
        onPressed: _busy ? null : _close,
        child: Text(_locked ? 'Close' : 'Cancel'),
      ),
      if (last == null || last.retryable)
        ElevatedButton(
          key: const ValueKey('card-refund-confirm'),
          onPressed: _busy ? null : _refund,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.error,
            foregroundColor: AppTheme.textOnDark,
          ),
          child: Text(last == null ? 'Refund $_money' : 'Try again'),
        ),
    ];
  }
}
