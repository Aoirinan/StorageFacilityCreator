import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/deposit_model.dart';
import '../services/deposit_service.dart';
import '../services/payment_service.dart';
import '../models/payment_model.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';

class DepositDetailScreen extends ConsumerStatefulWidget {
  final DepositModel deposit;
  final String facilityId;

  const DepositDetailScreen({
    super.key,
    required this.deposit,
    required this.facilityId,
  });

  @override
  ConsumerState<DepositDetailScreen> createState() => _DepositDetailScreenState();
}

class _DepositDetailScreenState extends ConsumerState<DepositDetailScreen> {
  bool _isUpdating = false;

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MMM d, yyyy');
    
    return SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatusCard(),
            const SizedBox(height: 16),
            _buildDepositInfo(),
            const SizedBox(height: 16),
            _buildAmountBreakdown(),
            if (widget.deposit.paymentIds.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildPaymentsList(),
            ],
            if (widget.deposit.notes != null && widget.deposit.notes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildNotes(),
            ],
          ],
        ),
      );
  }

  Widget _buildStatusCard() {
    final statusColor = _getStatusColor(widget.deposit.status);
    
    return Card(
      color: statusColor.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: statusColor,
              child: Icon(
                _getStatusIcon(widget.deposit.status),
                color: AppTheme.textOnDark,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.deposit.statusDisplayName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    widget.deposit.formattedTotal,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDepositInfo() {
    final dateFormat = DateFormat('MMM d, yyyy');
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Deposit Information',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildInfoRow('Deposit Number', widget.deposit.depositNumber),
            _buildInfoRow('Method', widget.deposit.methodDisplayName),
            _buildInfoRow('Deposit Date', dateFormat.format(widget.deposit.depositDate)),
            if (widget.deposit.bankDepositDate != null)
              _buildInfoRow('Bank Deposit Date', dateFormat.format(widget.deposit.bankDepositDate!)),
            if (widget.deposit.bankAccount != null)
              _buildInfoRow('Bank Account', widget.deposit.bankAccount!),
            if (widget.deposit.referenceNumber != null)
              _buildInfoRow('Reference Number', widget.deposit.referenceNumber!),
            if (widget.deposit.reconciledAt != null)
              _buildInfoRow('Reconciled At', dateFormat.format(widget.deposit.reconciledAt!)),
          ],
        ),
      ),
    );
  }

  Widget _buildAmountBreakdown() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Amount Breakdown',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            if (widget.deposit.cashAmount != null)
              _buildAmountRow('Cash', widget.deposit.cashAmount!),
            if (widget.deposit.checkAmount != null) ...[
              _buildAmountRow('Check', widget.deposit.checkAmount!),
              if (widget.deposit.checkCount != null)
                Padding(
                  padding: const EdgeInsets.only(left: 16.0, top: 4.0),
                  child: Text(
                    '${widget.deposit.checkCount} check(s)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
            ],
            if (widget.deposit.creditCardAmount != null)
              _buildAmountRow('Credit Card', widget.deposit.creditCardAmount!),
            if (widget.deposit.achAmount != null)
              _buildAmountRow('ACH', widget.deposit.achAmount!),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total:',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  widget.deposit.formattedTotal,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (widget.deposit.overShort != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Over/Short:',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: widget.deposit.overShort! > 0 ? AppTheme.success : AppTheme.error,
                    ),
                  ),
                  Text(
                    widget.deposit.formattedOverShort!,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: widget.deposit.overShort! > 0 ? AppTheme.success : AppTheme.error,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAmountRow(String label, double amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentsList() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Payments in Deposit',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            FutureBuilder<List<PaymentModel>>(
              future: _loadPayments(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                
                if (snapshot.hasError) {
                  return Text('Error loading payments: ${snapshot.error}');
                }
                
                final payments = snapshot.data ?? [];
                if (payments.isEmpty) {
                  return const Text('No payments found');
                }
                
                return Column(
                  children: payments.map((payment) {
                    return ListTile(
                      leading: const Icon(Icons.payment, color: AppTheme.success),
                      title: Text(payment.formattedAmount),
                      subtitle: Text('${payment.methodDisplayName} • ${payment.tenantId.substring(0, 8)}...'),
                      trailing: IconButton(
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () {
                          context.push(
                            '${AppRoute.paymentDetail}?paymentId=${payment.id}',
                          );
                        },
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotes() {
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
            const SizedBox(height: 8),
            Text(
              widget.deposit.notes!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(DepositStatus status) {
    switch (status) {
      case DepositStatus.pending:
        return AppTheme.warning;
      case DepositStatus.deposited:
        return AppTheme.info;
      case DepositStatus.reconciled:
        return AppTheme.success;
      case DepositStatus.cancelled:
        return AppTheme.textSecondary;
    }
  }

  IconData _getStatusIcon(DepositStatus status) {
    switch (status) {
      case DepositStatus.pending:
        return Icons.pending;
      case DepositStatus.deposited:
        return Icons.check_circle;
      case DepositStatus.reconciled:
        return Icons.verified;
      case DepositStatus.cancelled:
        return Icons.cancel;
    }
  }

  Future<List<PaymentModel>> _loadPayments() async {
    final payments = <PaymentModel>[];
    for (final paymentId in widget.deposit.paymentIds) {
      try {
        final payment = await PaymentService.getPayment(
          facilityId: widget.facilityId,
          paymentId: paymentId,
        );
        if (payment != null) {
          payments.add(payment);
        }
      } catch (e) {
        // Skip payments that can't be loaded
      }
    }
    return payments;
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'mark_deposited':
        _updateStatus(DepositStatus.deposited);
        break;
      case 'reconcile':
        _showReconcileDialog();
        break;
      case 'cancel':
        _updateStatus(DepositStatus.cancelled);
        break;
    }
  }

  void _showReconcileDialog() {
    final overShortController = TextEditingController();
    final referenceController = TextEditingController();
    DateTime? bankDepositDate = widget.deposit.bankDepositDate ?? DateTime.now();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Reconcile Deposit'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('Bank Deposit Date'),
                  subtitle: Text(DateFormat('MMM d, yyyy').format(bankDepositDate ?? DateTime.now())),
                  trailing: IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: bankDepositDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                      );
                      if (date != null) {
                        setState(() {
                          bankDepositDate = date;
                        });
                      }
                    },
                  ),
                ),
                TextField(
                  controller: referenceController,
                  decoration: const InputDecoration(
                    labelText: 'Bank Reference Number (Optional)',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: overShortController,
                  decoration: const InputDecoration(
                    labelText: 'Over/Short Amount (Optional)',
                    prefixText: '\$',
                    helperText: 'Positive = over, Negative = short',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final overShort = double.tryParse(overShortController.text);
                _reconcileDeposit(
                  bankDepositDate: bankDepositDate,
                  referenceNumber: referenceController.text.isEmpty ? null : referenceController.text,
                  overShort: overShort,
                );
                Navigator.pop(context);
              },
              child: const Text('Reconcile'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _updateStatus(DepositStatus status) async {
    setState(() {
      _isUpdating = true;
    });

    try {
      await DepositService.updateDepositStatus(
        facilityId: widget.facilityId,
        depositId: widget.deposit.id,
        status: status,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deposit ${status.name} successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        context.pop(true); // Refresh list
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating deposit: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  Future<void> _reconcileDeposit({
    required DateTime? bankDepositDate,
    String? referenceNumber,
    double? overShort,
  }) async {
    setState(() {
      _isUpdating = true;
    });

    try {
      await DepositService.updateDepositStatus(
        facilityId: widget.facilityId,
        depositId: widget.deposit.id,
        status: DepositStatus.reconciled,
        bankDepositDate: bankDepositDate,
        referenceNumber: referenceNumber,
        overShort: overShort,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Deposit reconciled successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        context.pop(true); // Refresh list
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error reconciling deposit: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }
}

