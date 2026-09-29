import 'dart:math';

import 'package:flutter/material.dart';

import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/security_deposit_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/security_deposit_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

String _money(double v) => '\$${v.toStringAsFixed(2)}';

String _day(DateTime d) => '${d.month}/${d.day}/${d.year}';

/// What the Security deposit dialog hands back: a save, or Remove.
sealed class SecurityDepositEdit {
  const SecurityDepositEdit();
}

class SecurityDepositSave extends SecurityDepositEdit {
  const SecurityDepositSave({
    required this.amount,
    required this.receivedDate,
    required this.method,
    required this.reference,
    required this.note,
  });

  final double amount;

  /// Null when the owner cleared the date: received, date unknown.
  final DateTime? receivedDate;
  final PaymentMethod method;
  final String? reference;
  final String? note;
}

class SecurityDepositRemove extends SecurityDepositEdit {
  const SecurityDepositRemove();
}

/// The "Security deposit" dialog behind the pencil on the tenant page's
/// Security Deposit row: records the deposit the facility holds, or corrects
/// the one on file. It only collects; [editSecurityDeposit] saves.
class SecurityDepositDialog extends StatefulWidget {
  const SecurityDepositDialog({
    super.key,
    this.current,
    this.defaultAmount,
    this.defaultReceivedDate,
    this.today,
  });

  /// The deposit on file, when correcting one.
  final SecurityDeposit? current;

  /// The facility's usual deposit, prefilled when nothing is on file.
  final double? defaultAmount;

  /// The tenant's move-in date, the usual day a deposit is taken.
  final DateTime? defaultReceivedDate;

  /// For tests; the clock otherwise.
  final DateTime? today;

  @override
  State<SecurityDepositDialog> createState() => _SecurityDepositDialogState();
}

