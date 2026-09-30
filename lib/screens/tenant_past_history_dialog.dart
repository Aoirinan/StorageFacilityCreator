import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/providers/payment_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/past_history_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/past_history_math.dart';

/// Opens Enter past history for [tenant]: for an owner moving from a paper
/// ledger, the rent owed and payments received before today, saved with
/// their real dates so the balance and paid-through date come out right.
///
/// [fromLedger] is true when opened on the tenant's ledger, so the result
/// dialog does not offer to open the page the owner is already on.
Future<void> showTenantPastHistoryDialog(
  BuildContext context,
  TenantModel tenant, {
  bool fromLedger = false,
}) async {
  final result = await showDialog<PastHistoryResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => TenantPastHistoryDialog(tenant: tenant),
  );
  if (result == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => PastHistorySavedDialog(
      result: result,
      onOpenLedger: fromLedger
          ? null
          : () {
              Navigator.of(dialogContext).pop();
              context.push(
                AppRoute.tenantLedgerFor(tenantId: tenant.id, facilityId: tenant.facilityId),
                extra: tenant,
              );
            },
    ),
  );
}

String _money(double v) => v < 0 ? '(\$${v.abs().toStringAsFixed(2)})' : '\$${v.toStringAsFixed(2)}';

String _day(DateTime d) => '${d.month}/${d.day}/${d.year}';

class _PaymentRow {
  _PaymentRow({String date = '', String amount = ''})
      : date = TextEditingController(text: date),
        amount = TextEditingController(text: amount);

  PaymentMethod method = PaymentMethod.cash;
  final TextEditingController date;
  final TextEditingController amount;
  final TextEditingController reference = TextEditingController();
  final TextEditingController note = TextEditingController();

  double? get parsedAmount => double.tryParse(amount.text.trim());
  ({DateTime date, bool monthOnly})? get parsedDate => parseHistoryDateInput(date.text);

  HistoryPaymentInput? toInput() {
    final d = parsedDate;
    if (d == null) return null;
    return HistoryPaymentInput(
      date: d.date,
      monthOnly: d.monthOnly,
      amount: parsedAmount ?? 0,
      method: method,
      reference: reference.text,
      note: note.text,
    );
  }

  void dispose() {
    date.dispose();
    amount.dispose();
    reference.dispose();
    note.dispose();
  }
}

class TenantPastHistoryDialog extends ConsumerStatefulWidget {
  const TenantPastHistoryDialog({super.key, required this.tenant, this.today});

  final TenantModel tenant;

  /// For tests; the clock otherwise.
  final DateTime? today;

  @override
  ConsumerState<TenantPastHistoryDialog> createState() => _TenantPastHistoryDialogState();
}

class _TenantPastHistoryDialogState extends ConsumerState<TenantPastHistoryDialog> {
  /// This save's id. A retry of an unchanged save reuses it (the server
  /// answers with what the first attempt saved); any edit after a failed or
  /// timed-out save takes a new one, since the server refuses a changed
  /// request under an old id.
  String _requestId = PastHistoryService.newRequestId();

  /// Ids of saves that failed or timed out. One may have gone through
  /// anyway; before saving again the ledger is checked for them.
  final Set<String> _unconfirmedIds = {};
  bool _lastSaveFailed = false;

  /// The owner's paid-through choice, when they made one (else the default).
  PaidThroughChoice? _choice;
  HistoryPreview? _preview;
  List<LedgerEntry> _ledger = const [];

  /// Invoice numbers by id, for entries being voided.
  final Map<String, String> _invoiceNumbers = {};

  /// Asked for, never guessed: imported tenants have none, and the unit's or
  /// the record's date is the day they were typed in.
  DateTime? _moveIn;
  List<ProposedHistoryCharge> _charges = [];
  final List<TextEditingController> _chargeAmounts = [];
  ({int year, int month})? _stoppedBefore;
  final List<_PaymentRow> _payments = [];

