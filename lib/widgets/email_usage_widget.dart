import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/billing_model.dart';
import '../services/billing_service.dart';

/// Widget to display email usage for a facility
class EmailUsageWidget extends ConsumerStatefulWidget {
  final String facilityId;
  final bool showDetails;

  const EmailUsageWidget({
    super.key,
    required this.facilityId,
    this.showDetails = true,
  });

  @override
  ConsumerState<EmailUsageWidget> createState() => _EmailUsageWidgetState();
}

class _EmailUsageWidgetState extends ConsumerState<EmailUsageWidget> {
  FacilityBillingModel? _currentBilling;
  BillingStatistics? _statistics;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBillingData();
  }

  Future<void> _loadBillingData() async {
    try {
      setState(() {
        _isLoading = true;
        _error = null;
      });

      final billing = await BillingService.getCurrentBilling(widget.facilityId);
      final statistics = await BillingService.getBillingStatistics(widget.facilityId);

      setState(() {
        _currentBilling = billing;
        _statistics = statistics;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_error != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Icon(Icons.error, color: Colors.red[600]),
              const SizedBox(height: 8),
              Text('Error loading usage data'),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _loadBillingData,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_currentBilling == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Text('No billing data available'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.email, color: Theme.of(context).primaryColor),
                const SizedBox(width: 8),
                Text(
                  'Email Usage',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                if (_currentBilling!.status != BillingStatus.normal)
                  _buildStatusIndicator(_currentBilling!.status),
              ],
            ),
            const SizedBox(height: 16),
            _buildUsageBar(_currentBilling!),
            const SizedBox(height: 12),
            if (widget.showDetails) ...[
              _buildUsageDetails(_currentBilling!),
              if (_statistics != null) ...[
                const SizedBox(height: 16),
                _buildStatistics(_statistics!),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(BillingStatus status) {
    Color color;
    IconData icon;
    String tooltip;

    switch (status) {
      case BillingStatus.normal:
        color = Colors.green;
        icon = Icons.check_circle;
        tooltip = 'Usage within limits';
        break;
      case BillingStatus.warning:
        color = Colors.orange;
        icon = Icons.warning;
        tooltip = 'Usage at warning level';
        break;
      case BillingStatus.overage:
        color = Colors.red;
        icon = Icons.error;
        tooltip = 'Usage exceeds free tier';
        break;
    }

    return Tooltip(
      message: tooltip,
      child: Icon(icon, color: color, size: 20),
    );
  }

  Widget _buildUsageBar(FacilityBillingModel billing) {
    final usagePercentage = billing.usagePercentage;
    final progressColor = _getProgressColor(usagePercentage);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${billing.emailCount} / ${billing.emailFreeTier}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              '${(usagePercentage * 100).toInt()}%',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: progressColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: usagePercentage.clamp(0.0, 1.0),
          backgroundColor: Colors.grey[300],
          valueColor: AlwaysStoppedAnimation<Color>(progressColor),
          minHeight: 8,
        ),
        const SizedBox(height: 4),
        if (billing.hasOverage)
          Text(
            'Overage: \$${billing.overageAmount.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.red[600],
              fontWeight: FontWeight.bold,
            ),
          ),
      ],
    );
  }

  Widget _buildUsageDetails(FacilityBillingModel billing) {
    return Column(
      children: [
        _buildDetailRow('Free Tier', '${billing.emailFreeTier} emails/month'),
        _buildDetailRow('Used This Month', '${billing.emailCount} emails'),
        _buildDetailRow('Overage Rate', '\$${billing.emailOverageRate.toStringAsFixed(4)} per email'),
        if (billing.hasOverage)
          _buildDetailRow('Estimated Overage', '\$${billing.overageAmount.toStringAsFixed(2)}'),
      ],
    );
  }

  Widget _buildStatistics(BillingStatistics stats) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Annual Statistics',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        _buildDetailRow('Total Emails This Year', '${stats.totalEmailsThisYear}'),
        _buildDetailRow('Average Monthly', '${stats.averageMonthlyEmails.toInt()} emails'),
        _buildDetailRow('Months with Usage', '${stats.monthsWithUsage}/${stats.totalMonths}'),
        if (stats.totalOverageThisYear > 0)
          _buildDetailRow('Total Overage This Year', '\$${stats.totalOverageThisYear.toStringAsFixed(2)}'),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Color _getProgressColor(double percentage) {
    if (percentage >= 1.0) return Colors.red;
    if (percentage >= 0.8) return Colors.orange;
    return Colors.green;
  }
}

/// Compact version of the email usage widget for smaller spaces
class CompactEmailUsageWidget extends StatelessWidget {
  final String facilityId;

  const CompactEmailUsageWidget({
    super.key,
    required this.facilityId,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FacilityBillingModel>(
      future: BillingService.getCurrentBilling(facilityId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            width: 120,
            height: 40,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return const SizedBox(
            width: 120,
            height: 40,
            child: Center(child: Icon(Icons.error, color: Colors.red)),
          );
        }

        final billing = snapshot.data!;
        final usagePercentage = billing.usagePercentage;
        final progressColor = _getProgressColor(usagePercentage);

        return Container(
          width: 120,
          height: 40,
          decoration: BoxDecoration(
            border: Border.all(color: progressColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${billing.emailCount}/${billing.emailFreeTier}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: progressColor,
                ),
              ),
              Text(
                'emails',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }

  static Color _getProgressColor(double percentage) {
    if (percentage >= 1.0) return Colors.red;
    if (percentage >= 0.8) return Colors.orange;
    return Colors.green;
  }
}