class _SecurityDepositDialogState extends State<SecurityDepositDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _reference;
  late final TextEditingController _note;
  late PaymentMethod _method;
  DateTime? _receivedDate;

  DateTime get _today => widget.today ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    final amount = current?.amount ?? widget.defaultAmount;
    _amount = TextEditingController(
        text: amount == null ? '' : amount.toStringAsFixed(2));
    _reference = TextEditingController(text: current?.reference ?? '');
    _note = TextEditingController(text: current?.note ?? '');
    _method = current?.method ?? PaymentMethod.cash;
    // A deposit on file keeps its date (unknown stays unknown); a new one
    // starts at move-in, or today when no move-in date was ever saved.
    _receivedDate = current != null
        ? current.receivedDate
        : (widget.defaultReceivedDate ?? _today);
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final initial = _receivedDate ?? _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(_today) ? _today : initial,
      firstDate: DateTime(2000),
      lastDate: _today,
      helpText: 'Date received',
    );
    if (picked == null) return;
    setState(() => _receivedDate = picked);
  }

  String? _amountProblem(String? value) {
    final parsed = double.tryParse((value ?? '').trim());
    if (parsed == null || parsed <= 0) return 'Enter an amount above \$0.';
    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final reference = _reference.text.trim();
    final note = _note.text.trim();
    Navigator.of(context).pop(SecurityDepositSave(
      amount: double.parse(_amount.text.trim()),
      receivedDate: _receivedDate,
      method: _method,
      reference: reference.isEmpty ? null : reference,
      note: note.isEmpty ? null : note,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final canRemove = widget.current?.isHeld == true;
    return AlertDialog(
      title: const Text('Security deposit'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Money the facility holds for the tenant. It is kept off '
                  'the ledger, so it does not change the balance or the '
                  'statement until it is settled.',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('security-deposit-amount'),
                  controller: _amount,
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixText: '\$ ',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  validator: _amountProblem,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                ),
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Date received',
                    border: const OutlineInputBorder(),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_receivedDate != null)
                          IconButton(
                            tooltip: 'Date unknown',
                            icon: const Icon(Icons.clear),
                            onPressed: () =>
                                setState(() => _receivedDate = null),
                          ),
                        IconButton(
                          tooltip: 'Pick date',
                          icon: const Icon(Icons.calendar_today_outlined),
                          onPressed: _pickDate,
                        ),
                      ],
                    ),
                  ),
                  child: InkWell(
                    onTap: _pickDate,
                    child: Text(
                      _receivedDate == null
                          ? 'Unknown'
                          : _day(_receivedDate!),
                      key: const Key('security-deposit-date'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<PaymentMethod>(
                  key: const Key('security-deposit-method'),
                  initialValue: _method,
                  decoration: const InputDecoration(
                    labelText: 'Method',
                    border: OutlineInputBorder(),
                  ),
                  items: manualPaymentMethods
                      .map((m) => DropdownMenuItem(
                          value: m, child: Text(m.displayName)))
                      .toList(),
                  onChanged: (m) =>
                      setState(() => _method = m ?? PaymentMethod.cash),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('security-deposit-reference'),
                  controller: _reference,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Check or reference #',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('security-deposit-note'),
                  controller: _note,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Note',
                    hintText: 'e.g. Covers Units 6 and 7',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (canRemove)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(const SecurityDepositRemove()),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Remove'),
          ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// What the Settle dialog hands back.
class SecurityDepositSettlement {
  const SecurityDepositSettlement({
    required this.appliedAmount,
    required this.refundedAmount,
    required this.refundMethod,
    required this.refundReference,
  });

  final double appliedAmount;
  final double refundedAmount;
  final PaymentMethod? refundMethod;
  final String? refundReference;
}

/// How a held deposit splits by default: against what the tenant owes first
/// (never more than the deposit, never against a credit balance), the rest
/// back to the tenant.
({double applied, double refunded}) defaultDepositSplit(
    SecurityDeposit deposit, double balance) {
  final applied =
      SecurityDeposit.toCents(min(deposit.amount, max(balance, 0.0)));
  return (
    applied: applied,
    refunded: SecurityDeposit.toCents(deposit.amount - applied),
  );
}

/// The "Settle security deposit" dialog: how much of the held deposit goes
/// against the balance and how much back to the tenant. It only collects;
/// [settleSecurityDeposit] writes.
class SettleSecurityDepositDialog extends StatefulWidget {
  const SettleSecurityDepositDialog({
    super.key,
    required this.deposit,
    required this.balance,
  });

  final SecurityDeposit deposit;

  /// The tenant's ledger balance now (LedgerService.getLedgerBalance).
  final double balance;

  @override
  State<SettleSecurityDepositDialog> createState() =>
      _SettleSecurityDepositDialogState();
}

class _SettleSecurityDepositDialogState
    extends State<SettleSecurityDepositDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _applied;
  late final TextEditingController _refunded;
  late final TextEditingController _refundReference;
  PaymentMethod _refundMethod = PaymentMethod.cash;

  @override
  void initState() {
    super.initState();
    final split = defaultDepositSplit(widget.deposit, widget.balance);
    _applied = TextEditingController(text: split.applied.toStringAsFixed(2));
    _refunded =
        TextEditingController(text: split.refunded.toStringAsFixed(2));
    _refundReference = TextEditingController();
  }

  @override
  void dispose() {
    _applied.dispose();
    _refunded.dispose();
    _refundReference.dispose();
    super.dispose();
  }

  double? _parsed(TextEditingController c) =>
      double.tryParse(c.text.trim());

  /// Typing one side fills in the other, so the two always add up unless
  /// the owner overrides both.
  void _balanceFrom(TextEditingController edited, TextEditingController other) {
    final value = _parsed(edited);
    if (value == null || value < 0 || value > widget.deposit.amount) {
      setState(() {});
      return;
    }
    other.text =
        SecurityDeposit.toCents(widget.deposit.amount - value).toStringAsFixed(2);
    setState(() {});
  }

  String? _problem() {
    final applied = _parsed(_applied);
    final refunded = _parsed(_refunded);
    if (applied == null || refunded == null) return 'Enter both amounts.';
    if (applied < 0 || refunded < 0) return 'Amounts cannot be negative.';
    final sum = (applied * 100).round() + (refunded * 100).round();
    if (sum != (widget.deposit.amount * 100).round()) {
      return 'The two amounts must add up to ${_money(widget.deposit.amount)}.';
    }
    return null;
  }

  void _settle() {
    if (_problem() != null) return;
    final refunded = _parsed(_refunded)!;
    final reference = _refundReference.text.trim();
    Navigator.of(context).pop(SecurityDepositSettlement(
      appliedAmount: _parsed(_applied)!,
      refundedAmount: refunded,
      refundMethod: refunded > 0 ? _refundMethod : null,
      refundReference: refunded > 0 && reference.isNotEmpty ? reference : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem();
    final refunding = (_parsed(_refunded) ?? 0) > 0;
    final balance = widget.balance;
    return AlertDialog(
      title: const Text('Settle security deposit'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Deposit held: ${_money(widget.deposit.amount)}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  balance > 0
                      ? 'Current balance: ${_money(balance)} owed'
                      : balance < 0
                          ? 'Current balance: ${_money(balance.abs())} credit'
                          : 'Current balance: \$0.00',
                  key: const Key('settle-deposit-balance'),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('settle-deposit-applied'),
                  controller: _applied,
                  decoration: const InputDecoration(
                    labelText: 'Apply to balance (\$)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => _balanceFrom(_applied, _refunded),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('settle-deposit-refunded'),
                  controller: _refunded,
                  decoration: const InputDecoration(
                    labelText: 'Refund to tenant (\$)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => _balanceFrom(_refunded, _applied),
                ),
                if (refunding) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<PaymentMethod>(
                    key: const Key('settle-deposit-refund-method'),
                    initialValue: _refundMethod,
                    decoration: const InputDecoration(
                      labelText: 'Refund method',
                      border: OutlineInputBorder(),
                    ),
                    items: manualPaymentMethods
                        .map((m) => DropdownMenuItem(
                            value: m, child: Text(m.displayName)))
                        .toList(),
                    onChanged: (m) => setState(
                        () => _refundMethod = m ?? PaymentMethod.cash),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('settle-deposit-refund-reference'),
                    controller: _refundReference,
                    maxLength: 100,
                    decoration: const InputDecoration(
                      labelText: 'Refund check or reference #',
                      counterText: '',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Applying posts a credit on the ledger; the refund is '
                  'recorded here, not on the ledger.',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                if (problem != null) ...[
                  const SizedBox(height: 8),
                  Text(problem,
                      key: const Key('settle-deposit-problem'),
                      style: const TextStyle(color: AppTheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: problem == null ? _settle : null,
          child: const Text('Settle'),
        ),
      ],
    );
  }
}

void _snack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? AppTheme.error : AppTheme.success,
    duration: Duration(seconds: error ? 8 : 4),
  ));
}

String _errorText(Object e) => e is SecurityDepositException
    ? e.message
    : ErrorMessageHelper.getUserFriendlyMessage(e);

/// Opens the Security deposit dialog for [tenant] and saves what comes
/// back. [defaultAmount] is the facility's usual deposit
/// (SecurityDeposit.facilityDefault).
Future<void> editSecurityDeposit(
  BuildContext context,
  TenantModel tenant, {
  double? defaultAmount,
}) async {
  final edit = await showDialog<SecurityDepositEdit>(
    context: context,
    builder: (_) => SecurityDepositDialog(
      current: tenant.securityDeposit,
      defaultAmount: defaultAmount,
      defaultReceivedDate: tenant.moveInDate,
    ),
  );
  if (edit == null || !context.mounted) return;
  try {
    switch (edit) {
      case SecurityDepositSave():
        final saved = await SecurityDepositService.record(
          facilityId: tenant.facilityId,
          tenantId: tenant.id,
          amount: edit.amount,
          receivedDate: edit.receivedDate,
          method: edit.method,
          reference: edit.reference,
          note: edit.note,
        );
        if (!context.mounted) return;
        _snack(context, 'Security deposit saved: ${saved.summary}');
      case SecurityDepositRemove():
        await SecurityDepositService.remove(
          facilityId: tenant.facilityId,
          tenantId: tenant.id,
        );
        if (!context.mounted) return;
        _snack(context, 'Security deposit removed.');
    }
  } catch (e) {
    if (!context.mounted) return;
    _snack(context, "Couldn't save the security deposit: ${_errorText(e)}",
        error: true);
  }
}

/// Reads the tenant's balance, opens the Settle dialog and settles the held
/// deposit with what comes back.
Future<void> settleSecurityDeposit(
    BuildContext context, TenantModel tenant) async {
  final deposit = tenant.securityDeposit;
  if (deposit == null || !deposit.isHeld) return;
  double balance;
  try {
    balance = await LedgerService.getLedgerBalance(
      tenantId: tenant.id,
      facilityId: tenant.facilityId,
    );
  } catch (e) {
    if (!context.mounted) return;
    _snack(context, "Couldn't read the balance: ${_errorText(e)}",
        error: true);
    return;
  }
  if (!context.mounted) return;
  final settlement = await showDialog<SecurityDepositSettlement>(
    context: context,
    builder: (_) =>
        SettleSecurityDepositDialog(deposit: deposit, balance: balance),
  );
  if (settlement == null || !context.mounted) return;
  try {
    final settled = await SecurityDepositService.settle(
      facilityId: tenant.facilityId,
      tenantId: tenant.id,
      appliedAmount: settlement.appliedAmount,
      refundedAmount: settlement.refundedAmount,
      refundMethod: settlement.refundMethod,
      refundReference: settlement.refundReference,
    );
    if (!context.mounted) return;
    _snack(context, settled.summary);
  } catch (e) {
    if (!context.mounted) return;
    _snack(context, "Couldn't settle the security deposit: ${_errorText(e)}",
        error: true);
  }
}