  /// Existing entries ticked to void in the same save. None by default.
  final Set<String> _voiding = {};
  bool _showExisting = false;
  bool _confirmed = false;
  bool _saving = false;
  String? _error;

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  @override
  void dispose() {
    for (final c in _chargeAmounts) {
      c.dispose();
    }
    for (final p in _payments) {
      p.dispose();
    }
    super.dispose();
  }

  /// Lists the months again (after the move-in date or the entries to void
  /// change), keeping what the owner already changed on months still listed.
  void _propose(List<LedgerEntry> ledger) {
    final moveIn = _moveIn;
    if (moveIn == null) return;
    final kept = {for (final c in _charges) '${c.year}-${c.month}': c};
    final proposal = proposeHistoryCharges(
      moveIn: moveIn,
      monthlyRate: widget.tenant.monthlyRate,
      existing: ledger.where((e) => !_voiding.contains(e.id)).toList(),
      today: _today,
    );
    for (final c in proposal.charges) {
      final before = kept['${c.year}-${c.month}'];
      if (before != null && before.day == c.day) {
        c.amount = before.amount;
        c.included = before.included;
      }
    }
    for (final c in _chargeAmounts) {
      c.dispose();
    }
    _chargeAmounts
      ..clear()
      ..addAll([for (final c in proposal.charges) TextEditingController(text: c.amount.toStringAsFixed(2))]);
    _charges = proposal.charges;
    _stoppedBefore = proposal.stoppedBefore;
  }

