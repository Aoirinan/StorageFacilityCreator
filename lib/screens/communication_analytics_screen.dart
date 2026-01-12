import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../models/communication_analytics_model.dart';
import '../services/communication_analytics_service.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../services/modern_navigation_service.dart';

/// Screen for viewing communication analytics and cost tracking
class CommunicationAnalyticsScreen extends ConsumerStatefulWidget {
  final String? facilityId;

  const CommunicationAnalyticsScreen({
    super.key,
    this.facilityId,
  });

  @override
  ConsumerState<CommunicationAnalyticsScreen> createState() => _CommunicationAnalyticsScreenState();
}

class _CommunicationAnalyticsScreenState extends ConsumerState<CommunicationAnalyticsScreen> {
  CommunicationAnalytics? _analytics;
  bool _isLoading = true;
  String? _selectedFacilityId;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    _endDate = DateTime.now();
    _startDate = DateTime(_endDate!.year, _endDate!.month, 1); // Start of month
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedFacilityId != null) {
      _loadAnalytics();
    } else {
      _loadUserFacilities();
    }
  }

  Future<void> _loadUserFacilities() async {
    final authState = ref.read(authStateProvider);
    authState.whenData((user) {
      if (user != null && mounted) {
        ref.read(userFacilitiesProvider(user.uid).future).then((facilities) {
          if (facilities.isNotEmpty && mounted) {
            setState(() {
              _selectedFacilityId = facilities.first.id;
            });
            _loadAnalytics();
          }
        });
      }
    });
  }

  Future<void> _loadAnalytics() async {
    if (_selectedFacilityId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final analytics = await CommunicationAnalyticsService.getAnalytics(
        facilityId: _selectedFacilityId!,
        startDate: _startDate,
        endDate: _endDate,
      );

      setState(() {
        _analytics = analytics;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading analytics: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _selectDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _startDate != null && _endDate != null
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );

    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _loadAnalytics();
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = '/analytics/communication';
    
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Communication Analytics',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.calendar_today),
          onPressed: _selectDateRange,
          tooltip: 'Select Date Range',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadAnalytics,
          tooltip: 'Refresh',
        ),
      ],
      child: Column(
        children: [
          // Facility Selector
          if (widget.facilityId == null) _buildFacilitySelector(),
          // Date Range Display
          _buildDateRangeDisplay(),
          const Divider(),
          // Analytics Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _analytics == null
                    ? _buildEmptyState()
                    : _buildAnalyticsContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilitySelector() {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (user) {
        if (user == null) return const SizedBox.shrink();
        
        final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
        return facilitiesAsync.when(
          data: (facilities) {
            if (facilities.isEmpty) return const SizedBox.shrink();
            
            return Container(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<String>(
                value: _selectedFacilityId,
                decoration: const InputDecoration(
                  labelText: 'Facility',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                items: facilities.map((facility) {
                  return DropdownMenuItem<String>(
                    value: facility.id,
                    child: Text(facility.name),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null && value != _selectedFacilityId) {
                    setState(() {
                      _selectedFacilityId = value;
                    });
                    _loadAnalytics();
                  }
                },
              ),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildDateRangeDisplay() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.date_range, color: AppTheme.primaryBlue),
          const SizedBox(width: 8),
          Text(
            _startDate != null && _endDate != null
                ? '${DateFormat('MMM d, yyyy').format(_startDate!)} - ${DateFormat('MMM d, yyyy').format(_endDate!)}'
                : 'Select date range',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.analytics_outlined, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 16),
          Text(
            'No analytics data available',
            style: TextStyle(
              fontSize: 18,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticsContent() {
    final analytics = _analytics!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Overview Cards
          _buildOverviewCards(analytics),
          const SizedBox(height: 24),
          // Email Metrics
          _buildEmailMetrics(analytics),
          const SizedBox(height: 24),
          // SMS Metrics
          _buildSMSMetrics(analytics),
          const SizedBox(height: 24),
          // Cost Breakdown
          _buildCostBreakdown(analytics),
        ],
      ),
    );
  }

  Widget _buildOverviewCards(CommunicationAnalytics analytics) {
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            'Total Messages',
            '${analytics.emailsSent + analytics.smsSent}',
            Icons.message,
            AppTheme.primaryBlue,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildMetricCard(
            'Email Open Rate',
            '${analytics.emailOpenRate.toStringAsFixed(1)}%',
            Icons.email,
            AppTheme.success,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildMetricCard(
            'Total Cost',
            '\$${analytics.totalCost.toStringAsFixed(2)}',
            Icons.attach_money,
            AppTheme.warning,
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard(String label, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailMetrics(CommunicationAnalytics analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Email Metrics',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildMetricRow('Sent', analytics.emailsSent.toString()),
            _buildMetricRow('Delivered', analytics.emailsDelivered.toString()),
            _buildMetricRow('Opened', '${analytics.emailsOpened} (${analytics.emailOpenRate.toStringAsFixed(1)}%)'),
            _buildMetricRow('Clicked', '${analytics.emailsClicked} (${analytics.emailClickRate.toStringAsFixed(1)}%)'),
            _buildMetricRow('Bounced', analytics.emailsBounced.toString()),
            _buildMetricRow('Failed', analytics.emailsFailed.toString()),
            const Divider(),
            _buildProgressBar(
              'Usage',
              analytics.emailUsagePercentage,
              analytics.emailsSent,
              analytics.emailLimit,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSMSMetrics(CommunicationAnalytics analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'SMS Metrics',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildMetricRow('Sent', analytics.smsSent.toString()),
            _buildMetricRow('Delivered', analytics.smsDelivered.toString()),
            _buildMetricRow('Failed', analytics.smsFailed.toString()),
            _buildMetricRow('Delivery Rate', '${analytics.smsDeliveryRate.toStringAsFixed(1)}%'),
            const Divider(),
            _buildProgressBar(
              'Usage',
              analytics.smsUsagePercentage,
              analytics.smsSent,
              analytics.smsLimit,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCostBreakdown(CommunicationAnalytics analytics) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cost Breakdown',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildCostRow('Email', analytics.emailCost, analytics.emailsSent),
            _buildCostRow('SMS', analytics.smsCost, analytics.smsSent),
            const Divider(),
            _buildCostRow(
              'Total',
              analytics.totalCost,
              analytics.emailsSent + analytics.smsSent,
              isTotal: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(String label, double percentage, int current, int limit) {
    final color = percentage >= 100
        ? AppTheme.error
        : percentage >= 80
            ? AppTheme.warning
            : AppTheme.success;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            Text(
              '$current / $limit (${percentage.toStringAsFixed(1)}%)',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: percentage / 100,
          backgroundColor: AppTheme.backgroundLight,
          valueColor: AlwaysStoppedAnimation<Color>(color),
          minHeight: 8,
        ),
      ],
    );
  }

  Widget _buildCostRow(String label, double cost, int count, {bool isTotal = false}) {
    final costPerMessage = count > 0 ? cost / count : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: isTotal ? FontWeight.bold : FontWeight.normal,
              fontSize: isTotal ? 16 : 14,
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '\$${cost.toStringAsFixed(2)}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: isTotal ? 18 : 14,
                  color: isTotal ? AppTheme.primaryBlue : null,
                ),
              ),
              if (!isTotal && count > 0)
                Text(
                  '\$${costPerMessage.toStringAsFixed(4)} per message',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppTheme.textTertiary,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

