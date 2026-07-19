import 'package:cloud_firestore/cloud_firestore.dart';

/// Severity for a global DNR entry.
enum GlobalDnrSeverity {
  low,
  medium,
  high;

  static GlobalDnrSeverity fromString(String? v) {
    if (v == null) return GlobalDnrSeverity.medium;
    switch (v.toLowerCase()) {
      case 'low':
        return GlobalDnrSeverity.low;
      case 'high':
        return GlobalDnrSeverity.high;
      default:
        return GlobalDnrSeverity.medium;
    }
  }

  String get value => name;
}

/// Status for a global DNR entry.
enum GlobalDnrStatus {
  active,
  inactive,
  appealed;

  static GlobalDnrStatus fromString(String? v) {
    if (v == null) return GlobalDnrStatus.active;
    switch (v.toLowerCase()) {
      case 'inactive':
        return GlobalDnrStatus.inactive;
      case 'appealed':
        return GlobalDnrStatus.appealed;
      default:
        return GlobalDnrStatus.active;
    }
  }

  String get value => name;
}

/// Evidence type for global DNR.
enum GlobalDnrEvidenceType {
  photo,
  doc;

  static GlobalDnrEvidenceType fromString(String? v) {
    if (v == 'doc') return GlobalDnrEvidenceType.doc;
    return GlobalDnrEvidenceType.photo;
  }

  String get value => name;
}

/// One evidence item under global_dnr_entries/{entryId}/evidence/{evidenceId}
class GlobalDNREvidenceModel {
  final String id;
  final String type; // 'photo' | 'doc'
  final String storagePath;
  final String? downloadUrl;
  final String? caption;
  final DateTime createdAt;
  final String createdByUserId;

  const GlobalDNREvidenceModel({
    required this.id,
    required this.type,
    required this.storagePath,
    this.downloadUrl,
    this.caption,
    required this.createdAt,
    required this.createdByUserId,
  });

  factory GlobalDNREvidenceModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return GlobalDNREvidenceModel(
      id: doc.id,
      type: data['type'] as String? ?? 'photo',
      storagePath: data['storagePath'] as String? ?? '',
      downloadUrl: data['downloadUrl'] as String?,
      caption: data['caption'] as String?,
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      createdByUserId: data['createdByUserId'] as String? ?? '',
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'type': type,
      'storagePath': storagePath,
      if (downloadUrl != null) 'downloadUrl': downloadUrl,
      if (caption != null) 'caption': caption,
      'createdAt': Timestamp.fromDate(createdAt),
      'createdByUserId': createdByUserId,
    };
  }
}

/// Global DNR entry (collection global_dnr_entries).
/// Shared across every SFC operator account; any signed-in user can read; only owner/manager of the reporting facility can create/update (per rules).
class GlobalDNREntryModel {
  final String id;
  final String fullName;
  final String? dob; // string or stored as string for search
  final String phone;
  final String email;
  final String? driversLicenseLast4;
  final String? idLast4;
  final String reason;
  final String? notes;
  final GlobalDnrSeverity severity;
  final GlobalDnrStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdByUserId;
  final String createdByFacilityId;
  final String? createdByFacilityName;
  final String? createdByState;
  final String? reportedByName;
  final String? reportedByEmail;
  final String? linkedTenantId;
  final int evidenceCount;
  final List<String>? searchTokens;

  const GlobalDNREntryModel({
    required this.id,
    required this.fullName,
    this.dob,
    required this.phone,
    required this.email,
    this.driversLicenseLast4,
    this.idLast4,
    required this.reason,
    this.notes,
    this.severity = GlobalDnrSeverity.medium,
    this.status = GlobalDnrStatus.active,
    required this.createdAt,
    this.updatedAt,
    required this.createdByUserId,
    required this.createdByFacilityId,
    this.createdByFacilityName,
    this.createdByState,
    this.reportedByName,
    this.reportedByEmail,
    this.linkedTenantId,
    this.evidenceCount = 0,
    this.searchTokens,
  });

