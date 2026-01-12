import 'package:cloud_firestore/cloud_firestore.dart';

/// Report type for scheduling
enum ScheduledReportType {
  financial,
  arAging,
  occupancy,
  delinquency,
  deposits,
  communicationAnalytics,
  all, // Schedule all report types
}

/// Schedule frequency
enum ReportScheduleFrequency {
  daily,
  weekly,
  monthly,
  quarterly,
  custom,
}

/// Export format
enum ReportExportFormat {
  csv,
  excel,
  pdf,
}

/// Scheduled report configuration
class ScheduledReport {
  final String id;
  final String facilityId;
  final String name; // User-friendly name for the schedule
  final ScheduledReportType reportType;
  final ReportScheduleFrequency frequency;
  final List<String> recipients; // Email addresses to send to
  final ReportExportFormat format;
  final String? scheduleDay; // Day of week (for weekly) or day of month (for monthly)
  final String? scheduleTime; // Time of day (HH:mm)
  final Map<String, dynamic>? reportParams; // Parameters for the report (date range, filters, etc.)
  final bool isActive;
  final DateTime? lastSentAt;
  final DateTime? nextScheduledAt;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;

  const ScheduledReport({
    required this.id,
    required this.facilityId,
    required this.name,
    required this.reportType,
    required this.frequency,
    required this.recipients,
    required this.format,
    this.scheduleDay,
    this.scheduleTime,
    this.reportParams,
    this.isActive = true,
    this.lastSentAt,
    this.nextScheduledAt,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'name': name,
      'reportType': reportType.name,
      'frequency': frequency.name,
      'recipients': recipients,
      'format': format.name,
      'scheduleDay': scheduleDay,
      'scheduleTime': scheduleTime ?? '09:00',
      'reportParams': reportParams,
      'isActive': isActive,
      'lastSentAt': lastSentAt != null ? Timestamp.fromDate(lastSentAt!) : null,
      'nextScheduledAt': nextScheduledAt != null ? Timestamp.fromDate(nextScheduledAt!) : null,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'createdBy': createdBy,
    };
  }

  factory ScheduledReport.fromMap(String id, Map<String, dynamic> map) {
    return ScheduledReport(
      id: id,
      facilityId: map['facilityId'] as String,
      name: map['name'] as String,
      reportType: ScheduledReportType.values.firstWhere(
        (t) => t.name == map['reportType'],
        orElse: () => ScheduledReportType.financial,
      ),
      frequency: ReportScheduleFrequency.values.firstWhere(
        (f) => f.name == map['frequency'],
        orElse: () => ReportScheduleFrequency.monthly,
      ),
      recipients: List<String>.from(map['recipients'] ?? []),
      format: ReportExportFormat.values.firstWhere(
        (f) => f.name == map['format'],
        orElse: () => ReportExportFormat.csv,
      ),
      scheduleDay: map['scheduleDay'] as String?,
      scheduleTime: map['scheduleTime'] as String? ?? '09:00',
      reportParams: map['reportParams'] as Map<String, dynamic>?,
      isActive: map['isActive'] as bool? ?? true,
      lastSentAt: (map['lastSentAt'] as Timestamp?)?.toDate(),
      nextScheduledAt: (map['nextScheduledAt'] as Timestamp?)?.toDate(),
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: map['createdBy'] as String,
    );
  }

  /// Calculate next scheduled time based on frequency
  DateTime calculateNextScheduledTime({DateTime? from}) {
    final baseDate = from ?? DateTime.now();
    final timeParts = (scheduleTime ?? '09:00').split(':');
    final hour = int.tryParse(timeParts[0]) ?? 9;
    final minute = int.tryParse(timeParts[1]) ?? 0;

    switch (frequency) {
      case ReportScheduleFrequency.daily:
        var next = DateTime(baseDate.year, baseDate.month, baseDate.day, hour, minute);
        if (next.isBefore(baseDate)) {
          next = next.add(const Duration(days: 1));
        }
        return next;

      case ReportScheduleFrequency.weekly:
        // scheduleDay should be day name (Monday, Tuesday, etc.) or number (0-6)
        final targetDay = _parseDayOfWeek(scheduleDay);
        var next = DateTime(baseDate.year, baseDate.month, baseDate.day, hour, minute);
        while (next.weekday != targetDay || next.isBefore(baseDate)) {
          next = next.add(const Duration(days: 1));
        }
        return next;

      case ReportScheduleFrequency.monthly:
        // scheduleDay should be day of month (1-31)
        final dayOfMonth = int.tryParse(scheduleDay ?? '1') ?? 1;
        var next = DateTime(baseDate.year, baseDate.month, dayOfMonth.clamp(1, 28), hour, minute);
        if (next.isBefore(baseDate)) {
          next = DateTime(baseDate.year, baseDate.month + 1, dayOfMonth.clamp(1, 28), hour, minute);
        }
        return next;

      case ReportScheduleFrequency.quarterly:
        // First day of next quarter
        final quarter = (baseDate.month - 1) ~/ 3;
        var nextQuarterMonth = (quarter + 1) * 3 + 1;
        var nextQuarterYear = baseDate.year;
        if (nextQuarterMonth > 12) {
          nextQuarterMonth = 1;
          nextQuarterYear++;
        }
        return DateTime(nextQuarterYear, nextQuarterMonth, 1, hour, minute);

      case ReportScheduleFrequency.custom:
        // For custom, nextScheduledAt should be set manually
        return nextScheduledAt ?? baseDate.add(const Duration(days: 1));
    }
  }

  int _parseDayOfWeek(String? dayString) {
    if (dayString == null) return 1; // Default to Monday
    final lower = dayString.toLowerCase();
    switch (lower) {
      case 'monday':
      case 'mon':
      case '1':
        return 1;
      case 'tuesday':
      case 'tue':
      case '2':
        return 2;
      case 'wednesday':
      case 'wed':
      case '3':
        return 3;
      case 'thursday':
      case 'thu':
      case '4':
        return 4;
      case 'friday':
      case 'fri':
      case '5':
        return 5;
      case 'saturday':
      case 'sat':
      case '6':
        return 6;
      case 'sunday':
      case 'sun':
      case '0':
        return 7;
      default:
        return 1;
    }
  }
}

/// Scheduled report delivery record
class ScheduledReportDelivery {
  final String id;
  final String scheduledReportId;
  final DateTime sentAt;
  final bool success;
  final String? errorMessage;
  final String? attachmentUrl; // URL to the generated report file
  final List<String> recipients;
  final Map<String, dynamic>? metadata;

  const ScheduledReportDelivery({
    required this.id,
    required this.scheduledReportId,
    required this.sentAt,
    required this.success,
    this.errorMessage,
    this.attachmentUrl,
    required this.recipients,
    this.metadata,
  });

  Map<String, dynamic> toMap() {
    return {
      'scheduledReportId': scheduledReportId,
      'sentAt': Timestamp.fromDate(sentAt),
      'success': success,
      'errorMessage': errorMessage,
      'attachmentUrl': attachmentUrl,
      'recipients': recipients,
      'metadata': metadata,
    };
  }

  factory ScheduledReportDelivery.fromMap(String id, Map<String, dynamic> map) {
    return ScheduledReportDelivery(
      id: id,
      scheduledReportId: map['scheduledReportId'] as String,
      sentAt: (map['sentAt'] as Timestamp).toDate(),
      success: map['success'] as bool,
      errorMessage: map['errorMessage'] as String?,
      attachmentUrl: map['attachmentUrl'] as String?,
      recipients: List<String>.from(map['recipients'] ?? []),
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }
}

