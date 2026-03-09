import 'package:cloud_firestore/cloud_firestore.dart';

enum ContractStatus {
  draft,
  sent,
  signed,
  expired,
  cancelled,
}

/// Compliance status for contracts/templates
enum ComplianceStatus {
  active,
  disabled,
}

enum MoveOutStatus {
  notStarted,
  initiated,
  chargesCalculated,
  refundProcessed,
  completed,
  cancelled,
}

enum ContractType {
  lease,
  rental,
  storage,
  custom,
}

class ContractModel {
  final String id;
  final String facilityId;
  final String facilityOwnerUid;  // ✅ REQUIRED for Firestore security rules
  final String tenantId;
  final String title;
  final String description;
  final ContractType type;
  final ContractStatus status;
  final String? templateId;
  final String? fileUrl;
  final String? signedFileUrl;
  final DateTime createdAt;
  final DateTime? sentAt;
  final DateTime? signedAt;
  final DateTime? expiresAt;
  final String createdBy;
  final String? sentBy;
  final String? signedBy;
  final Map<String, dynamic>? customFields;
  final String? notes;
  final bool isActive;
  // Move-out fields
  final MoveOutStatus? moveOutStatus;
  final DateTime? moveOutDate;
  final double? moveOutCharges;
  final double? moveOutRefund;
  final String? moveOutNotes;
  // Compliance fields
  final ComplianceStatus complianceStatus;
  final bool isLicensedForm; // Association/licensed form flag
  final DateTime? lastReconfirmedAt; // Last rights reconfirmation
  final String? documentSha256; // SHA-256 hash of uploaded PDF
  final int? fileSize; // File size in bytes
  final String? contentType; // MIME type (e.g., 'application/pdf')
  final DateTime? uploadedAt; // When file was uploaded
  final String? storagePath; // Storage path in Firebase Storage
  final DateTime? disabledAt; // When contract was disabled
  final String? disabledBy; // User ID who disabled it
  final String? disabledReason; // Reason for disabling

  ContractModel({
    required this.id,
    required this.facilityId,
    required this.facilityOwnerUid,
    required this.tenantId,
    required this.title,
    required this.description,
    required this.type,
    required this.status,
    this.templateId,
    this.fileUrl,
    this.signedFileUrl,
    required this.createdAt,
    this.sentAt,
    this.signedAt,
    this.expiresAt,
    required this.createdBy,
    this.sentBy,
    this.signedBy,
    this.customFields,
    this.notes,
    this.isActive = true,
    this.moveOutStatus,
    this.moveOutDate,
    this.moveOutCharges,
    this.moveOutRefund,
    this.moveOutNotes,
    this.complianceStatus = ComplianceStatus.active,
    this.isLicensedForm = false,
    this.lastReconfirmedAt,
    this.documentSha256,
    this.fileSize,
    this.contentType,
    this.uploadedAt,
    this.storagePath,
    this.disabledAt,
    this.disabledBy,
    this.disabledReason,
  });

  /// Parse from Cloud Function response (timestamps as {seconds, nanoseconds})
  static DateTime? _dateFrom(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    if (v is Map) {
      final sec = v['seconds'] as int?;
      if (sec != null) return DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    }
    return null;
  }

