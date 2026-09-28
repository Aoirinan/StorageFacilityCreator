import 'package:flutter/material.dart';
import '../widgets/keyboard_scrollable.dart';
import '../utils/error_message_helper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../models/payment_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import '../providers/payment_provider.dart';
import '../providers/tenant_provider.dart';
import '../providers/facility_provider.dart';
import '../models/provider_params.dart';
import '../theme/app_theme.dart';
import 'tenant_creation_screen.dart';
import 'package:sfcapp/screens/tenant_past_history_dialog.dart';
import '../router/app_route.dart';
import 'package:sfcapp/router/back_navigation.dart';

/// Record a payment received from a tenant (Payments -> Create Payment, and
/// the calendar's "Payment received").
///
/// This screen used to create a "payment request": a pending payment doc
/// with a pending ledger entry that nothing ever posted, behind a required
/// contract that tenants imported without one could not pick ("Select a
/// tenant and contract first"). The rules refused that payload for owners
/// anyway (a client may only create a payment that is completed and dated
/// now), so the screen saved nothing. It now records money received today
/// through the same path as the tenant page's Record payment dialog
/// (PaymentService.recordManualPayment): a completed payment, a posted
/// ledger line, and paidThrough moved on by the months it buys. Money
/// received on earlier dates goes through Enter past history.
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
  final _referenceController = TextEditingController();
  final _notesController = TextEditingController();

  TenantModel? _selectedTenant;
  PaymentMethod _selectedMethod = PaymentMethod.cash;
  bool _submitting = false;

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    return KeyboardScrollable(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Record a payment received',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
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

                      final selectedId = _selectedTenant?.id;
                      return DropdownButtonFormField<String>(
                        value: tenants.any((t) => t.id == selectedId) ? selectedId : null,
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
                            _selectedTenant = tenants.where((t) => t.id == value).firstOrNull;
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
              if (_selectedTenant != null) ...[
                _TenantSnapshot(facilityId: widget.facilityId, tenantId: _selectedTenant!.id),
                const SizedBox(height: 16),
              ],

              // Amount
              TextFormField(
                controller: _amountController,
                decoration: const InputDecoration(
                  labelText: 'Amount *',
                  prefixText: '\$',
                  border: OutlineInputBorder(),
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter an amount';
                  }
                  final amount = double.tryParse(value);
                  if (amount == null || amount < 0.01) {
                    return 'Please enter a valid amount';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Payment method: the ways money reaches an owner outside the
              // card flow. Card payments go through the tenant page's Stripe
              // buttons, which record themselves.
              DropdownButtonFormField<PaymentMethod>(
                initialValue: _selectedMethod,
                decoration: const InputDecoration(
                  labelText: 'Payment Method *',
                  border: OutlineInputBorder(),
                ),
                items: manualPaymentMethods.map((method) {
                  return DropdownMenuItem(
                    value: method,
                    child: Text(method.displayName),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedMethod = value ?? PaymentMethod.cash;
                  });
                },
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _referenceController,
                decoration: const InputDecoration(
                  labelText: 'Check # / reference',
                  border: OutlineInputBorder(),
                ),
                maxLength: 100,
              ),
              const SizedBox(height: 8),

              // Date received: today. The rules date a client-recorded
              // payment at the server's clock.
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Date received',
                  border: OutlineInputBorder(),
                ),
                child: Text('Today (${_formatDate(today)})'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Received on an earlier date? ',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                    ),
                    TextButton(
                      onPressed: _selectedTenant == null
                          ? null
                          : () => showTenantPastHistoryDialog(context, _selectedTenant!),
                      child: Text(_selectedTenant == null
                          ? 'Pick a tenant, then use Enter past history'
                          : 'Enter past history for ${_selectedTenant!.name}'),
                    ),
                  ],
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

              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _submitting ? null : _submitForm,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save),
                  label: Text(_submitting ? 'Saving...' : 'Record payment'),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
      );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  void _submitForm() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;
    final tenant = _selectedTenant;
    if (tenant == null) return;

    final amount = double.parse(_amountController.text.trim());
    String? trimmed(TextEditingController c) {
      final v = c.text.trim();
      return v.isEmpty ? null : v;
    }

    setState(() => _submitting = true);
    try {
      // The contract is not asked for: the payment stores the tenant's own
      // contractId, or '' for a tenant without one, as the other writers do.
      await ref.read(paymentOperationsProvider.notifier).recordManualPayment(
        facilityId: widget.facilityId,
        tenantId: tenant.id,
        amount: amount,
        method: _selectedMethod,
        notes: trimmed(_notesController),
        reference: trimmed(_referenceController),
      );

      if (mounted) {
        ref.invalidate(paymentListProvider(widget.facilityId));
        ref.invalidate(paymentStatsProvider(widget.facilityId));
        ref.invalidate(facilityTenantsProvider(widget.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment recorded')),
        );
        // The calendar reaches this screen with context.go, which leaves
        // nothing on the stack to pop, so fall back to the payments list
        // rather than popping out of the shell.
        popOrGo(context, AppRoute.payments);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error recording payment: ${ErrorMessageHelper.getUserFriendlyMessage(e)}')),
        );
      }
    } finally {
      // Without this the button stayed disabled after any failure and the
      // operator had to leave the screen to try again.
      if (mounted) setState(() => _submitting = false);
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
    // Outstanding Balance is the ledger's: the sum of posted entries, the
    // Ledger screen's Current Balance. It summed unpaid payment docs, which
    // leaves out every rent charge the monthly job raises, so the two
    // screens disagreed about what a tenant owed.
    final balanceAsync = ref.watch(ledgerBalanceProvider(
      LedgerParams(tenantId: tenantId, facilityId: facilityId),
    ));

    return summaryAsync.when(
      data: (summary) {
        final balance = balanceAsync.hasError ? null : balanceAsync.value;
        final balanceText = balanceAsync.hasError
            ? 'Unavailable'
            : balance == null
                ? '…'
                : balance < 0
                    ? '(\$${balance.abs().toStringAsFixed(2)}) credit'
                    : '\$${balance.toStringAsFixed(2)}';
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
                        value: balanceText,
                        valueColor: balance == null
                            ? null
                            : balance > 0
                                ? AppTheme.error
                                : AppTheme.success,
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