  factory GlobalDNREntryModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return GlobalDNREntryModel(
      id: doc.id,
      fullName: data['fullName'] as String? ?? '',
      dob: data['dob'] as String?,
      phone: data['phone'] as String? ?? '',
      email: data['email'] as String? ?? '',
      driversLicenseLast4: data['driversLicenseLast4'] as String?,
      idLast4: data['idLast4'] as String?,
      reason: data['reason'] as String? ?? '',
      notes: data['notes'] as String?,
      severity: GlobalDnrSeverity.fromString(data['severity'] as String?),
      status: GlobalDnrStatus.fromString(data['status'] as String?),
      createdAt: data['createdAt'] != null
          ? (data['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
      createdByUserId: data['createdByUserId'] as String? ?? '',
      createdByFacilityId: data['createdByFacilityId'] as String? ?? '',
      createdByFacilityName: data['createdByFacilityName'] as String?,
      createdByState: data['createdByState'] as String?,
      reportedByName: data['reportedByName'] as String?,
      reportedByEmail: data['reportedByEmail'] as String?,
      linkedTenantId: data['linkedTenantId'] as String?,
      evidenceCount: (data['evidenceCount'] as int?) ?? 0,
      searchTokens: data['searchTokens'] != null
          ? List<String>.from(data['searchTokens'] as List)
          : null,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'fullName': fullName,
      if (dob != null) 'dob': dob,
      'phone': phone,
      'email': email,
      if (driversLicenseLast4 != null) 'driversLicenseLast4': driversLicenseLast4,
      if (idLast4 != null) 'idLast4': idLast4,
      'reason': reason,
      if (notes != null) 'notes': notes,
      'severity': severity.value,
      'status': status.value,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
      'createdByUserId': createdByUserId,
      'createdByFacilityId': createdByFacilityId,
      if (createdByFacilityName != null) 'createdByFacilityName': createdByFacilityName,
      if (createdByState != null) 'createdByState': createdByState,
      if (reportedByName != null) 'reportedByName': reportedByName,
      if (reportedByEmail != null) 'reportedByEmail': reportedByEmail,
      if (linkedTenantId != null) 'linkedTenantId': linkedTenantId,
      'evidenceCount': evidenceCount,
      if (searchTokens != null) 'searchTokens': searchTokens,
    };
  }

  GlobalDNREntryModel copyWith({
    String? id,
    String? fullName,
    String? dob,
    String? phone,
    String? email,
    String? driversLicenseLast4,
    String? idLast4,
    String? reason,
    String? notes,
    GlobalDnrSeverity? severity,
    GlobalDnrStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdByUserId,
    String? createdByFacilityId,
    String? createdByFacilityName,
    String? createdByState,
    String? reportedByName,
    String? reportedByEmail,
    String? linkedTenantId,
    int? evidenceCount,
    List<String>? searchTokens,
  }) {
    return GlobalDNREntryModel(
      id: id ?? this.id,
      fullName: fullName ?? this.fullName,
      dob: dob ?? this.dob,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      driversLicenseLast4: driversLicenseLast4 ?? this.driversLicenseLast4,
      idLast4: idLast4 ?? this.idLast4,
      reason: reason ?? this.reason,
      notes: notes ?? this.notes,
      severity: severity ?? this.severity,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdByUserId: createdByUserId ?? this.createdByUserId,
      createdByFacilityId: createdByFacilityId ?? this.createdByFacilityId,
      createdByFacilityName: createdByFacilityName ?? this.createdByFacilityName,
      createdByState: createdByState ?? this.createdByState,
      reportedByName: reportedByName ?? this.reportedByName,
      reportedByEmail: reportedByEmail ?? this.reportedByEmail,
      linkedTenantId: linkedTenantId ?? this.linkedTenantId,
      evidenceCount: evidenceCount ?? this.evidenceCount,
      searchTokens: searchTokens ?? this.searchTokens,
    );
  }

  bool get isActive => status == GlobalDnrStatus.active;
}
