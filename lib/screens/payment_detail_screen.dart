import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/payment_model.dart';
import '../models/tenant_model.dart';
import '../providers/payment_provider.dart';
import '../providers/tenant_provider.dart';
import '../services/payment_service.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import '../utils/error_message_helper.dart';

class PaymentDetailScreen extends ConsumerStatefulWidget {
  final PaymentModel payment;

  const PaymentDetailScreen({
    super.key,
    required this.payment,
  });

  @override
  ConsumerState<PaymentDetailScreen> createState() => _PaymentDetailScreenState();
}

class _PaymentDetailScreenState extends ConsumerState<PaymentDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatusCard(),
                const SizedBox(height: 24),
                _buildPaymentInfo(),
                const SizedBox(height: 24),
                _buildTimeline(),
                if (widget.payment.receiptUrl != null) ...[
                  const SizedBox(height: 24),
                  _buildReceiptSection(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _paymentHeaderTitle() {
    final tenants = ref
        .watch(facilityTenantsProvider(widget.payment.facilityId))
        .whenOrNull(data: (v) => v);
    var line = widget.payment.snapshotPayerLine;
    if (line == null && tenants != null && widget.payment.tenantId.isNotEmpty) {
      for (final t in tenants) {
        if (t.id == widget.payment.tenantId) {
          final u = t.unitNumber.trim();
          line = u.isNotEmpty ? '${t.name} · Unit $u' : t.name;
          break;
        }
      }
    }
    final base = 'Payment ${widget.payment.formattedAmount}';
    if (line == null || line.isEmpty) return base;
    return '$base · $line';
  }

  Widget _buildHeader() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outline),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go(AppRoute.payments),
            tooltip: 'Back',
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _paymentHeaderTitle(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          if (widget.payment.status == PaymentStatus.pending)
            IconButton(
              icon: const Icon(Icons.payment),
              onPressed: _processPayment,
              tooltip: 'Process payment',
              color: cs.primary,
            ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            onPressed: () {
              if (widget.payment.receiptUrl != null) {
                _downloadReceipt();
              }
            },
            tooltip: 'Open receipt',
            color: cs.onSurfaceVariant,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 20),
                    SizedBox(width: 12),
                    Text('Edit'),
                  ],
                ),
              ),
              if (widget.payment.status == PaymentStatus.pending)
                const PopupMenuItem(
                  value: 'cancel',
                  child: Row(
                    children: [
                      Icon(Icons.cancel_outlined, size: 20),
                      SizedBox(width: 12),
                      Text('Cancel'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 20, color: AppTheme.error),
                    SizedBox(width: 12),
                    Text('Delete', style: TextStyle(color: AppTheme.error)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final statusColor = _getStatusColor(widget.payment.status);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _getStatusIcon(widget.payment.status),
              color: Theme.of(context).colorScheme.onPrimary,
              size: 28,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.payment.statusDisplayName,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.payment.formattedAmount,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                if (widget.payment.isOverdue) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Overdue by ${widget.payment.daysOverdue} days',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaymentInfo() {
    final cs = Theme.of(context).colorScheme;
    final reference = widget.payment.effectiveTransactionReference;
    final tenants = ref
        .watch(facilityTenantsProvider(widget.payment.facilityId))
        .whenOrNull(data: (v) => v);
    TenantModel? tenant;
    if (tenants != null) {
      for (final t in tenants) {
        if (t.id == widget.payment.tenantId) {
          tenant = t;
          break;
        }
      }
    }
    final snapName = widget.payment.snapshotTenantName?.trim();
    final tenantLabel = (snapName != null && snapName.isNotEmpty)
        ? snapName
        : (tenant?.name ??
            (widget.payment.tenantId.isEmpty ? '—' : 'Unknown tenant'));
    final unitVal = (widget.payment.snapshotUnitNumber ?? tenant?.unitNumber ?? '').trim();
    final metadataPurpose = _paymentMetadataPurpose(widget.payment.metadata);
    final notes = widget.payment.notes?.trim();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Payment Information',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          _buildInfoRow('Tenant', tenantLabel),
          if (unitVal.isNotEmpty) _buildInfoRow('Unit', unitVal),
          if (metadataPurpose != null) _buildInfoRow('Details', metadataPurpose),
          _buildInfoRow('Method', widget.payment.methodDisplayName),
          if (notes != null && notes.isNotEmpty) _buildInfoRow('Notes', notes),
          if (!widget.payment.isPaid)
            _buildInfoRow('Due Date', _formatDate(widget.payment.dueDate)),
          if (widget.payment.isPaid && widget.payment.paidDate != null)
            _buildInfoRow('Paid Date', _formatDate(widget.payment.paidDate!)),
          if (reference != null) _buildInfoRow('Reference', reference),
          if (metadataPurpose == null && (notes == null || notes.isEmpty)) ...[
            const SizedBox(height: 12),
            Text(
              'Without a linked invoice line item, this amount is credited to the tenant’s account. '
              'Open the tenant’s ledger to see how it was applied to charges.',
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    final timelineItems = <_TimelineEntry>[
      _TimelineEntry(
        'Payment Created',
        _formatDateTime(widget.payment.createdAt),
        Icons.add_circle_outline,
        AppTheme.primaryBlue,
      ),
      if (widget.payment.paidDate != null)
        _TimelineEntry(
          'Payment Processed',
          _formatDateTime(widget.payment.paidDate!),
          Icons.check_circle_outline,
          AppTheme.success,
        ),
    ];
    // Only add "Last Updated" if it differs from the most recent event
    final lastEvent = widget.payment.paidDate ?? widget.payment.createdAt;
    if (widget.payment.updatedAt.difference(lastEvent).inSeconds.abs() > 1) {
      timelineItems.add(_TimelineEntry(
        'Last Updated',
        _formatDateTime(widget.payment.updatedAt),
        Icons.update,
        Theme.of(context).colorScheme.onSurfaceVariant,
      ));
    }

    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Timeline',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          ...timelineItems.asMap().entries.map((entry) {
            final isLast = entry.key == timelineItems.length - 1;
            return _buildTimelineItem(
              entry.value.title,
              entry.value.date,
              entry.value.icon,
              entry.value.color,
              showConnector: !isLast,
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTimelineItem(
    String title,
    String date,
    IconData icon,
    Color color, {
    bool showConnector = true,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              if (showConnector)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    date,
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptSection() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outline),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Receipt',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.receipt_long,
                  color: cs.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  'Payment Receipt',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface,
                  ),
                ),
              ),
              ElevatedButton.icon(
                onPressed: _downloadReceipt,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('Download'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.pending:
        return AppTheme.warning;
      case PaymentStatus.paid:
      case PaymentStatus.completed:
        return AppTheme.success;
      case PaymentStatus.failed:
        return AppTheme.error;
      case PaymentStatus.refunded:
        return AppTheme.primaryBlue;
      case PaymentStatus.cancelled:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }

  IconData _getStatusIcon(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.pending:
        return Icons.pending;
      case PaymentStatus.paid:
      case PaymentStatus.completed:
        return Icons.check;
      case PaymentStatus.failed:
        return Icons.error_outline;
      case PaymentStatus.refunded:
        return Icons.refresh;
      case PaymentStatus.cancelled:
        return Icons.cancel_outlined;
    }
  }

  /// Optional invoice / description fields sometimes stored on payment metadata.
  String? _paymentMetadataPurpose(Map<String, dynamic>? metadata) {
    if (metadata == null || metadata.isEmpty) return null;
    const keys = ['invoiceNumber', 'invoiceId', 'statementDescription', 'description', 'purpose'];
    for (final k in keys) {
      final v = metadata[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }

  String _formatDateTime(DateTime date) {
    return '${date.month}/${date.day}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  void _processPayment() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Process Payment'),
        content: Text('Process payment of ${widget.payment.formattedAmount}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await ref.read(paymentOperationsProvider.notifier).processPayment(
                  facilityId: widget.payment.facilityId,
                  paymentId: widget.payment.id,
                  method: widget.payment.method,
                );
                if (!mounted) return;
                context.go(AppRoute.payments);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Payment processed successfully'),
                    backgroundColor: AppTheme.success,
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
                    backgroundColor: AppTheme.error,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Process'),
          ),
        ],
      ),
    );
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'edit':
        _editPayment();
        break;
      case 'cancel':
        _cancelPayment();
        break;
      case 'delete':
        _deletePayment();
        break;
    }
  }

  void _editPayment() {
    final amountController = TextEditingController(
      text: widget.payment.amount.toStringAsFixed(2),
    );
    final notesController = TextEditingController(text: widget.payment.notes ?? '');
    PaymentMethod selectedMethod = widget.payment.method;
    DateTime selectedDueDate = widget.payment.dueDate;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit Payment'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: amountController,
                  decoration: const InputDecoration(
                    labelText: 'Amount *',
                    border: OutlineInputBorder(),
                    prefixText: '\$',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<PaymentMethod>(
                  value: selectedMethod,
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
                    if (value != null) {
                      setDialogState(() => selectedMethod = value);
                    }
                  },
                ),
                const SizedBox(height: 16),
                ListTile(
                  title: const Text('Due Date'),
                  subtitle: Text(
                    '${selectedDueDate.year}-${selectedDueDate.month.toString().padLeft(2, '0')}-${selectedDueDate.day.toString().padLeft(2, '0')}',
                  ),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: selectedDueDate,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) {
                      setDialogState(() => selectedDueDate = picked);
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final amount = double.tryParse(amountController.text);
                if (amount == null || amount <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please enter a valid amount')),
                  );
                  return;
                }
                try {
                  await PaymentService.updatePayment(
                    facilityId: widget.payment.facilityId,
                    paymentId: widget.payment.id,
                    amount: amount,
                    method: selectedMethod,
                    dueDate: selectedDueDate,
                    notes: notesController.text.isEmpty
                        ? null
                        : notesController.text,
                  );
                  if (context.mounted) {
                    Navigator.of(context).pop();
                    setState(() {});
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Payment updated successfully'),
                        backgroundColor: AppTheme.success,
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error updating payment: $e'),
                        backgroundColor: AppTheme.error,
                      ),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryBlue,
                foregroundColor: AppTheme.textOnDark,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _cancelPayment() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Payment'),
        content: const Text(
          'Are you sure you want to cancel this payment?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await PaymentService.updatePayment(
                  facilityId: widget.payment.facilityId,
                  paymentId: widget.payment.id,
                  status: PaymentStatus.cancelled,
                );
                if (mounted) {
                  context.go(AppRoute.payments);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Payment cancelled'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error cancelling payment: $e'),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryBlue,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
  }

  void _deletePayment() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Payment'),
        content: const Text(
          'Are you sure you want to delete this payment? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await ref.read(paymentOperationsProvider.notifier).deletePayment(
                  widget.payment.facilityId,
                  widget.payment.id,
                );
                if (!mounted) return;
                context.go(AppRoute.payments);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Payment deleted'),
                    backgroundColor: AppTheme.success,
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
                    backgroundColor: AppTheme.error,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _downloadReceipt() async {
    if (widget.payment.receiptUrl == null ||
        widget.payment.receiptUrl!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No receipt available for this payment'),
        ),
      );
      return;
    }

    final receiptUrl = Uri.parse(widget.payment.receiptUrl!);
    if (await canLaunchUrl(receiptUrl)) {
      await launchUrl(receiptUrl, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open receipt URL')),
        );
      }
    }
  }
}

class _TimelineEntry {
  final String title;
  final String date;
  final IconData icon;
  final Color color;

  _TimelineEntry(this.title, this.date, this.icon, this.color);
}
