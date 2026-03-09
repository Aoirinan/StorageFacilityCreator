import 'package:cloud_firestore/cloud_firestore.dart';

/// Placeholder for future e-sign provider (contracts not yet implemented)
enum EsignProvider {
  placeholder,
}

extension EsignProviderExtension on EsignProvider {
  String get displayName {
    switch (this) {
      case EsignProvider.placeholder:
        return 'Not configured';
    }
  }
}

class LeaseTemplateModel {
  final String id;
  final String facilityId;
  final String facilityOwnerUid; // Required for security rules
  final String name;
  final String? description;
  final EsignProvider provider; // Which E-sign provider this template uses
  final String? providerTemplateId; // External provider's template ID
  final bool isActive;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final String? notes;

  LeaseTemplateModel({
    required this.id,
    required this.facilityId,
    required this.facilityOwnerUid,
    required this.name,
    this.description,
    required this.provider,
    this.providerTemplateId,
    this.isActive = true,
    required this.createdAt,
    this.updatedAt,
    required this.createdBy,
    this.notes,
  });

  factory LeaseTemplateModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    
    return LeaseTemplateModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      facilityOwnerUid: data['facilityOwnerUid'] ?? '',
      name: data['name'] ?? '',
      description: data['description'],
      provider: EsignProvider.values.firstWhere(
        (e) => e.name == data['provider'],
        orElse: () => EsignProvider.placeholder,
      ),
      providerTemplateId: data['providerTemplateId'],
      isActive: data['isActive'] ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
      createdBy: data['createdBy'] ?? '',
      notes: data['notes'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'facilityOwnerUid': facilityOwnerUid,
      'name': name,
      if (description != null && description!.isNotEmpty) 'description': description,
      'provider': provider.name,
      if (providerTemplateId != null && providerTemplateId!.isNotEmpty) 'providerTemplateId': providerTemplateId,
      'isActive': isActive,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : FieldValue.serverTimestamp(),
      'createdBy': createdBy,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
    };
  }

  LeaseTemplateModel copyWith({
    String? id,
    String? facilityId,
    String? facilityOwnerUid,
    String? name,
    String? description,
    EsignProvider? provider,
    String? providerTemplateId,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    String? notes,
  }) {
    return LeaseTemplateModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      facilityOwnerUid: facilityOwnerUid ?? this.facilityOwnerUid,
      name: name ?? this.name,
      description: description ?? this.description,
      provider: provider ?? this.provider,
      providerTemplateId: providerTemplateId ?? this.providerTemplateId,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      notes: notes ?? this.notes,
    );
  }
}
