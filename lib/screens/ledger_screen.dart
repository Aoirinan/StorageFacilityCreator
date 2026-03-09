import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'dart:typed_data';
import '../models/ledger_entry_model.dart';
import '../models/tenant_model.dart';
import '../providers/ledger_provider.dart';
import '../services/ledger_service.dart';
import '../services/statement_service.dart';
import '../services/facility_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import 'ledger_entry_creation_dialog.dart';
import '../providers/invoice_provider.dart';
import '../providers/ledger_provider.dart';
import '../widgets/ledger_entry_card.dart';
import '../utils/error_message_helper.dart';

class LedgerScreen extends ConsumerStatefulWidget {
  final TenantModel tenant;

  const LedgerScreen({
    super.key,
    required this.tenant,
  });

  @override
  ConsumerState<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends ConsumerState<LedgerScreen> {
  LedgerEntryType? _typeFilter;
  LedgerEntryStatus? _statusFilter;
  DateTime? _startDate;
  DateTime? _endDate;
  double _runningBalance = 0.0;

  @override
  Widget build(BuildContext context) {
    final ledgerParams = LedgerParams(
      tenantId: widget.tenant.id,
      facilityId: widget.tenant.facilityId,
    );

    final ledgerAsync = ref.watch(ledgerStreamProvider(ledgerParams));
    final balanceAsync = ref.watch(ledgerBalanceProvider(ledgerParams));

    return ledgerAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) {
          // Check if it's a missing index error
          final errorStr = error.toString();
          if (errorStr.contains('index') || errorStr.contains('The query requires an index')) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 64, color: AppTheme.warning),
                    const SizedBox(height: 16),
                    Text(
                      'Database Index Required',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'This query requires a Firestore index. Please check the error message below for a link to create the index, then refresh this page.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      errorStr,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () {
                        // Refresh the provider
                        ref.invalidate(ledgerStreamProvider(ledgerParams));
                      },
                      child: const Text('Refresh After Creating Index'),
                    ),
                  ],
                ),
              ),
            );
          }
          // Other errors
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 64, color: AppTheme.error),
                  const SizedBox(height: 16),
                  Text(
                    'Error Loading Ledger',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    ErrorMessageHelper.getUserFriendlyMessage(error),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () {
                      ref.invalidate(ledgerStreamProvider(ledgerParams));
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        },
        data: (entries) {
          // Calculate running balance
          _runningBalance = balanceAsync.maybeWhen(
            data: (balance) => balance,
            orElse: () => 0.0,
          );

          // Apply filters
          var filteredEntries = entries;
          if (_typeFilter != null) {
            filteredEntries = filteredEntries.where((e) => e.type == _typeFilter).toList();
          }
          if (_statusFilter != null) {
            filteredEntries = filteredEntries.where((e) => e.status == _statusFilter).toList();
          }
          if (_startDate != null) {
            filteredEntries = filteredEntries.where((e) => e.entryDate.isAfter(_startDate!) || e.entryDate.isAtSameMomentAs(_startDate!)).toList();
          }
          if (_endDate != null) {
            filteredEntries = filteredEntries.where((e) => e.entryDate.isBefore(_endDate!) || e.entryDate.isAtSameMomentAs(_endDate!)).toList();
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Page header with back button and tenant name
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => context.push(AppRoute.tenantDetail, extra: widget.tenant),
                      tooltip: 'Back to tenant',
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.tenant.name,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (widget.tenant.unitNumber != null && widget.tenant.unitNumber!.isNotEmpty)
                            Text(
                              'Unit ${widget.tenant.unitNumber}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textTertiary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.filter_alt),
                      onPressed: () => _showFiltersDialog(context),
                      tooltip: 'Filter',
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.receipt_long, size: 18),
                      label: const Text('Generate Invoice'),
                      onPressed: () => _showGenerateInvoiceDialog(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: AppTheme.textOnDark,
                      ),
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add entry'),
                      onPressed: () => _showCreateEntryDialog(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Balance Summary Card
                      Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Current Balance',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _formatCurrency(_runningBalance),
                                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  color: _runningBalance >= 0 ? AppTheme.error : AppTheme.success,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _runningBalance >= 0 ? AppTheme.error.withOpacity(0.1) : AppTheme.success.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            _runningBalance >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
                            color: _runningBalance >= 0 ? AppTheme.error : AppTheme.success,
                            size: 32,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Filters Summary
                if (_hasActiveFilters())
                  Card(
                    color: AppTheme.primaryBlueLight.withOpacity(0.1),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Row(
                        children: [
                          const Icon(Icons.filter_alt, size: 16, color: AppTheme.primaryBlue),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _getFilterSummary(),
                              style: const TextStyle(fontSize: 12, color: AppTheme.primaryBlue),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _typeFilter = null;
                                _statusFilter = null;
                                _startDate = null;
                                _endDate = null;
                              });
                            },
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 16),

                // Ledger Entries List
                if (filteredEntries.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(48.0),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.receipt_long_outlined,
                              size: 64,
                              color: AppTheme.textTertiary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No ledger entries',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Create your first entry to get started',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: AppTheme.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  ...filteredEntries.map((entry) => LedgerEntryCard(
                    entry: entry,
                    onVoid: () => _voidEntry(context, entry),
                  )),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      );
  }

  bool _hasActiveFilters() {
    return _typeFilter != null || _statusFilter != null || _startDate != null || _endDate != null;
  }

  String _getFilterSummary() {
    final parts = <String>[];
    if (_typeFilter != null) parts.add('Type: ${_typeFilter!.displayName}');
    if (_statusFilter != null) parts.add('Status: ${_statusFilter!.displayName}');
    if (_startDate != null) parts.add('From: ${DateFormat('MM/dd/yyyy').format(_startDate!)}');
    if (_endDate != null) parts.add('To: ${DateFormat('MM/dd/yyyy').format(_endDate!)}');
    return parts.join(' • ');
  }

  void _showFiltersDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Filter Ledger'),
        content: StatefulBuilder(
          builder: (context, setState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<LedgerEntryType?>(
                  value: _typeFilter,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Types')),
                    ...LedgerEntryType.values.map((type) => DropdownMenuItem(
                      value: type,
                      child: Text(type.displayName),
                    )),
                  ],
                  onChanged: (value) => setState(() => _typeFilter = value),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<LedgerEntryStatus?>(
                  value: _statusFilter,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All Statuses')),
                    ...LedgerEntryStatus.values.map((status) => DropdownMenuItem(
                      value: status,
                      child: Text(status.displayName),
                    )),
                  ],
                  onChanged: (value) => setState(() => _statusFilter = value),
                ),
                const SizedBox(height: 16),
                ListTile(
                  title: const Text('Start Date'),
                  subtitle: Text(_startDate != null ? DateFormat('MM/dd/yyyy').format(_startDate!) : 'None'),
                  trailing: IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _startDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                      );
                      if (date != null) {
                        setState(() => _startDate = date);
                      }
                    },
                  ),
                ),
                ListTile(
                  title: const Text('End Date'),
                  subtitle: Text(_endDate != null ? DateFormat('MM/dd/yyyy').format(_endDate!) : 'None'),
                  trailing: IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: _endDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now(),
                      );
                      if (date != null) {
                        setState(() => _endDate = date);
                      }
                    },
                  ),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {});
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  void _showCreateEntryDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => LedgerEntryCreationDialog(
        tenant: widget.tenant,
        onEntryCreated: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ledger entry created')),
          );
        },
      ),
    );
  }

  Future<void> _voidEntry(BuildContext context, LedgerEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void Entry'),
        content: Text('Are you sure you want to void this entry?\n\n${entry.typeDisplayName}: ${entry.formattedAmount}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Void'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await LedgerService.voidLedgerEntry(
          entryId: entry.id,
          facilityId: entry.facilityId,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Entry voided')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error voiding entry: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  void _showGenerateInvoiceDialog(BuildContext context) {
    final ledgerParams = LedgerParams(
      tenantId: widget.tenant.id,
      facilityId: widget.tenant.facilityId,
    );

    final ledgerAsync = ref.read(ledgerStreamProvider(ledgerParams));
    
    ledgerAsync.whenData((entries) {
      // Get unpaid charges
      final unpaidCharges = entries.where((e) => 
        e.status == LedgerEntryStatus.posted &&
        e.type != LedgerEntryType.payment &&
        e.type != LedgerEntryType.credit &&
        e.type != LedgerEntryType.refund &&
        e.amount > 0
      ).toList();

      if (unpaidCharges.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No unpaid charges to invoice'),
            backgroundColor: AppTheme.warning,
          ),
        );
        return;
      }

      final totalAmount = unpaidCharges.fold(0.0, (sum, e) => sum + e.amount);
      final dueDate = DateTime.now().add(const Duration(days: 30));

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Generate Invoice'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This will create an invoice for ${unpaidCharges.length} unpaid charge(s):',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                ...unpaidCharges.take(5).map((entry) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            entry.description ?? entry.typeDisplayName,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Text(
                          entry.formattedAmount,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (unpaidCharges.length > 5)
                  Text(
                    '... and ${unpaidCharges.length - 5} more',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                const SizedBox(height: 16),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total:',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '\$${totalAmount.toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Due Date: ${DateFormat('MMM d, yyyy').format(dueDate)}',
                  style: Theme.of(context).textTheme.bodyMedium,
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
              onPressed: () async {
                Navigator.pop(context);
                await _generateInvoice(unpaidCharges, dueDate);
              },
              child: const Text('Generate Invoice'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _generateInvoice(List<LedgerEntry> entries, DateTime dueDate) async {
    try {
      final operations = ref.read(invoiceOperationsProvider.notifier);
      final ledgerEntryIds = entries.map((e) => e.id).toList();

      await operations.generateInvoice(
        tenantId: widget.tenant.id,
        facilityId: widget.tenant.facilityId,
        ledgerEntryIds: ledgerEntryIds,
        issueDate: DateTime.now(),
        dueDate: dueDate,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invoice generated successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generating invoice: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  String _formatCurrency(double amount) {
    final formatter = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    return formatter.format(amount);
  }

  Future<void> _showPrintStatementDialog(BuildContext context) async {
    final ledgerParams = LedgerParams(
      tenantId: widget.tenant.id,
      facilityId: widget.tenant.facilityId,
    );

    final ledgerAsync = ref.read(ledgerStreamProvider(ledgerParams));
    
    await ledgerAsync.whenData((entries) async {
      try {
        // Get facility
        final facility = await FacilityService.getFacility(widget.tenant.facilityId);
        if (facility == null) {
          throw Exception('Facility not found');
        }

        // Apply filters if any
        var filteredEntries = entries;
        if (_startDate != null) {
          filteredEntries = filteredEntries.where((e) => e.entryDate.isAfter(_startDate!.subtract(const Duration(seconds: 1))) || e.entryDate.isAtSameMomentAs(_startDate!)).toList();
        }
        if (_endDate != null) {
          filteredEntries = filteredEntries.where((e) => e.entryDate.isBefore(_endDate!.add(const Duration(days: 1))) || e.entryDate.isAtSameMomentAs(_endDate!)).toList();
        }

        // Calculate balance forward
        double balanceForward = 0.0;
        if (_startDate != null) {
          final earlierEntries = entries.where((e) => e.entryDate.isBefore(_startDate!)).toList();
          balanceForward = 0.0;
          for (final entry in earlierEntries) {
            if (entry.status != LedgerEntryStatus.voided) {
              if (entry.type == LedgerEntryType.payment || 
                  entry.type == LedgerEntryType.credit || 
                  entry.type == LedgerEntryType.refund) {
                balanceForward -= entry.amount.abs();
              } else {
                balanceForward += entry.amount;
              }
            }
          }
        }

        // Generate PDF
        final pdfData = await StatementService.generateStatementPDF(
          entries: filteredEntries,
          tenant: widget.tenant,
          facility: facility,
          startDate: _startDate,
          endDate: _endDate ?? DateTime.now(),
          balanceForward: balanceForward,
        );

        // Show print dialog
        await Printing.layoutPdf(
          onLayout: (format) async => pdfData,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Statement ready to print'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error generating statement: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    });
  }

  Future<void> _showSendStatementDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Statement'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Send account statement to ${widget.tenant.email}?'),
            if (_startDate != null || _endDate != null) ...[
              const SizedBox(height: 16),
              Text(
                'Statement Period:',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textSecondary,
                ),
              ),
              Text(
                '${_startDate != null ? DateFormat('MMM d, yyyy').format(_startDate!) : 'All time'} - ${_endDate != null ? DateFormat('MMM d, yyyy').format(_endDate!) : 'Today'}',
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _sendStatement(context);
    }
  }

  Future<void> _sendStatement(BuildContext context) async {
    // Show loading
    ScaffoldMessengerState? messenger;
    if (mounted) {
      messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textOnDark),
              ),
              SizedBox(width: 16),
              Text('Sending statement...'),
            ],
          ),
          duration: Duration(seconds: 60), // Extended duration for async operations
        ),
      );
    }

    try {
      // Get ledger entries - use the stream provider and wait for data
      final ledgerParams = LedgerParams(
        tenantId: widget.tenant.id,
        facilityId: widget.tenant.facilityId,
      );
      
      // Get current entries from the stream
      final ledgerAsync = ref.read(ledgerStreamProvider(ledgerParams));
      
      final entries = await ledgerAsync.when(
        data: (entries) => Future.value(entries),
        loading: () => Future.value(<LedgerEntry>[]),
        error: (error, stack) => throw error,
      );

      if (entries.isEmpty) {
        if (mounted && messenger != null) {
          messenger.hideCurrentSnackBar();
          messenger.showSnackBar(
            const SnackBar(
              content: Text('No ledger entries to send'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      await StatementService.sendStatement(
        tenantId: widget.tenant.id,
        facilityId: widget.tenant.facilityId,
        entries: entries,
        startDate: _startDate,
        endDate: _endDate,
      );

      if (mounted && messenger != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Statement sent successfully'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted && messenger != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error sending statement: $e'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }
}

