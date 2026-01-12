import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/payment_model.dart';
import '../providers/payment_provider.dart';
import '../theme/app_theme.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: Text('Payment ${widget.payment.id.substring(0, 8)}...'),
        actions: [
          if (widget.payment.status == PaymentStatus.pending)
            IconButton(
              icon: const Icon(Icons.payment),
              onPressed: _processPayment,
            ),
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  leading: Icon(Icons.edit),
                  title: Text('Edit'),
                ),
              ),
              if (widget.payment.status == PaymentStatus.pending)
                const PopupMenuItem(
                  value: 'cancel',
                  child: ListTile(
                    leading: Icon(Icons.cancel),
                    title: Text('Cancel'),
                  ),
                ),
              const PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete),
                  title: Text('Delete'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatusCard(),
            const SizedBox(height: 16),
            _buildPaymentInfo(),
            const SizedBox(height: 16),
            _buildTimeline(),
            if (widget.payment.receiptUrl != null) ...[
              const SizedBox(height: 16),
              _buildReceiptSection(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Card(
      color: _getStatusColor(widget.payment.status).withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: _getStatusColor(widget.payment.status),
              child: Icon(
                _getStatusIcon(widget.payment.status),
                color: AppTheme.textOnDark,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.payment.statusDisplayName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: _getStatusColor(widget.payment.status),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    widget.payment.formattedAmount,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (widget.payment.isOverdue)
                    Text(
                      'Overdue by ${widget.payment.daysOverdue} days',
                      style: TextStyle(
                        color: AppTheme.error,
                        fontWeight: FontWeight.w500,
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

  Widget _buildPaymentInfo() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Payment Information',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildInfoRow('Amount', widget.payment.formattedAmount),
            _buildInfoRow('Method', widget.payment.methodDisplayName),
            _buildInfoRow('Due Date', _formatDate(widget.payment.dueDate)),
            if (widget.payment.paidDate != null)
              _buildInfoRow('Paid Date', _formatDate(widget.payment.paidDate!)),
            _buildInfoRow('Transaction ID', widget.payment.transactionId ?? 'N/A'),
            if (widget.payment.externalPaymentId != null)
              _buildInfoRow('External ID', widget.payment.externalPaymentId!),
            _buildInfoRow('Created', _formatDateTime(widget.payment.createdAt)),
            _buildInfoRow('Updated', _formatDateTime(widget.payment.updatedAt)),
            if (widget.payment.notes != null) ...[
              const SizedBox(height: 8),
              Text(
                'Notes',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(widget.payment.notes!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeline() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Timeline',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildTimelineItem(
              'Payment Created',
              _formatDateTime(widget.payment.createdAt),
              Icons.add_circle,
              AppTheme.primaryBlue,
            ),
            if (widget.payment.paidDate != null)
              _buildTimelineItem(
                'Payment Processed',
                _formatDateTime(widget.payment.paidDate!),
                Icons.check_circle,
                AppTheme.success,
              ),
            _buildTimelineItem(
              'Last Updated',
              _formatDateTime(widget.payment.updatedAt),
              Icons.update,
              AppTheme.warning,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineItem(String title, String date, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  date,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReceiptSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Receipt',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.receipt),
                const SizedBox(width: 8),
                const Text('Payment Receipt'),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _downloadReceipt,
                  icon: const Icon(Icons.download),
                  label: const Text('Download'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.pending:
        return AppTheme.warning;
      case PaymentStatus.paid:
        return AppTheme.success;
      case PaymentStatus.completed:
        return AppTheme.success;
      case PaymentStatus.failed:
        return AppTheme.error;
      case PaymentStatus.refunded:
        return AppTheme.primaryBlue;
      case PaymentStatus.cancelled:
        return AppTheme.textTertiary;
    }
  }

  IconData _getStatusIcon(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.pending:
        return Icons.pending;
      case PaymentStatus.paid:
        return Icons.check;
      case PaymentStatus.completed:
        return Icons.check;
      case PaymentStatus.failed:
        return Icons.error;
      case PaymentStatus.refunded:
        return Icons.refresh;
      case PaymentStatus.cancelled:
        return Icons.cancel;
    }
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
              await ref.read(paymentOperationsProvider.notifier).processPayment(
                facilityId: widget.payment.facilityId,
                paymentId: widget.payment.id,
                method: widget.payment.method,
              );
              if (mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Payment processed successfully')),
                );
              }
            },
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
    // TODO: Implement edit payment
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Edit payment feature coming soon')),
    );
  }

  void _cancelPayment() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel Payment'),
        content: const Text('Are you sure you want to cancel this payment?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await ref.read(paymentOperationsProvider.notifier).updatePayment(
                facilityId: widget.payment.facilityId,
                paymentId: widget.payment.id,
              );
              if (mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Payment cancelled')),
                );
              }
            },
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
        content: const Text('Are you sure you want to delete this payment? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await ref.read(paymentOperationsProvider.notifier).deletePayment(widget.payment.facilityId, widget.payment.id);
              if (mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Payment deleted')),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _downloadReceipt() {
    // TODO: Implement receipt download
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Receipt download feature coming soon')),
    );
  }
}
