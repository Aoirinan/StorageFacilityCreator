import 'package:cloud_firestore/cloud_firestore.dart';

class DNRModel {
  final String id;
  final String name;
  final String nameLower;
  final String email;
  final String emailLower;
  final String phone;
  final String phoneDigits;
  final String reason;
  final bool active;
  final DateTime? expiresAt;
  final List<String>? evidenceUrls;
  final DateTime addedAt;
  final String addedByUid;
  final String? addedByEmail; // New attribution field
  final String? addedByName; // New attribution field
  final String facilityId; // Required for subcollection
  final String? facilityName; // New required field
  final String? ownerEmail; // New required field
  final String? facilityPhone; // New required field
  final DateTime? updatedAt;
  final String? updatedByUid;
  final String? linkedTenantId;
  final String? linkedTenantName;

  const DNRModel({
    required this.id,
    required this.name,
    required this.nameLower,
    required this.email,
    required this.emailLower,
    required this.phone,
    required this.phoneDigits,
    required this.reason,
    required this.active,
    this.expiresAt,
    this.evidenceUrls,
    required this.addedAt,
    required this.addedByUid,
    this.addedByEmail,
    this.addedByName,
    required this.facilityId,
    this.facilityName,
    this.ownerEmail,
    this.facilityPhone,
    this.updatedAt,
    this.updatedByUid,
    this.linkedTenantId,
    this.linkedTenantName,
  });

  factory DNRModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return DNRModel(
      id: doc.id,
      name: data['name'] ?? '',
      nameLower: data['nameLower'] ?? '',
      email: data['email'] ?? '',
      emailLower: data['emailLower'] ?? '',
      phone: data['phone'] ?? '',
      phoneDigits: data['phoneDigits'] ?? '',
      reason: data['reason'] ?? '',
      active: data['active'] ?? true,
      expiresAt: data['expiresAt'] != null 
          ? (data['expiresAt'] as Timestamp).toDate()
          : null,
      evidenceUrls: data['evidenceUrls'] != null 
          ? List<String>.from(data['evidenceUrls'])
          : null,
      addedAt: (data['addedAt'] as Timestamp).toDate(),
      addedByUid: data['addedByUid'] ?? '',
      addedByEmail: data['addedByEmail'],
      addedByName: data['addedByName'],
      facilityId: data['facilityId'] ?? '',
      facilityName: data['facilityName'],
      ownerEmail: data['ownerEmail'],
      facilityPhone: data['facilityPhone'],
      updatedAt: data['updatedAt'] != null 
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
      updatedByUid: data['updatedByUid'],
      linkedTenantId: data['linkedTenantId'],
      linkedTenantName: data['linkedTenantName'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'nameLower': nameLower,
      'email': email,
      'emailLower': emailLower,
      'phone': phone,
      'phoneDigits': phoneDigits,
      'reason': reason,
      'active': active,
      'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt!) : null,
      'evidenceUrls': evidenceUrls,
      'addedAt': Timestamp.fromDate(addedAt),
      'addedByUid': addedByUid,
      'addedByEmail': addedByEmail,
      'addedByName': addedByName,
      'facilityId': facilityId,
      'facilityName': facilityName,
      'ownerEmail': ownerEmail,
      'facilityPhone': facilityPhone,
      'updatedAt': updatedAt != null ? Timestamp.fromDate(updatedAt!) : null,
      'updatedByUid': updatedByUid,
      'linkedTenantId': linkedTenantId,
      'linkedTenantName': linkedTenantName,
    };
  }

  DNRModel copyWith({
    String? id,
    String? name,
    String? nameLower,
    String? email,
    String? emailLower,
    String? phone,
    String? phoneDigits,
    String? reason,
    bool? active,
    DateTime? expiresAt,
    List<String>? evidenceUrls,
    DateTime? addedAt,
    String? addedByUid,
    String? addedByEmail,
    String? addedByName,
    String? facilityId,
    String? facilityName,
    String? ownerEmail,
    String? facilityPhone,
    DateTime? updatedAt,
    String? updatedByUid,
    String? linkedTenantId,
    String? linkedTenantName,
  }) {
    return DNRModel(
      id: id ?? this.id,
      name: name ?? this.name,
      nameLower: nameLower ?? this.nameLower,
      email: email ?? this.email,
      emailLower: emailLower ?? this.emailLower,
      phone: phone ?? this.phone,
      phoneDigits: phoneDigits ?? this.phoneDigits,
      reason: reason ?? this.reason,
      active: active ?? this.active,
      expiresAt: expiresAt ?? this.expiresAt,
      evidenceUrls: evidenceUrls ?? this.evidenceUrls,
      addedAt: addedAt ?? this.addedAt,
      addedByUid: addedByUid ?? this.addedByUid,
      addedByEmail: addedByEmail ?? this.addedByEmail,
      addedByName: addedByName ?? this.addedByName,
      facilityId: facilityId ?? this.facilityId,
      facilityName: facilityName ?? this.facilityName,
      ownerEmail: ownerEmail ?? this.ownerEmail,
      facilityPhone: facilityPhone ?? this.facilityPhone,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedByUid: updatedByUid ?? this.updatedByUid,
      linkedTenantId: linkedTenantId ?? this.linkedTenantId,
      linkedTenantName: linkedTenantName ?? this.linkedTenantName,
    );
  }

  // Helper getters
  String get displayName => name;
  String get displayEmail => email;
  String get displayPhone => phone;
  
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }
  
  bool get isActive => active && !isExpired;
}