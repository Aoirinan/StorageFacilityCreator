import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/scheduled_report_model.dart';
import '../services/reports_service.dart';
import '../services/email_cloud_service.dart';
import '../services/reports_service.dart' as reports;

/// Service for scheduling and delivering reports
class ReportSchedulingService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a scheduled report
  static Future<String> createScheduledReport({
    required String facilityId,
    required String name,
    required ScheduledReportType reportType,
    required ReportScheduleFrequency frequency,
    required List<String> recipients,
    required ReportExportFormat format,
    String? scheduleDay,
    String? scheduleTime,
    Map<String, dynamic>? reportParams,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final scheduledReport = ScheduledReport(
        id: '',
        facilityId: facilityId,
        name: name,
        reportType: reportType,
        frequency: frequency,
        recipients: recipients,
        format: format,
        scheduleDay: scheduleDay,
        scheduleTime: scheduleTime ?? '09:00',
        reportParams: reportParams,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      // Calculate next scheduled time
      final nextScheduledAt = scheduledReport.calculateNextScheduledTime();

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('scheduledReports')
          .add(scheduledReport.copyWith(
            nextScheduledAt: nextScheduledAt,
          ).toMap());

      if (kDebugMode) {
        print('✅ [ReportScheduling] Created scheduled report: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReportScheduling] Error creating scheduled report: $e');
      }
      rethrow;
    }
  }

  /// Get scheduled reports for a facility
  static Future<List<ScheduledReport>> getScheduledReports(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('scheduledReports')
          .where('isActive', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => ScheduledReport.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReportScheduling] Error getting scheduled reports: $e');
      }
      return [];
    }
  }

  /// Update a scheduled report
  static Future<void> updateScheduledReport({
    required String facilityId,
    required String reportId,
    String? name,
    ScheduledReportType? reportType,
    ReportScheduleFrequency? frequency,
    List<String>? recipients,
    ReportExportFormat? format,
    String? scheduleDay,
    String? scheduleTime,
    Map<String, dynamic>? reportParams,
    bool? isActive,
  }) async {
    try {
      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (name != null) updates['name'] = name;
      if (reportType != null) updates['reportType'] = reportType.name;
      if (frequency != null) updates['frequency'] = frequency.name;
      if (recipients != null) updates['recipients'] = recipients;
      if (format != null) updates['format'] = format.name;
      if (scheduleDay != null) updates['scheduleDay'] = scheduleDay;
      if (scheduleTime != null) updates['scheduleTime'] = scheduleTime;
      if (reportParams != null) updates['reportParams'] = reportParams;
      if (isActive != null) updates['isActive'] = isActive;

      // Recalculate next scheduled time if schedule changed
      if (frequency != null || scheduleDay != null || scheduleTime != null) {
        final doc = await _firestore
            .collection('facilities')
            .doc(facilityId)
            .collection('scheduledReports')
            .doc(reportId)
            .get();

        if (doc.exists) {
          final current = ScheduledReport.fromMap(reportId, doc.data()!);
          final updated = current.copyWith(
            name: name ?? current.name,
            reportType: reportType ?? current.reportType,
            frequency: frequency ?? current.frequency,
            scheduleDay: scheduleDay ?? current.scheduleDay,
            scheduleTime: scheduleTime ?? current.scheduleTime,
          );
          updates['nextScheduledAt'] = Timestamp.fromDate(
            updated.calculateNextScheduledTime(),
          );
        }
      }

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('scheduledReports')
          .doc(reportId)
          .update(updates);

      if (kDebugMode) {
        print('✅ [ReportScheduling] Updated scheduled report: $reportId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReportScheduling] Error updating scheduled report: $e');
      }
      rethrow;
    }
  }

  /// Delete a scheduled report
  static Future<void> deleteScheduledReport({
    required String facilityId,
    required String reportId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('scheduledReports')
          .doc(reportId)
          .update({'isActive': false});

      if (kDebugMode) {
        print('✅ [ReportScheduling] Deleted scheduled report: $reportId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReportScheduling] Error deleting scheduled report: $e');
      }
      rethrow;
    }
  }

  /// Get delivery history for a scheduled report
  static Future<List<ScheduledReportDelivery>> getDeliveryHistory({
    required String facilityId,
    required String reportId,
    int limit = 50,
  }) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('scheduledReports')
          .doc(reportId)
          .collection('deliveries')
          .orderBy('sentAt', descending: true)
          .limit(limit)
          .get();

      return snapshot.docs
          .map((doc) => ScheduledReportDelivery.fromMap(doc.id, doc.data()))
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReportScheduling] Error getting delivery history: $e');
      }
      return [];
    }
  }

  /// Process pending scheduled reports (called by scheduled Cloud Function)
  static Future<void> processPendingReports(String facilityId) async {
    try {
      final now = DateTime.now();

      // Find reports that should be sent now
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('scheduledReports')
          .where('isActive', isEqualTo: true)
          .where('nextScheduledAt', isLessThanOrEqualTo: Timestamp.fromDate(now))
          .get();

      for (final doc in snapshot.docs) {
        final scheduledReport = ScheduledReport.fromMap(doc.id, doc.data());
        await _sendScheduledReport(scheduledReport);
      }

      if (kDebugMode) {
        print('✅ [ReportScheduling] Processed pending reports for facility: $facilityId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReportScheduling] Error processing pending reports: $e');
      }
    }
  }

  /// Send a scheduled report
  static Future<void> _sendScheduledReport(ScheduledReport scheduledReport) async {
    try {
      // Generate report based on type
      final reportContent = await _generateReport(
        facilityId: scheduledReport.facilityId,
        reportType: scheduledReport.reportType,
        format: scheduledReport.format,
        params: scheduledReport.reportParams,
      );

      if (reportContent == null) {
        throw Exception('Failed to generate report');
      }

      // Send email with report attachment
      // Note: For now, we'll send the content in the email body
      // In production, you'd upload to Firebase Storage and attach the URL
      final subject = '${scheduledReport.name} - ${DateTime.now().toString().split(' ')[0]}';
      final body = 'Please find your scheduled report attached.\n\nGenerated: ${DateTime.now()}';

      for (final recipient in scheduledReport.recipients) {
        try {
          final emailResult = await EmailCloudService.sendEmail(
            facilityId: scheduledReport.facilityId,
            to: recipient,
            subject: subject,
            html: body.replaceAll('\n', '<br>'),
          );

          if (!emailResult.success) {
            throw Exception(emailResult.error ?? 'Email send failed');
          }

          // Record successful delivery
          await _firestore
              .collection('facilities')
              .doc(scheduledReport.facilityId)
              .collection('scheduledReports')
              .doc(scheduledReport.id)
              .collection('deliveries')
              .add({
            'scheduledReportId': scheduledReport.id,
            'sentAt': FieldValue.serverTimestamp(),
            'success': true,
            'recipients': [recipient],
            if (emailResult.messageId != null) 'messageId': emailResult.messageId,
          });
        } catch (e) {
          // Record failed delivery
          await _firestore
              .collection('facilities')
              .doc(scheduledReport.facilityId)
              .collection('scheduledReports')
              .doc(scheduledReport.id)
              .collection('deliveries')
              .add({
            'scheduledReportId': scheduledReport.id,
            'sentAt': FieldValue.serverTimestamp(),
            'success': false,
            'errorMessage': e.toString(),
            'recipients': [recipient],
          });
        }
      }

      // Update scheduled report
      final nextScheduledAt = scheduledReport.calculateNextScheduledTime();
      await _firestore
          .collection('facilities')
          .doc(scheduledReport.facilityId)
          .collection('scheduledReports')
          .doc(scheduledReport.id)
          .update({
        'lastSentAt': FieldValue.serverTimestamp(),
        'nextScheduledAt': Timestamp.fromDate(nextScheduledAt),
      });

      if (kDebugMode) {
        print('✅ [ReportScheduling] Sent scheduled report: ${scheduledReport.id}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReportScheduling] Error sending scheduled report: $e');
      }
      rethrow;
    }
  }

  /// Generate report content
  static Future<String?> _generateReport({
    required String facilityId,
    required ScheduledReportType reportType,
    required ReportExportFormat format,
    Map<String, dynamic>? params,
  }) async {
    try {
      // Calculate date range from params or use defaults
      final now = DateTime.now();
      final from = params?['from'] != null
          ? DateTime.parse(params!['from'])
          : DateTime(now.year, now.month - 1, 1);
      final to = params?['to'] != null
          ? DateTime.parse(params!['to'])
          : DateTime(now.year, now.month, 0);

      switch (reportType) {
        case ScheduledReportType.financial:
          final reportData = await ReportsService.fetchPaymentsReport(
            facilityId: facilityId,
            from: from,
            to: to,
          );
          if (format == ReportExportFormat.csv) {
            return ReportsService.exportToCsv(reportData);
          } else if (format == ReportExportFormat.pdf) {
            // PDF export returns bytes, convert to base64 for email attachment
            final pdfBytes = await ReportsService.exportPaymentsToPdf(
              reportData: reportData,
              facilityId: facilityId,
              from: from,
              to: to,
            );
            return 'PDF:' + base64.encode(pdfBytes); // Prefix to identify PDF format
          }
          // Default to CSV
          return ReportsService.exportToCsv(reportData);

        case ScheduledReportType.arAging:
          final report = await ReportsService.generateARAgingReport(facilityId: facilityId);
          if (format == ReportExportFormat.csv) {
            return ReportsService.exportARAgingToCsv(report);
          } else if (format == ReportExportFormat.pdf) {
            final pdfBytes = await ReportsService.exportARAgingToPdf(
              report: report,
              facilityId: facilityId,
            );
            return 'PDF:' + base64.encode(pdfBytes);
          }
          return ReportsService.exportARAgingToCsv(report);

        case ScheduledReportType.occupancy:
          final metrics = await ReportsService.generateOccupancyReport(facilityId: facilityId);
          if (format == ReportExportFormat.csv) {
            return ReportsService.exportOccupancyToCsv(metrics);
          } else if (format == ReportExportFormat.pdf) {
            final pdfBytes = await ReportsService.exportOccupancyToPdf(
              metrics: metrics,
              facilityId: facilityId,
            );
            return 'PDF:' + base64.encode(pdfBytes);
          }
          return ReportsService.exportOccupancyToCsv(metrics);

        case ScheduledReportType.delinquency:
          final summary = await ReportsService.generateDelinquencyReport(facilityId: facilityId);
          if (format == ReportExportFormat.csv) {
            return ReportsService.exportDelinquencyToCsv(summary);
          } else if (format == ReportExportFormat.pdf) {
            final pdfBytes = await ReportsService.exportDelinquencyToPdf(
              summary: summary,
              facilityId: facilityId,
            );
            return 'PDF:' + base64.encode(pdfBytes);
          }
          return ReportsService.exportDelinquencyToCsv(summary);

        case ScheduledReportType.deposits:
          final summary = await ReportsService.generateDepositReport(
            facilityId: facilityId,
            startDate: from,
            endDate: to,
          );
          if (format == ReportExportFormat.csv) {
            return ReportsService.exportDepositToCsv(summary);
          } else if (format == ReportExportFormat.pdf) {
            final pdfBytes = await ReportsService.exportDepositToPdf(
              summary: summary,
              facilityId: facilityId,
            );
            return 'PDF:' + base64.encode(pdfBytes);
          }
          return ReportsService.exportDepositToCsv(summary);

        case ScheduledReportType.communicationAnalytics:
        case ScheduledReportType.all:
          // For 'all', would need to generate multiple reports
          // For now, return placeholder
          return 'Multiple reports - not yet implemented';
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [ReportScheduling] Error generating report: $e');
      }
      return null;
    }
  }
}

extension ScheduledReportExtension on ScheduledReport {
  ScheduledReport copyWith({
    String? id,
    String? facilityId,
    String? name,
    ScheduledReportType? reportType,
    ReportScheduleFrequency? frequency,
    List<String>? recipients,
    ReportExportFormat? format,
    String? scheduleDay,
    String? scheduleTime,
    Map<String, dynamic>? reportParams,
    bool? isActive,
    DateTime? lastSentAt,
    DateTime? nextScheduledAt,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
  }) {
    return ScheduledReport(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      name: name ?? this.name,
      reportType: reportType ?? this.reportType,
      frequency: frequency ?? this.frequency,
      recipients: recipients ?? this.recipients,
      format: format ?? this.format,
      scheduleDay: scheduleDay ?? this.scheduleDay,
      scheduleTime: scheduleTime ?? this.scheduleTime,
      reportParams: reportParams ?? this.reportParams,
      isActive: isActive ?? this.isActive,
      lastSentAt: lastSentAt ?? this.lastSentAt,
      nextScheduledAt: nextScheduledAt ?? this.nextScheduledAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}

