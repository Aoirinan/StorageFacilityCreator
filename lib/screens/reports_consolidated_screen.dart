import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/report_models.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/search_provider.dart' hide userFacilitiesProvider;
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';
import 'package:sfcapp/services/reports_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';
// Conditional import for web-only CSV download
import 'package:sfcapp/screens/reports_consolidated_stub.dart'
    if (dart.library.html) 'package:sfcapp/screens/reports_consolidated_web.dart'
    as platform;

const _kAllFacilitiesReport = '__all__';

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
  // _kAllFacilitiesReport = show aggregated view; '' = not yet loaded; otherwise a real facility id
  String _selectedFacilityId = _kAllFacilitiesReport;
  List<FacilityModel> _allFacilities = [];
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

        ref.invalidate(userFacilitiesProvider(user.uid));
        final facilitiesAsync = await ref.read(userFacilitiesProvider(user.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (mounted) {
          // Respect the global facility picker if one is already set
          final globalFacility = ref.read(selectedFacilityProvider);
          setState(() {
            _allFacilities = facilities;
            if (globalFacility != null && facilities.any((f) => f.id == globalFacility.id)) {
              _selectedFacilityId = globalFacility.id;
            } else {
              _selectedFacilityId = _kAllFacilitiesReport;
            }
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

  bool get _isAllFacilities => _selectedFacilityId == _kAllFacilitiesReport;

  Future<void> _loadReport() async {
    if (_selectedFacilityId.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      if (_isAllFacilities) {
        await _loadAggregatedReport();
      } else {
        await _loadSingleFacilityReport(_selectedFacilityId);
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
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadSingleFacilityReport(String facilityId) async {
    switch (_selectedReportType) {
      case ReportType.arAging:
        _arAgingReport = await ReportsService.generateARAgingReport(facilityId: facilityId);
        break;
      case ReportType.occupancy:
        _occupancyMetrics = await ReportsService.generateOccupancyReport(facilityId: facilityId);
        break;
      case ReportType.delinquency:
        _delinquencySummary = await ReportsService.generateDelinquencyReport(facilityId: facilityId);
        break;
      case ReportType.deposits:
        _depositSummary = await ReportsService.generateDepositReport(
          facilityId: facilityId,
          startDate: _startDate,
          endDate: _endDate,
        );
        break;
      case ReportType.financial:
        break;
    }
  }

  Future<void> _loadAggregatedReport() async {
    final facilities = _allFacilities;
    if (facilities.isEmpty) return;

    switch (_selectedReportType) {
      case ReportType.arAging:
        final reports = await Future.wait(
          facilities.map((f) => ReportsService.generateARAgingReport(facilityId: f.id)),
        );
        _arAgingReport = _mergeARAgingReports(reports);
        break;
      case ReportType.occupancy:
        final reports = await Future.wait(
          facilities.map((f) => ReportsService.generateOccupancyReport(facilityId: f.id)),
        );
        _occupancyMetrics = _mergeOccupancyMetrics(reports);
        break;
      case ReportType.delinquency:
        final reports = await Future.wait(
          facilities.map((f) => ReportsService.generateDelinquencyReport(facilityId: f.id)),
        );
        _delinquencySummary = _mergeDelinquencySummaries(reports);
        break;
      case ReportType.deposits:
        final reports = await Future.wait(
          facilities.map((f) => ReportsService.generateDepositReport(
            facilityId: f.id,
            startDate: _startDate,
            endDate: _endDate,
          )),
        );
        _depositSummary = _mergeDepositSummaries(reports);
        break;
      case ReportType.financial:
        break;
    }
  }

  ARAgingReport _mergeARAgingReports(List<ARAgingReport> reports) {
    final bucketMap = <String, ARAgingBucket>{};
    double totalAR = 0;
    int totalTenants = 0;
    for (final r in reports) {
      totalAR += r.totalAR;
      totalTenants += r.totalTenants;
      for (final b in r.buckets) {
        final existing = bucketMap[b.range];
        bucketMap[b.range] = ARAgingBucket(
          range: b.range,
          amount: (existing?.amount ?? 0) + b.amount,
          tenantCount: (existing?.tenantCount ?? 0) + b.tenantCount,
        );
      }
    }
    return ARAgingReport(
      buckets: bucketMap.values.toList(),
      totalAR: totalAR,
      totalTenants: totalTenants,
    );
  }

  OccupancyMetrics _mergeOccupancyMetrics(List<OccupancyMetrics> reports) {
    int totalUnits = 0, occupied = 0, available = 0, reserved = 0, maintenance = 0;
    double potential = 0, actual = 0;
    for (final r in reports) {
      totalUnits += r.totalUnits;
      occupied += r.occupiedUnits;
      available += r.availableUnits;
      reserved += r.reservedUnits;
      maintenance += r.maintenanceUnits;
      potential += r.potentialMonthlyRevenue;
      actual += r.actualMonthlyRevenue;
    }
    final rate = totalUnits > 0 ? (occupied / totalUnits) * 100 : 0.0;
    final avgRate = occupied > 0 ? actual / occupied : 0.0;
    return OccupancyMetrics(
      totalUnits: totalUnits,
      occupiedUnits: occupied,
      availableUnits: available,
      reservedUnits: reserved,
      maintenanceUnits: maintenance,
      occupancyRate: rate,
      averageMonthlyRate: avgRate,
      potentialMonthlyRevenue: potential,
      actualMonthlyRevenue: actual,
    );
  }

  DelinquencySummary _mergeDelinquencySummaries(List<DelinquencySummary> reports) {
    int currentCount = 0, lateCount = 0, overdueCount = 0, severelyCount = 0;
    double currentAmt = 0, lateAmt = 0, overdueAmt = 0, severelyAmt = 0;
    for (final r in reports) {
      currentCount += r.currentCount;
      lateCount += r.lateCount;
      overdueCount += r.overdueCount;
      severelyCount += r.severelyOverdueCount;
      currentAmt += r.currentAmount;
      lateAmt += r.lateAmount;
      overdueAmt += r.overdueAmount;
      severelyAmt += r.severelyOverdueAmount;
    }
    return DelinquencySummary(
      currentCount: currentCount,
      lateCount: lateCount,
      overdueCount: overdueCount,
      severelyOverdueCount: severelyCount,
      currentAmount: currentAmt,
      lateAmount: lateAmt,
      overdueAmount: overdueAmt,
      severelyOverdueAmount: severelyAmt,
      totalDelinquentAmount: lateAmt + overdueAmt + severelyAmt,
    );
  }

  DepositSummary _mergeDepositSummaries(List<DepositSummary> reports) {
    int total = 0, pending = 0, deposited = 0, reconciled = 0;
    double totalAmt = 0, pendingAmt = 0, depositedAmt = 0, reconciledAmt = 0, overShort = 0;
    for (final r in reports) {
      total += r.totalDeposits;
      pending += r.pendingDeposits;
      deposited += r.depositedCount;
      reconciled += r.reconciledCount;
      totalAmt += r.totalAmount;
      pendingAmt += r.pendingAmount;
      depositedAmt += r.depositedAmount;
      reconciledAmt += r.reconciledAmount;
      overShort += r.totalOverShort;
    }
    return DepositSummary(
      totalDeposits: total,
      pendingDeposits: pending,
      depositedCount: deposited,
      reconciledCount: reconciled,
      totalAmount: totalAmt,
      pendingAmount: pendingAmt,
      depositedAmount: depositedAmt,
      reconciledAmount: reconciledAmt,
      totalOverShort: overShort,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Sync with global facility picker
    final globalFacility = ref.watch(selectedFacilityProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final globalId = globalFacility?.id;
      if (globalId != null && _selectedFacilityId != globalId) {
        setState(() => _selectedFacilityId = globalId);
        _loadReport();
      }
    });

    return Column(
      children: [
        _buildReportSelector(),
        _buildFacilitySelector(),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _buildReportContent(),
        ),
      ],
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
    final facilities = _allFacilities;
    if (facilities.isEmpty) return const SizedBox.shrink();

    // Ensure current selection is valid
    final effectiveId = (_selectedFacilityId == _kAllFacilitiesReport ||
            facilities.any((f) => f.id == _selectedFacilityId))
        ? _selectedFacilityId
        : _kAllFacilitiesReport;

    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              value: effectiveId,
              decoration: InputDecoration(
                labelText: 'Facility',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: _kAllFacilitiesReport,
                  child: Text('All Facilities'),
                ),
                ...facilities.map((facility) => DropdownMenuItem<String>(
                  value: facility.id,
                  child: Text(facility.name),
                )),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedFacilityId = value);
                  // Sync global picker
                  if (value == _kAllFacilitiesReport) {
                    ref.read(selectedFacilityProvider.notifier).state = null;
                  } else {
                    final picked = facilities.firstWhere((f) => f.id == value);
                    ref.read(selectedFacilityProvider.notifier).state = picked;
                  }
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
          DropdownButton<ExportFormat>(
            value: _exportFormat,
            items: const [
              DropdownMenuItem(value: ExportFormat.csv, child: Text('CSV')),
              DropdownMenuItem(value: ExportFormat.pdf, child: Text('PDF')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _exportFormat = value);
            },
          ),
          const SizedBox(width: 12),
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
    if (_exportFormat == ExportFormat.csv) {
      _exportToCsv();
    } else {
      await _exportToPdf();
    }
  }

  Future<void> _exportToCsv() async {
    final facilityLabel = _isAllFacilities ? 'all' : _selectedFacilityId;
    final dateSuffix = DateFormat('yyyyMMdd').format(DateTime.now());

    String csvContent;
    String filename;

    switch (_selectedReportType) {
      case ReportType.arAging:
        if (_arAgingReport == null) return;
        csvContent = ReportsService.exportARAgingToCsv(_arAgingReport!);
        filename = 'ar_aging_report_${facilityLabel}_$dateSuffix.csv';
        break;
      case ReportType.occupancy:
        if (_occupancyMetrics == null) return;
        csvContent = ReportsService.exportOccupancyToCsv(_occupancyMetrics!);
        filename = 'occupancy_report_${facilityLabel}_$dateSuffix.csv';
        break;
      case ReportType.delinquency:
        if (_delinquencySummary == null) return;
        csvContent = ReportsService.exportDelinquencyToCsv(_delinquencySummary!);
        filename = 'delinquency_report_${facilityLabel}_$dateSuffix.csv';
        break;
      case ReportType.deposits:
        if (_depositSummary == null) return;
        csvContent = ReportsService.exportDepositToCsv(_depositSummary!);
        filename = 'deposits_report_${facilityLabel}_$dateSuffix.csv';
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
    final facilityLabel = _isAllFacilities ? 'all_facilities' : _selectedFacilityId;

    try {
      setState(() => _isLoading = true);

      Uint8List pdfData;

      switch (_selectedReportType) {
        case ReportType.arAging:
          if (_arAgingReport == null) return;
          pdfData = await ReportsService.exportARAgingToPdf(
            report: _arAgingReport!,
            facilityId: facilityLabel,
          );
          break;
        case ReportType.occupancy:
          if (_occupancyMetrics == null) return;
          pdfData = await ReportsService.exportOccupancyToPdf(
            metrics: _occupancyMetrics!,
            facilityId: facilityLabel,
          );
          break;
        case ReportType.delinquency:
          if (_delinquencySummary == null) return;
          pdfData = await ReportsService.exportDelinquencyToPdf(
            summary: _delinquencySummary!,
            facilityId: facilityLabel,
          );
          break;
        case ReportType.deposits:
          if (_depositSummary == null) return;
          pdfData = await ReportsService.exportDepositToPdf(
            summary: _depositSummary!,
            facilityId: facilityLabel,
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