  Future<void> _pickMoveIn(List<LedgerEntry> ledger) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _moveIn ?? _today,
      firstDate: DateTime(2000),
      lastDate: _today,
      helpText: 'Move-in date',
    );
    if (picked == null) return;
    setState(() {
      _moveIn = picked;
      _propose(ledger);
      _edited();
    });
  }

  Future<void> _pickPaymentDate(_PaymentRow row) async {
    final current = row.parsedDate?.date;
    final picked = await showDatePicker(
      context: context,
      initialDate: current == null || current.isAfter(_today) ? _today : current,
      firstDate: DateTime(2000),
      lastDate: _today,
      helpText: 'Date received',
    );
    if (picked == null) return;
    setState(() {
      row.date.text = formatHistoryDateInput(picked);
      _edited();
    });
  }

  void _addPayment() {
    setState(() {
      _payments.add(_PaymentRow(
        amount: widget.tenant.monthlyRate > 0 ? widget.tenant.monthlyRate.toStringAsFixed(2) : '',
      ));
      _edited();
    });
  }

  void _toggleVoid(List<LedgerEntry> ledger, String id, bool on) {
    setState(() {
      if (on) {
        _voiding.add(id);
      } else {
        _voiding.remove(id);
      }
      _propose(ledger);
      _edited();
    });
  }

  /// Called inside setState for every change to the form: the owner must
  /// confirm again, and after a failed save the next one gets a new id.
  void _edited() {
    _confirmed = false;
    if (_lastSaveFailed) {
      _unconfirmedIds.add(_requestId);
      _requestId = PastHistoryService.newRequestId();
      _lastSaveFailed = false;
    }
  }

  /// Why Save is off, or null when it may be pressed.
  String? _problem() {
    final included = _charges.where((c) => c.included).toList();
    if (_moveIn == null) return 'Choose the move-in date.';
    if (included.isEmpty && _payments.isEmpty && _voiding.isEmpty) {
      return 'Add at least one month of rent or one payment.';
    }
    for (final c in included) {
      if (c.amount <= 0) return '${c.label}: enter an amount, or untick the month.';
    }
    for (var i = 0; i < _payments.length; i++) {
      final d = _payments[i].parsedDate;
      if (d == null) return 'Payment ${i + 1}: enter the date received, like 6/1/2026 or 6/2026.';
      if (d.date.isAfter(_today)) return 'Payment ${i + 1}: the date is in the future.';
      if (d.date.isBefore(DateTime(2000))) return 'Payment ${i + 1}: dates before 2000 are not allowed.';
      final a = _payments[i].parsedAmount;
      if (a == null || a <= 0) return 'Payment ${i + 1}: enter the amount received.';
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving || !_confirmed || _problem() != null) return;
    // A save that failed or timed out may have gone through after all. If
    // it did, its entries are on the (live) ledger: saving the edited
    // version as well would enter the history twice.
    final landed = postedHistoryBatches(_ledger).map((b) => b.requestId).toSet();
    if (_unconfirmedIds.any(landed.contains)) {
      setState(() => _error =
          'Your earlier save went through after all. Close this, check the Ledger, and use '
          '"Undo this history entry" there if it needs changing.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await PastHistoryService.record(
        facilityId: widget.tenant.facilityId,
        tenantId: widget.tenant.id,
        requestId: _requestId,
        charges: _charges,
        payments: _payments.map((p) => p.toInput()!).toList(),
        moveInDate: _moveIn,
        voidLedgerEntryIds: _voiding.toList(),
        paidThroughChoice: _preview?.choice,
      );
      ref.invalidate(facilityTenantsProvider(widget.tenant.facilityId));
      ref.invalidate(paymentListProvider(widget.tenant.facilityId));
      ref.invalidate(paymentStatsProvider(widget.tenant.facilityId));
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = ErrorMessageHelper.getUserFriendlyMessage(e);
          _lastSaveFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _loadInvoiceNumbers(List<String> ids) {
    final missing = ids.where((id) => !_invoiceNumbers.containsKey(id)).toList();
    if (missing.isEmpty) return;
    for (final id in missing) {
      _invoiceNumbers[id] = id;
    }
    PastHistoryService.invoiceNumbers(widget.tenant.facilityId, missing).then((numbers) {
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < missing.length; i++) {
          _invoiceNumbers[missing[i]] = numbers[i];
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final ledgerAsync = ref.watch(ledgerStreamProvider(
      LedgerParams(tenantId: widget.tenant.id, facilityId: widget.tenant.facilityId),
    ));
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;

    Widget body;
    String? problem;
    if (ledgerAsync.hasError) {
      body = Text('Could not read this tenant\'s ledger: ${ErrorMessageHelper.getUserFriendlyMessage(ledgerAsync.error!)}');
      problem = 'The ledger could not be read.';
    } else if (!ledgerAsync.hasValue) {
      body = const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
      problem = 'Loading…';
    } else {
      final ledger = ledgerAsync.value!;
      final preview = computeHistoryPreview(
        existing: ledger,
        charges: _charges,
        payments: _payments.map((p) => p.toInput()).whereType<HistoryPaymentInput>().toList(),
        existingPaidThrough: widget.tenant.paidThrough,
        voiding: _voiding,
        monthlyRate: widget.tenant.monthlyRate,
        choice: _choice,
      );
      _ledger = ledger;
      _preview = preview;
      if (preview.invoiceIds.isNotEmpty) _loadInvoiceNumbers(preview.invoiceIds);
      body = _buildForm(context, ledger, preview);
      problem = _problem();
    }

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 860, maxHeight: size.height * 0.92),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Enter past history', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.tenant.name}${widget.tenant.unitNumber.isNotEmpty ? ' · Unit ${widget.tenant.unitNumber}' : ''}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: body,
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_error!, style: const TextStyle(color: AppTheme.error)),
                    ),
                  CheckboxListTile(
                    value: _confirmed,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: _saving ? null : (v) => setState(() => _confirmed = v ?? false),
                    title: const Text('I checked these months, amounts and dates against my records'),
                  ),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      TextButton(
                        onPressed: _saving ? null : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      FilledButton.icon(
                        onPressed: _saving || !_confirmed || problem != null ? null : _save,
                        icon: _saving
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.save_outlined, size: 18),
                        label: Text(_saving ? 'Saving…' : 'Save history'),
                      ),
                    ],
                  ),
                  if (problem != null && problem != 'Loading…')
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(problem, textAlign: TextAlign.end, style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textTertiary)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, List<LedgerEntry> ledger, HistoryPreview preview) {
    final theme = Theme.of(context);
    final existing = ledger
        .where((e) => e.status == LedgerEntryStatus.posted && e.amount != 0)
        .toList()
      ..sort((a, b) => a.entryDate.compareTo(b.entryDate));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Enter the rent owed and the payments received before today, from your records. '
          'Each is saved with its own date, so the balance, paid-through date and statements come out right. '
          'Late fees are not added for past months.',
          style: theme.textTheme.bodyMedium,
        ),
        if (existing.isNotEmpty) ...[
          const SizedBox(height: 16),
          _buildExistingSection(context, ledger, existing),
        ],
        const SizedBox(height: 16),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _pickMoveIn(ledger),
              icon: const Icon(Icons.event, size: 18),
              label: Text(_moveIn == null ? 'Choose move-in date *' : 'Move-in date: ${_day(_moveIn!)}'),
            ),
            Text('Monthly rate: ${_money(widget.tenant.monthlyRate)}', style: theme.textTheme.bodyMedium),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'The monthly rate is the tenant\'s total for all their units. Saved on the tenant if no move-in date is set.',
            style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
          ),
        ),
        const SizedBox(height: 20),
        Text('1. Rent charges', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'One month of rent from the move-in month. Untick a month that was free; change an amount if it differed (a prorated first month, say).',
          style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
        ),
        if (_stoppedBefore != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Stops before ${historyMonthLabel(_stoppedBefore!.year, _stoppedBefore!.month)}, which already has rent on the ledger.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
            ),
          ),
        const SizedBox(height: 8),
        if (_moveIn == null)
          Text('Choose the move-in date to list the months.', style: theme.textTheme.bodySmall)
        else if (_charges.isEmpty)
          Text('No months to add: rent is already on the ledger from the move-in month.', style: theme.textTheme.bodySmall)
        else ...[
          for (var i = 0; i < _charges.length; i++) _buildChargeRow(i),
          // A person renting two units was entered at their combined rent on
          // a record whose rate was one unit's, and nothing said so. Above
          // the rate is that case and gets the warning. The other unit is
          // usually held by a duplicate record of the same person, so Assign
          // Tenant alone stops on "occupied": the copy names Unassign first,
          // and says what Unassign does to that copy (TenantService
          // .unassignUnit switches it off once it holds no unit; its ledger
          // stays). The rate only follows when it was the sum of the units
          // already held (rentAfterUnitChange); otherwise Assign shows a
          // "Check ... rent" notice and the owner sets it on Edit Tenant, so
          // the copy says both. Below the rate is what the helper text
          // invites (a rent raise, a discounted month), so it is only named,
          // in case of a slip. Saving goes ahead either way; the rate is
          // theirs to fix.
          for (final amount in historyAmountsOffRate(charges: _charges, monthlyRate: widget.tenant.monthlyRate))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: amount > widget.tenant.monthlyRate
                  ? Text(
                      '${_money(amount)} is more than this tenant\'s rate of ${_money(widget.tenant.monthlyRate)}. '
                      'Do they rent another unit? Add it to this tenant first: open the other unit (Units › Unit List). '
                      'If it shows a second copy of this tenant, choose Unassign Tenant there (that copy is switched off '
                      'once it holds no unit; anything already entered on it stays there), then Assign Tenant and pick '
                      'this tenant. Their rate becomes the total when it matched the rate of the unit they already hold; '
                      'otherwise you are asked to check it under Edit Tenant.',
                      style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
                    )
                  : Text(
                      '${_money(amount)} is not this tenant\'s rate of ${_money(widget.tenant.monthlyRate)}. '
                      'Fine if the rent was different then.',
                      style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                    ),
            ),
        ],
        const SizedBox(height: 20),
        Text('2. Payments received', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'One line per payment. Type the date received (6/1/2026), or just the month (6/2026) if that is all your records say; a month is dated the 1st.',
          style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _payments.length; i++) _buildPaymentRow(i),
        TextButton.icon(
          onPressed: _saving ? null : _addPayment,
          icon: const Icon(Icons.add),
          label: const Text('Add payment'),
        ),
        const SizedBox(height: 20),
        Text('3. Check before saving', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        PastHistoryPreviewCard(
          preview: preview,
          invoiceNumbers: [for (final id in preview.invoiceIds) _invoiceNumbers[id] ?? id],
          onChoice: _saving
              ? null
              : (c) => setState(() {
                    _choice = c;
                    _edited();
                  }),
        ),
      ],
    );
  }

  Widget _buildExistingSection(BuildContext context, List<LedgerEntry> ledger, List<LedgerEntry> existing) {
    final theme = Theme.of(context);
    final charges = existing.where((e) => e.amount > 0).toList();
    final payments = existing.where((e) => e.amount < 0).toList();
    final chargeTotal = charges.fold(0.0, (s, e) => s + e.amount);
    final paymentTotal = payments.fold(0.0, (s, e) => s - e.amount);
    final voidable = existing.where((e) => !isPastHistoryEntry(e)).toList();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This tenant already has ${charges.length} charge${charges.length == 1 ? '' : 's'} (${_money(chargeTotal)}) and '
            '${payments.length} payment${payments.length == 1 ? '' : 's'} (${_money(paymentTotal)}) entered.',
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'They count in the balance below. If some are this same history typed in by hand, tick them to void them '
            'in this save, so nothing is counted twice. Undo this history entry puts them back.',
            style: theme.textTheme.bodySmall,
          ),
          if (voidable.isNotEmpty)
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => setState(() => _showExisting = !_showExisting),
                  child: Text(_showExisting ? 'Hide entries' : 'Choose entries to void (${_voiding.length} ticked)'),
                ),
                if (_showExisting && _voiding.length < voidable.length)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                              _voiding.addAll(voidable.map((e) => e.id));
                              _propose(ledger);
                              _edited();
                            }),
                    child: Text('Tick all ${voidable.length}'),
                  ),
                if (_showExisting && _voiding.isNotEmpty)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                              _voiding.clear();
                              _propose(ledger);
                              _edited();
                            }),
                    child: const Text('Untick all'),
                  ),
              ],
            ),
          if (_showExisting)
            for (final e in voidable)
              CheckboxListTile(
                key: ValueKey('existing-${e.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _voiding.contains(e.id),
                onChanged: _saving ? null : (v) => _toggleVoid(ledger, e.id, v ?? false),
                title: Text('Void: ${e.description ?? e.typeDisplayName}'),
                subtitle: Text('${DateFormat('M/d/yyyy').format(e.entryDate)} · ${e.formattedAmount}'),
              ),
        ],
      ),
    );
  }

  Widget _buildChargeRow(int i) {
    final c = _charges[i];
    return Row(
      key: ValueKey('history-charge-${c.year}-${c.month}'),
      children: [
        Checkbox(
          value: c.included,
          onChanged: _saving
              ? null
              : (v) => setState(() {
                    c.included = v ?? false;
                    _edited();
                  }),
        ),
        Expanded(
          child: Text(
            i == 0 && c.day != 1 ? '${c.label} (from ${c.month}/${c.day})' : c.label,
            style: c.included ? null : const TextStyle(color: AppTheme.textTertiary, decoration: TextDecoration.lineThrough),
          ),
        ),
        SizedBox(
          width: 120,
          child: TextField(
            controller: _chargeAmounts[i],
            enabled: c.included && !_saving,
            decoration: const InputDecoration(prefixText: '\$ ', isDense: true, border: OutlineInputBorder()),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) => setState(() {
              c.amount = double.tryParse(v.trim()) ?? 0;
              _edited();
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildPaymentRow(int i) {
    final row = _payments[i];
    final parsed = row.parsedDate;
    return Padding(
      key: ObjectKey(row),
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 170,
            child: TextField(
              controller: row.date,
              enabled: !_saving,
              decoration: InputDecoration(
                labelText: 'Date received',
                hintText: '6/1/2026 or 6/2026',
                isDense: true,
                border: const OutlineInputBorder(),
                helperText: parsed?.monthOnly == true ? 'Month only: dated the 1st' : null,
                suffixIcon: IconButton(
                  tooltip: 'Pick a date',
                  icon: const Icon(Icons.calendar_today, size: 18),
                  onPressed: _saving ? null : () => _pickPaymentDate(row),
                ),
              ),
              onChanged: (_) => setState(_edited),
            ),
          ),
          SizedBox(
            width: 110,
            child: TextField(
              controller: row.amount,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Amount', prefixText: '\$ ', isDense: true, border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(_edited),
            ),
          ),
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<PaymentMethod>(
              initialValue: row.method,
              isDense: true,
              decoration: const InputDecoration(labelText: 'Method', isDense: true, border: OutlineInputBorder()),
              items: manualPaymentMethods
                  .map((m) => DropdownMenuItem(value: m, child: Text(m.displayName)))
                  .toList(),
              onChanged: _saving ? null : (m) => setState(() => row.method = m ?? PaymentMethod.cash),
            ),
          ),
          SizedBox(
            width: 150,
            child: TextField(
              controller: row.reference,
              enabled: !_saving,
              maxLength: 100,
              decoration: const InputDecoration(labelText: 'Check # / reference', isDense: true, counterText: '', border: OutlineInputBorder()),
            ),
          ),
          SizedBox(
            width: 180,
            child: TextField(
              controller: row.note,
              enabled: !_saving,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Note', isDense: true, counterText: '', border: OutlineInputBorder()),
            ),
          ),
          IconButton(
            tooltip: 'Remove payment',
            icon: const Icon(Icons.delete_outline),
            onPressed: _saving
                ? null
                : () => setState(() {
                      _payments.removeAt(i).dispose();
                      _edited();
                    }),
          ),
        ],
      ),
    );
  }
}

/// The totals the owner checks before saving.
class PastHistoryPreviewCard extends StatelessWidget {
  const PastHistoryPreviewCard({
    super.key,
    required this.preview,
    this.invoiceNumbers = const [],
    this.onChoice,
  });

  final HistoryPreview preview;

  /// Numbers of the invoices the entries being voided are on.
  final List<String> invoiceNumbers;

  /// Picks between the recomputed and the current paid-through date, when
  /// the recomputed one is earlier. Null hides the choice.
  final ValueChanged<PaidThroughChoice>? onChoice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(String label, String value, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        );
    final pt = preview.resultingPaidThrough;
    final unpaid = preview.firstUnpaidMonth;
    final hasExisting = preview.existingCharges + preview.existingPayments > 0;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row('Rent charges added', _money(preview.totalCharges)),
            row('Payments added', _money(preview.totalPayments)),
            if (hasExisting) ...[
              row(
                'Already on the ledger (kept): ${preview.existingCharges} charge${preview.existingCharges == 1 ? '' : 's'}',
                _money(preview.existingChargeTotal),
              ),
              row(
                'Already on the ledger (kept): ${preview.existingPayments} payment${preview.existingPayments == 1 ? '' : 's'}',
                _money(-preview.existingPaymentTotal),
              ),
            ],
            if (preview.voidedCount > 0)
              row('Existing entries voided by this save', '${preview.voidedCount}'),
            const Divider(),
            row(
              'Balance after saving',
              _money(preview.balance),
              color: preview.balance > 0 ? AppTheme.error : AppTheme.success,
            ),
            row('Paid through now', preview.paidThroughNow == null ? 'Not set' : _day(preview.paidThroughNow!)),
            row('Paid through after saving', pt == null ? 'Not set' : _day(pt)),
            if (preview.prepaidMonths > 0)
              Text(
                'Includes ${preview.prepaidMonths} month${preview.prepaidMonths == 1 ? '' : 's'} paid ahead from credit.',
                style: theme.textTheme.bodySmall,
              ),
            if (preview.recomputedIsEarlier && onChoice != null) ...[
              const SizedBox(height: 8),
              Text(
                'The history works out to paid through '
                '${preview.computedPaidThrough == null ? 'no month' : _day(preview.computedPaidThrough!)}, '
                'earlier than the ${_day(preview.paidThroughNow!)} set now'
                '${preview.voidsPayment ? ' (the payments being voided had moved it forward)' : ''}.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
              ),
              RadioGroup<PaidThroughChoice>(
                groupValue: preview.choice,
                onChanged: (c) {
                  if (c != null) onChoice!(c);
                },
                child: Column(
                  children: [
                    RadioListTile<PaidThroughChoice>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: PaidThroughChoice.computed,
                      title: Text(
                        'Use ${preview.computedPaidThrough == null ? 'not set' : _day(preview.computedPaidThrough!)} (from the ledger)',
                      ),
                    ),
                    RadioListTile<PaidThroughChoice>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: PaidThroughChoice.keepLater,
                      title: Text('Keep ${_day(preview.paidThroughNow!)}'),
                    ),
                  ],
                ),
              ),
            ],
            if (preview.credit > 0)
              row(
                unpaid == null
                    ? 'Credit on the account (less than a month)'
                    : 'Credit toward ${historyMonthLabel(unpaid.year, unpaid.month)}',
                _money(preview.credit),
              ),
            if (preview.voidsPayment) ...[
              const SizedBox(height: 8),
              Text(
                "The voided payments' rows in the tenant's Payment History are voided too. "
                'Any row that cannot be matched is named after saving, so you can check it.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (invoiceNumbers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'These entries were on invoice(s) ${invoiceNumbers.join(', ')}; open Invoices and void them '
                "so they don't show as unpaid.",
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
              ),
            ],
            if (preview.paidThroughWarning != null) ...[
              const SizedBox(height: 8),
              Text(preview.paidThroughWarning!, style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning)),
            ],
            if (hasExisting) ...[
              const SizedBox(height: 8),
              Text(
                'The balance includes the entries already on the ledger. If they are the same history, it is counted twice: '
                'tick them above to void them.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.warning),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Payments count toward rent first; fees and deposits still show in the balance. '
              'Late fees are not added for past months. Rent from next month on is added by the monthly rent run as usual.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown after saving: what was saved and where to print the statement.
class PastHistorySavedDialog extends StatelessWidget {
  const PastHistorySavedDialog({super.key, required this.result, this.onOpenLedger});

  final PastHistoryResult result;
  final VoidCallback? onOpenLedger;

  @override
  Widget build(BuildContext context) {
    final pt = result.paidThrough;
    return AlertDialog(
      title: Text(result.alreadyApplied ? 'History already saved' : 'Past history saved'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Balance: ${_money(result.balance)}'),
            Text('Paid through: ${pt == null ? 'Not set' : _day(pt)}'),
            if (result.credit > 0) Text('Credit: ${_money(result.credit)}'),
            if (result.existingVoided > 0) Text('Entries already on the ledger voided: ${result.existingVoided}'),
            if (result.moveInDateSaved) const Text('Move-in date saved on the tenant.'),
            if (result.paidThroughBefore != null &&
                (pt == null || !DateUtils.isSameDay(result.paidThroughBefore, pt)))
              Text('Paid through was ${_day(result.paidThroughBefore!)} before this save.'),
            for (final w in result.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(w, style: const TextStyle(color: AppTheme.warning)),
              ),
            const SizedBox(height: 12),
            const Text(
              'To mail this tenant a statement: open their Ledger, click the Statement '
              'button (the page icon at the top), then Print statement.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Entered something wrong? On the Ledger, use "Undo this history entry" and enter it again.',
            ),
          ],
        ),
      ),
      actions: [
        if (onOpenLedger != null) TextButton(onPressed: onOpenLedger, child: const Text('Open ledger')),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ],
    );
  }
}
