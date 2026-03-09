import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../services/payment_reconciliation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../providers/active_facility_provider.dart';

class PaymentReconciliationScreen extends ConsumerStatefulWidget {
  const PaymentReconciliationScreen({super.key});

  @override
  ConsumerState<PaymentReconciliationScreen> createState() => _PaymentReconciliationScreenState();
}

class _PaymentReconciliationScreenState extends ConsumerState<PaymentReconciliationScreen> {
  bool _isReconciling = false;
  Map<String, PaymentReconciliationResult>? _reconciliationResults;
  Map<String, dynamic>? _summary;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  Widget build(BuildContext context) {
    final facilityId = ref.watch(activeFacilityIdProvider).value;

    if (facilityId == null) {
      return ModernPageWrapper(
        currentRoute: '/payment-reconciliation',
        title: 'Payment Reconciliation',
        child: const Center(
          child: Text('Please select a facility'),
        ),
      );
    }

    return ModernPageWrapper(
      currentRoute: '/payment-reconciliation',
      title: 'Payment Reconciliation',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _isReconciling ? null : () => _reconcilePayments(facilityId),
          tooltip: 'Reconcile Payments',
        ),
      ],
      child: Column(
        children: [
          _buildDateFilters(),
          if (_summary != null) _buildSummary(),
          Expanded(
            child: _buildReconciliationResults(),
          ),
        ],
      ),
    );
  }

  Widget _buildDateFilters() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _startDate ?? DateTime.now().subtract(const Duration(days: 30)),
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (date != null) {
                  setState(() {
                    _startDate = date;
                  });
                }
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Start Date',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  suffixIcon: const Icon(Icons.calendar_today),
                ),
                child: Text(
                  _startDate != null
                      ? DateFormat('MM/dd/yyyy').format(_startDate!)
                      : 'Select start date',
                  style: TextStyle(
                    color: _startDate != null ? null : AppTheme.textTertiary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _endDate ?? DateTime.now(),
                  firstDate: _startDate ?? DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (date != null) {
                  setState(() {
                    _endDate = date;
                  });
                }
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'End Date',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  suffixIcon: const Icon(Icons.calendar_today),
                ),
                child: Text(
                  _endDate != null
                      ? DateFormat('MM/dd/yyyy').format(_endDate!)
                      : 'Select end date',
                  style: TextStyle(
                    color: _endDate != null ? null : AppTheme.textTertiary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () {
              setState(() {
                _startDate = null;
                _endDate = null;
              });
            },
            tooltip: 'Clear date filters',
          ),
        ],
      ),
    );
  }

  Widget _buildSummary() {
    if (_summary == null) return const SizedBox.shrink();

    final total = _summary!['total'] as int? ?? 0;
    final reconciled = _summary!['reconciled'] as int? ?? 0;
    final discrepancies = _summary!['discrepancies'] as int? ?? 0;

    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildStatCard('Total Payments', total.toString(), AppTheme.primaryBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard('Reconciled', reconciled.toString(), AppTheme.success),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildStatCard('Discrepancies', discrepancies.toString(), discrepancies > 0 ? AppTheme.error : AppTheme.success),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String title, String value, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReconciliationResults() {
    if (_isReconciling) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Reconciling payments...'),
          ],
        ),
      );
    }

    if (_reconciliationResults == null || _reconciliationResults!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.account_balance_wallet, size: 64, color: AppTheme.textTertiary),
            const SizedBox(height: 16),
            Text(
              'No reconciliation results yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: () {
                final facilityId = ref.read(activeFacilityIdProvider).value;
                if (facilityId != null) {
                  _reconcilePayments(facilityId);
                }
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Reconcile Payments'),
            ),
          ],
        ),
      );
    }

    final results = _reconciliationResults!;
    final reconciled = results.values.where((r) => r.isReconciled).toList();
    final discrepancies = results.values.where((r) => !r.isReconciled).toList();

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          TabBar(
            tabs: [
              Tab(
                text: 'All (${results.length})',
                icon: const Icon(Icons.list),
              ),
              Tab(
                text: 'Discrepancies (${discrepancies.length})',
                icon: const Icon(Icons.warning),
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildResultsList(results.values.toList()),
                _buildResultsList(discrepancies),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsList(List<PaymentReconciliationResult> results) {
    if (results.isEmpty) {
      return const Center(
        child: Text('No results to display'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final result = results[index];
        return _buildResultCard(result);
      },
    );
  }

  Widget _buildResultCard(PaymentReconciliationResult result) {
    final isReconciled = result.isReconciled;
    final firestorePayment = result.firestorePayment;
    final stripePayment = result.stripePayment;
    final paymentIntentId = stripePayment?['id'] as String? ?? firestorePayment?['externalPaymentId'] as String? ?? 'Unknown';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isReconciled ? AppTheme.success.withOpacity(0.1) : AppTheme.error.withOpacity(0.1),
      child: ExpansionTile(
        leading: Icon(
          isReconciled ? Icons.check_circle : Icons.error,
          color: isReconciled ? AppTheme.success : AppTheme.error,
        ),
        title: Text(
          paymentIntentId,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          isReconciled
              ? 'Reconciled'
              : result.discrepancy ?? 'Discrepancy detected',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: isReconciled ? AppTheme.success : AppTheme.error,
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (result.discrepancy != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.error),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning, color: AppTheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            result.discrepancy!,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppTheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (result.recommendation != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.info.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.lightbulb, color: AppTheme.info),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            result.recommendation!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (firestorePayment != null) ...[
                  Text(
                    'Firestore Payment:',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildDetailRow('Amount', '\$${(firestorePayment['amount'] as num?)?.toStringAsFixed(2) ?? 'N/A'}'),
                        _buildDetailRow('Status', firestorePayment['status'] as String? ?? 'N/A'),
                        _buildDetailRow('Payment ID', firestorePayment['id'] as String? ?? 'N/A'),
                        if (firestorePayment['createdAt'] != null)
                          _buildDetailRow(
                            'Created',
                            DateFormat('MM/dd/yyyy HH:mm:ss').format(
                              (firestorePayment['createdAt'] as dynamic).toDate(),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (stripePayment != null) ...[
                  Text(
                    'Stripe Payment:',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundLight,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildDetailRow('Amount', '\$${((stripePayment['amount'] as num?)?.toInt() ?? 0) / 100.0}'),
                        _buildDetailRow('Status', stripePayment['status'] as String? ?? 'N/A'),
                        _buildDetailRow('Payment Intent ID', stripePayment['id'] as String? ?? 'N/A'),
                        if (stripePayment['created'] != null)
                          _buildDetailRow(
                            'Created',
                            DateFormat('MM/dd/yyyy HH:mm:ss').format(
                              DateTime.fromMillisecondsSinceEpoch((stripePayment['created'] as int) * 1000),
                            ),
                          ),
                      ],
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

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _reconcilePayments(String facilityId) async {
    setState(() {
      _isReconciling = true;
      _reconciliationResults = null;
      _summary = null;
    });

    try {
      // Get reconciliation summary first
      final summary = await PaymentReconciliationService.getReconciliationSummary(
        facilityId: facilityId,
        startDate: _startDate,
        endDate: _endDate,
      );

      // Then get detailed results
      final results = await PaymentReconciliationService.reconcileFacilityPayments(
        facilityId: facilityId,
        startDate: _startDate,
        endDate: _endDate,
        limit: 100,
      );

      if (mounted) {
        setState(() {
          _reconciliationResults = results;
          _summary = summary;
          _isReconciling = false;
        });

        final discrepancyCount = summary['discrepancies'] as int? ?? 0;
        if (discrepancyCount > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Reconciliation complete: $discrepancyCount discrepancy(ies) found'),
              backgroundColor: AppTheme.warning,
              duration: const Duration(seconds: 5),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Reconciliation complete: All payments reconciled'),
              backgroundColor: AppTheme.success,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isReconciling = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error reconciling payments: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}
