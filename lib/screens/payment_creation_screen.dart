import 'package:flutter/material.dart';
import '../widgets/keyboard_scrollable.dart';
import '../utils/error_message_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../models/payment_model.dart';
import '../providers/payment_provider.dart';
import '../providers/tenant_provider.dart';
import '../providers/facility_provider.dart';
import '../models/provider_params.dart';
import '../theme/app_theme.dart';
import 'tenant_creation_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';

class PaymentCreationScreen extends ConsumerStatefulWidget {
  final String facilityId;
  
  const PaymentCreationScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<PaymentCreationScreen> createState() => _PaymentCreationScreenState();
}

class _PaymentCreationScreenState extends ConsumerState<PaymentCreationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();
  
  String _selectedTenantId = '';
  String _selectedContractId = '';
  PaymentMethod _selectedMethod = PaymentMethod.square;
  DateTime _selectedDueDate = DateTime.now().add(const Duration(days: 30));
  
  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardScrollable(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Tenant selection
              Consumer(
                builder: (context, ref, child) {
                  return ref.watch(activeTenantsProvider(widget.facilityId)).when(
                    data: (tenants) {
                      if (tenants.isEmpty) {
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.person_off,
                                  size: 48,
                                  color: AppTheme.textTertiary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'No active tenants found',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Create a tenant first to add payments.',
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton.icon(
                                  onPressed: () async {
                                    // Get facilities for tenant creation
                                    final uid = FirebaseAuth.instance.currentUser!.uid;
                                    ref.invalidate(userFacilitiesProvider(uid));
                                    final facilities = await ref.read(userFacilitiesProvider(uid).future);
                                    if (mounted && facilities.isNotEmpty) {
                                      context.push(
                                        AppRoute.legacyScreen,
                                        extra: TenantCreationScreen(
                                          facilities: facilities,
                                          selectedFacilityId: facilities.first.id,
                                        ),
                                      );
                                    } else if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Please create a facility first'),
                                          backgroundColor: AppTheme.warning,
                                        ),
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.add),
                                  label: const Text('Create Tenant'),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      
                      return DropdownButtonFormField<String>(
                        value: _selectedTenantId.isEmpty ? null : _selectedTenantId,
                        decoration: const InputDecoration(
                          labelText: 'Tenant *',
                          border: OutlineInputBorder(),
                        ),
                        items: tenants.map((tenant) {
                          return DropdownMenuItem(
                            value: tenant.id,
                            child: Text(tenant.name),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedTenantId = value ?? '';
                            _selectedContractId = ''; // Reset contract selection
                          });
                        },
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please select a tenant';
                          }
                          return null;
                        },
                      );
                    },
                    loading: () => const CircularProgressIndicator(),
                    error: (_, __) => const Text('Error loading tenants'),
                  );
                },
              ),
              const SizedBox(height: 16),
              
              // Contract selection
              if (_selectedTenantId.isNotEmpty)
                Consumer(
                  builder: (context, ref, child) {
                    final params = FacilityTenantParams(
                      facilityId: widget.facilityId,
                      tenantId: _selectedTenantId,
                    );
                    return ref.watch(tenantContractsProvider(params)).when(
                      data: (contracts) {
                        if (contracts.isEmpty) {
                          return const Card(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('No contracts found for this tenant'),
                            ),
                          );
                        }
                        
                        return DropdownButtonFormField<String>(
                          value: _selectedContractId.isEmpty ? null : _selectedContractId,
                          decoration: const InputDecoration(
                            labelText: 'Contract *',
                            border: OutlineInputBorder(),
                          ),
                          items: contracts.map((contract) {
                            final label = contract.title.trim().isNotEmpty
                                ? contract.title
                                : 'Contract ${contract.id.substring(0, 8)}...';
                            return DropdownMenuItem(
                              value: contract.id,
                              child: Text(label),
                            );
                          }).toList(),
                          onChanged: (value) {
                            setState(() {
                              _selectedContractId = value ?? '';
                            });
                          },
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please select a contract';
                            }
                            return null;
                          },
                        );
                      },
                      loading: () => const _InlineLoader(message: 'Loading contracts...'),
                      error: (_, __) => const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('Unable to load contracts for this tenant.'),
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 16),
              if (_selectedTenantId.isNotEmpty) _TenantSnapshot(facilityId: widget.facilityId, tenantId: _selectedTenantId),
              const SizedBox(height: 16),
              
              // Amount
              TextFormField(
                controller: _amountController,
                decoration: const InputDecoration(
                  labelText: 'Amount *',
                  prefixText: '\$',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter an amount';
                  }
                  final amount = double.tryParse(value);
                  if (amount == null || amount <= 0) {
                    return 'Please enter a valid amount';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Payment method
              DropdownButtonFormField<PaymentMethod>(
                value: _selectedMethod,
                decoration: const InputDecoration(
                  labelText: 'Payment Method *',
                  border: OutlineInputBorder(),
                ),
                items: PaymentMethod.values.map((method) {
                  return DropdownMenuItem(
                    value: method,
                    child: Text(method.displayName),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedMethod = value ?? PaymentMethod.square;
                  });
                },
              ),
              const SizedBox(height: 16),
              
              // Due date
              InkWell(
                onTap: _selectDueDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Due Date *',
                    border: OutlineInputBorder(),
                  ),
                  child: Text(_formatDate(_selectedDueDate)),
                ),
              ),
              const SizedBox(height: 16),
              
              // Notes
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 24),
              
              // Generate monthly payments option
              if (_selectedTenantId.isNotEmpty && _selectedContractId.isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bulk Actions',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Generate monthly rent payments for this contract',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _generateMonthlyPayments,
                          icon: const Icon(Icons.calendar_month),
                          label: const Text('Generate Monthly Payments'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      );
  }

  void _selectDueDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _selectedDueDate,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    
    if (date != null) {
      setState(() {
        _selectedDueDate = date;
      });
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  void _submitForm() async {
    if (!_formKey.currentState!.validate()) return;
    
    final amount = double.parse(_amountController.text);
    
    try {
      await ref.read(paymentOperationsProvider.notifier).createPayment(
        tenantId: _selectedTenantId,
        facilityId: widget.facilityId,
        contractId: _selectedContractId,
        amount: amount,
        method: _selectedMethod,
        dueDate: _selectedDueDate,
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      );
      
      if (mounted) {
        Navigator.of(context).pop();
        // Invalidate providers to refresh payment lists
        ref.invalidate(paymentListProvider(widget.facilityId));
        ref.invalidate(paymentStatsProvider(widget.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment created successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating payment: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
        );
      }
    }
  }

  void _generateMonthlyPayments() async {
    if (_selectedTenantId.isEmpty || _selectedContractId.isEmpty) return;
    
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid amount first')),
      );
      return;
    }
    
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Generate Monthly Payments'),
        content: Text(
          'This will create monthly rent payments of \$${amount.toStringAsFixed(2)} '
          'for the next 12 months. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Generate'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      try {
        final startDate = _selectedDueDate;
        final endDate = DateTime(
          startDate.year + 1,
          startDate.month,
          startDate.day,
        );
        
        await ref.read(paymentOperationsProvider.notifier).generateMonthlyRentPayments(
          facilityId: widget.facilityId,
          tenantId: _selectedTenantId,
          amount: amount,
          startDate: startDate,
          months: 12,
        );
        
        if (mounted) {
          Navigator.of(context).pop();
          // Invalidate providers to refresh payment lists
          ref.invalidate(paymentListProvider(widget.facilityId));
          ref.invalidate(paymentStatsProvider(widget.facilityId));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Monthly payments generated successfully')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error generating payments: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
          );
        }
      }
    }
  }
}

