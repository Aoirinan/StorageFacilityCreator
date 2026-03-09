import 'package:cloud_firestore/cloud_firestore.dart';

import 'contract_model.dart';

/// Compliance status for contracts/templates
enum ComplianceStatus {
  active,
  disabled,
}

enum SignatureFieldType {
  signature,
  initials,
  date,
  text,
  storageUnit,
  name,
}

extension SignatureFieldTypeExtension on SignatureFieldType {
  String get displayName {
    switch (this) {
      case SignatureFieldType.signature:
        return 'Signature';
      case SignatureFieldType.initials:
        return 'Initials';
      case SignatureFieldType.date:
        return 'Date';
      case SignatureFieldType.text:
        return 'Text';
      case SignatureFieldType.storageUnit:
        return 'Storage Unit Number';
      case SignatureFieldType.name:
        return 'Name';
    }
  }

  /// Default prompt shown to signer (e.g. "Sign your name")
  String get defaultPrompt {
    switch (this) {
      case SignatureFieldType.signature:
        return 'Sign your name';
      case SignatureFieldType.initials:
        return 'Enter your initials';
      case SignatureFieldType.date:
        return 'Sign the date';
      case SignatureFieldType.text:
        return 'Enter text';
      case SignatureFieldType.storageUnit:
        return 'Sign your contract storage unit number';
      case SignatureFieldType.name:
        return 'Enter your full name';
    }
  }
}

class TemplateSigner {
  final String id;
  final String label;
  final String role; // e.g. owner, tenant, witness
  final bool requiresEmail;
  final bool requiresPhone;
  final bool isFacilitySigner;
  final bool isTenantSigner;
  final Map<String, dynamic>? metadata;

  const TemplateSigner({
    required this.id,
    required this.label,
    required this.role,
    this.requiresEmail = true,
    this.requiresPhone = false,
    this.isFacilitySigner = false,
    this.isTenantSigner = false,
    this.metadata,
  });

  factory TemplateSigner.fromMap(Map<String, dynamic> map) {
    return TemplateSigner(
      id: map['id'] ?? '',
      label: map['label'] ?? '',
      role: map['role'] ?? 'signer',
      requiresEmail: map['requiresEmail'] ?? true,
      requiresPhone: map['requiresPhone'] ?? false,
      isFacilitySigner: map['isFacilitySigner'] ?? false,
      isTenantSigner: map['isTenantSigner'] ?? false,
      metadata: map['metadata'] != null ? Map<String, dynamic>.from(map['metadata']) : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'role': role,
      'requiresEmail': requiresEmail,
      'requiresPhone': requiresPhone,
      'isFacilitySigner': isFacilitySigner,
      'isTenantSigner': isTenantSigner,
      if (metadata != null) 'metadata': metadata,
    };
  }
}

class SignaturePlaceholder {
  final String id;
  final String signerId;
  final SignatureFieldType fieldType;
  final int page;
  final double x; // 0-1 relative horizontal position
  final double y; // 0-1 relative vertical position
  final double width; // 0-1 relative width
  final double height; // 0-1 relative height
  final bool required;
  final String? label;
  final String? tooltip;

  const SignaturePlaceholder({
    required this.id,
    required this.signerId,
    required this.fieldType,
    required this.page,
    required this.x,
    required this.y,
    this.width = 0.18,
    this.height = 0.05,
    this.required = true,
    this.label,
    this.tooltip,
  });

