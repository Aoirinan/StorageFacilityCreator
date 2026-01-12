import 'package:cloud_firestore/cloud_firestore.dart';

enum ContractStatus {
  draft,
  sent,
  signed,
  expired,
  cancelled,
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
  });

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
