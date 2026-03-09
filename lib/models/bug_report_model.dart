import 'package:cloud_firestore/cloud_firestore.dart';

enum BugReportStatus { open, inProgress, resolved, closed }

enum BugReportSeverity { low, medium, high, critical }

class BugReportModel {
  final String id;
  final String title;
  final String description;
  final String submittedByUid;
  final String submittedByEmail;
  final String? facilityId;
  final String? facilityName;
  final BugReportStatus status;
  final BugReportSeverity severity;
  final String? adminNotes;
  final DateTime createdAt;
  final DateTime updatedAt;

  const BugReportModel({
    required this.id,
    required this.title,
    required this.description,
    required this.submittedByUid,
    required this.submittedByEmail,
    this.facilityId,
    this.facilityName,
    this.status = BugReportStatus.open,
    this.severity = BugReportSeverity.medium,
    this.adminNotes,
    required this.createdAt,
    required this.updatedAt,
  });

  factory BugReportModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return BugReportModel(
      id: doc.id,
      title: data['title'] as String? ?? '',
      description: data['description'] as String? ?? '',
      submittedByUid: data['submittedByUid'] as String? ?? '',
      submittedByEmail: data['submittedByEmail'] as String? ?? '',
      facilityId: data['facilityId'] as String?,
      facilityName: data['facilityName'] as String?,
      status: BugReportStatus.values.firstWhere(
        (s) => s.name == (data['status'] as String?),
        orElse: () => BugReportStatus.open,
      ),
      severity: BugReportSeverity.values.firstWhere(
        (s) => s.name == (data['severity'] as String?),
        orElse: () => BugReportSeverity.medium,
      ),
      adminNotes: data['adminNotes'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'title': title,
      'description': description,
      'submittedByUid': submittedByUid,
      'submittedByEmail': submittedByEmail,
      if (facilityId != null) 'facilityId': facilityId,
      if (facilityName != null) 'facilityName': facilityName,
      'status': status.name,
      'severity': severity.name,
      if (adminNotes != null) 'adminNotes': adminNotes,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
    };
  }

  BugReportModel copyWith({
    BugReportStatus? status,
    String? adminNotes,
    DateTime? updatedAt,
  }) {
    return BugReportModel(
      id: id,
      title: title,
      description: description,
      submittedByUid: submittedByUid,
      submittedByEmail: submittedByEmail,
      facilityId: facilityId,
      facilityName: facilityName,
      status: status ?? this.status,
      severity: severity,
      adminNotes: adminNotes ?? this.adminNotes,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
