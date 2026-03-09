import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/contract_model.dart';
import '../models/tenant_model.dart';
import '../models/unit_model.dart';
import '../services/move_out_service.dart';
import '../services/contract_service.dart';
import '../services/tenant_service.dart';
import '../services/unit_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';

class MoveOutScreen extends ConsumerStatefulWidget {
  final String contractId;
  final String facilityId;

  const MoveOutScreen({
    super.key,
    required this.contractId,
    required this.facilityId,
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
  MoveOutCalculation? _calculation;

  DateTime _moveOutDate = DateTime.now();
  final _cleaningFeeController = TextEditingController();
  final _damageFeeController = TextEditingController();
  final _otherFeesController = TextEditingController();
  final _notesController = TextEditingController();
  bool _prorateRent = true;
  bool _processRefund = false;
  String? _refundMethod;
  final _refundReferenceController = TextEditingController();

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

      UnitModel? unit;
      if (tenant != null && tenant.unitNumber.isNotEmpty) {
        final units = await UnitService.getUnitsForFacility(widget.facilityId);
        unit = units.firstWhere(
          (u) => u.unitNumber == tenant.unitNumber,
          orElse: () => units.first,
        );
      }

      setState(() {
        _contract = contract;
        _tenant = tenant;
        _unit = unit;
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
      );

      setState(() {
        _calculation = calculation;
        _processRefund = calculation.refundAmount > 0;
        _isCalculating = false;
      });
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

  Future<void> _completeMoveOut() async {
    if (!_formKey.currentState!.validate()) return;
    if (_calculation == null || _contract == null || _tenant == null || _unit == null) {
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Move-out completed successfully${result.refund != null && result.refund! > 0 ? '\nRefund: \$${result.refund!.toStringAsFixed(2)}' : ''}',
              ),
              backgroundColor: AppTheme.success,
              duration: const Duration(seconds: 5),
            ),
          );
          context.pop(true);
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
      }
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
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
                      Text(
                        _tenant?.unitNumber ?? 'N/A',
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
              subtitle: const Text('Calculate prorated rent for partial month'),
              value: _prorateRent,
              onChanged: (value) {
                setState(() {
                  _prorateRent = value ?? true;
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
                items: const [
                  DropdownMenuItem(value: 'cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'check', child: Text('Check')),
                  DropdownMenuItem(value: 'creditCard', child: Text('Credit Card Refund')),
                  DropdownMenuItem(value: 'ach', child: Text('ACH')),
                ],
                onChanged: (value) {
                  setState(() {
                    _refundMethod = value;
                  });
                },
                validator: (value) {
                  if (_processRefund && (value == null || value.isEmpty)) {
                    return 'Please select a refund method';
                  }
                  return null;
                },
              ),
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
            onPressed: _isProcessing ? null : () => context.pop(),
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

