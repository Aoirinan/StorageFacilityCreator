import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/invoice_model.dart';
import '../models/invoice_status_actions.dart';
import '../providers/invoice_provider.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import 'package:sfcapp/router/back_navigation.dart';
import '../services/invoice_service.dart';
import '../services/tenant_service.dart';
import '../services/facility_service.dart';
import '../models/tenant_model.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/invoice_edit_rules.dart';
import 'package:sfcapp/utils/print_util.dart';
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
  // Send, mark paid or void in flight. The action buttons stayed live while
  // one ran, so a second tap emailed the tenant twice, or ran mark paid a
  // second time before the first had written.
  bool _isRunningAction = false;
  bool _isPreparingPrint = false;
  bool _isSavingEdits = false;
  late InvoiceModel _invoice = widget.invoice;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatusCard(),
            const SizedBox(height: 16),
            // An invoice could be looked at and its PDF opened, and nothing
            // else: _handleMenuAction dispatched send, mark paid and void from
            // a menu that was never built, and _generatePDF had no caller
            // either, so an invoice with no PDF yet could not be given one.
            _buildInvoiceActions(),
            _buildInvoiceInfo(),
            const SizedBox(height: 16),
            _buildLineItems(),
            const SizedBox(height: 16),
            _buildTotals(),
            if (_invoice.pdfUrl != null) ...[
              const SizedBox(height: 16),
              _buildPDFSection(),
            ],
            if (_invoice.paymentIds.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildPaymentHistory(),
            ],
            if (_invoice.notes != null && _invoice.notes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildNotes(),
            ],
          ],
        ),
      );
  }

  Widget _buildStatusCard() {
    final statusColor = _getStatusColor(_invoice.status);
    
    return Card(
      color: statusColor.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: statusColor,
              child: Icon(
                _getStatusIcon(_invoice.status),
                color: AppTheme.textOnDark,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _invoice.statusDisplayName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    _invoice.formattedTotal,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (_invoice.balance > 0)
                    Text(
                      'Balance: ${_invoice.formattedBalance}',
                      style: TextStyle(
                        color: AppTheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  if (_invoice.isOverdue)
                    Text(
                      '${_invoice.daysOverdue} days overdue',
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
            _buildInfoRow('Invoice Number', _invoice.invoiceNumber),
            _buildInfoRow('Issue Date', dateFormat.format(_invoice.issueDate)),
            _buildInfoRow('Due Date', dateFormat.format(_invoice.dueDate)),
            if (_invoice.paidDate != null)
              _buildInfoRow('Paid Date', dateFormat.format(_invoice.paidDate!)),
            if (_invoice.sentAt != null)
              _buildInfoRow('Sent Date', dateFormat.format(_invoice.sentAt!)),
            // The tenant's name and unit, not the Firestore id that used to
            // lead this section. The id is what the record is keyed by, not
            // anything an operator recognises or can act on.
            FutureBuilder<TenantModel?>(
              future: TenantService.getTenantById(widget.facilityId, _invoice.tenantId),
              builder: (context, snapshot) {
                final tenant = snapshot.data;
                if (tenant == null) {
                  return _buildInfoRow(
                    'Tenant',
                    snapshot.connectionState == ConnectionState.waiting
                        ? 'Loading...'
                        : 'No longer on file',
                  );
                }
                final unit = tenant.unitNumber.trim();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoRow('Tenant', tenant.name),
                    if (unit.isNotEmpty) _buildInfoRow('Unit', unit),
                  ],
                );
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
                ..._invoice.lineItems.map((item) {
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
                  _invoice.formattedSubtotal,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
            if (_invoice.tax != null) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Tax:',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  Text(
                    _invoice.formattedTax!,
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
                  _invoice.formattedTotal,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (_invoice.balance > 0) ...[
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
                    _invoice.formattedBalance,
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
            InvoicePDFViewer(pdfUrl: _invoice.pdfUrl!),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: () async {
                    if (_invoice.pdfUrl != null) {
                      final uri = Uri.parse(_invoice.pdfUrl!);
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
                    if (_invoice.pdfUrl != null) {
                      final uri = Uri.parse(_invoice.pdfUrl!);
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
            ..._invoice.paymentIds.map((paymentId) {
              return ListTile(
                leading: const Icon(Icons.payment, color: AppTheme.success),
                title: Text('Payment $paymentId'),
                subtitle: Text('Applied to invoice'),
                trailing: IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () {
                    // Navigate to payment detail
                    // With the facility: the payment page loads by both ids
                    // and showed "Page not found" without it.
                    context.push(AppRoute.paymentDetailFor(
                      paymentId: paymentId,
                      facilityId: widget.facilityId,
                    ));
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
              _invoice.notes!,
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
        invoice: _invoice,
        facilityId: widget.facilityId,
        invoiceId: _invoice.id,
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
        invoiceId: _invoice.id,
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
            // A refusal (no email address, a closed invoice) or an emailed
            // invoice not marked sent explains itself.
            content: Text(
              'Error sending invoice: ${ErrorMessageHelper.getUserFriendlyMessage(e)}',
            ),
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

  /// Builds the printable invoice and opens the print dialog.
  ///
  /// The tenant and facility are read here rather than passed in, because the
  /// printed document has to carry both parties' details — a tenant's name and
  /// unit alone is not something an operator can send to a customer.
  Future<void> _printInvoice() async {
    setState(() => _isPreparingPrint = true);
    try {
      final tenant = await TenantService.getTenantById(
        widget.facilityId,
        _invoice.tenantId,
      );
      final facility = await FacilityService.getFacility(widget.facilityId);
      if (facility == null) {
        throw Exception('Facility not found');
      }

      final money = NumberFormat.currency(symbol: '\$');
      final date = DateFormat('MMM d, yyyy');

      printInvoice(
        facilityName: facility.name,
        facilityAddress: facility.address,
        facilityPhone: facility.phone,
        facilityEmail: facility.email,
        tenantName: tenant?.name ?? 'Tenant',
        tenantAddress: tenant?.addresses.isNotEmpty == true
            ? tenant!.addresses.first.toString()
            : null,
        tenantPhone: tenant?.phone,
        tenantEmail: tenant?.email,
        unitNumber: tenant?.unitNumber,
        invoiceNumber: _invoice.invoiceNumber,
        issueDateFormatted: date.format(_invoice.issueDate),
        dueDateFormatted: date.format(_invoice.dueDate),
        lineItems: _invoice.lineItems
            .map((item) => (
                  description: item.description,
                  amount: money.format(item.amount),
                ))
            .toList(),
        subtotalFormatted: money.format(_invoice.subtotal),
        taxFormatted: _invoice.tax != null && _invoice.tax! > 0
            ? money.format(_invoice.tax)
            : null,
        totalFormatted: money.format(_invoice.total),
        balanceFormatted: money.format(_invoice.balance),
        notes: _invoice.notes,
        statusLabel: _invoice.status == InvoiceStatus.paid ? 'Paid' : null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not prepare the invoice for printing: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPreparingPrint = false);
    }
  }

  /// Lets the operator change the due date, the notes, and — while the invoice
  /// is still a draft — its number.
  ///
  /// Amounts are absent on purpose: they come from the ledger entries this
  /// invoice was generated from. See lib/utils/invoice_edit_rules.dart.
  Future<void> _openEditSheet() async {
    final dateFormat = DateFormat('MMM d, yyyy');
    final numberController = TextEditingController(text: _invoice.invoiceNumber);
    final notesController = TextEditingController(text: _invoice.notes ?? '');
    var dueDate = _invoice.dueDate;
    final numberEditable = canEditInvoiceNumber(_invoice.status);

    // Every other number in use at this facility, so a clash is caught while
    // the operator is still typing rather than on save.
    final otherNumbers = ref
        .read(invoicesForFacilityProvider(widget.facilityId))
        .maybeWhen(data: (list) => list, orElse: () => const <InvoiceModel>[])
        .where((i) => i.id != _invoice.id)
        .map((i) => i.invoiceNumber)
        .toList();

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        String? numberError;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Edit invoice details'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: numberController,
                      enabled: numberEditable,
                      decoration: InputDecoration(
                        labelText: 'Invoice number',
                        border: const OutlineInputBorder(),
                        errorText: numberError,
                        helperText: numberEditable
                            ? 'Use your own numbering if you have one'
                            : invoiceNumberLockReason(_invoice.status),
                        helperMaxLines: 3,
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: dueDate,
                          firstDate: DateTime(DateTime.now().year - 2),
                          lastDate: DateTime(DateTime.now().year + 5),
                        );
                        if (picked != null) {
                          setDialogState(() => dueDate = picked);
                        }
                      },
                      icon: const Icon(Icons.calendar_today, size: 18),
                      label: Text('Due ${dateFormat.format(dueDate)}'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: notesController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Notes',
                        hintText: 'Anything the tenant should see on the invoice',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (numberEditable) {
                      final error = validateInvoiceNumber(
                        numberController.text,
                        existingNumbers: otherNumbers,
                      );
                      if (error != null) {
                        setDialogState(() => numberError = error);
                        return;
                      }
                    }
                    Navigator.of(dialogContext).pop(true);
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;

    setState(() => _isSavingEdits = true);
    try {
      await InvoiceService.updateInvoiceDetails(
        facilityId: widget.facilityId,
        invoiceId: _invoice.id,
        dueDate: dueDate,
        notes: notesController.text,
        invoiceNumber: numberEditable ? numberController.text.trim() : null,
      );

      final trimmedNotes = notesController.text.trim();
      setState(() {
        _invoice = _invoice.copyWith(
          dueDate: dueDate,
          notes: trimmedNotes.isEmpty ? null : trimmedNotes,
          invoiceNumber:
              numberEditable ? numberController.text.trim() : _invoice.invoiceNumber,
        );
      });
      ref.invalidate(invoicesForFacilityProvider(widget.facilityId));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invoice updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save: $e'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingEdits = false);
    }
  }

  Widget _buildInvoiceActions() {
    final actions = availableInvoiceActions(_invoice.status);
    final canMakePdf = _invoice.pdfUrl == null;
    // Printing is always offered, so this card never collapses away.

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Actions',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Printing is the first thing an operator reaches for, and it
                // must not depend on a file having been generated first: this
                // builds the page and opens the browser's print dialog, which
                // also offers Save as PDF.
                ElevatedButton.icon(
                  onPressed: _isPreparingPrint ? null : _printInvoice,
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: Text(
                    _isPreparingPrint ? 'Preparing...' : 'Print / Save as PDF',
                  ),
                ),
                if (canEditDueDateAndNotes(_invoice.status))
                  OutlinedButton.icon(
                    onPressed: _isSavingEdits ? null : _openEditSheet,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(_isSavingEdits ? 'Saving...' : 'Edit details'),
                  ),
                if (canMakePdf)
                  OutlinedButton.icon(
                    onPressed: _isGeneratingPDF ? null : _generatePDF,
                    icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: Text(
                      _isGeneratingPDF ? 'Generating...' : 'Attach PDF copy',
                    ),
                  ),
                for (final action in actions)
                  action.isDestructive
                      ? OutlinedButton(
                          onPressed: _isRunningAction
                              ? null
                              : () => _runInvoiceAction(action),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.error,
                          ),
                          child: Text(action.label),
                        )
                      : ElevatedButton(
                          onPressed: _isRunningAction
                              ? null
                              : () => _runInvoiceAction(action),
                          child: Text(
                            action == InvoiceAction.send &&
                                    _invoice.status != InvoiceStatus.draft
                                ? 'Resend to tenant'
                                : action.label,
                          ),
                        ),
              ],
            ),
            if (_isGeneratingPDF) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _runInvoiceAction(InvoiceAction action) async {
    if (_isRunningAction) return;
    setState(() => _isRunningAction = true);
    try {
      switch (action) {
        case InvoiceAction.send:
          await _sendInvoice();
          break;
        case InvoiceAction.markPaid:
          await _markAsPaid();
          break;
        case InvoiceAction.voidInvoice:
          await _voidInvoice();
          break;
      }
    } finally {
      if (mounted) setState(() => _isRunningAction = false);
    }
  }

  Future<void> _markAsPaid() async {
    // Confirm action
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark Invoice as Paid'),
        content: Text(
          'Are you sure you want to mark invoice ${_invoice.invoiceNumber} as paid? This will set the balance to \$0.00.',
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
        invoiceId: _invoice.id,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invoice ${_invoice.invoiceNumber} marked as paid'),
            backgroundColor: AppTheme.success,
          ),
        );
        // Leave for the refreshed list. popOrGo, not a bare pop: that throws
        // when nothing is underneath, and the catch below would then report
        // the finished change as failed.
        popOrGo(context, AppRoute.paymentsInvoices);
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
              'Are you sure you want to void invoice ${_invoice.invoiceNumber}? This action cannot be undone.',
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
        invoiceId: _invoice.id,
        reason: reason,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invoice ${_invoice.invoiceNumber} has been voided'),
            backgroundColor: AppTheme.warning,
          ),
        );
        // Leave for the refreshed list. popOrGo, not a bare pop: that throws
        // when nothing is underneath, and the catch below would then report
        // the finished change as failed.
        popOrGo(context, AppRoute.paymentsInvoices);
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