  factory SignaturePlaceholder.fromMap(Map<String, dynamic> map) {
    return SignaturePlaceholder(
      id: map['id'] ?? '',
      signerId: map['signerId'] ?? '',
      fieldType: SignatureFieldType.values.firstWhere(
        (e) => e.name == map['fieldType'],
        orElse: () => SignatureFieldType.signature,
      ),
      page: map['page'] ?? 1,
      x: (map['x'] ?? 0.1).toDouble(),
      y: (map['y'] ?? 0.1).toDouble(),
      width: (map['width'] ?? 0.18).toDouble(),
      height: (map['height'] ?? 0.05).toDouble(),
      required: map['required'] ?? true,
      label: map['label'],
      tooltip: map['tooltip'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'signerId': signerId,
      'fieldType': fieldType.name,
      'page': page,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'required': required,
      if (label != null) 'label': label,
      if (tooltip != null) 'tooltip': tooltip,
    };
  }
}

class ContractTemplateModel {
  final String id;
  final String name;
  final String description;
  final String content; // HTML or Markdown content
  final ContractType type;
  final String? fileUrl; // PDF template file
  final List<String> requiredFields;
  final Map<String, dynamic> defaultValues;
  final List<TemplateSigner> signers;
  final List<SignaturePlaceholder> signaturePlaceholders;
  final bool isActive;
  final String createdBy;
  final String facilityId; // Facility this template belongs to
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? updatedBy;
  // Compliance fields
  final ComplianceStatus complianceStatus;
  final bool isLicensedForm; // Association/licensed form flag
  final DateTime? lastReconfirmedAt; // Last rights reconfirmation
  final String? documentSha256; // SHA-256 hash of uploaded PDF
  final int? fileSize; // File size in bytes
  final String? contentType; // MIME type (e.g., 'application/pdf')
  final DateTime? uploadedAt; // When file was uploaded
  final String? storagePath; // Storage path in Firebase Storage
  final DateTime? disabledAt; // When template was disabled
  final String? disabledBy; // User ID who disabled it
  final String? disabledReason; // Reason for disabling

  ContractTemplateModel({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
    required this.type,
    this.fileUrl,
    required this.requiredFields,
    required this.defaultValues,
    this.signers = const [],
    this.signaturePlaceholders = const [],
    this.isActive = true,
    required this.createdBy,
    required this.facilityId,
    required this.createdAt,
    this.updatedAt,
    this.updatedBy,
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
  
  factory ContractTemplateModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ContractTemplateModel(
      id: doc.id,
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      content: data['content'] ?? '',
      type: ContractType.values.firstWhere(
        (e) => e.name == data['type'],
        orElse: () => ContractType.custom,
      ),
      fileUrl: data['fileUrl'],
      requiredFields: List<String>.from(data['requiredFields'] ?? []),
      defaultValues: Map<String, dynamic>.from(data['defaultValues'] ?? {}),
      signers: (data['signers'] as List<dynamic>? ?? [])
          .map((item) => TemplateSigner.fromMap(Map<String, dynamic>.from(item)))
          .toList(),
      signaturePlaceholders: (data['signaturePlaceholders'] as List<dynamic>? ?? [])
          .map((item) => SignaturePlaceholder.fromMap(Map<String, dynamic>.from(item)))
          .toList(),
      isActive: data['isActive'] ?? true,
      createdBy: data['createdBy'] ?? '',
      facilityId: data['facilityId'] ?? '', // Required for facility-scoped templates
      createdAt: data['createdAt'] != null ? (data['createdAt'] as Timestamp).toDate() : DateTime.now(),
      updatedAt: data['updatedAt'] != null ? (data['updatedAt'] as Timestamp).toDate() : null,
      updatedBy: data['updatedBy'],
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
      'name': name,
      'description': description,
      'content': content,
      'type': type.name,
      'fileUrl': fileUrl,
      'requiredFields': requiredFields,
      'defaultValues': defaultValues,
      'signers': signers.map((signer) => signer.toMap()).toList(),
      'signaturePlaceholders': signaturePlaceholders.map((field) => field.toMap()).toList(),
      'isActive': isActive,
      'createdBy': createdBy,
      'facilityId': facilityId, // Required for facility-scoped templates
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'updatedBy': updatedBy,
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

  ContractTemplateModel copyWith({
    String? id,
    String? name,
    String? description,
    String? content,
    ContractType? type,
    String? fileUrl,
    List<String>? requiredFields,
    Map<String, dynamic>? defaultValues,
    List<TemplateSigner>? signers,
    List<SignaturePlaceholder>? signaturePlaceholders,
    bool? isActive,
    String? createdBy,
    String? facilityId,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? updatedBy,
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
    return ContractTemplateModel(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      content: content ?? this.content,
      type: type ?? this.type,
      fileUrl: fileUrl ?? this.fileUrl,
      requiredFields: requiredFields ?? this.requiredFields,
      defaultValues: defaultValues ?? this.defaultValues,
      signers: signers ?? this.signers,
      signaturePlaceholders: signaturePlaceholders ?? this.signaturePlaceholders,
      isActive: isActive ?? this.isActive,
      createdBy: createdBy ?? this.createdBy,
      facilityId: facilityId ?? this.facilityId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
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
