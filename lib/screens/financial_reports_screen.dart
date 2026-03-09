import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';
import '../providers/reports_provider.dart';
import '../services/reports_service.dart';
import '../services/facility_service.dart';
import '../services/facility_creator_account_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../models/facility_model.dart';
import '../providers/auth_provider.dart';
import '../utils/error_message_helper.dart';

class FinancialReportsScreen extends ConsumerStatefulWidget {
  final FacilityModel? facility;

  const FinancialReportsScreen({
    super.key,
    this.facility,
  });

  @override
  ConsumerState<FinancialReportsScreen> createState() => _FinancialReportsScreenState();
}

class _FinancialReportsScreenState extends ConsumerState<FinancialReportsScreen> {
  DateTime? _customFromDate;
  DateTime? _customToDate;
  List<FacilityModel> _facilities = const [];
  String? _selectedFacilityId;
  bool _isLoadingFacilities = true;
  String? _facilityError;
  StreamSubscription<List<FacilityModel>>? _facilitySub;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facility?.id;
    _initializeAccountAndLoadFacilities();
  }

  Future<void> _initializeAccountAndLoadFacilities() async {
    try {
      // CRITICAL: Ensure account exists BEFORE trying to load facilities
      // Permission errors often occur because account doesn't exist yet
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        final user = authState.value!;
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
          if (kDebugMode) {
            debugPrint('✅ Account verified/created for user: ${user.uid}');
          }
        } catch (accountError) {
          if (mounted) {
            debugPrint('❌ Could not ensure account exists: $accountError');
            setState(() {
              _facilityError = 'Account setup error: $accountError. Please try again or contact support.';
              _isLoadingFacilities = false;
            });
            return;
          }
        }

        // Small delay to ensure account is fully created and permissions are set
        await Future.delayed(const Duration(milliseconds: 500));

        // Now subscribe to facilities stream
        if (mounted) {
          _facilitySub = FacilityService.getFacilitiesForUserStream().listen(
            (facilities) {
              if (!mounted) return;
              // Only update if facilities actually changed to prevent flickering
              // Compare by IDs to avoid unnecessary updates
              final currentIds = _facilities.map((f) => f.id).toSet();
              final newIds = facilities.map((f) => f.id).toSet();
              final facilitiesChanged = currentIds.length != newIds.length ||
                  currentIds.any((id) => !newIds.contains(id));
              
              if (facilitiesChanged || _isLoadingFacilities) {
                setState(() {
                  _facilities = facilities;
                  _isLoadingFacilities = false;
                  _facilityError = null;
                  if (_selectedFacilityId == null || facilities.every((f) => f.id != _selectedFacilityId)) {
                    _selectedFacilityId =
                        widget.facility?.id?.isNotEmpty == true && facilities.any((f) => f.id == widget.facility!.id)
                            ? widget.facility!.id
                            : (facilities.isNotEmpty ? facilities.first.id : null);
                  }
                });
              }
            },
            onError: (error) {
              if (!mounted) return;
              final errorMessage = error.toString();
              final isPermissionError = errorMessage.contains('permission-denied') || 
                                        errorMessage.contains('Missing or insufficient permissions');
              
              // Check if user is facility owner - if so, this is likely a setup issue
              final authState = ref.read(authStateProvider);
              final user = authState.value;
              bool isLikelySetupIssue = false;
              
              if (user != null && isPermissionError) {
                // Try to verify if user should have access
                // If they're logged in and getting permission errors, it's likely a setup issue
                isLikelySetupIssue = true;
              }
              
              setState(() {
                if (isPermissionError && isLikelySetupIssue) {
                  // Don't show error for setup issues - just show loading or success
                  // The account creation should handle this
                  _facilityError = null; // Clear error for setup issues
                  _isLoadingFacilities = true; // Keep loading to retry
                  // Retry after a short delay
                  Future.delayed(const Duration(seconds: 2), () {
                    if (mounted) {
                      _facilitySub?.cancel();
                      _initializeAccountAndLoadFacilities();
                    }
                  });
                } else if (isPermissionError) {
                  _facilityError = 'You do not have permission to access reports for this facility.';
                  _isLoadingFacilities = false;
                } else {
                  _facilityError = 'Unable to load facilities: ${errorMessage.length > 100 ? errorMessage.substring(0, 100) + "..." : errorMessage}';
                  _isLoadingFacilities = false;
                }
              });
            },
          );
        }
      }
    } catch (e) {
      if (mounted) {
        debugPrint('❌ Error initializing account in financial reports: $e');
        setState(() {
          _facilityError = 'Error initializing: $e';
          _isLoadingFacilities = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _facilitySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedFacilityId = _selectedFacilityId;
    final selectedFilter = ref.watch(reportFilterProvider);
    AsyncValue<ReportData>? reportsAsync;
    if (selectedFacilityId != null) {
      reportsAsync = ref.watch(reportsDataProvider(ReportParams(facilityId: selectedFacilityId)));
    }

    return Column(
        children: [
          _buildFacilitySelector(),
          _buildFilterSection(selectedFilter),
          Expanded(
            child: _buildReportBody(reportsAsync),
          ),
        ],
    );
  }

  Widget _buildFacilitySelector() {
    if (_isLoadingFacilities) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_facilityError != null) {
      // Only show error if it's a real permission issue, not a setup issue
      final isSetupIssue = _facilityError!.contains('Account setup') || 
                          _facilityError!.contains('setup in progress');
      
      // If it's a setup issue, show info banner instead of error
      return Padding(
        padding: const EdgeInsets.all(16),
        child: MaterialBanner(
          backgroundColor: isSetupIssue 
              ? AppTheme.info.withOpacity(0.1) 
              : AppTheme.error.withOpacity(0.1),
          content: Text(_facilityError!),
          leading: Icon(
            isSetupIssue ? Icons.info_outline : Icons.error_outline, 
            color: isSetupIssue ? AppTheme.info : AppTheme.error,
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _isLoadingFacilities = true;
                  _facilityError = null;
                });
                _facilitySub?.cancel();
                _initializeAccountAndLoadFacilities();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_facilities.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No facilities available',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a facility first to view financial reports.',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    final selectedFacility = _facilities.firstWhere(
      (facility) => facility.id == _selectedFacilityId,
      orElse: () => _facilities.first,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: selectedFacility.id,
                  decoration: const InputDecoration(
                    labelText: 'Facility',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.business),
                  ),
                  items: _facilities
                      .map(
                        (facility) => DropdownMenuItem<String>(
                          value: facility.id,
                          child: Text(facility.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null || value == _selectedFacilityId) return;
                    setState(() {
                      _selectedFacilityId = value;
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Viewing reports for ${selectedFacility.name}',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterSection(String selectedFilter) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Date Range',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _buildFilterChip('30d', 'Last 30 Days', selectedFilter),
              _buildFilterChip('90d', 'Last 90 Days', selectedFilter),
              _buildFilterChip('ytd', 'Year to Date', selectedFilter),
              _buildFilterChip('custom', 'Custom Range', selectedFilter),
            ],
          ),
          if (selectedFilter == 'custom') ...[
            const SizedBox(height: 16),
            _buildCustomDateRange(),
          ],
        ],
      ),
    );
  }

  Widget _buildFilterChip(String value, String label, String selected) {
    return FilterChip(
      label: Text(label),
      selected: selected == value,
      onSelected: (selected) {
        if (selected) {
          ref.read(reportFilterProvider.notifier).state = value;
          if (value != 'custom') {
            ref.read(customDateRangeProvider.notifier).state = null;
          }
        }
      },
    );
  }

  Widget _buildCustomDateRange() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => _selectDate(true),
            child: Text(_customFromDate != null 
                ? 'From: ${_formatDate(_customFromDate!)}'
                : 'Select Start Date'),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: OutlinedButton(
            onPressed: () => _selectDate(false),
            child: Text(_customToDate != null 
                ? 'To: ${_formatDate(_customToDate!)}'
                : 'Select End Date'),
          ),
        ),
        const SizedBox(width: 16),
        ElevatedButton(
          onPressed: _customFromDate != null && _customToDate != null 
              ? () {
                  ref.read(customDateRangeProvider.notifier).state = {
                    'from': _customFromDate!,
                    'to': _customToDate!,
                  };
                }
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _buildReportContent(ReportData reportData) {
    if (reportData.paymentCount == 0) {
      return _buildEmptyState();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Summary cards
          _buildSummaryCards(reportData),
          const SizedBox(height: 24),
          
          // Monthly breakdown table
          _buildMonthlyTable(reportData),
          const SizedBox(height: 24),
          
          // Simple chart
          _buildSimpleChart(reportData),
        ],
      ),
    );
  }

  Widget _buildReportBody(AsyncValue<ReportData>? reportsAsync) {
    if (_selectedFacilityId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.business_outlined, size: 56, color: AppTheme.textTertiary),
              const SizedBox(height: 12),
              Text(
                'Select a facility to view financial reports.',
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (reportsAsync == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return reportsAsync.when(
      data: (reportData) => _buildReportContent(reportData),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => _buildErrorState(error),
    );
  }

  Widget _buildSummaryCards(ReportData reportData) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Summary',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildSummaryCard(
                'Total Revenue',
                '\$${reportData.totalRevenue.toStringAsFixed(2)}',
                Icons.attach_money,
                AppTheme.success,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSummaryCard(
                'Payments',
                '${reportData.paymentCount}',
                Icons.receipt,
                AppTheme.primaryBlue,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildSummaryCard(
                'Average Payment',
                '\$${reportData.averagePayment.toStringAsFixed(2)}',
                Icons.analytics,
                AppTheme.warning,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildSummaryCard(
                'Last Payment',
                reportData.lastPaymentDate != null
                    ? _formatDate(reportData.lastPaymentDate!)
                    : 'None',
                Icons.schedule,
                Colors.purple,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSummaryCard(String title, String value, IconData icon, Color color) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
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
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthlyTable(ReportData reportData) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Monthly Breakdown',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Month')),
                DataColumn(label: Text('Count')),
                DataColumn(label: Text('Total')),
                DataColumn(label: Text('Average')),
              ],
              rows: reportData.monthlyData.values.map((monthlyData) {
                return DataRow(
                  cells: [
                    DataCell(Text(monthlyData.month)),
                    DataCell(Text('${monthlyData.count}')),
                    DataCell(Text('\$${monthlyData.sum.toStringAsFixed(2)}')),
                    DataCell(Text('\$${monthlyData.average.toStringAsFixed(2)}')),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSimpleChart(ReportData reportData) {
    if (reportData.monthlyData.isEmpty) return const SizedBox.shrink();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Monthly Revenue Trend',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildBarChart(reportData),
          ),
        ),
      ],
    );
  }

  Widget _buildBarChart(ReportData reportData) {
    final maxValue = reportData.monthlyData.values
        .map((m) => m.sum)
        .reduce((a, b) => a > b ? a : b);
    
    return Column(
      children: reportData.monthlyData.values.map((monthlyData) {
        final percentage = maxValue > 0 ? monthlyData.sum / maxValue : 0.0;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 80,
                child: Text(
                  monthlyData.month,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  children: [
                    Container(
                      height: 20,
                      decoration: BoxDecoration(
                        color: AppTheme.borderLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    Container(
                      height: 20,
                      width: MediaQuery.of(context).size.width * percentage * 0.3,
                      decoration: BoxDecoration(
                        color: AppTheme.success,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '\$${monthlyData.sum.toStringAsFixed(0)}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.receipt_long,
            size: 64,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(height: 16),
          Text(
            'No payments in this range',
            style: TextStyle(
              fontSize: 18,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Try selecting a different date range',
            style: TextStyle(
              color: AppTheme.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(Object error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error, size: 64, color: AppTheme.error),
          const SizedBox(height: 16),
          const Text('Error loading report'),
          const SizedBox(height: 8),
          Text(
            ErrorMessageHelper.getUserFriendlyMessage(error),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _selectedFacilityId == null
                ? null
                : () {
                    final params = ReportParams(facilityId: _selectedFacilityId!);
                    ref.invalidate(reportsDataProvider(params));
                  },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectDate(bool isFromDate) async {
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: isFromDate 
          ? (_customFromDate ?? DateTime.now().subtract(const Duration(days: 30)))
          : (_customToDate ?? DateTime.now()),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    
    if (selectedDate != null) {
      setState(() {
        if (isFromDate) {
          _customFromDate = selectedDate;
        } else {
          _customToDate = selectedDate;
        }
      });
    }
  }

  void _exportToCsv(ReportData reportData) {
    final now = DateTime.now();
    final facilityName = _currentFacilityName().replaceAll(' ', '_');
    final filename =
        'financial_report_${facilityName}_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.csv';

    ref.read(reportExportProvider.notifier).exportToCsv(reportData, filename);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Report exported as $filename')),
    );
  }

  String _currentFacilityName() {
    if (_selectedFacilityId != null) {
      final match = _facilities.where((f) => f.id == _selectedFacilityId).toList();
      if (match.isNotEmpty) {
        return match.first.name;
      }
    }
    return widget.facility?.name ?? 'facility';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
