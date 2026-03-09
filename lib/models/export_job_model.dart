import 'package:cloud_firestore/cloud_firestore.dart';

enum ExportType {
  tenants,
  payments,
  auditLogs,
  ledgerEntries,
  invoices,
  contracts,
}

enum ExportStatus {
  pending,
  processing,
  completed,
  failed,
}

class ExportJobModel {
  final String id;
  final String facilityId;
  final ExportType type;
  final ExportStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? downloadUrl;
  final String? errorMessage;
  final Map<String, dynamic>? filters; // Date range, status filters, etc.
  final int? recordCount;
  final String createdBy;

  const ExportJobModel({
    required this.id,
    required this.facilityId,
    required this.type,
    required this.status,
    required this.createdAt,
    this.completedAt,
    this.downloadUrl,
    this.errorMessage,
    this.filters,
    this.recordCount,
    required this.createdBy,
  });

  factory ExportJobModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ExportJobModel(
      id: doc.id,
      facilityId: data['facilityId'] as String,
      type: ExportType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => ExportType.tenants,
      ),
      status: ExportStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => ExportStatus.pending,
      ),
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      completedAt: data['completedAt'] != null
          ? (data['completedAt'] as Timestamp).toDate()
          : null,
      downloadUrl: data['downloadUrl'] as String?,
      errorMessage: data['errorMessage'] as String?,
      filters: data['filters'] as Map<String, dynamic>?,
      recordCount: data['recordCount'] as int?,
      createdBy: data['createdBy'] as String,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'type': type.name,
      'status': status.name,
      'createdAt': Timestamp.fromDate(createdAt),
      if (completedAt != null) 'completedAt': Timestamp.fromDate(completedAt!),
      if (downloadUrl != null) 'downloadUrl': downloadUrl,
      if (errorMessage != null) 'errorMessage': errorMessage,
      if (filters != null) 'filters': filters,
      if (recordCount != null) 'recordCount': recordCount,
      'createdBy': createdBy,
    };
  }

  ExportJobModel copyWith({
    String? id,
    String? facilityId,
    ExportType? type,
    ExportStatus? status,
    DateTime? createdAt,
    DateTime? completedAt,
    String? downloadUrl,
    String? errorMessage,
    Map<String, dynamic>? filters,
    int? recordCount,
    String? createdBy,
  }) {
    return ExportJobModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      type: type ?? this.type,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      errorMessage: errorMessage ?? this.errorMessage,
      filters: filters ?? this.filters,
      recordCount: recordCount ?? this.recordCount,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}
