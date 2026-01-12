import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/services.dart';
import '../models/facility_model.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../services/facility_creator_account_service.dart';
import '../services/reports_service.dart';
import '../models/report_models.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../widgets/keyboard_scrollable.dart';
import '../utils/error_message_helper.dart';
// Conditional import for web-only CSV download
import 'reports_consolidated_stub.dart'
    if (dart.library.html) 'reports_consolidated_web.dart' as platform;

enum ReportType {
  financial,
  arAging,
  occupancy,
  delinquency,
  deposits,
}

class ReportsConsolidatedScreen extends ConsumerStatefulWidget {
  const ReportsConsolidatedScreen({super.key});

  @override
  ConsumerState<ReportsConsolidatedScreen> createState() => _ReportsConsolidatedScreenState();
}

enum ExportFormat { csv, pdf }

class _ReportsConsolidatedScreenState extends ConsumerState<ReportsConsolidatedScreen> {
  String _selectedFacilityId = '';
  ReportType _selectedReportType = ReportType.financial;
  ExportFormat _exportFormat = ExportFormat.csv;
  bool _isLoading = false;
  DateTime? _startDate;
  DateTime? _endDate;

  // Report data
  ARAgingReport? _arAgingReport;
  OccupancyMetrics? _occupancyMetrics;
  DelinquencySummary? _delinquencySummary;
  DepositSummary? _depositSummary;

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
  }

  Future<void> _loadUserFacilities() async {
    try {
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        final user = authState.value!;
        
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        } catch (accountError) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(ErrorMessageHelper.getUserFriendlyMessage(accountError)),
                backgroundColor: AppTheme.warning,
              ),
            );
            return;
          }
        }
        
        await Future.delayed(const Duration(milliseconds: 500));
        
        final facilitiesAsync = await ref.read(userFacilitiesProvider(user.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty) {
          setState(() {
            _selectedFacilityId = facilities.first.id;
          });
          _loadReport();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading facilities: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _loadReport() async {
    if (_selectedFacilityId.isEmpty) return;

    setState(() {
      _isLoading = true;
    });

    try {
      switch (_selectedReportType) {
        case ReportType.arAging:
          _arAgingReport = await ReportsService.generateARAgingReport(
            facilityId: _selectedFacilityId,
          );
          break;
        case ReportType.occupancy:
          _occupancyMetrics = await ReportsService.generateOccupancyReport(
            facilityId: _selectedFacilityId,
          );
          break;
        case ReportType.delinquency:
          _delinquencySummary = await ReportsService.generateDelinquencyReport(
            facilityId: _selectedFacilityId,
          );
          break;
        case ReportType.deposits:
          _depositSummary = await ReportsService.generateDepositReport(
            facilityId: _selectedFacilityId,
            startDate: _startDate,
            endDate: _endDate,
          );
          break;
        case ReportType.financial:
          // Use existing financial reports screen
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading report: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/reports',
      title: 'Reports',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: Column(
        children: [
          _buildReportSelector(),
          _buildFacilitySelector(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _buildReportContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildReportSelector() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: SegmentedButton<ReportType>(
        segments: const [
          ButtonSegment(value: ReportType.financial, label: Text('Financial')),
          ButtonSegment(value: ReportType.arAging, label: Text('AR Aging')),
          ButtonSegment(value: ReportType.occupancy, label: Text('Occupancy')),
          ButtonSegment(value: ReportType.delinquency, label: Text('Delinquency')),
          ButtonSegment(value: ReportType.deposits, label: Text('Deposits')),
        ],
        selected: {_selectedReportType},
        onSelectionChanged: (Set<ReportType> selection) {
          setState(() {
            _selectedReportType = selection.first;
          });
          _loadReport();
        },
      ),
    );
  }

  Widget _buildFacilitySelector() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: FutureBuilder<List<FacilityModel>>(
        future: ref.read(authStateProvider).maybeWhen(
          data: (user) => user != null
              ? ref.read(userFacilitiesProvider(user.uid).future)
              : Future.value(<FacilityModel>[]),
          orElse: () => Future.value(<FacilityModel>[]),
        ),
        builder: (context, snapshot) {
          final facilities = snapshot.data ?? [];
          if (facilities.isEmpty) return const SizedBox.shrink();
          
          return Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedFacilityId.isEmpty ? null : _selectedFacilityId,
                  decoration: InputDecoration(
                    labelText: 'Facility',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: facilities.map((facility) {
                    return DropdownMenuItem(
                      value: facility.id,
                      child: Text(facility.name),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _selectedFacilityId = value;
                      });
                      _loadReport();
                    }
                  },
                ),
              ),
              if (_selectedReportType == ReportType.deposits) ...[
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: () => _showDateRangeDialog(),
                  tooltip: 'Select Date Range',
                ),
              ],
              const SizedBox(width: 12),
              // Export Format Selector
              DropdownButton<ExportFormat>(
                value: _exportFormat,
                items: const [
                  DropdownMenuItem(value: ExportFormat.csv, child: Text('CSV')),
                  DropdownMenuItem(value: ExportFormat.pdf, child: Text('PDF')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _exportFormat = value;
                    });
                  }
                },
              ),
              const SizedBox(width: 12),
              // Export Button
              ElevatedButton.icon(
                icon: Icon(_exportFormat == ExportFormat.csv ? Icons.file_download : Icons.picture_as_pdf),
                label: Text(_exportFormat == ExportFormat.csv ? 'Export CSV' : 'Export PDF'),
                onPressed: _canExport() ? _exportReport : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryBlue,
                  foregroundColor: AppTheme.textOnDark,
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loadReport,
                tooltip: 'Refresh Report',
              ),
            ],
          );
        },
      ),
    );
  }

  bool _canExport() {
    switch (_selectedReportType) {
      case ReportType.arAging:
        return _arAgingReport != null;
      case ReportType.occupancy:
        return _occupancyMetrics != null;
      case ReportType.delinquency:
        return _delinquencySummary != null;
      case ReportType.deposits:
        return _depositSummary != null;
      case ReportType.financial:
        return false; // Use FinancialReportsScreen for export
    }
  }

  Future<void> _exportReport() async {
    if (_selectedFacilityId.isEmpty) return;

    if (_exportFormat == ExportFormat.csv) {
      _exportToCsv();
    } else {
      await _exportToPdf();
    }
  }

  Future<void> _exportToCsv() async {
    if (_selectedFacilityId.isEmpty) return;

    String csvContent;
    String filename;

    switch (_selectedReportType) {
      case ReportType.arAging:
        if (_arAgingReport == null) return;
        csvContent = ReportsService.exportARAgingToCsv(_arAgingReport!);
        filename = 'ar_aging_report_${_selectedFacilityId}_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv';
        break;
      case ReportType.occupancy:
        if (_occupancyMetrics == null) return;
        csvContent = ReportsService.exportOccupancyToCsv(_occupancyMetrics!);
        filename = 'occupancy_report_${_selectedFacilityId}_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv';
        break;
      case ReportType.delinquency:
        if (_delinquencySummary == null) return;
        csvContent = ReportsService.exportDelinquencyToCsv(_delinquencySummary!);
        filename = 'delinquency_report_${_selectedFacilityId}_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv';
        break;
      case ReportType.deposits:
        if (_depositSummary == null) return;
        csvContent = ReportsService.exportDepositToCsv(_depositSummary!);
        filename = 'deposits_report_${_selectedFacilityId}_${DateFormat('yyyyMMdd').format(DateTime.now())}.csv';
        break;
      case ReportType.financial:
        return; // Use FinancialReportsScreen
    }

    // Export CSV
    if (kIsWeb) {
      platform.downloadCsv(csvContent, filename);
    } else {
      // For mobile, save to file and share
      await _exportCsvMobile(csvContent, filename);
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Report exported as $filename'),
        backgroundColor: AppTheme.success,
      ),
    );
  }

  Future<void> _exportCsvMobile(String csvContent, String filename) async {
    try {
      // Get temporary directory
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/$filename');
      
      // Write CSV content to file
      await file.writeAsString(csvContent);
      
      if (mounted) {
        // Copy to clipboard as fallback and show success message
        await Clipboard.setData(ClipboardData(text: csvContent));
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('CSV saved to ${file.path}\nContent also copied to clipboard'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'OK',
              onPressed: () {},
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        // Fallback: copy to clipboard
        try {
          await Clipboard.setData(ClipboardData(text: csvContent));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('CSV copied to clipboard (file save failed: $e)'),
              backgroundColor: AppTheme.warning,
            ),
          );
        } catch (clipboardError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to export CSV: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _exportToPdf() async {
    if (_selectedFacilityId.isEmpty) return;

    try {
      setState(() {
        _isLoading = true;
      });

      Uint8List pdfData;

      switch (_selectedReportType) {
        case ReportType.arAging:
          if (_arAgingReport == null) return;
          pdfData = await ReportsService.exportARAgingToPdf(
            report: _arAgingReport!,
            facilityId: _selectedFacilityId,
          );
          break;
        case ReportType.occupancy:
          if (_occupancyMetrics == null) return;
          pdfData = await ReportsService.exportOccupancyToPdf(
            metrics: _occupancyMetrics!,
            facilityId: _selectedFacilityId,
          );
          break;
        case ReportType.delinquency:
          if (_delinquencySummary == null) return;
          pdfData = await ReportsService.exportDelinquencyToPdf(
            summary: _delinquencySummary!,
            facilityId: _selectedFacilityId,
          );
          break;
        case ReportType.deposits:
          if (_depositSummary == null) return;
          pdfData = await ReportsService.exportDepositToPdf(
            summary: _depositSummary!,
            facilityId: _selectedFacilityId,
          );
          break;
        case ReportType.financial:
          return; // Use FinancialReportsScreen
      }

      // Show print dialog
      await Printing.layoutPdf(
        onLayout: (format) async => pdfData,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('PDF ready to print or save'),
            backgroundColor: AppTheme.success,
          ),
        );
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
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildReportContent() {
    if (_selectedFacilityId.isEmpty) {
      return Center(
        child: Text(
          'Select a facility to view reports',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: AppTheme.textSecondary,
          ),
        ),
      );
    }

    switch (_selectedReportType) {
      case ReportType.financial:
        return const Center(
          child: Text('Use Financial Reports screen for detailed financial reports'),
        );
      case ReportType.arAging:
        return _buildARAgingReport();
      case ReportType.occupancy:
        return _buildOccupancyReport();
      case ReportType.delinquency:
        return _buildDelinquencyReport();
      case ReportType.deposits:
        return _buildDepositsReport();
    }
  }

  Widget _buildARAgingReport() {
    if (_arAgingReport == null) {
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
              'No AR Aging Data',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'No accounts receivable data available for this facility.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Report'),
              onPressed: _loadReport,
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            color: AppTheme.primaryBlueLight.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total AR',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        '\$${_arAgingReport!.totalAR.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Tenants',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        '${_arAgingReport!.totalTenants}',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ..._arAgingReport!.buckets.map((bucket) => Card(
                margin: const EdgeInsets.only(bottom: 12.0),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _getBucketColor(bucket.range).withOpacity(0.1),
                    child: Icon(
                      Icons.timer,
                      color: _getBucketColor(bucket.range),
                    ),
                  ),
                  title: Text('${bucket.range} Days'),
                  subtitle: Text('${bucket.tenantCount} tenant(s)'),
                  trailing: Text(
                    '\$${bucket.amount.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildOccupancyReport() {
    if (_occupancyMetrics == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.home_outlined,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              'No Occupancy Data',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'No occupancy metrics available for this facility.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Report'),
              onPressed: _loadReport,
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            color: AppTheme.success.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text(
                    'Occupancy Rate',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  Text(
                    '${_occupancyMetrics!.occupancyRate.toStringAsFixed(1)}%',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.success,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildMetricCard(
                  'Total Units',
                  '${_occupancyMetrics!.totalUnits}',
                  Icons.home,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  'Occupied',
                  '${_occupancyMetrics!.occupiedUnits}',
                  Icons.check_circle,
                  AppTheme.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildMetricCard(
                  'Available',
                  '${_occupancyMetrics!.availableUnits}',
                  Icons.home_outlined,
                  AppTheme.info,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  'Maintenance',
                  '${_occupancyMetrics!.maintenanceUnits}',
                  Icons.build,
                  AppTheme.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Revenue Metrics',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _buildRevenueRow('Average Monthly Rate', '\$${_occupancyMetrics!.averageMonthlyRate.toStringAsFixed(2)}'),
                  _buildRevenueRow('Potential Monthly Revenue', '\$${_occupancyMetrics!.potentialMonthlyRevenue.toStringAsFixed(2)}'),
                  _buildRevenueRow('Actual Monthly Revenue', '\$${_occupancyMetrics!.actualMonthlyRevenue.toStringAsFixed(2)}'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDelinquencyReport() {
    if (_delinquencySummary == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.money_off,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              'No Delinquency Data',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'No delinquency data available for this facility.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Report'),
              onPressed: _loadReport,
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            color: AppTheme.error.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text(
                    'Total Delinquent Amount',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  Text(
                    '\$${_delinquencySummary!.totalDelinquentAmount.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _buildDelinquencyCard('Current', _delinquencySummary!.currentCount, _delinquencySummary!.currentAmount, AppTheme.success),
          _buildDelinquencyCard('Late (1-7 days)', _delinquencySummary!.lateCount, _delinquencySummary!.lateAmount, AppTheme.warning),
          _buildDelinquencyCard('Overdue (8-30 days)', _delinquencySummary!.overdueCount, _delinquencySummary!.overdueAmount, AppTheme.error),
          _buildDelinquencyCard('Severely Overdue (30+ days)', _delinquencySummary!.severelyOverdueCount, _delinquencySummary!.severelyOverdueAmount, AppTheme.error),
        ],
      ),
    );
  }

  Widget _buildDepositsReport() {
    if (_depositSummary == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.account_balance_wallet,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              'No Deposit Data',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'No deposit data available for this facility.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh Report'),
              onPressed: _loadReport,
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            color: AppTheme.primaryBlueLight.withOpacity(0.1),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Deposits',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        '\$${_depositSummary!.totalAmount.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Count',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      Text(
                        '${_depositSummary!.totalDeposits}',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildMetricCard(
                  'Pending',
                  '\$${_depositSummary!.pendingAmount.toStringAsFixed(2)}',
                  Icons.pending,
                  AppTheme.warning,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  'Deposited',
                  '\$${_depositSummary!.depositedAmount.toStringAsFixed(2)}',
                  Icons.check_circle,
                  AppTheme.info,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildMetricCard(
                  'Reconciled',
                  '\$${_depositSummary!.reconciledAmount.toStringAsFixed(2)}',
                  Icons.verified,
                  AppTheme.success,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  'Over/Short',
                  '\$${_depositSummary!.totalOverShort.toStringAsFixed(2)}',
                  Icons.balance,
                  _depositSummary!.totalOverShort >= 0 ? AppTheme.success : AppTheme.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(String label, String value, IconData icon, [Color? color]) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Icon(icon, color: color ?? AppTheme.primaryBlue, size: 32),
            const SizedBox(height: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: color ?? AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRevenueRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDelinquencyCard(String label, int count, double amount, Color color) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.1),
          child: Icon(Icons.warning, color: color),
        ),
        title: Text(label),
        subtitle: Text('$count tenant(s)'),
        trailing: Text(
          '\$${amount.toStringAsFixed(2)}',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }

  Color _getBucketColor(String range) {
    switch (range) {
      case '0-30':
        return AppTheme.success;
      case '31-60':
        return AppTheme.warning;
      case '61-90':
        return AppTheme.error;
      case '90+':
        return AppTheme.error;
      default:
        return AppTheme.textSecondary;
    }
  }

  void _showDateRangeDialog() {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Select Date Range'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                      setState(() {
                        _startDate = date;
                      });
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
                      setState(() {
                        _endDate = date;
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _startDate = null;
                  _endDate = null;
                });
              },
              child: const Text('Clear'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _loadReport();
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}

