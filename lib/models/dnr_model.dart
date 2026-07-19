import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/global_dnr_model.dart';

class DNRModel {
  /// Synthetic [facilityId] for rows sourced from Firestore `global_dnr_entries`.
  static const String platformWideDnrFacilityId = 'platform_dnr';

  final String id;
  final String name;
  final String nameLower;
  final String email;
  final String emailLower;
  final String phone;
  final String phoneDigits;
  final String reason;
  final String? notes;
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
    this.notes,
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

  /// Map a platform-wide global DNR row into the shared [DNRModel] shape for screening UI.
  factory DNRModel.fromGlobalDnrEntry(GlobalDNREntryModel e) {
    final fn = e.fullName.trim();
    final em = e.email.trim();
    final phoneDigits = e.phone.replaceAll(RegExp(r'[^\d]'), '');
    final reporting = e.createdByFacilityName?.trim();
    return DNRModel(
      id: e.id,
      name: fn,
      nameLower: fn.toLowerCase(),
      email: em,
      emailLower: em.toLowerCase(),
      phone: e.phone,
      phoneDigits: phoneDigits,
      reason: e.reason,
      notes: e.notes,
      active: e.isActive,
      expiresAt: null,
      evidenceUrls: null,
      addedAt: e.createdAt,
      addedByUid: e.createdByUserId,
      addedByEmail: null,
      addedByName: null,
      facilityId: platformWideDnrFacilityId,
      facilityName: reporting != null && reporting.isNotEmpty
          ? 'SFC platform-wide · reported by $reporting'
          : 'SFC platform-wide',
      ownerEmail: null,
      facilityPhone: null,
      updatedAt: e.updatedAt,
      updatedByUid: null,
      linkedTenantId: null,
      linkedTenantName: null,
    );
  }

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
      notes: data['notes'],
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
      'notes': notes,
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
    String? notes,
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
      notes: notes ?? this.notes,
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

  bool get isPlatformWideDnr => facilityId == platformWideDnrFacilityId;
}