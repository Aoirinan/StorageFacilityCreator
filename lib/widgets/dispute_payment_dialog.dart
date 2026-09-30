import 'package:flutter/material.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// How staff take the money for a lost card dispute.
enum DisputePaymentWay {
  /// Cash, check, Venmo, Zelle, bank transfer or other: recorded as received
  /// today through PaymentService.recordManualPayment.
  byHand,

  /// The tenant's saved card, through the chargeTenantOffSession callable.
  cardOnFile,

  /// A public payment link the tenant pays later (createPublicPaymentLink).
  paymentLink,
}

/// What the dialog returns: [method] is only read for [DisputePaymentWay.byHand].
/// [tenantConsent] is true only for the card on file, once staff have
/// confirmed the tenant agreed; it is sent to chargeTenantOffSession, which
/// refuses a dispute charge without it.
typedef DisputePaymentEntry = ({
  DisputePaymentWay way,
  double amount,
  PaymentMethod method,
  String? reference,
  String? notes,
  bool tenantConsent,
});

/// Stripe's smallest card charge; the callable refuses less.
const double _minimumCardCharge = 0.5;

/// Stripe's dispute reason when the cardholder says they never made the charge.
const String fraudulentDisputeReason = 'fraudulent';

/// Why the card on file is not offered for a fraud dispute.
const String fraudDisputeCardNote =
    'The card on file is not offered: the cardholder told their bank they did '
    'not make this charge. Take it by cash or check, or send a payment link '
    'the tenant pays themselves.';

/// What staff confirm before the card on file is charged for a dispute.
const String cardConsentLabel = 'The tenant has agreed to this charge on their card';

/// The Ledger's "Record payment for this dispute".
///
/// Every way staff could collect a lost dispute (cash, the card on file, a
/// payment link) used to post an ordinary payment, which counted as rent
/// while the dispute stayed in the disputed part of the balance: autopay and
/// the delinquency job then treated next month's rent as paid. Each way here
/// carries the dispute's id, so the payment nets against the dispute. The
/// amount is capped at what the dispute still has out ([outstanding]).
///
/// Charging the card on file again needs the cardholder's fresh consent, so
/// staff tick that the tenant agreed, and the confirmation goes to the
/// server, which refuses the charge without it and keeps it on the
/// PaymentIntent and in the audit log. For a `fraudulent` dispute
/// ([disputeReason]) it is not offered at all (the server refuses it too).
/// The amount cap is checked by the server as well: by hand through
/// recordDisputePaymentByHand, the card and the link by their callables.
class DisputePaymentDialog extends StatefulWidget {
  final double outstanding;
  final bool hasCardOnFile;

  /// Stripe's reason for the dispute (the dispute row's `metadata.reason`).
  final String? disputeReason;

  const DisputePaymentDialog({
    super.key,
    required this.outstanding,
    required this.hasCardOnFile,
    this.disputeReason,
  });

  @override
  State<DisputePaymentDialog> createState() => _DisputePaymentDialogState();
}

class _DisputePaymentDialogState extends State<DisputePaymentDialog> {
  late final TextEditingController _amountController =
      TextEditingController(text: widget.outstanding.toStringAsFixed(2));
  final _referenceController = TextEditingController();
  final _notesController = TextEditingController();

  DisputePaymentWay _way = DisputePaymentWay.byHand;

  /// The method recorded when [_way] is by hand.
  PaymentMethod _method = PaymentMethod.cash;
  String? _error;

  /// Staff confirmed the tenant agreed to the card charge.
  bool _cardConsent = false;

  bool get _fraudDispute => widget.disputeReason == fraudulentDisputeReason;

  bool get _cardOnFileOffered => widget.hasCardOnFile && !_fraudDispute;

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  String? _trimmed(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
  }

  /// The dropdown's value: 'card', 'link', or a manual method's name.
  String get _choice => switch (_way) {
        DisputePaymentWay.cardOnFile => 'card',
        DisputePaymentWay.paymentLink => 'link',
        DisputePaymentWay.byHand => _method.name,
      };

  void _choose(String? value) {
    setState(() {
      _error = null;
      if (value == 'card') {
        _way = DisputePaymentWay.cardOnFile;
      } else if (value == 'link') {
        _way = DisputePaymentWay.paymentLink;
      } else {
        _way = DisputePaymentWay.byHand;
        _method = manualPaymentMethods.firstWhere((m) => m.name == value, orElse: () => PaymentMethod.cash);
      }
    });
  }

  void _submit() {
    final amount = double.tryParse(_amountController.text.trim());
    final cents = amount == null ? null : (amount * 100).round() / 100;
    String? error;
    if (cents == null || cents < 0.01) {
      error = 'Enter the amount received.';
    } else if (cents > widget.outstanding) {
      // More would sit against the dispute as a credit no rent is set against.
      error = 'This dispute has \$${widget.outstanding.toStringAsFixed(2)} left to collect.';
    } else if (_way == DisputePaymentWay.cardOnFile && cents < _minimumCardCharge) {
      error = 'A card charge must be at least \$0.50.';
    } else if (_way == DisputePaymentWay.cardOnFile && !_cardConsent) {
      error = 'Confirm the tenant agreed to this card charge.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop<DisputePaymentEntry>(context, (
      way: _way,
      amount: cents!,
      method: _method,
      reference: _way == DisputePaymentWay.byHand ? _trimmed(_referenceController) : null,
      notes: _trimmed(_notesController),
      tenantConsent: _way == DisputePaymentWay.cardOnFile && _cardConsent,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textTertiary);
    return AlertDialog(
      title: const Text('Record payment for this dispute'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('\$${widget.outstanding.toStringAsFixed(2)} of this card dispute is still to collect.'),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('dispute-payment-amount'),
              controller: _amountController,
              decoration: InputDecoration(
                labelText: 'Amount (\$)',
                prefixText: '\$ ',
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const ValueKey('dispute-payment-method'),
              initialValue: _choice,
              decoration: const InputDecoration(
                labelText: 'How it is paid',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final m in manualPaymentMethods)
                  DropdownMenuItem(value: m.name, child: Text(m.displayName)),
                if (_cardOnFileOffered)
                  const DropdownMenuItem(value: 'card', child: Text('Charge card on file')),
                const DropdownMenuItem(value: 'link', child: Text('Send a payment link')),
              ],
              onChanged: _choose,
            ),
            if (widget.hasCardOnFile && _fraudDispute) ...[
              const SizedBox(height: 8),
              Text(fraudDisputeCardNote, style: muted),
            ],
            if (_way == DisputePaymentWay.cardOnFile)
              CheckboxListTile(
                key: const ValueKey('dispute-card-consent'),
                value: _cardConsent,
                onChanged: (v) => setState(() {
                  _cardConsent = v ?? false;
                  _error = null;
                }),
                title: const Text(cardConsentLabel),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            if (_way == DisputePaymentWay.byHand) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _referenceController,
                decoration: const InputDecoration(
                  labelText: 'Check # / reference (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLength: 100,
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            Text(
              'Booked against this dispute, not as rent: autopay still charges '
              'the rent and paid-through does not move. Collect it only once '
              'the dispute is lost; if the facility wins, Stripe returns the '
              'money and the tenant will have paid twice.',
              style: muted,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _submit,
          child: Text(switch (_way) {
            DisputePaymentWay.byHand => 'Record payment',
            DisputePaymentWay.cardOnFile => 'Charge card',
            DisputePaymentWay.paymentLink => 'Create link',
          }),
        ),
      ],
    );
  }
}
