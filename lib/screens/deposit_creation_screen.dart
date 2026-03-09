import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/deposit_model.dart';
import '../models/payment_model.dart';
import '../services/deposit_service.dart';
import '../services/payment_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';

class DepositCreationScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const DepositCreationScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<DepositCreationScreen> createState() => _DepositCreationScreenState();
}

class _DepositCreationScreenState extends ConsumerState<DepositCreationScreen> {
  final _formKey = GlobalKey<FormState>();
  
  DepositMethod _method = DepositMethod.mixed;
  DateTime _depositDate = DateTime.now();
  double? _cashAmount;
  double? _checkAmount;
  int? _checkCount;
  double? _creditCardAmount;
  double? _achAmount;
  String? _bankAccount;
  String? _notes;
  
  List<String> _selectedPaymentIds = [];
  List<PaymentModel> _availablePayments = [];
  bool _isLoadingPayments = false;
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    _loadAvailablePayments();
  }

  Future<void> _loadAvailablePayments() async {
    setState(() {
      _isLoadingPayments = true;
    });

    try {
      final payments = await DepositService.getPaymentsAvailableForDeposit(
        facilityId: widget.facilityId,
      );
      setState(() {
        _availablePayments = payments;
        _isLoadingPayments = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingPayments = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading payments: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  double get _calculatedTotal {
    double total = 0.0;
    if (_cashAmount != null) total += _cashAmount!;
    if (_checkAmount != null) total += _checkAmount!;
    if (_creditCardAmount != null) total += _creditCardAmount!;
    if (_achAmount != null) total += _achAmount!;
    
    // Add selected payment amounts
    for (final paymentId in _selectedPaymentIds) {
      final payment = _availablePayments.firstWhere(
        (p) => p.id == paymentId,
        orElse: () => _availablePayments.first,
      );
      if (payment.id == paymentId) {
        total += payment.amount;
      }
    }
    
    return total;
  }

  Future<void> _createDeposit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_calculatedTotal <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Total amount must be greater than 0'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      final deposit = await DepositService.createDeposit(
        facilityId: widget.facilityId,
        method: _method,
        depositDate: _depositDate,
        totalAmount: _calculatedTotal,
        paymentIds: _selectedPaymentIds.isNotEmpty ? _selectedPaymentIds : null,
        cashAmount: _cashAmount,
        checkAmount: _checkAmount,
        checkCount: _checkCount,
        creditCardAmount: _creditCardAmount,
        achAmount: _achAmount,
        bankAccount: _bankAccount,
        notes: _notes,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Deposit created successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        context.pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error creating deposit: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isCreating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Deposit Method
              DropdownButtonFormField<DepositMethod>(
                value: _method,
                decoration: const InputDecoration(
                  labelText: 'Deposit Method',
                  border: OutlineInputBorder(),
                ),
                items: DepositMethod.values.map((method) {
                  return DropdownMenuItem(
                    value: method,
                    child: Text(_getMethodLabel(method)),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _method = value;
                    });
                  }
                },
              ),
              const SizedBox(height: 16),
              
              // Deposit Date
              InkWell(
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: _depositDate,
                    firstDate: DateTime.now().subtract(const Duration(days: 365)),
                    lastDate: DateTime.now(),
                  );
                  if (date != null) {
                    setState(() {
                      _depositDate = date;
                    });
                  }
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Deposit Date',
                    suffixIcon: Icon(Icons.calendar_today),
                    border: OutlineInputBorder(),
                  ),
                  child: Text(DateFormat('MMM d, yyyy').format(_depositDate)),
                ),
              ),
              const SizedBox(height: 24),

              // Payment Selection
              if (_availablePayments.isNotEmpty) ...[
                const Text(
                  'Select Payments to Include',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 300),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.borderLight),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _isLoadingPayments
                      ? const Center(child: Padding(
                          padding: EdgeInsets.all(16.0),
                          child: CircularProgressIndicator(),
                        ))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _availablePayments.length,
                          itemBuilder: (context, index) {
                            final payment = _availablePayments[index];
                            final isSelected = _selectedPaymentIds.contains(payment.id);
                            return CheckboxListTile(
                              title: Text('${payment.formattedAmount} - ${payment.methodDisplayName}'),
                              subtitle: Text('Tenant: ${payment.tenantId.substring(0, 8)}...'),
                              value: isSelected,
                              onChanged: (value) {
                                setState(() {
                                  if (value == true) {
                                    _selectedPaymentIds.add(payment.id);
                                  } else {
                                    _selectedPaymentIds.remove(payment.id);
                                  }
                                });
                              },
                            );
                          },
                        ),
                ),
                const SizedBox(height: 24),
              ],

              // Amount Breakdown
              const Text(
                'Amount Breakdown',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              
              if (_method == DepositMethod.mixed || _method == DepositMethod.cash)
                TextFormField(
                  initialValue: _cashAmount?.toStringAsFixed(2),
                  decoration: const InputDecoration(
                    labelText: 'Cash Amount',
                    prefixText: '\$',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (value) {
                    setState(() {
                      _cashAmount = double.tryParse(value);
                    });
                  },
                ),
              
              if (_method == DepositMethod.mixed || _method == DepositMethod.check) ...[
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: _checkAmount?.toStringAsFixed(2),
                  decoration: const InputDecoration(
                    labelText: 'Check Amount',
                    prefixText: '\$',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (value) {
                    setState(() {
                      _checkAmount = double.tryParse(value);
                    });
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: _checkCount?.toString(),
                  decoration: const InputDecoration(
                    labelText: 'Number of Checks',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (value) {
                    setState(() {
                      _checkCount = int.tryParse(value);
                    });
                  },
                ),
              ],
              
              if (_method == DepositMethod.mixed || _method == DepositMethod.creditCard) ...[
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: _creditCardAmount?.toStringAsFixed(2),
                  decoration: const InputDecoration(
                    labelText: 'Credit Card Amount',
                    prefixText: '\$',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (value) {
                    setState(() {
                      _creditCardAmount = double.tryParse(value);
                    });
                  },
                ),
              ],
              
              if (_method == DepositMethod.mixed || _method == DepositMethod.ach) ...[
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: _achAmount?.toStringAsFixed(2),
                  decoration: const InputDecoration(
                    labelText: 'ACH Amount',
                    prefixText: '\$',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (value) {
                    setState(() {
                      _achAmount = double.tryParse(value);
                    });
                  },
                ),
              ],
              
              const SizedBox(height: 24),
              
              // Bank Account
              TextFormField(
                initialValue: _bankAccount,
                decoration: const InputDecoration(
                  labelText: 'Bank Account (Optional)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  setState(() {
                    _bankAccount = value.isEmpty ? null : value;
                  });
                },
              ),
              const SizedBox(height: 16),
              
              // Notes
              TextFormField(
                initialValue: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (Optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
                onChanged: (value) {
                  setState(() {
                    _notes = value.isEmpty ? null : value;
                  });
                },
              ),
              const SizedBox(height: 24),
              
              // Total
              Card(
                color: AppTheme.primaryBlueLight.withOpacity(0.1),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Total Amount:',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '\$${_calculatedTotal.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primaryBlue,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              
              // Create Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isCreating ? null : _createDeposit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                  ),
                  child: _isCreating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Create Deposit'),
                ),
              ),
            ],
          ),
        ),
      );
  }

  String _getMethodLabel(DepositMethod method) {
    switch (method) {
      case DepositMethod.cash:
        return 'Cash';
      case DepositMethod.check:
        return 'Check';
      case DepositMethod.creditCard:
        return 'Credit Card';
      case DepositMethod.ach:
        return 'ACH';
      case DepositMethod.mixed:
        return 'Mixed';
    }
  }
}

