import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import '../models/report_models.dart';
import '../models/ledger_entry_model.dart';
import '../models/tenant_model.dart';
import '../models/unit_model.dart';
import '../models/deposit_model.dart';
import '../models/delinquency_stage_model.dart';
import '../models/facility_model.dart';
import '../services/ledger_service.dart';
import '../services/tenant_service.dart';
import '../services/unit_service.dart';
import '../services/deposit_service.dart';
import '../services/late_logic_service.dart';
import '../services/facility_service.dart';

class ReportData {
  final double totalRevenue;
  final int paymentCount;
  final double averagePayment;
  final DateTime? lastPaymentDate;
  final Map<String, MonthlyData> monthlyData;

  ReportData({
    required this.totalRevenue,
    required this.paymentCount,
    required this.averagePayment,
    required this.lastPaymentDate,
    required this.monthlyData,
  });
}

class MonthlyData {
  final String month; // YYYY-MM format
  final int count;
  final double sum;
  final double average;

  MonthlyData({
    required this.month,
    required this.count,
    required this.sum,
    required this.average,
  });
}

class ReportsService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Fetch payments report for a facility within a date range
  static Future<ReportData> fetchPaymentsReport({
    required String facilityId,
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Not signed in');
      }

      if (kDebugMode) {
        print('🔄 Fetching payments report for facility: $facilityId');
        print('📅 Date range: ${from.toIso8601String()} to ${to.toIso8601String()}');
      }

      // Query payments within date range
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('payments')
          .where('paidAt', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
          .where('paidAt', isLessThanOrEqualTo: Timestamp.fromDate(to))
          .orderBy('paidAt', descending: true)
          .get();

      if (kDebugMode) {
        print('📊 Found ${snapshot.docs.length} payments in range');
      }

      // Process payments
      double totalRevenue = 0.0;
      int paymentCount = 0;
      DateTime? lastPaymentDate;
      final Map<String, List<double>> monthlyPayments = {};

      for (final doc in snapshot.docs) {
        try {
          final data = doc.data();
          
          // Handle missing or malformed data gracefully
          final amount = _safeGetDouble(data['amount']);
          if (amount == null || amount <= 0) {
            if (kDebugMode) {
              print('⚠️ Skipping payment with invalid amount: ${data['amount']}');
            }
            continue;
          }

          final paidAt = data['paidAt'];
          if (paidAt == null) {
            if (kDebugMode) {
              print('⚠️ Skipping payment with missing paidAt');
            }
            continue;
          }

          final paymentDate = paidAt is Timestamp ? paidAt.toDate() : null;
          if (paymentDate == null) {
            if (kDebugMode) {
              print('⚠️ Skipping payment with invalid paidAt: $paidAt');
            }
            continue;
          }

          // Update totals
          totalRevenue += amount;
          paymentCount++;
          
          // Track last payment date
          if (lastPaymentDate == null || paymentDate.isAfter(lastPaymentDate)) {
            lastPaymentDate = paymentDate;
          }

          // Group by month (YYYY-MM format)
          final monthKey = '${paymentDate.year.toString().padLeft(4, '0')}-${paymentDate.month.toString().padLeft(2, '0')}';
          monthlyPayments.putIfAbsent(monthKey, () => []).add(amount);

        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Error processing payment ${doc.id}: $e');
          }
          // Continue processing other payments
        }
      }

      // Calculate monthly data
      final Map<String, MonthlyData> monthlyData = {};
      for (final entry in monthlyPayments.entries) {
        final amounts = entry.value;
        final sum = amounts.reduce((a, b) => a + b);
        final count = amounts.length;
        final average = sum / count;

        monthlyData[entry.key] = MonthlyData(
          month: entry.key,
          count: count,
          sum: sum,
          average: average,
        );
      }

      // Sort monthly data by month (newest first)
      final sortedMonths = monthlyData.keys.toList()
        ..sort((a, b) => b.compareTo(a));

      final sortedMonthlyData = <String, MonthlyData>{};
      for (final month in sortedMonths) {
        sortedMonthlyData[month] = monthlyData[month]!;
      }

      final averagePayment = paymentCount > 0 ? totalRevenue / paymentCount : 0.0;

      final reportData = ReportData(
        totalRevenue: totalRevenue,
        paymentCount: paymentCount,
        averagePayment: averagePayment,
        lastPaymentDate: lastPaymentDate,
        monthlyData: sortedMonthlyData,
      );

      if (kDebugMode) {
        print('✅ Report generated: \$${totalRevenue.toStringAsFixed(2)} total, $paymentCount payments');
      }

      return reportData;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error fetching payments report: $e');
      }
      rethrow;
    }
  }

  /// Safely extract double value from dynamic data
  static double? _safeGetDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return null;
  }

  /// Get available date ranges
  static Map<String, DateTime> getDateRange(DateTime now, String range) {
    switch (range.toLowerCase()) {
      case '30d':
        return {
          'from': now.subtract(const Duration(days: 30)),
          'to': now,
        };
      case '90d':
        return {
          'from': now.subtract(const Duration(days: 90)),
          'to': now,
        };
      case 'ytd':
        return {
          'from': DateTime(now.year, 1, 1),
          'to': now,
        };
      default:
        return {
          'from': now.subtract(const Duration(days: 30)),
          'to': now,
        };
    }
  }

  /// Export monthly data to CSV format
  static String exportToCsv(ReportData reportData) {
    final buffer = StringBuffer();
    
    // CSV header
    buffer.writeln('Month,Count,Sum,Average');
    
    // CSV rows
    for (final monthlyData in reportData.monthlyData.values) {
      buffer.writeln('${monthlyData.month},${monthlyData.count},${monthlyData.sum.toStringAsFixed(2)},${monthlyData.average.toStringAsFixed(2)}');
    }
    
    return buffer.toString();
  }

  /// Export Payments Report to PDF
  static Future<Uint8List> exportPaymentsToPdf({
    required ReportData reportData,
    required String facilityId,
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      final pdf = pw.Document();
      final dateFormat = DateFormat('MM/dd/yyyy');

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(72),
          build: (pw.Context context) {
            return [
              // Header
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          facility.name,
                          style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        if (facility.address != null)
                          pw.Text(
                            facility.address!,
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'PAYMENTS REPORT',
                          style: pw.TextStyle(
                            fontSize: 28,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          '${dateFormat.format(from)} - ${dateFormat.format(to)}',
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 40),

              // Summary Section
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  _buildMetricRow('Total Revenue', '\$${reportData.totalRevenue.toStringAsFixed(2)}'),
                  _buildMetricRow('Payment Count', '${reportData.paymentCount}'),
                  _buildMetricRow('Average Payment', '\$${reportData.averagePayment.toStringAsFixed(2)}'),
                  if (reportData.lastPaymentDate != null)
                    _buildMetricRow('Last Payment Date', dateFormat.format(reportData.lastPaymentDate!)),
                ],
              ),
              pw.SizedBox(height: 30),

              // Monthly Breakdown
              pw.Text(
                'Monthly Breakdown',
                style: pw.TextStyle(
                  fontSize: 16,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('Month', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Count',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Total',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Average',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  ...reportData.monthlyData.values.map((monthlyData) => pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(monthlyData.month),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('${monthlyData.count}', textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('\$${monthlyData.sum.toStringAsFixed(2)}', textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('\$${monthlyData.average.toStringAsFixed(2)}', textAlign: pw.TextAlign.right),
                      ),
                    ],
                  )),
                ],
              ),
            ];
          },
        ),
      );

      return pdf.save();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating Payments PDF: $e');
      }
      rethrow;
    }
  }

  /// Export AR Aging Report to CSV
  static String exportARAgingToCsv(ARAgingReport report) {
    final buffer = StringBuffer();
    
    // CSV header
    buffer.writeln('Range,Amount,Tenant Count');
    
    // CSV rows
    for (final bucket in report.buckets) {
      buffer.writeln('${bucket.range},${bucket.amount.toStringAsFixed(2)},${bucket.tenantCount}');
    }
    
    // Summary row
    buffer.writeln('');
    buffer.writeln('Total,${report.totalAR.toStringAsFixed(2)},${report.totalTenants}');
    
    return buffer.toString();
  }

  /// Export Occupancy Report to CSV
  static String exportOccupancyToCsv(OccupancyMetrics metrics) {
    final buffer = StringBuffer();
    
    // CSV header
    buffer.writeln('Metric,Value');
    
    // CSV rows
    buffer.writeln('Total Units,${metrics.totalUnits}');
    buffer.writeln('Occupied Units,${metrics.occupiedUnits}');
    buffer.writeln('Available Units,${metrics.availableUnits}');
    buffer.writeln('Reserved Units,${metrics.reservedUnits}');
    buffer.writeln('Maintenance Units,${metrics.maintenanceUnits}');
    buffer.writeln('Occupancy Rate,${metrics.occupancyRate.toStringAsFixed(2)}%');
    buffer.writeln('Average Monthly Rate,\$${metrics.averageMonthlyRate.toStringAsFixed(2)}');
    buffer.writeln('Potential Monthly Revenue,\$${metrics.potentialMonthlyRevenue.toStringAsFixed(2)}');
    buffer.writeln('Actual Monthly Revenue,\$${metrics.actualMonthlyRevenue.toStringAsFixed(2)}');
    
    return buffer.toString();
  }

  /// Export Delinquency Report to CSV
  static String exportDelinquencyToCsv(DelinquencySummary summary) {
    final buffer = StringBuffer();
    
    // CSV header
    buffer.writeln('Category,Count,Amount');
    
    // CSV rows
    buffer.writeln('Current,${summary.currentCount},\$${summary.currentAmount.toStringAsFixed(2)}');
    buffer.writeln('Late (1-7 days),${summary.lateCount},\$${summary.lateAmount.toStringAsFixed(2)}');
    buffer.writeln('Overdue (8-30 days),${summary.overdueCount},\$${summary.overdueAmount.toStringAsFixed(2)}');
    buffer.writeln('Severely Overdue (30+ days),${summary.severelyOverdueCount},\$${summary.severelyOverdueAmount.toStringAsFixed(2)}');
    
    // Summary row
    buffer.writeln('');
    buffer.writeln('Total Delinquent,${summary.currentCount + summary.lateCount + summary.overdueCount + summary.severelyOverdueCount},\$${summary.totalDelinquentAmount.toStringAsFixed(2)}');
    
    return buffer.toString();
  }

  /// Export Deposit Report to CSV
  static String exportDepositToCsv(DepositSummary summary) {
    final buffer = StringBuffer();
    
    // CSV header
    buffer.writeln('Status,Count,Amount');
    
    // CSV rows
    buffer.writeln('Pending,${summary.pendingDeposits},\$${summary.pendingAmount.toStringAsFixed(2)}');
    buffer.writeln('Deposited,${summary.depositedCount},\$${summary.depositedAmount.toStringAsFixed(2)}');
    buffer.writeln('Reconciled,${summary.reconciledCount},\$${summary.reconciledAmount.toStringAsFixed(2)}');
    
    // Summary rows
    buffer.writeln('');
    buffer.writeln('Total Deposits,${summary.totalDeposits},\$${summary.totalAmount.toStringAsFixed(2)}');
    buffer.writeln('Total Over/Short,\$${summary.totalOverShort.toStringAsFixed(2)}');
    
    return buffer.toString();
  }

  // ========== PDF Export Methods ==========

  /// Export AR Aging Report to PDF
  static Future<Uint8List> exportARAgingToPdf({
    required ARAgingReport report,
    required String facilityId,
    DateTime? asOfDate,
  }) async {
    try {
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      final pdf = pw.Document();
      final now = DateTime.now();
      final reportDate = asOfDate ?? now;
      final dateFormat = DateFormat('MM/dd/yyyy');

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(72),
          build: (pw.Context context) {
            return [
              // Header
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          facility.name,
                          style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        if (facility.address != null)
                          pw.Text(
                            facility.address!,
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'AR AGING REPORT',
                          style: pw.TextStyle(
                            fontSize: 28,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          'As of: ${dateFormat.format(reportDate)}',
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 40),

              // Report Table
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  // Header row
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('Age Range', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Amount',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Tenants',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  // Data rows
                  ...report.buckets.map((bucket) => pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('${bucket.range} days'),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('\$${bucket.amount.toStringAsFixed(2)}', textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('${bucket.tenantCount}', textAlign: pw.TextAlign.right),
                      ),
                    ],
                  )),
                  // Summary row
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('TOTAL', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('\$${report.totalAR.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('${report.totalTenants}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                    ],
                  ),
                ],
              ),
            ];
          },
        ),
      );

      return pdf.save();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating AR Aging PDF: $e');
      }
      rethrow;
    }
  }

  /// Export Occupancy Report to PDF
  static Future<Uint8List> exportOccupancyToPdf({
    required OccupancyMetrics metrics,
    required String facilityId,
  }) async {
    try {
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      final pdf = pw.Document();
      final now = DateTime.now();
      final dateFormat = DateFormat('MM/dd/yyyy');

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(72),
          build: (pw.Context context) {
            return [
              // Header
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          facility.name,
                          style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        if (facility.address != null)
                          pw.Text(
                            facility.address!,
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'OCCUPANCY REPORT',
                          style: pw.TextStyle(
                            fontSize: 28,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          'Date: ${dateFormat.format(now)}',
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 40),

              // Metrics Table
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('Metric', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Value',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  _buildMetricRow('Total Units', '${metrics.totalUnits}'),
                  _buildMetricRow('Occupied Units', '${metrics.occupiedUnits}'),
                  _buildMetricRow('Available Units', '${metrics.availableUnits}'),
                  _buildMetricRow('Reserved Units', '${metrics.reservedUnits}'),
                  _buildMetricRow('Maintenance Units', '${metrics.maintenanceUnits}'),
                  _buildMetricRow('Occupancy Rate', '${metrics.occupancyRate.toStringAsFixed(2)}%'),
                  _buildMetricRow('Average Monthly Rate', '\$${metrics.averageMonthlyRate.toStringAsFixed(2)}'),
                  _buildMetricRow('Potential Monthly Revenue', '\$${metrics.potentialMonthlyRevenue.toStringAsFixed(2)}'),
                  _buildMetricRow('Actual Monthly Revenue', '\$${metrics.actualMonthlyRevenue.toStringAsFixed(2)}'),
                ],
              ),
            ];
          },
        ),
      );

      return pdf.save();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating Occupancy PDF: $e');
      }
      rethrow;
    }
  }

  /// Helper to build metric row
  static pw.TableRow _buildMetricRow(String label, String value) {
    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(label),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(value, textAlign: pw.TextAlign.right),
        ),
      ],
    );
  }

  /// Export Delinquency Report to PDF
  static Future<Uint8List> exportDelinquencyToPdf({
    required DelinquencySummary summary,
    required String facilityId,
  }) async {
    try {
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      final pdf = pw.Document();
      final now = DateTime.now();
      final dateFormat = DateFormat('MM/dd/yyyy');

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(72),
          build: (pw.Context context) {
            return [
              // Header
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          facility.name,
                          style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        if (facility.address != null)
                          pw.Text(
                            facility.address!,
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'DELINQUENCY REPORT',
                          style: pw.TextStyle(
                            fontSize: 28,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          'Date: ${dateFormat.format(now)}',
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 40),

              // Report Table
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  // Header row
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('Category', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Count',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Amount',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  // Data rows
                  _buildMetricRow3('Current', '${summary.currentCount}', '\$${summary.currentAmount.toStringAsFixed(2)}'),
                  _buildMetricRow3('Late (1-7 days)', '${summary.lateCount}', '\$${summary.lateAmount.toStringAsFixed(2)}'),
                  _buildMetricRow3('Overdue (8-30 days)', '${summary.overdueCount}', '\$${summary.overdueAmount.toStringAsFixed(2)}'),
                  _buildMetricRow3('Severely Overdue (30+ days)', '${summary.severelyOverdueCount}', '\$${summary.severelyOverdueAmount.toStringAsFixed(2)}'),
                  // Summary row
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('Total Delinquent', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('${summary.currentCount + summary.lateCount + summary.overdueCount + summary.severelyOverdueCount}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('\$${summary.totalDelinquentAmount.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                    ],
                  ),
                ],
              ),
            ];
          },
        ),
      );

      return pdf.save();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating Delinquency PDF: $e');
      }
      rethrow;
    }
  }

  /// Helper to build metric row with 3 columns
  static pw.TableRow _buildMetricRow3(String label, String count, String amount) {
    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(label),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(count, textAlign: pw.TextAlign.right),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(amount, textAlign: pw.TextAlign.right),
        ),
      ],
    );
  }

  /// Export Deposit Report to PDF
  static Future<Uint8List> exportDepositToPdf({
    required DepositSummary summary,
    required String facilityId,
  }) async {
    try {
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) throw Exception('Facility not found');

      final pdf = pw.Document();
      final now = DateTime.now();
      final dateFormat = DateFormat('MM/dd/yyyy');

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(72),
          build: (pw.Context context) {
            return [
              // Header
              pw.Header(
                level: 0,
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          facility.name,
                          style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        if (facility.address != null)
                          pw.Text(
                            facility.address!,
                            style: const pw.TextStyle(fontSize: 10),
                          ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'DEPOSIT REPORT',
                          style: pw.TextStyle(
                            fontSize: 28,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Text(
                          'Date: ${dateFormat.format(now)}',
                          style: const pw.TextStyle(fontSize: 10),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 40),

              // Report Table
              pw.Table(
                border: pw.TableBorder.all(),
                children: [
                  // Header row
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey300),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('Status', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Count',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text(
                          'Amount',
                          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  // Data rows
                  _buildMetricRow3('Pending', '${summary.pendingDeposits}', '\$${summary.pendingAmount.toStringAsFixed(2)}'),
                  _buildMetricRow3('Deposited', '${summary.depositedCount}', '\$${summary.depositedAmount.toStringAsFixed(2)}'),
                  _buildMetricRow3('Reconciled', '${summary.reconciledCount}', '\$${summary.reconciledAmount.toStringAsFixed(2)}'),
                  // Summary rows
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('Total Deposits', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('${summary.totalDeposits}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('\$${summary.totalAmount.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                    ],
                  ),
                  pw.TableRow(
                    children: [
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('Total Over/Short', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('', textAlign: pw.TextAlign.right),
                      ),
                      pw.Padding(
                        padding: const pw.EdgeInsets.all(8),
                        child: pw.Text('\$${summary.totalOverShort.toStringAsFixed(2)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.right),
                      ),
                    ],
                  ),
                ],
              ),
            ];
          },
        ),
      );

      return pdf.save();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating Deposit PDF: $e');
      }
      rethrow;
    }
  }

  /// Generate AR Aging Report
  static Future<ARAgingReport> generateARAgingReport({
    required String facilityId,
    DateTime? asOfDate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      final cutoffDate = asOfDate ?? DateTime.now();
      
      // Get all active tenants
      final tenants = await TenantService.getTenantsForFacility(facilityId);
      final activeTenants = tenants.where((t) => t.isActive).toList();

      final buckets = <ARAgingBucket>[];
      double totalAR = 0.0;
      int totalTenants = 0;

      // Initialize buckets
      final bucketRanges = ['0-30', '31-60', '61-90', '90+'];
      final bucketAmounts = <String, double>{};
      final bucketCounts = <String, int>{};
      for (final range in bucketRanges) {
        bucketAmounts[range] = 0.0;
        bucketCounts[range] = 0;
      }

      for (final tenant in activeTenants) {
        final balance = await LedgerService.getLedgerBalance(
          tenantId: tenant.id,
          facilityId: facilityId,
        );

        if (balance <= 0) continue; // Skip tenants with no balance

        totalAR += balance;
        totalTenants++;

        // Calculate days overdue
        int daysOverdue = 0;
        if (tenant.isLate) {
          daysOverdue = tenant.daysLate;
        } else {
          // Check ledger for oldest unpaid charge
          final entries = await LedgerService.getLedgerEntries(
            tenantId: tenant.id,
            facilityId: facilityId,
          );
          final unpaidCharges = entries.where((e) => 
            e.isCharge && 
            e.isActive && 
            e.status == LedgerEntryStatus.posted
          ).toList();
          
          if (unpaidCharges.isNotEmpty) {
            unpaidCharges.sort((a, b) {
              final aDate = a.dueDate ?? DateTime.now();
              final bDate = b.dueDate ?? DateTime.now();
              return aDate.compareTo(bDate);
            });
            final oldestCharge = unpaidCharges.first;
            final oldestDueDate = oldestCharge.dueDate ?? DateTime.now();
            daysOverdue = cutoffDate.difference(oldestDueDate).inDays;
            if (daysOverdue < 0) daysOverdue = 0;
          }
        }

        // Assign to bucket
        String bucketRange;
        if (daysOverdue <= 30) {
          bucketRange = '0-30';
        } else if (daysOverdue <= 60) {
          bucketRange = '31-60';
        } else if (daysOverdue <= 90) {
          bucketRange = '61-90';
        } else {
          bucketRange = '90+';
        }

        bucketAmounts[bucketRange] = (bucketAmounts[bucketRange] ?? 0.0) + balance;
        bucketCounts[bucketRange] = (bucketCounts[bucketRange] ?? 0) + 1;
      }

      // Build bucket list
      for (final range in bucketRanges) {
        buckets.add(ARAgingBucket(
          range: range,
          amount: bucketAmounts[range] ?? 0.0,
          tenantCount: bucketCounts[range] ?? 0,
        ));
      }

      return ARAgingReport(
        buckets: buckets,
        totalAR: totalAR,
        totalTenants: totalTenants,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating AR aging report: $e');
      }
      rethrow;
    }
  }

  /// Generate Occupancy Report
  static Future<OccupancyMetrics> generateOccupancyReport({
    required String facilityId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      // Get all units
      final units = await UnitService.getUnitsForFacility(facilityId);
      
      int totalUnits = units.length;
      int occupiedUnits = units.where((u) => u.status == UnitStatus.occupied).length;
      int availableUnits = units.where((u) => u.status == UnitStatus.available).length;
      int reservedUnits = units.where((u) => u.status == UnitStatus.reserved).length;
      int maintenanceUnits = units.where((u) => 
        u.status == UnitStatus.maintenance || u.status == UnitStatus.outOfOrder
      ).length;

      final occupancyRate = totalUnits > 0 ? (occupiedUnits / totalUnits) * 100 : 0.0;

      // Calculate average monthly rate
      final occupiedUnitsWithRates = units.where((u) => 
        u.status == UnitStatus.occupied && u.monthlyRate > 0
      ).toList();
      final averageMonthlyRate = occupiedUnitsWithRates.isEmpty
          ? 0.0
          : occupiedUnitsWithRates.fold(0.0, (sum, u) => sum + u.monthlyRate) / occupiedUnitsWithRates.length;

      // Calculate potential revenue (all units at average rate)
      final potentialMonthlyRevenue = totalUnits * averageMonthlyRate;

      // Calculate actual revenue (from occupied units)
      final actualMonthlyRevenue = occupiedUnitsWithRates.fold(0.0, (sum, u) => sum + u.monthlyRate);

      return OccupancyMetrics(
        totalUnits: totalUnits,
        occupiedUnits: occupiedUnits,
        availableUnits: availableUnits,
        reservedUnits: reservedUnits,
        maintenanceUnits: maintenanceUnits,
        occupancyRate: occupancyRate,
        averageMonthlyRate: averageMonthlyRate,
        potentialMonthlyRevenue: potentialMonthlyRevenue,
        actualMonthlyRevenue: actualMonthlyRevenue,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating occupancy report: $e');
      }
      rethrow;
    }
  }

  /// Generate Delinquency Report
  static Future<DelinquencySummary> generateDelinquencyReport({
    required String facilityId,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      // Get tenants with overdue payments
      final overdueInfo = await LateLogicService.getTenantsWithOverduePayments(facilityId);

      int currentCount = 0;
      int lateCount = 0;
      int overdueCount = 0;
      int severelyOverdueCount = 0;
      double currentAmount = 0.0;
      double lateAmount = 0.0;
      double overdueAmount = 0.0;
      double severelyOverdueAmount = 0.0;

      for (final info in overdueInfo) {
        final daysOverdue = info.maxDaysOverdue;
        final balance = info.totalBalance;

        if (daysOverdue <= 0) {
          currentCount++;
          currentAmount += balance;
        } else if (daysOverdue <= 7) {
          lateCount++;
          lateAmount += balance;
        } else if (daysOverdue <= 30) {
          overdueCount++;
          overdueAmount += balance;
        } else {
          severelyOverdueCount++;
          severelyOverdueAmount += balance;
        }
      }

      return DelinquencySummary(
        currentCount: currentCount,
        lateCount: lateCount,
        overdueCount: overdueCount,
        severelyOverdueCount: severelyOverdueCount,
        currentAmount: currentAmount,
        lateAmount: lateAmount,
        overdueAmount: overdueAmount,
        severelyOverdueAmount: severelyOverdueAmount,
        totalDelinquentAmount: currentAmount + lateAmount + overdueAmount + severelyOverdueAmount,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating delinquency report: $e');
      }
      rethrow;
    }
  }

  /// Generate Deposit Report
  static Future<DepositSummary> generateDepositReport({
    required String facilityId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not signed in');

      final deposits = await DepositService.getDepositsForFacility(facilityId);

      // Filter by date range if provided
      var filteredDeposits = deposits;
      if (startDate != null) {
        filteredDeposits = filteredDeposits.where((d) => 
          d.depositDate.isAfter(startDate!) || d.depositDate.isAtSameMomentAs(startDate!)
        ).toList();
      }
      if (endDate != null) {
        filteredDeposits = filteredDeposits.where((d) => 
          d.depositDate.isBefore(endDate!) || d.depositDate.isAtSameMomentAs(endDate!)
        ).toList();
      }

      int totalDeposits = filteredDeposits.length;
      int pendingDeposits = filteredDeposits.where((d) => d.status == DepositStatus.pending).length;
      int depositedCount = filteredDeposits.where((d) => d.status == DepositStatus.deposited).length;
      int reconciledCount = filteredDeposits.where((d) => d.status == DepositStatus.reconciled).length;

      double totalAmount = filteredDeposits.fold(0.0, (sum, d) => sum + d.totalAmount);
      double pendingAmount = filteredDeposits
          .where((d) => d.status == DepositStatus.pending)
          .fold(0.0, (sum, d) => sum + d.totalAmount);
      double depositedAmount = filteredDeposits
          .where((d) => d.status == DepositStatus.deposited)
          .fold(0.0, (sum, d) => sum + d.totalAmount);
      double reconciledAmount = filteredDeposits
          .where((d) => d.status == DepositStatus.reconciled)
          .fold(0.0, (sum, d) => sum + d.totalAmount);
      double totalOverShort = filteredDeposits
          .where((d) => d.overShort != null)
          .fold(0.0, (sum, d) => sum + (d.overShort ?? 0.0));

      return DepositSummary(
        totalDeposits: totalDeposits,
        pendingDeposits: pendingDeposits,
        depositedCount: depositedCount,
        reconciledCount: reconciledCount,
        totalAmount: totalAmount,
        pendingAmount: pendingAmount,
        depositedAmount: depositedAmount,
        reconciledAmount: reconciledAmount,
        totalOverShort: totalOverShort,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [Reports] Error generating deposit report: $e');
      }
      rethrow;
    }
  }
}
