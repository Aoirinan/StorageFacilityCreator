import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/ledger_entry_model.dart';
import '../models/tenant_model.dart';
import '../services/ledger_service.dart';
import '../theme/app_theme.dart';

class LedgerEntryCreationDialog extends StatefulWidget {
  final TenantModel tenant;
  final VoidCallback onEntryCreated;

  const LedgerEntryCreationDialog({
    super.key,
    required this.tenant,
    required this.onEntryCreated,
  });

  @override
  State<LedgerEntryCreationDialog> createState() => _LedgerEntryCreationDialogState();
}

class _LedgerEntryCreationDialogState extends State<LedgerEntryCreationDialog> {
  final _formKey = GlobalKey<FormState>();
  LedgerEntryType _selectedType = LedgerEntryType.rentCharge;
  double _amount = 0.0;
  String? _description;
  DateTime? _dueDate;
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Ledger Entry'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<LedgerEntryType>(
                value: _selectedType,
                decoration: const InputDecoration(
                  labelText: 'Entry Type',
                  border: OutlineInputBorder(),
                ),
                items: LedgerEntryType.values.map((type) {
                  return DropdownMenuItem(
                    value: type,
                    child: Text(type.displayName),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _selectedType = value);
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '\$',
                  border: OutlineInputBorder(),
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                ],
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter an amount';
                  }
                  final amount = double.tryParse(value);
                  if (amount == null || amount <= 0) {
                    return 'Amount must be greater than 0';
                  }
                  return null;
                },
                onSaved: (value) {
                  if (value != null) {
                    _amount = double.parse(value);
                  }
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
                onSaved: (value) => _description = value,
              ),
              const SizedBox(height: 16),
              if (_selectedType != LedgerEntryType.payment && _selectedType != LedgerEntryType.credit && _selectedType != LedgerEntryType.adjustment && _selectedType != LedgerEntryType.refund)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Due Date (optional)'),
                  subtitle: Text(
                    _dueDate != null
                        ? '${_dueDate!.month}/${_dueDate!.day}/${_dueDate!.year}'
                        : 'Not set',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _dueDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (date != null) {
                        setState(() => _dueDate = date);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _createEntry,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _createEntry() async {
    if (!_formKey.currentState!.validate()) return;

    _formKey.currentState!.save();

    // For payments/credits/adjustments/refunds, amount should be negative
    // For charges, amount should be positive
    final amount = (_selectedType == LedgerEntryType.payment ||
            _selectedType == LedgerEntryType.credit ||
            _selectedType == LedgerEntryType.adjustment ||
            _selectedType == LedgerEntryType.refund)
        ? -_amount
        : _amount;

    setState(() => _isLoading = true);

    try {
      await LedgerService.createLedgerEntry(
        tenantId: widget.tenant.id,
        facilityId: widget.tenant.facilityId,
        type: _selectedType,
        amount: amount,
        description: _description,
        dueDate: _dueDate,
      );

      if (mounted) {
        Navigator.pop(context);
        widget.onEntryCreated();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating entry: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}

