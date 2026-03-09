import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../models/lead_source_model.dart';
import '../services/lead_source_service.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../services/modern_navigation_service.dart';
import '../models/facility_model.dart';

/// Screen for viewing lead source analytics and statistics
class LeadSourceAnalyticsScreen extends ConsumerStatefulWidget {
  final String? facilityId;

  const LeadSourceAnalyticsScreen({
    super.key,
    this.facilityId,
  });

  @override
  ConsumerState<LeadSourceAnalyticsScreen> createState() => _LeadSourceAnalyticsScreenState();
}

class _LeadSourceAnalyticsScreenState extends ConsumerState<LeadSourceAnalyticsScreen> {
  LeadSourceSummary? _summary;
  bool _isLoading = true;
  String? _selectedFacilityId;
  DateTime? _startDate;
  DateTime? _endDate;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    _endDate = DateTime.now();
    _startDate = DateTime(_endDate!.year - 1, 1, 1); // Last year
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
      final summary = await LeadSourceService.getLeadSourceSummary(
        facilityId: _selectedFacilityId!,
        startDate: _startDate,
        endDate: _endDate,
      );

      setState(() {
        _summary = summary;
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
      firstDate: DateTime.now().subtract(const Duration(days: 3650)), // 10 years
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
    final currentRoute = '/analytics/lead-sources';

    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Lead Source Analytics',
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
                : _summary == null
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

        final facilities = ref.watch(userFacilitiesProvider(user.uid));

        return Container(
          padding: const EdgeInsets.all(16),
          child: facilities.when(
            data: (facilitiesList) {
              if (facilitiesList.isEmpty) {
                return const Text('No facilities available');
              }

              return DropdownButtonFormField<String>(
                value: _selectedFacilityId,
                decoration: const InputDecoration(
                  labelText: 'Facility',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                items: facilitiesList.map((facility) {
                  return DropdownMenuItem<String>(
                    value: facility.id,
                    child: Text(facility.name),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _selectedFacilityId = value;
                    });
                    _loadAnalytics();
                  }
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) => const SizedBox.shrink(),
          ),
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
            'No lead source data available',
            style: TextStyle(
              fontSize: 18,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create tenants with lead source information to see analytics',
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textTertiary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticsContent() {
    final summary = _summary!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Overview Cards
          _buildOverviewCards(summary),
          const SizedBox(height: 24),
          // Category Breakdown
          if (summary.categoryBreakdown.isNotEmpty) ...[
            _buildCategoryBreakdown(summary),
            const SizedBox(height: 24),
          ],
          // Top Sources
          if (summary.topSources.isNotEmpty) ...[
            _buildTopSources(summary),
            const SizedBox(height: 24),
          ],
          // All Sources Table
          _buildAllSourcesTable(summary),
        ],
      ),
    );
  }

  Widget _buildOverviewCards(LeadSourceSummary summary) {
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            title: 'Total Tenants',
            value: '${summary.totalTenants}',
            icon: Icons.people,
            color: AppTheme.primaryBlue,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildMetricCard(
            title: 'Converted',
            value: '${summary.totalConverted}',
            icon: Icons.check_circle,
            color: AppTheme.success,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildMetricCard(
            title: 'Conversion Rate',
            value: '${summary.overallConversionRate.toStringAsFixed(1)}%',
            icon: Icons.trending_up,
            color: AppTheme.warning,
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color, size: 32),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBreakdown(LeadSourceSummary summary) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Category Breakdown',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          ...summary.categoryBreakdown.entries.map((entry) {
            final total = summary.totalTenants;
            final percentage = total > 0 ? (entry.value / total) * 100 : 0.0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      entry.key,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: LinearProgressIndicator(
                      value: percentage / 100,
                      backgroundColor: AppTheme.borderLight,
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryBlue),
                      minHeight: 8,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${entry.value} (${percentage.toStringAsFixed(1)}%)',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTopSources(LeadSourceSummary summary) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Top Lead Sources',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          ...summary.topSources.asMap().entries.map((entry) {
            final index = entry.key;
            final stat = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primaryBlue,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stat.source.displayName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${stat.count} tenants • ${stat.conversionRate.toStringAsFixed(1)}% conversion',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.trending_up,
                    color: stat.conversionRate >= 50 ? AppTheme.success : AppTheme.warning,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildAllSourcesTable(LeadSourceSummary summary) {
    // Filter to show only sources with data
    final sourcesWithData = summary.stats.where((s) => s.count > 0).toList();

    if (sourcesWithData.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'All Lead Sources',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          Table(
            columnWidths: const {
              0: FlexColumnWidth(3),
              1: FlexColumnWidth(2),
              2: FlexColumnWidth(2),
              3: FlexColumnWidth(2),
            },
            children: [
              // Header row
              TableRow(
                decoration: BoxDecoration(
                  color: AppTheme.backgroundLight,
                  border: Border(
                    bottom: BorderSide(color: AppTheme.borderLight),
                  ),
                ),
                children: [
                  _buildTableHeader('Source'),
                  _buildTableHeader('Total'),
                  _buildTableHeader('Converted'),
                  _buildTableHeader('Rate'),
                ],
              ),
              // Data rows
              ...sourcesWithData.map((stat) {
                return TableRow(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppTheme.borderLight),
                    ),
                  ),
                  children: [
                    _buildTableCell(stat.source.displayName),
                    _buildTableCell('${stat.count}'),
                    _buildTableCell('${stat.convertedCount}'),
                    _buildTableCell(
                      '${stat.conversionRate.toStringAsFixed(1)}%',
                      color: stat.conversionRate >= 50
                          ? AppTheme.success
                          : stat.conversionRate >= 25
                              ? AppTheme.warning
                              : AppTheme.error,
                    ),
                  ],
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader(String text) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }

  Widget _buildTableCell(String text, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          color: color ?? AppTheme.textPrimary,
        ),
      ),
    );
  }
}