class _InlineLoader extends StatelessWidget {
  final String message;
  const _InlineLoader({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Text(message),
        ],
      ),
    );
  }
}

class _TenantSnapshot extends ConsumerWidget {
  final String facilityId;
  final String tenantId;

  const _TenantSnapshot({
    required this.facilityId,
    required this.tenantId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final params = FacilityTenantParams(facilityId: facilityId, tenantId: tenantId);
    final summaryAsync = ref.watch(tenantPaymentSummaryProvider(params));

    return summaryAsync.when(
      data: (summary) {
        final outstanding = (summary['outstanding'] as double?) ?? 0.0;
        final pendingCount = (summary['pendingCount'] as int?) ?? 0;
        final nextDueDate = summary['nextDueDate'] as DateTime?;
        final recentPending = (summary['recentPending'] as List<PaymentModel>? ?? const []);

        return Card(
          elevation: 1,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.account_balance_wallet_outlined, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Tenant Account Snapshot',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _MetricTile(
                        label: 'Outstanding Balance',
                        value: '\$${outstanding.toStringAsFixed(2)}',
                        valueColor: outstanding > 0 ? AppTheme.error : AppTheme.success,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricTile(
                        label: 'Pending Payments',
                        value: pendingCount.toString(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_outlined),
                  title: const Text('Next Due Date'),
                  subtitle: Text(nextDueDate != null
                      ? '${nextDueDate.month}/${nextDueDate.day}/${nextDueDate.year}'
                      : 'No upcoming due date'),
                ),
                if (recentPending.isNotEmpty) ...[
                  const Divider(),
                  Text(
                    'Pending Invoices',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...recentPending.map(
                    (payment) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.receipt_long, color: AppTheme.warning),
                      title: Text('\$${payment.amount.toStringAsFixed(2)} due '
                          '${payment.dueDate.month}/${payment.dueDate.day}/${payment.dueDate.year}'),
                      subtitle: Text(payment.statusDisplayName),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
      loading: () => const _InlineLoader(message: 'Fetching tenant account snapshot...'),
      error: (error, _) => Card(
        color: AppTheme.warning.withOpacity(0.1),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Icon(Icons.warning_amber_outlined, color: AppTheme.warning),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Unable to load tenant balance information. You can still create the payment.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _MetricTile({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: AppTheme.textTertiary),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: valueColor ?? theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
