import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/transfer_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/transfer_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';

class TransferWorkflowScreen extends ConsumerStatefulWidget {
  final String tenantId;
  final String facilityId;
  final TenantModel? tenant; // Optional: pre-loaded tenant

  const TransferWorkflowScreen({
    super.key,
    required this.tenantId,
    required this.facilityId,
    this.tenant,
  });

  @override
  ConsumerState<TransferWorkflowScreen> createState() => _TransferWorkflowScreenState();
}

class _TransferWorkflowScreenState extends ConsumerState<TransferWorkflowScreen> {
  TenantModel? _tenant;
  UnitModel? _fromUnit;
  UnitModel? _toUnit;
  DateTime _transferDate = DateTime.now();
  String? _notes;
  bool _isLoading = false;
  bool _isCalculating = false;
  TransferModel? _calculatedTransfer;

  @override
  void initState() {
    super.initState();
    _tenant = widget.tenant;
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Load tenant if not provided
      if (_tenant == null) {
        _tenant = await TenantService.getTenantById(widget.facilityId, widget.tenantId);
      }

      // Load current unit
      if (_tenant != null && _tenant!.unitNumber.isNotEmpty) {
        final units = await UnitService.getUnitsForFacility(widget.facilityId);
        _fromUnit = units.firstWhere(
          (u) => u.unitNumber == _tenant!.unitNumber && u.status == UnitStatus.occupied,
          orElse: () => units.firstWhere(
            (u) => u.unitNumber == _tenant!.unitNumber,
            orElse: () => units.first,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading data: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _calculateTransfer() async {
    if (_fromUnit == null || _toUnit == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select both from and to units'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    setState(() {
      _isCalculating = true;
    });

    try {
      final transfer = await TransferService.createTransfer(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
        fromUnitId: _fromUnit!.id,
        toUnitId: _toUnit!.id,
        transferDate: _transferDate,
        notes: _notes,
      );

      setState(() {
        _calculatedTransfer = transfer;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error calculating transfer: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isCalculating = false;
      });
    }
  }

  Future<void> _completeTransfer() async {
    if (_calculatedTransfer == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please calculate transfer first'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Complete Transfer'),
        content: Text(
          'Are you sure you want to complete this transfer?\n\n'
          'This will:\n'
          '• Move tenant from ${_calculatedTransfer!.fromUnitNumber} to ${_calculatedTransfer!.toUnitNumber}\n'
          '• Create ledger entries for prorated amounts\n'
          '• Update unit statuses\n'
          '• Update tenant information',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: Colors.white,
            ),
            child: const Text('Complete Transfer'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isLoading = true;
    });

    try {
      await TransferService.completeTransfer(
        facilityId: widget.facilityId,
        transferId: _calculatedTransfer!.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Transfer completed successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error completing transfer: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/transfer',
      title: 'Unit Transfer',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTenantInfo(),
                  const SizedBox(height: 24),
                  _buildFromUnitSelector(),
                  const SizedBox(height: 24),
                  _buildToUnitSelector(),
                  const SizedBox(height: 24),
                  _buildTransferDateSelector(),
                  const SizedBox(height: 24),
                  _buildNotesField(),
                  const SizedBox(height: 24),
                  if (_calculatedTransfer != null) ...[
                    _buildTransferSummary(),
                    const SizedBox(height: 24),
                  ],
                  _buildActions(),
                ],
              ),
            ),
    );
  }

  Widget _buildTenantInfo() {
    if (_tenant == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('Loading tenant information...'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tenant Information',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildInfoRow('Name', _tenant!.name),
                ),
                Expanded(
                  child: _buildInfoRow('Current Unit', _tenant!.unitNumber),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildInfoRow('Email', _tenant!.email),
                ),
                Expanded(
                  child: _buildInfoRow('Phone', _tenant!.phone),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFromUnitSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From Unit',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (_fromUnit != null)
              Container(
                padding: const EdgeInsets.all(12.0),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundLight,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderLight),
                ),
                child: Row(
                  children: [
                    Icon(Icons.home, color: AppTheme.primaryBlue),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _fromUnit!.unitNumber,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Rate: \$${_fromUnit!.monthlyRate.toStringAsFixed(2)}/month',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            else
              Text(
                'No current unit found',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildToUnitSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'To Unit *',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<UnitModel>>(
              future: UnitService.getUnitsForFacility(widget.facilityId),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (!snapshot.hasData) {
                  return const Text('Error loading units');
                }

                final availableUnits = snapshot.data!
                    .where((u) => u.status == UnitStatus.available)
                    .toList();

                if (availableUnits.isEmpty) {
                  return Text(
                    'No available units',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  );
                }

                return DropdownButtonFormField<UnitModel>(
                  value: _toUnit,
                  decoration: const InputDecoration(
                    labelText: 'Select Unit',
                    border: OutlineInputBorder(),
                  ),
                  items: availableUnits.map((unit) {
                    return DropdownMenuItem(
                      value: unit,
                      child: Text(
                        '${unit.unitNumber} - \$${unit.monthlyRate.toStringAsFixed(2)}/month',
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      _toUnit = value;
                      _calculatedTransfer = null; // Reset calculation
                    });
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferDateSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transfer Date *',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              title: Text(DateFormat('MMM d, y').format(_transferDate)),
              trailing: const Icon(Icons.calendar_today),
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _transferDate,
                  firstDate: DateTime.now().subtract(const Duration(days: 30)),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (date != null) {
                  setState(() {
                    _transferDate = date;
                    _calculatedTransfer = null; // Reset calculation
                  });
                }
              },
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: AppTheme.borderLight),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotesField() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Notes (Optional)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                labelText: 'Transfer notes',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) {
                setState(() {
                  _notes = value;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransferSummary() {
    if (_calculatedTransfer == null) return const SizedBox.shrink();

    return Card(
      color: AppTheme.primaryBlueLight.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transfer Summary',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildSummaryRow(
              'From Unit Refund',
              '\$${_calculatedTransfer!.fromUnitProratedRent.toStringAsFixed(2)}',
            ),
            _buildSummaryRow(
              'To Unit Charge',
              '\$${_calculatedTransfer!.toUnitProratedRent.toStringAsFixed(2)}',
            ),
            const Divider(),
            _buildSummaryRow(
              'Net Amount',
              _calculatedTransfer!.formattedNetAmount,
              isBold: true,
              color: _calculatedTransfer!.netAmount >= 0
                  ? AppTheme.error
                  : AppTheme.success,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value, {bool isBold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _calculatedTransfer == null
              ? (_isCalculating ? null : _calculateTransfer)
              : _completeTransfer,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: _isCalculating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text(_calculatedTransfer == null ? 'Calculate Transfer' : 'Complete Transfer'),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

