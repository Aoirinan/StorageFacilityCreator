import 'package:cloud_firestore/cloud_firestore.dart';

enum LeadStage {
  inquiry,
  qualified,
  converted,
  lost,
}

enum LeadSource {
  publicRental,
  walkIn,
  phone,
  referral,
  website,
  other,
}

class LeadModel {
  final String id;
  final String facilityId;
  final LeadSource source;
  final LeadStage stage;
  final String name;
  final String email;
  final String? phone;
  final String? desiredUnit;
  final String? notes;
  final String? convertedToTenantId; // Link to tenant if converted
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdBy;

  const LeadModel({
    required this.id,
    required this.facilityId,
    required this.source,
    required this.stage,
    required this.name,
    required this.email,
    this.phone,
    this.desiredUnit,
    this.notes,
    this.convertedToTenantId,
    required this.createdAt,
    required this.updatedAt,
    this.createdBy,
  });

  factory LeadModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return LeadModel(
      id: doc.id,
      facilityId: data['facilityId'] as String,
      source: LeadSource.values.firstWhere(
        (e) => e.name == data['source'],
        orElse: () => LeadSource.other,
      ),
      stage: LeadStage.values.firstWhere(
        (e) => e.name == data['stage'],
        orElse: () => LeadStage.inquiry,
      ),
      name: data['name'] as String,
      email: data['email'] as String,
      phone: data['phone'] as String?,
      desiredUnit: data['desiredUnit'] as String?,
      notes: data['notes'] as String?,
      convertedToTenantId: data['convertedToTenantId'] as String?,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
      createdBy: data['createdBy'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'source': source.name,
      'stage': stage.name,
      'name': name,
      'email': email,
      if (phone != null) 'phone': phone,
      if (desiredUnit != null) 'desiredUnit': desiredUnit,
      if (notes != null) 'notes': notes,
      if (convertedToTenantId != null) 'convertedToTenantId': convertedToTenantId,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      if (createdBy != null) 'createdBy': createdBy,
    };
  }

  LeadModel copyWith({
    String? id,
    String? facilityId,
    LeadSource? source,
    LeadStage? stage,
    String? name,
    String? email,
    String? phone,
    String? desiredUnit,
    String? notes,
    String? convertedToTenantId,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
  }) {
    return LeadModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      source: source ?? this.source,
      stage: stage ?? this.stage,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      desiredUnit: desiredUnit ?? this.desiredUnit,
      notes: notes ?? this.notes,
      convertedToTenantId: convertedToTenantId ?? this.convertedToTenantId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}

extension LeadStageExtension on LeadStage {
  String get displayName {
    switch (this) {
      case LeadStage.inquiry:
        return 'Inquiry';
      case LeadStage.qualified:
        return 'Qualified';
      case LeadStage.converted:
        return 'Converted';
      case LeadStage.lost:
        return 'Lost';
    }
  }
}

extension LeadSourceExtension on LeadSource {
  String get displayName {
    switch (this) {
      case LeadSource.publicRental:
        return 'Public Rental';
      case LeadSource.walkIn:
        return 'Walk-In';
      case LeadSource.phone:
        return 'Phone';
      case LeadSource.referral:
        return 'Referral';
      case LeadSource.website:
        return 'Website';
      case LeadSource.other:
        return 'Other';
    }
  }
}
