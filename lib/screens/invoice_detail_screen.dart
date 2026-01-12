import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/invoice_model.dart';
import '../providers/invoice_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../services/invoice_service.dart';
import '../services/tenant_service.dart';
import '../services/facility_service.dart';
import '../models/tenant_model.dart';
import '../models/facility_model.dart';
import '../widgets/invoice_pdf_viewer.dart';

class InvoiceDetailScreen extends ConsumerStatefulWidget {
  final InvoiceModel invoice;
  final String facilityId;

  const InvoiceDetailScreen({
    super.key,
    required this.invoice,
    required this.facilityId,
  });

  @override
  ConsumerState<InvoiceDetailScreen> createState() => _InvoiceDetailScreenState();
}

class _InvoiceDetailScreenState extends ConsumerState<InvoiceDetailScreen> {
  bool _isGeneratingPDF = false;
  bool _isSending = false;

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/invoices',
      title: 'Invoice ${widget.invoice.invoiceNumber}',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        if (widget.invoice.pdfUrl == null)
          IconButton(
            icon: _isGeneratingPDF
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf),
            onPressed: _isGeneratingPDF ? null : _generatePDF,
            tooltip: 'Generate PDF',
          ),
        if (widget.invoice.pdfUrl != null)
          IconButton(
            icon: const Icon(Icons.email),
            onPressed: _isSending ? null : _sendInvoice,
            tooltip: 'Send Invoice',
          ),
        PopupMenuButton<String>(
          onSelected: _handleMenuAction,
          itemBuilder: (context) => [
            if (widget.invoice.status == InvoiceStatus.draft)
              const PopupMenuItem(
                value: 'send',
                child: ListTile(
                  leading: Icon(Icons.send),
                  title: Text('Send Invoice'),
                ),
              ),
            if (widget.invoice.status == InvoiceStatus.sent && widget.invoice.balance > 0)
              const PopupMenuItem(
                value: 'mark_paid',
                child: ListTile(
                  leading: Icon(Icons.check_circle),
                  title: Text('Mark as Paid'),
                ),
              ),
            if (widget.invoice.status != InvoiceStatus.voided)
              const PopupMenuItem(
                value: 'void',
                child: ListTile(
                  leading: Icon(Icons.cancel),
                  title: Text('Void Invoice'),
                ),
              ),
          ],
        ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatusCard(),
            const SizedBox(height: 16),
            _buildInvoiceInfo(),
            const SizedBox(height: 16),
            _buildLineItems(),
            const SizedBox(height: 16),
            _buildTotals(),
            if (widget.invoice.pdfUrl != null) ...[
              const SizedBox(height: 16),
              _buildPDFSection(),
            ],
            if (widget.invoice.paymentIds.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildPaymentHistory(),
            ],
            if (widget.invoice.notes != null && widget.invoice.notes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildNotes(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final statusColor = _getStatusColor(widget.invoice.status);
    
    return Card(
      color: statusColor.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: statusColor,
              child: Icon(
                _getStatusIcon(widget.invoice.status),
                color: AppTheme.textOnDark,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.invoice.statusDisplayName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    widget.invoice.formattedTotal,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (widget.invoice.balance > 0)
                    Text(
                      'Balance: ${widget.invoice.formattedBalance}',
                      style: TextStyle(
                        color: AppTheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (widget.invoice.isOverdue)
                    Text(
                      '${widget.invoice.daysOverdue} days overdue',
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

  Widget _buildInvoiceInfo() {
    final dateFormat = DateFormat('MMM d, yyyy');
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Invoice Information',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildInfoRow('Invoice Number', widget.invoice.invoiceNumber),
            _buildInfoRow('Issue Date', dateFormat.format(widget.invoice.issueDate)),
            _buildInfoRow('Due Date', dateFormat.format(widget.invoice.dueDate)),
            if (widget.invoice.paidDate != null)
              _buildInfoRow('Paid Date', dateFormat.format(widget.invoice.paidDate!)),
            if (widget.invoice.sentAt != null)
              _buildInfoRow('Sent Date', dateFormat.format(widget.invoice.sentAt!)),
            _buildInfoRow('Tenant ID', widget.invoice.tenantId),
            FutureBuilder<TenantModel?>(
              future: TenantService.getTenantById(widget.facilityId, widget.invoice.tenantId),
              builder: (context, snapshot) {
                if (snapshot.hasData && snapshot.data != null) {
                  return _buildInfoRow('Tenant Name', snapshot.data!.name);
                }
                return const SizedBox.shrink();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLineItems() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Line Items',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Table(
              columnWidths: const {
                0: FlexColumnWidth(3),
                1: FlexColumnWidth(1),
              },
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundLight,
                    border: Border(
                      bottom: BorderSide(color: AppTheme.borderLight),
                    ),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        'Description',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        'Amount',
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                ...widget.invoice.lineItems.map((item) {
                  return TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.description),
                            if (item.isProrated)
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.info.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'Prorated',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppTheme.info,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          item.formattedAmount,
                          textAlign: TextAlign.right,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  );
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTotals() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Subtotal:',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Text(
                  widget.invoice.formattedSubtotal,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
            if (widget.invoice.tax != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Tax:',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  Text(
                    widget.invoice.formattedTax!,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            ],
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
                  widget.invoice.formattedTotal,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (widget.invoice.balance > 0) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Balance:',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppTheme.error,
                    ),
                  ),
                  Text(
                    widget.invoice.formattedBalance,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppTheme.error,
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

  Widget _buildPDFSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Invoice PDF',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            InvoicePDFViewer(pdfUrl: widget.invoice.pdfUrl!),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    if (widget.invoice.pdfUrl != null) {
                      final uri = Uri.parse(widget.invoice.pdfUrl!);
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    }
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open in New Tab'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    if (widget.invoice.pdfUrl != null) {
                      final uri = Uri.parse(widget.invoice.pdfUrl!);
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    }
                  },
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

  Widget _buildPaymentHistory() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Payment History',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            ...widget.invoice.paymentIds.map((paymentId) {
              return ListTile(
                leading: const Icon(Icons.payment, color: AppTheme.success),
                title: Text('Payment $paymentId'),
                subtitle: Text('Applied to invoice'),
                trailing: IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () {
                    // Navigate to payment detail
                    context.push('${AppRoute.paymentDetail}?paymentId=$paymentId');
                  },
                ),
              );
            }),
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
              widget.invoice.notes!,
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

  Color _getStatusColor(InvoiceStatus status) {
    switch (status) {
      case InvoiceStatus.draft:
        return AppTheme.textTertiary;
      case InvoiceStatus.sent:
        return AppTheme.info;
      case InvoiceStatus.paid:
        return AppTheme.success;
      case InvoiceStatus.overdue:
        return AppTheme.error;
      case InvoiceStatus.voided:
        return AppTheme.textSecondary;
    }
  }

  IconData _getStatusIcon(InvoiceStatus status) {
    switch (status) {
      case InvoiceStatus.draft:
        return Icons.edit;
      case InvoiceStatus.sent:
        return Icons.send;
      case InvoiceStatus.paid:
        return Icons.check_circle;
      case InvoiceStatus.overdue:
        return Icons.warning;
      case InvoiceStatus.voided:
        return Icons.cancel;
    }
  }

  Future<void> _generatePDF() async {
    setState(() {
      _isGeneratingPDF = true;
    });

    try {
      final operations = ref.read(invoiceOperationsProvider.notifier);
      await operations.generateAndUploadPDF(
        invoice: widget.invoice,
        facilityId: widget.facilityId,
        invoiceId: widget.invoice.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PDF generated successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        // Refresh the invoice
        ref.invalidate(invoicesForFacilityProvider(widget.facilityId));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generating PDF: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingPDF = false;
        });
      }
    }
  }

  Future<void> _sendInvoice() async {
    setState(() {
      _isSending = true;
    });

    try {
      final operations = ref.read(invoiceOperationsProvider.notifier);
      await operations.sendInvoice(
        facilityId: widget.facilityId,
        invoiceId: widget.invoice.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invoice sent successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        // Refresh the invoice
        ref.invalidate(invoicesForFacilityProvider(widget.facilityId));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending invoice: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'send':
        _sendInvoice();
        break;
      case 'mark_paid':
        _markAsPaid();
        break;
      case 'void':
        _voidInvoice();
        break;
    }
  }

  Future<void> _markAsPaid() async {
    // Confirm action
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark Invoice as Paid'),
        content: Text(
          'Are you sure you want to mark invoice ${widget.invoice.invoiceNumber} as paid? This will set the balance to \$0.00.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Mark as Paid'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await InvoiceService.markInvoiceAsPaid(
        facilityId: widget.facilityId,
        invoiceId: widget.invoice.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invoice ${widget.invoice.invoiceNumber} marked as paid'),
            backgroundColor: AppTheme.success,
          ),
        );
        // Refresh the screen by popping and pushing again
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _voidInvoice() async {
    // Get reason from user
    String? reason;
    final reasonController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void Invoice'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Are you sure you want to void invoice ${widget.invoice.invoiceNumber}? This action cannot be undone.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: reasonController,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'Enter reason for voiding this invoice',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              reason = reasonController.text.trim();
              if (reason?.isEmpty ?? true) reason = null;
              Navigator.of(context).pop(true);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Void Invoice'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await InvoiceService.voidInvoice(
        facilityId: widget.facilityId,
        invoiceId: widget.invoice.id,
        reason: reason,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invoice ${widget.invoice.invoiceNumber} has been voided'),
            backgroundColor: AppTheme.warning,
          ),
        );
        // Refresh the screen by popping and pushing again
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString()}'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}