  factory ContractModel.fromMap(Map<String, dynamic> data, {required String id}) {
    return ContractModel(
      id: id,
      facilityId: data['facilityId'] ?? '',
      facilityOwnerUid: data['facilityOwnerUid'] ?? '',
      tenantId: data['tenantId'] ?? '',
      title: data['title'] ?? '',
      description: data['description'] ?? '',
      type: ContractType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => ContractType.custom,
      ),
      status: ContractStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => ContractStatus.draft,
      ),
      templateId: data['templateId'],
      fileUrl: data['fileUrl'],
      signedFileUrl: data['signedFileUrl'],
      createdAt: _dateFrom(data['createdAt']) ?? DateTime.now(),
      sentAt: _dateFrom(data['sentAt']),
      signedAt: _dateFrom(data['signedAt']),
      expiresAt: _dateFrom(data['expiresAt']),
      createdBy: data['createdBy'] ?? '',
      sentBy: data['sentBy'],
      signedBy: data['signedBy'],
      customFields: data['customFields'] != null ? Map<String, dynamic>.from(data['customFields']) : null,
      notes: data['notes'],
      isActive: data['isActive'] ?? true,
      moveOutStatus: data['moveOutStatus'] != null
          ? MoveOutStatus.values.firstWhere(
              (e) => e.name == data['moveOutStatus'],
              orElse: () => MoveOutStatus.notStarted,
            )
          : null,
      moveOutDate: _dateFrom(data['moveOutDate']),
      moveOutCharges: data['moveOutCharges'] != null ? (data['moveOutCharges'] as num).toDouble() : null,
      moveOutRefund: data['moveOutRefund'] != null ? (data['moveOutRefund'] as num).toDouble() : null,
      moveOutNotes: data['moveOutNotes'],
      complianceStatus: data['complianceStatus'] != null
          ? ComplianceStatus.values.firstWhere(
              (e) => e.name == data['complianceStatus'],
              orElse: () => ComplianceStatus.active,
            )
          : ComplianceStatus.active,
      isLicensedForm: data['isLicensedForm'] ?? false,
      lastReconfirmedAt: _dateFrom(data['lastReconfirmedAt']),
      documentSha256: data['documentSha256'],
      fileSize: data['fileSize'] != null ? (data['fileSize'] as num).toInt() : null,
      contentType: data['contentType'],
      uploadedAt: _dateFrom(data['uploadedAt']),
      storagePath: data['storagePath'],
      disabledAt: _dateFrom(data['disabledAt']),
      disabledBy: data['disabledBy'],
      disabledReason: data['disabledReason'],
    );
  }

  factory ContractModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ContractModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      facilityOwnerUid: data['facilityOwnerUid'] ?? '',
      tenantId: data['tenantId'] ?? '',
      title: data['title'] ?? '',
      description: data['description'] ?? '',
      type: ContractType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => ContractType.custom,
      ),
      status: ContractStatus.values.firstWhere(
        (e) => e.name == data['status'],
        orElse: () => ContractStatus.draft,
      ),
      templateId: data['templateId'],
      fileUrl: data['fileUrl'],
      signedFileUrl: data['signedFileUrl'],
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      sentAt: data['sentAt'] != null ? (data['sentAt'] as Timestamp).toDate() : null,
      signedAt: data['signedAt'] != null ? (data['signedAt'] as Timestamp).toDate() : null,
      expiresAt: data['expiresAt'] != null ? (data['expiresAt'] as Timestamp).toDate() : null,
      createdBy: data['createdBy'] ?? '',
      sentBy: data['sentBy'],
      signedBy: data['signedBy'],
      customFields: data['customFields'] != null ? Map<String, dynamic>.from(data['customFields']) : null,
      notes: data['notes'],
      isActive: data['isActive'] ?? true,
      moveOutStatus: data['moveOutStatus'] != null
          ? MoveOutStatus.values.firstWhere(
              (e) => e.name == data['moveOutStatus'],
              orElse: () => MoveOutStatus.notStarted,
            )
          : null,
      moveOutDate: data['moveOutDate'] != null ? (data['moveOutDate'] as Timestamp).toDate() : null,
      moveOutCharges: data['moveOutCharges'] != null ? (data['moveOutCharges'] as num).toDouble() : null,
      moveOutRefund: data['moveOutRefund'] != null ? (data['moveOutRefund'] as num).toDouble() : null,
      moveOutNotes: data['moveOutNotes'],
      complianceStatus: data['complianceStatus'] != null
          ? ComplianceStatus.values.firstWhere(
              (e) => e.name == data['complianceStatus'],
              orElse: () => ComplianceStatus.active,
            )
          : ComplianceStatus.active,
      isLicensedForm: data['isLicensedForm'] ?? false,
      lastReconfirmedAt: data['lastReconfirmedAt'] != null ? (data['lastReconfirmedAt'] as Timestamp).toDate() : null,
      documentSha256: data['documentSha256'],
      fileSize: data['fileSize'] != null ? (data['fileSize'] as num).toInt() : null,
      contentType: data['contentType'],
      uploadedAt: data['uploadedAt'] != null ? (data['uploadedAt'] as Timestamp).toDate() : null,
      storagePath: data['storagePath'],
      disabledAt: data['disabledAt'] != null ? (data['disabledAt'] as Timestamp).toDate() : null,
      disabledBy: data['disabledBy'],
      disabledReason: data['disabledReason'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'facilityOwnerUid': facilityOwnerUid,
      'tenantId': tenantId,
      'title': title,
      'description': description,
      'type': type.name,
      'status': status.name,
      'templateId': templateId,
      'fileUrl': fileUrl,
      'signedFileUrl': signedFileUrl,
      'createdAt': Timestamp.fromDate(createdAt),
      'sentAt': sentAt != null ? Timestamp.fromDate(sentAt!) : null,
      'signedAt': signedAt != null ? Timestamp.fromDate(signedAt!) : null,
      'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt!) : null,
      'createdBy': createdBy,
      'sentBy': sentBy,
      'signedBy': signedBy,
      'customFields': customFields,
      'notes': notes,
      'isActive': isActive,
      if (moveOutStatus != null) 'moveOutStatus': moveOutStatus!.name,
      if (moveOutDate != null) 'moveOutDate': Timestamp.fromDate(moveOutDate!),
      if (moveOutCharges != null) 'moveOutCharges': moveOutCharges,
      if (moveOutRefund != null) 'moveOutRefund': moveOutRefund,
      if (moveOutNotes != null && moveOutNotes!.isNotEmpty) 'moveOutNotes': moveOutNotes,
      'complianceStatus': complianceStatus.name,
      'isLicensedForm': isLicensedForm,
      if (lastReconfirmedAt != null) 'lastReconfirmedAt': Timestamp.fromDate(lastReconfirmedAt!),
      if (documentSha256 != null) 'documentSha256': documentSha256,
      if (fileSize != null) 'fileSize': fileSize,
      if (contentType != null) 'contentType': contentType,
      if (uploadedAt != null) 'uploadedAt': Timestamp.fromDate(uploadedAt!),
      if (storagePath != null) 'storagePath': storagePath,
      if (disabledAt != null) 'disabledAt': Timestamp.fromDate(disabledAt!),
      if (disabledBy != null) 'disabledBy': disabledBy,
      if (disabledReason != null) 'disabledReason': disabledReason,
    };
  }

  ContractModel copyWith({
    String? id,
    String? facilityId,
    String? facilityOwnerUid,
    String? tenantId,
    String? title,
    String? description,
    ContractType? type,
    ContractStatus? status,
    String? templateId,
    String? fileUrl,
    String? signedFileUrl,
    DateTime? createdAt,
    DateTime? sentAt,
    DateTime? signedAt,
    DateTime? expiresAt,
    String? createdBy,
    String? sentBy,
    String? signedBy,
    Map<String, dynamic>? customFields,
    String? notes,
    bool? isActive,
    MoveOutStatus? moveOutStatus,
    DateTime? moveOutDate,
    double? moveOutCharges,
    double? moveOutRefund,
    String? moveOutNotes,
    ComplianceStatus? complianceStatus,
    bool? isLicensedForm,
    DateTime? lastReconfirmedAt,
    String? documentSha256,
    int? fileSize,
    String? contentType,
    DateTime? uploadedAt,
    String? storagePath,
    DateTime? disabledAt,
    String? disabledBy,
    String? disabledReason,
  }) {
    return ContractModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      facilityOwnerUid: facilityOwnerUid ?? this.facilityOwnerUid,
      tenantId: tenantId ?? this.tenantId,
      title: title ?? this.title,
      description: description ?? this.description,
      type: type ?? this.type,
      status: status ?? this.status,
      templateId: templateId ?? this.templateId,
      fileUrl: fileUrl ?? this.fileUrl,
      signedFileUrl: signedFileUrl ?? this.signedFileUrl,
      createdAt: createdAt ?? this.createdAt,
      sentAt: sentAt ?? this.sentAt,
      signedAt: signedAt ?? this.signedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      createdBy: createdBy ?? this.createdBy,
      sentBy: sentBy ?? this.sentBy,
      signedBy: signedBy ?? this.signedBy,
      customFields: customFields ?? this.customFields,
      notes: notes ?? this.notes,
      isActive: isActive ?? this.isActive,
      moveOutStatus: moveOutStatus ?? this.moveOutStatus,
      moveOutDate: moveOutDate ?? this.moveOutDate,
      moveOutCharges: moveOutCharges ?? this.moveOutCharges,
      moveOutRefund: moveOutRefund ?? this.moveOutRefund,
      moveOutNotes: moveOutNotes ?? this.moveOutNotes,
      complianceStatus: complianceStatus ?? this.complianceStatus,
      isLicensedForm: isLicensedForm ?? this.isLicensedForm,
      lastReconfirmedAt: lastReconfirmedAt ?? this.lastReconfirmedAt,
      documentSha256: documentSha256 ?? this.documentSha256,
      fileSize: fileSize ?? this.fileSize,
      contentType: contentType ?? this.contentType,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      storagePath: storagePath ?? this.storagePath,
      disabledAt: disabledAt ?? this.disabledAt,
      disabledBy: disabledBy ?? this.disabledBy,
      disabledReason: disabledReason ?? this.disabledReason,
    );
  }
}

// Extension for display names
extension ContractStatusExtension on ContractStatus {
  String get displayName {
    switch (this) {
      case ContractStatus.draft:
        return 'Draft';
      case ContractStatus.sent:
        return 'Sent';
      case ContractStatus.signed:
        return 'Signed';
      case ContractStatus.expired:
        return 'Expired';
      case ContractStatus.cancelled:
        return 'Cancelled';
    }
  }
}

extension ContractTypeExtension on ContractType {
  String get displayName {
    switch (this) {
      case ContractType.lease:
        return 'Lease Agreement';
      case ContractType.rental:
        return 'Rental Agreement';
      case ContractType.storage:
        return 'Storage Agreement';
      case ContractType.custom:
        return 'Custom Contract';
    }
  }
}
