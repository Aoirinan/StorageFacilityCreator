import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../services/reports_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
// Conditional import for web-only dart:html
// - On web platforms: imports reports_provider_web.dart (which uses dart:html)
// - On other platforms: imports reports_provider_stub.dart (which throws UnsupportedError)
import 'reports_provider_stub.dart'
    if (dart.library.html) 'reports_provider_web.dart' as platform;

// Provider for report filter (date range selection)
final reportFilterProvider = StateProvider<String>((ref) => '30d');

// Provider for custom date range
final customDateRangeProvider = StateProvider<Map<String, DateTime>?>((ref) => null);

// Provider for reports data
final reportsDataProvider = FutureProvider.family<ReportData, ReportParams>((ref, params) async {
  final filter = ref.watch(reportFilterProvider);
  final customRange = ref.watch(customDateRangeProvider);
  
  DateTime from, to;
  
  if (filter == 'custom' && customRange != null) {
    from = customRange['from']!;
    to = customRange['to']!;
  } else {
    final dateRange = ReportsService.getDateRange(DateTime.now(), filter);
    from = dateRange['from']!;
    to = dateRange['to']!;
  }
  
  return ReportsService.fetchPaymentsReport(
    facilityId: params.facilityId,
    from: from,
    to: to,
  );
});

// Helper class for report parameters
class ReportParams {
  final String facilityId;
  
  ReportParams({required this.facilityId});
  
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReportParams &&
          runtimeType == other.runtimeType &&
          facilityId == other.facilityId;
  
  @override
  int get hashCode => facilityId.hashCode;
}

// Provider for report export functionality
final reportExportProvider = StateNotifierProvider<ReportExportNotifier, AsyncValue<void>>((ref) {
  return ReportExportNotifier();
});

class ReportExportNotifier extends StateNotifier<AsyncValue<void>> {
  ReportExportNotifier() : super(const AsyncValue.data(null));
  
  Future<void> exportToCsv(ReportData reportData, String filename) async {
    state = const AsyncValue.loading();
    try {
      final csvContent = ReportsService.exportToCsv(reportData);
      
      // For web, we'll use a simple download approach
      // The kIsWeb check ensures this is only called on web platforms
      if (kIsWeb) {
        _downloadCsvWeb(csvContent, filename);
      }
      
      state = const AsyncValue.data(null);
    } catch (e, stackTrace) {
      state = AsyncValue.error(e, stackTrace);
    }
  }
  
  void _downloadCsvWeb(String csvContent, String filename) {
    // Delegates to platform-specific implementation
    // Web: creates blob and triggers download
    // Non-web: throws UnsupportedError (but should never be called due to kIsWeb check above)
    platform.downloadCsv(csvContent, filename);
  }
}
