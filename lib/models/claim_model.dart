import 'package:cloud_firestore/cloud_firestore.dart';

enum ClaimStatus {
  pending,
  inReview,
  approved,
  denied,
  closed,
}

enum ClaimType {
  theft,
  damage,
  water,
  fire,
  vandalism,
  other,
}

class ClaimModel {
  final String id;
  final String facilityId;
  final String tenantId;
  final String? leaseId; // Optional reference to lease/contract
  final DateTime incidentDate;
  final ClaimType claimType;
  final ClaimStatus status;
  final double claimAmount;
  final double deductibleAmount;
  final String description;
  final String? managerStatement;
  final String? tenantStatement;
  final List<String> documentUrls; // URLs to photos, police reports, etc.
  final String? adjusterEmail;
  final String? adjusterNotes;
  final DateTime filedDate;
  final DateTime? resolvedDate;
  final String createdBy; // User UID who filed the claim
  final DateTime createdAt;
  final DateTime? updatedAt;

  const ClaimModel({
    required this.id,
    required this.facilityId,
    required this.tenantId,
    this.leaseId,
    required this.incidentDate,
    required this.claimType,
    required this.status,
    required this.claimAmount,
    required this.deductibleAmount,
    required this.description,
    this.managerStatement,
    this.tenantStatement,
    this.documentUrls = const [],
    this.adjusterEmail,
    this.adjusterNotes,
    required this.filedDate,
    this.resolvedDate,
    required this.createdBy,
    required this.createdAt,
    this.updatedAt,
  });

  factory ClaimModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('ClaimModel data is null');
    }

    return ClaimModel(
      id: doc.id,
      facilityId: data['facilityId'] as String,
      tenantId: data['tenantId'] as String,
      leaseId: data['leaseId'] as String?,
      incidentDate: (data['incidentDate'] as Timestamp).toDate(),
      claimType: _parseClaimType(data['claimType']),
      status: _parseClaimStatus(data['status']),
      claimAmount: (data['claimAmount'] as num).toDouble(),
      deductibleAmount: (data['deductibleAmount'] as num).toDouble(),
      description: data['description'] as String,
      managerStatement: data['managerStatement'] as String?,
      tenantStatement: data['tenantStatement'] as String?,
      documentUrls: (data['documentUrls'] as List<dynamic>? ?? [])
          .map((url) => url.toString())
          .toList(),
      adjusterEmail: data['adjusterEmail'] as String?,
      adjusterNotes: data['adjusterNotes'] as String?,
      filedDate: (data['filedDate'] as Timestamp).toDate(),
      resolvedDate: (data['resolvedDate'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'tenantId': tenantId,
      if (leaseId != null && leaseId!.isNotEmpty) 'leaseId': leaseId,
      'incidentDate': Timestamp.fromDate(incidentDate),
      'claimType': claimType.name,
      'status': status.name,
      'claimAmount': claimAmount,
      'deductibleAmount': deductibleAmount,
      'description': description,
      if (managerStatement != null && managerStatement!.isNotEmpty) 'managerStatement': managerStatement,
      if (tenantStatement != null && tenantStatement!.isNotEmpty) 'tenantStatement': tenantStatement,
      'documentUrls': documentUrls,
      if (adjusterEmail != null && adjusterEmail!.isNotEmpty) 'adjusterEmail': adjusterEmail,
      if (adjusterNotes != null && adjusterNotes!.isNotEmpty) 'adjusterNotes': adjusterNotes,
      'filedDate': Timestamp.fromDate(filedDate),
      if (resolvedDate != null) 'resolvedDate': Timestamp.fromDate(resolvedDate!),
      'createdBy': createdBy,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : FieldValue.serverTimestamp(),
    };
  }

  ClaimModel copyWith({
    String? id,
    String? facilityId,
    String? tenantId,
    String? leaseId,
    DateTime? incidentDate,
    ClaimType? claimType,
    ClaimStatus? status,
    double? claimAmount,
    double? deductibleAmount,
    String? description,
    String? managerStatement,
    String? tenantStatement,
    List<String>? documentUrls,
    String? adjusterEmail,
    String? adjusterNotes,
    DateTime? filedDate,
    DateTime? resolvedDate,
    String? createdBy,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ClaimModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      leaseId: leaseId ?? this.leaseId,
      incidentDate: incidentDate ?? this.incidentDate,
      claimType: claimType ?? this.claimType,
      status: status ?? this.status,
      claimAmount: claimAmount ?? this.claimAmount,
      deductibleAmount: deductibleAmount ?? this.deductibleAmount,
      description: description ?? this.description,
      managerStatement: managerStatement ?? this.managerStatement,
      tenantStatement: tenantStatement ?? this.tenantStatement,
      documentUrls: documentUrls ?? this.documentUrls,
      adjusterEmail: adjusterEmail ?? this.adjusterEmail,
      adjusterNotes: adjusterNotes ?? this.adjusterNotes,
      filedDate: filedDate ?? this.filedDate,
      resolvedDate: resolvedDate ?? this.resolvedDate,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static ClaimType _parseClaimType(dynamic value) {
    if (value is String) {
      return ClaimType.values.firstWhere(
        (e) => e.name == value,
        orElse: () => ClaimType.other,
      );
    }
    return ClaimType.other;
  }

  static ClaimStatus _parseClaimStatus(dynamic value) {
    if (value is String) {
      return ClaimStatus.values.firstWhere(
        (e) => e.name == value,
        orElse: () => ClaimStatus.pending,
      );
    }
    return ClaimStatus.pending;
  }
}

// Extension for display names
extension ClaimStatusExtension on ClaimStatus {
  String get displayName {
    switch (this) {
      case ClaimStatus.pending:
        return 'Pending';
      case ClaimStatus.inReview:
        return 'In Review';
      case ClaimStatus.approved:
        return 'Approved';
      case ClaimStatus.denied:
        return 'Denied';
      case ClaimStatus.closed:
        return 'Closed';
    }
  }
}

extension ClaimTypeExtension on ClaimType {
  String get displayName {
    switch (this) {
      case ClaimType.theft:
        return 'Theft';
      case ClaimType.damage:
        return 'Damage';
      case ClaimType.water:
        return 'Water Damage';
      case ClaimType.fire:
        return 'Fire';
      case ClaimType.vandalism:
        return 'Vandalism';
      case ClaimType.other:
        return 'Other';
    }
  }
}

