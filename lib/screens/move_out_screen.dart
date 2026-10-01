import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../models/contract_model.dart';
import '../models/tenant_model.dart';
import '../models/unit_model.dart';
import 'package:sfcapp/services/move_out_card_refund.dart';
import '../services/move_out_service.dart';
import '../services/contract_service.dart';
import '../services/tenant_service.dart';
import '../services/unit_service.dart';
import '../theme/app_theme.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/back_navigation.dart';
import 'package:sfcapp/utils/unit_label.dart';

class MoveOutScreen extends ConsumerStatefulWidget {
  final String contractId;
  final String facilityId;

  /// The unit being vacated, when the link names it (the unit's own menu).
  final String? unitId;

  const MoveOutScreen({
    super.key,
    required this.contractId,
    required this.facilityId,
    this.unitId,
  });

  @override
  ConsumerState<MoveOutScreen> createState() => _MoveOutScreenState();
}

class _MoveOutScreenState extends ConsumerState<MoveOutScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _isCalculating = false;
  bool _isProcessing = false;

  ContractModel? _contract;
  TenantModel? _tenant;
  UnitModel? _unit;

  /// The units this move-out can free (MoveOutService.moveOutUnitChoices).
  List<UnitModel> _unitChoices = const [];
  MoveOutCalculation? _calculation;

  DateTime _moveOutDate = DateTime.now();
  final _cleaningFeeController = TextEditingController();
  final _damageFeeController = TextEditingController();
  final _otherFeesController = TextEditingController();
  final _notesController = TextEditingController();
  // Off until the owner ticks it, as since the move-out hotfix: whether a
  // move-out prorates rent is the facility's policy. Ticked, it charges used
  // days no rent covers and credits rent posted for days after the move-out
  // (MoveOutRent).
  bool _prorateRent = false;
  bool _processRefund = false;
  String? _refundMethod;
  final _refundReferenceController = TextEditingController();

  /// What the app would refund to the tenant's card, for the words under
  /// Refund Method (MoveOutCardRefund.preview); null while it loads, or when
  /// the method is not a card.
  String? _cardRefundPreview;

  @override
  void initState() {
    super.initState();
    _loadContractData();
  }

  @override
  void dispose() {
    _cleaningFeeController.dispose();
    _damageFeeController.dispose();
    _otherFeesController.dispose();
    _notesController.dispose();
    _refundReferenceController.dispose();
    super.dispose();
  }

  Future<void> _loadContractData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final contract = await ContractService.getContract(widget.facilityId, widget.contractId);

      if (contract == null) {
        throw Exception('Contract not found');
      }

      final tenant = await TenantService.getTenantById(
        widget.facilityId,
        contract.tenantId,
      );

      // The owner picks which of the tenant's units this move-out frees:
      // it took their unitNumber's unit, or else the facility's first unit,
      // so a two-unit tenant's second contract freed their primary unit.
      ({List<UnitModel> choices, UnitModel? initial}) picked =
          (choices: const [], initial: null);
      if (tenant != null) {
        final units = await UnitService.getUnitsForFacility(widget.facilityId);
        picked = MoveOutService.moveOutUnitChoices(
          tenantId: tenant.id,
          tenantUnitNumber: tenant.unitNumber,
          units: units,
          tenantUnitId: tenant.unitId,
          contractUnitId: MoveOutService.contractUnitId(contract),
          // The unit's own menu names the unit it is moving out of.
          preferredUnitId: widget.unitId,
        );
      }

      if (!mounted) return;
      setState(() {
        _contract = contract;
        _tenant = tenant;
        _unitChoices = picked.choices;
        _unit = picked.initial;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading contract: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Whether the tenant holds a unit besides the one being freed, by the
  /// rule processMoveOut applies too (MoveOutService.keepsOtherUnits).
  bool get _keepsOtherUnits => MoveOutService.keepsOtherUnits(
        tenantId: _tenant?.id,
        vacated: _unit,
        units: _unitChoices,
      );

  Future<void> _calculateCharges() async {
    if (_contract == null || _tenant == null) return;

    setState(() {
      _isCalculating = true;
    });

    try {
      final calculation = await MoveOutService.calculateMoveOutCharges(
        tenantId: _tenant!.id,
        facilityId: widget.facilityId,
        contractId: widget.contractId,
        moveOutDate: _moveOutDate,
        cleaningFee: double.tryParse(_cleaningFeeController.text),
        damageFee: double.tryParse(_damageFeeController.text),
        otherFees: double.tryParse(_otherFeesController.text),
        prorateRent: _prorateRent,
        unitRate: _unit?.monthlyRate,
        keepsOtherUnits: _keepsOtherUnits,
        unitMoveInDate: _unit?.moveInDate,
      );

      setState(() {
        _calculation = calculation;
        _processRefund = calculation.refundAmount > 0;
        _isCalculating = false;
      });
      if (_refundMethod == 'creditCard') await _loadCardRefundPreview();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error calculating charges: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isCalculating = false;
        });
      }
    }
  }

  /// Works out what the app would refund to the tenant's card, from their
  /// posted ledger, for [_cardRefundPreview]. The refund itself is worked
  /// out again, from a fresh read, once the move-out is done.
  Future<void> _loadCardRefundPreview() async {
    final tenant = _tenant;
    final calculation = _calculation;
    if (!mounted || tenant == null || calculation == null || calculation.refundAmount <= 0) return;
    setState(() => _cardRefundPreview = null);
    String preview;
    try {
      final rows = await MoveOutCardRefund.postedLedgerRows(
        facilityId: widget.facilityId,
        tenantId: tenant.id,
      );
      preview = MoveOutCardRefund.preview(MoveOutCardRefund.plan(
        amount: calculation.refundAmount,
        payments: MoveOutCardRefund.refundablePayments(rows),
      ));
    } catch (e) {
      preview = "Couldn't check their card payments ($e). The app will try when you complete "
          "the move-out, and tell you what it couldn't refund.";
    }
    if (!mounted || _refundMethod != 'creditCard' || !identical(calculation, _calculation)) return;
    setState(() => _cardRefundPreview = preview);
  }

  /// A card refund that was not (all) made: what happened and what to do,
  /// kept on screen until the owner closes it. A snackbar was gone in 15
  /// seconds, with the credit still on the tenant's ledger.
  Future<void> _showRefundAlert(String? title, String alert) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        key: const Key('move-out-card-refund-alert'),
        title: Text(title ?? 'Card refund not made'),
        content: SingleChildScrollView(child: SelectableText(alert)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// A card refund an earlier press of Complete left pending (this press
  /// was answered "already completed"): that press committed, but its
  /// answer never arrived, so the card was never refunded, and the owner
  /// was told only that nothing had changed. They are told now, and asked
  /// before anything is refunded. The refund is made as the first press
  /// would have made it (refundAfterMoveOut with this contract, so the same
  /// processRefund request ids). When a refund has reached the ledger since
  /// the move-out, or the app has no card payment to refund, nothing is
  /// offered (MoveOutCardRefund.pendingChoiceFrom): the alert says how to
  /// finish it in Stripe. The same check runs again on the read the refund
  /// is made from (pendingSince), as one can land while the offer is open.
  /// An owner who refunds it in Stripe themselves has that recorded on the
  /// contract, so it is not offered again.
  Future<void> _settlePendingCardRefund(PendingCardRefund pending) async {
    final tenant = _tenant;
    if (tenant == null) return;
    final choice = await MoveOutCardRefund.pendingChoice(
      facilityId: widget.facilityId,
      tenantId: tenant.id,
      pending: pending,
    );
    if (!mounted) return;
    final plan = choice.plan;
    if (plan == null) {
      await _showRefundAlert(null, choice.alert!);
      return;
    }
    final make = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        key: const Key('move-out-pending-card-refund'),
        title: const Text('Card refund not made yet'),
        content: SingleChildScrollView(child: SelectableText(MoveOutCardRefund.pendingOffer(plan))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Refund it in Stripe myself'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Make the refund'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (make != true) {
      // No longer pending: left as it was, a later press of Complete
      // offered the whole refund again after the owner had made it.
      await MoveOutCardRefund.recordLeftToOwner(
        facilityId: widget.facilityId,
        tenantId: tenant.id,
        contractId: widget.contractId,
        requested: pending.requested,
      );
      if (!mounted) return;
      await _showRefundAlert(null, MoveOutCardRefund.pendingAlert(pending.requested));
      return;
    }
    final outcome = await MoveOutCardRefund.refundAfterMoveOut(
      facilityId: widget.facilityId,
      tenantId: tenant.id,
      contractId: widget.contractId,
      amount: pending.requested,
      pendingSince: pending.since,
    );
    if (!mounted) return;
    final alert = outcome.ownerAlert;
    if (alert != null) {
      await _showRefundAlert(outcome.alertTitle, alert);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Refunded ${MoveOutCardRefund.money(outcome.refunded)} to their card through Stripe.'),
        backgroundColor: AppTheme.success,
      ),
    );
  }

  /// The contract's page, by id: where a move-out is started from, and where
  /// leaving goes when nothing is underneath (a link or a reload).
  String get _contractPage => Uri(
        path: AppRoute.contractDetail,
        queryParameters: {
          'contractId': widget.contractId,
          'facilityId': widget.facilityId,
        },
      ).toString();

  Future<void> _completeMoveOut() async {
    // A second tap in the same frame, before the rebuild disables the
    // button, would run the move-out (and its refund) twice.
    if (_isProcessing) return;
    if (!_formKey.currentState!.validate()) return;
    if (_unit == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // Several units and none named for sure (see moveOutUnitChoices):
          // the owner picks, rather than the first one being freed.
          content: Text(_unitChoices.isNotEmpty
              ? 'Choose the unit the tenant is moving out of.'
              : 'This tenant holds no unit to move out of.'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }
    if (_calculation == null || _contract == null || _tenant == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please calculate charges first'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    var completed = false;
    MoveOutResult? completedResult;
    try {
      final result = await MoveOutService.completeMoveOut(
        tenantId: _tenant!.id,
        facilityId: widget.facilityId,
        contractId: widget.contractId,
        unitId: _unit!.id,
        moveOutDate: _moveOutDate,
        calculation: _calculation!,
        moveOutNotes: _notesController.text.isEmpty ? null : _notesController.text,
        processRefund: _processRefund && _calculation!.refundAmount > 0,
        refundMethod: _refundMethod,
        refundReferenceId: _refundReferenceController.text.isEmpty
            ? null
            : _refundReferenceController.text,
      );

      if (result.success) {
        completed = true;
        completedResult = result;
        if (mounted) {
          final refundLine = result.refund != null && result.refund! > 0
              ? '\n${result.refundByCard ? 'Refunded to their card' : 'Refund'}: '
                  '\$${result.refund!.toStringAsFixed(2)}'
              : '';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Move-out completed successfully$refundLine'
                // The tenant's new rent, or a request to check it.
                '${result.notice != null ? '\n${result.notice}' : ''}'
                '${result.warning != null ? '\n${result.warning}' : ''}',
              ),
              backgroundColor: result.warning != null ? AppTheme.warning : AppTheme.success,
              duration: Duration(
                  seconds: result.warning != null
                      ? 15
                      : result.notice != null
                          ? 10
                          : 5),
            ),
          );
        }
      } else {
        throw Exception(result.error ?? 'Unknown error');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error completing move-out: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isProcessing = false;
        });
      }
    }

    // A card refund not (all) made stays on screen until the owner closes
    // it, before the page goes.
    final refundAlert = completedResult?.refundAlert;
    if (completed && mounted && refundAlert != null) {
      await _showRefundAlert(completedResult?.refundAlertTitle, refundAlert);
    }
    // One an earlier press left pending: said, and made only if they ask.
    final pending = completedResult?.pendingCardRefund;
    if (completed && mounted && pending != null) await _settlePendingCardRefund(pending);

    // Leave outside the try, and leave the button off: a bare context.pop
    // threw when the page was opened by a link, the catch reported the
    // finished move-out as an error and re-enabled the button, inviting a
    // second move-out and refund.
    if (completed && mounted) popOrGo(context, _contractPage, true);
  }

  @override
  Widget build(BuildContext context) {
    return _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _contract == null || _tenant == null
              ? const Center(child: Text('Contract or tenant not found'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildTenantInfo(),
                        const SizedBox(height: 24),
                        _buildMoveOutDate(),
                        const SizedBox(height: 24),
                        _buildChargesSection(),
                        const SizedBox(height: 24),
                        if (_calculation != null) _buildCalculationSummary(),
                        const SizedBox(height: 24),
                        if (_calculation != null && _calculation!.refundAmount > 0)
                          _buildRefundSection(),
                        const SizedBox(height: 24),
                        _buildNotesSection(),
                        const SizedBox(height: 32),
                        _buildActionButtons(),
                      ],
                    ),
                  ),
                );
  }

  Widget _buildTenantInfo() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tenant Information',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tenant',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        _tenant?.name ?? 'N/A',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Unit',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      if (_unitChoices.length > 1)
                        // A tenant with several units: the owner says which
                        // one this move-out frees.
                        DropdownButton<String>(
                          key: const Key('moveOutUnitPicker'),
                          value: _unit?.id,
                          isExpanded: true,
                          hint: const Text('Choose the unit'),
                          items: [
                            for (final u in _unitChoices)
                              DropdownMenuItem(
                                value: u.id,
                                // With its area: two units can share a number.
                                child: Text(unitPickerLabel(u)),
                              ),
                          ],
                          onChanged: _isProcessing
                              ? null
                              : (id) => setState(() {
                                    _unit = _unitChoices
                                        .firstWhere((u) => u.id == id);
                                    // Worked out for the unit picked.
                                    _calculation = null;
                                  }),
                        )
                      else
                        Text(
                          _unit == null
                              ? 'No unit'
                              : unitPickerLabel(_unit!,
                                  style: UnitLabelStyle.plain),
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (_tenant?.monthlyRate != null) ...[
              const SizedBox(height: 8),
              Text(
                'Monthly Rate: \$${_tenant!.monthlyRate.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMoveOutDate() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Move-Out Date',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _moveOutDate,
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now(),
                );
                if (date != null) {
                  setState(() {
                    _moveOutDate = date;
                    // Worked out for the date it was calculated on.
                    _calculation = null;
                  });
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Move-Out Date',
                  suffixIcon: Icon(Icons.calendar_today),
                  border: OutlineInputBorder(),
                ),
                child: Text(DateFormat('MMM d, yyyy').format(_moveOutDate)),
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              title: const Text('Prorate Rent'),
              subtitle: const Text(
                  'Charge days used that no rent covers, and credit rent '
                  'already posted for days after the move-out'),
              value: _prorateRent,
              onChanged: (value) {
                setState(() {
                  _prorateRent = value ?? false;
                  _calculation = null;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChargesSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Move-Out Charges',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _cleaningFeeController,
              decoration: const InputDecoration(
                labelText: 'Cleaning Fee (\$)',
                prefixText: '\$',
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: (value) {
                if (value != null && value.isNotEmpty) {
                  final parsed = double.tryParse(value);
                  if (parsed == null || parsed < 0) {
                    return 'Please enter a valid amount';
                  }
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _damageFeeController,
              decoration: const InputDecoration(
                labelText: 'Damage Fee (\$)',
                prefixText: '\$',
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: (value) {
                if (value != null && value.isNotEmpty) {
                  final parsed = double.tryParse(value);
                  if (parsed == null || parsed < 0) {
                    return 'Please enter a valid amount';
                  }
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _otherFeesController,
              decoration: const InputDecoration(
                labelText: 'Other Fees (\$)',
                prefixText: '\$',
                border: OutlineInputBorder(),
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              validator: (value) {
                if (value != null && value.isNotEmpty) {
                  final parsed = double.tryParse(value);
                  if (parsed == null || parsed < 0) {
                    return 'Please enter a valid amount';
                  }
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isCalculating ? null : _calculateCharges,
                icon: _isCalculating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.calculate),
                label: Text(_isCalculating ? 'Calculating...' : 'Calculate Charges'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalculationSummary() {
    if (_calculation == null) return const SizedBox.shrink();

    return Card(
      color: AppTheme.primaryBlueLight.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Calculation Summary',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            if (_calculation!.lineItems.isNotEmpty) ...[
              ..._calculation!.lineItems.map((item) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(item.description),
                        Text(
                          '\$${item.amount.toStringAsFixed(2)}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  )),
              const Divider(),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Current Balance:',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Text(
                  '\$${_calculation!.currentBalance.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'New Charges:',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Text(
                  '\$${_calculation!.newCharges.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Final Balance:',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '\$${_calculation!.finalBalance.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: _calculation!.finalBalance >= 0
                        ? AppTheme.error
                        : AppTheme.success,
                  ),
                ),
              ],
            ),
            if (_calculation!.refundAmount > 0) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12.0),
                decoration: BoxDecoration(
                  color: AppTheme.success.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Refund Amount:',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.success,
                      ),
                    ),
                    Text(
                      '\$${_calculation!.refundAmount.toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.success,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Kept out of the maths above: a held deposit is not a credit
            // on the ledger, and the refund is recorded on the tenant.
            if (_tenant?.securityDeposit?.isHeld == true) ...[
              const SizedBox(height: 8),
              Text(
                'Security deposit held: '
                '\$${_tenant!.securityDeposit!.amount.toStringAsFixed(2)}'
                " — not included above; settle it on the tenant's page.",
                key: const Key('move-out-security-deposit'),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRefundSection() {
    if (_calculation == null || _calculation!.refundAmount <= 0) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Refund Processing',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              title: Text('Process Refund of \$${_calculation!.refundAmount.toStringAsFixed(2)}'),
              value: _processRefund,
              onChanged: (value) {
                setState(() {
                  _processRefund = value ?? false;
                });
              },
            ),
            if (_processRefund) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _refundMethod,
                decoration: const InputDecoration(
                  labelText: 'Refund Method',
                  border: OutlineInputBorder(),
                ),
                // Whether the app makes the refund is in the name: it
                // refunds a card through Stripe; cash, a check or ACH the
                // owner hands over, and the app records.
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Cash (you pay it; recorded now)')),
                  DropdownMenuItem(value: 'check', child: Text('Check (you pay it; recorded now)')),
                  DropdownMenuItem(
                    value: 'creditCard',
                    child: Text('Card (the app refunds it through Stripe)'),
                  ),
                  DropdownMenuItem(value: 'ach', child: Text('ACH (you send it; recorded now)')),
                ],
                onChanged: (value) {
                  setState(() {
                    _refundMethod = value;
                    _cardRefundPreview = null;
                  });
                  if (value == 'creditCard') _loadCardRefundPreview();
                },
                validator: (value) {
                  if (_processRefund && (value == null || value.isEmpty)) {
                    return 'Please select a refund method';
                  }
                  return null;
                },
              ),
              if (_refundMethod != null) ...[
                const SizedBox(height: 8),
                Text(
                  _refundMethod == 'creditCard'
                      ? _cardRefundPreview ?? 'Checking their card payments...'
                      : 'You hand over the refund yourself; the app records it on their '
                          'ledger as made when you complete the move-out.',
                  key: const Key('move-out-refund-method-note'),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppTheme.textSecondary),
                ),
              ],
              // The app fills in a card refund's Stripe ids itself.
              if (_refundMethod != 'creditCard') ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _refundReferenceController,
                  decoration: const InputDecoration(
                    labelText: 'Reference Number (Optional)',
                    border: OutlineInputBorder(),
                    helperText: 'Check number, transaction ID, etc.',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNotesSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Notes',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Move-Out Notes (Optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed:
                _isProcessing ? null : () => popOrGo(context, _contractPage),
            child: const Text('Cancel'),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          flex: 2,
          child: ElevatedButton(
            onPressed: (_isProcessing || _calculation == null) ? null : _completeMoveOut,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: Colors.white,
            ),
            child: _isProcessing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Complete Move-Out'),
          ),
        ),
      ],
    );
  }
}

