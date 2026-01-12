import 'package:cloud_firestore/cloud_firestore.dart';

enum DocumentType {
  contract,
  invoice,
  receipt,
  notice,
  lien,
  other,
}

enum DocumentCategory {
  tenant,
  facility,
  unit,
  contract,
  payment,
  legal,
  other,
}

class DocumentAttachment {
  final String id;
  final String facilityId;
  final String? tenantId; // Optional: link to tenant
  final String? unitId; // Optional: link to unit
  final String? contractId; // Optional: link to contract
  final String? paymentId; // Optional: link to payment
  final String? invoiceId; // Optional: link to invoice
  final String? lienId; // Optional: link to lien
  final String fileName;
  final String fileUrl; // Firebase Storage URL
  final String? filePath; // Firebase Storage path
  final int fileSize; // Size in bytes
  final String mimeType; // e.g., "application/pdf", "image/png"
  final DocumentType documentType;
  final DocumentCategory category;
  final String? description;
  final DateTime uploadedAt;
  final String uploadedBy;
  final String? uploadedByName;
  final DateTime? expiresAt; // For time-sensitive documents
  final bool isActive;
  final Map<String, dynamic>? metadata; // Additional context

  const DocumentAttachment({
    required this.id,
    required this.facilityId,
    this.tenantId,
    this.unitId,
    this.contractId,
    this.paymentId,
    this.invoiceId,
    this.lienId,
    required this.fileName,
    required this.fileUrl,
    this.filePath,
    required this.fileSize,
    required this.mimeType,
    required this.documentType,
    required this.category,
    this.description,
    required this.uploadedAt,
    required this.uploadedBy,
    this.uploadedByName,
    this.expiresAt,
    this.isActive = true,
    this.metadata,
  });

  factory DocumentAttachment.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('DocumentAttachment data is null');
    }

    return DocumentAttachment(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      tenantId: data['tenantId'],
      unitId: data['unitId'],
      contractId: data['contractId'],
      paymentId: data['paymentId'],
      invoiceId: data['invoiceId'],
      lienId: data['lienId'],
      fileName: data['fileName'] ?? '',
      fileUrl: data['fileUrl'] ?? '',
      filePath: data['filePath'],
      fileSize: data['fileSize'] ?? 0,
      mimeType: data['mimeType'] ?? 'application/octet-stream',
      documentType: DocumentType.values.firstWhere(
        (e) => e.name == data['documentType'],
        orElse: () => DocumentType.other,
      ),
      category: DocumentCategory.values.firstWhere(
        (e) => e.name == data['category'],
        orElse: () => DocumentCategory.other,
      ),
      description: data['description'],
      uploadedAt: (data['uploadedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      uploadedBy: data['uploadedBy'] ?? '',
      uploadedByName: data['uploadedByName'],
      expiresAt: data['expiresAt'] != null
          ? (data['expiresAt'] as Timestamp).toDate()
          : null,
      isActive: data['isActive'] ?? true,
      metadata: data['metadata'] != null
          ? Map<String, dynamic>.from(data['metadata'])
          : null,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      if (tenantId != null && tenantId!.isNotEmpty) 'tenantId': tenantId,
      if (unitId != null && unitId!.isNotEmpty) 'unitId': unitId,
      if (contractId != null && contractId!.isNotEmpty) 'contractId': contractId,
      if (paymentId != null && paymentId!.isNotEmpty) 'paymentId': paymentId,
      if (invoiceId != null && invoiceId!.isNotEmpty) 'invoiceId': invoiceId,
      if (lienId != null && lienId!.isNotEmpty) 'lienId': lienId,
      'fileName': fileName,
      'fileUrl': fileUrl,
      if (filePath != null && filePath!.isNotEmpty) 'filePath': filePath,
      'fileSize': fileSize,
      'mimeType': mimeType,
      'documentType': documentType.name,
      'category': category.name,
      if (description != null && description!.isNotEmpty) 'description': description,
      'uploadedAt': Timestamp.fromDate(uploadedAt),
      'uploadedBy': uploadedBy,
      if (uploadedByName != null && uploadedByName!.isNotEmpty) 'uploadedByName': uploadedByName,
      if (expiresAt != null) 'expiresAt': Timestamp.fromDate(expiresAt!),
      'isActive': isActive,
      if (metadata != null) 'metadata': metadata,
    };
  }

  DocumentAttachment copyWith({
    String? id,
    String? facilityId,
    String? tenantId,
    String? unitId,
    String? contractId,
    String? paymentId,
    String? invoiceId,
    String? lienId,
    String? fileName,
    String? fileUrl,
    String? filePath,
    int? fileSize,
    String? mimeType,
    DocumentType? documentType,
    DocumentCategory? category,
    String? description,
    DateTime? uploadedAt,
    String? uploadedBy,
    String? uploadedByName,
    DateTime? expiresAt,
    bool? isActive,
    Map<String, dynamic>? metadata,
  }) {
    return DocumentAttachment(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      unitId: unitId ?? this.unitId,
      contractId: contractId ?? this.contractId,
      paymentId: paymentId ?? this.paymentId,
      invoiceId: invoiceId ?? this.invoiceId,
      lienId: lienId ?? this.lienId,
      fileName: fileName ?? this.fileName,
      fileUrl: fileUrl ?? this.fileUrl,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      documentType: documentType ?? this.documentType,
      category: category ?? this.category,
      description: description ?? this.description,
      uploadedAt: uploadedAt ?? this.uploadedAt,
      uploadedBy: uploadedBy ?? this.uploadedBy,
      uploadedByName: uploadedByName ?? this.uploadedByName,
      expiresAt: expiresAt ?? this.expiresAt,
      isActive: isActive ?? this.isActive,
      metadata: metadata ?? this.metadata,
    );
  }

  String get documentTypeDisplayName {
    switch (documentType) {
      case DocumentType.contract:
        return 'Contract';
      case DocumentType.invoice:
        return 'Invoice';
      case DocumentType.receipt:
        return 'Receipt';
      case DocumentType.notice:
        return 'Notice';
      case DocumentType.lien:
        return 'Lien';
      case DocumentType.other:
        return 'Other';
    }
  }

  String get categoryDisplayName {
    switch (category) {
      case DocumentCategory.tenant:
        return 'Tenant';
      case DocumentCategory.facility:
        return 'Facility';
      case DocumentCategory.unit:
        return 'Unit';
      case DocumentCategory.contract:
        return 'Contract';
      case DocumentCategory.payment:
        return 'Payment';
      case DocumentCategory.legal:
        return 'Legal';
      case DocumentCategory.other:
        return 'Other';
    }
  }

  String get formattedFileSize {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);
  bool get isPdf => mimeType == 'application/pdf';
  bool get isImage => mimeType.startsWith('image/');
}

