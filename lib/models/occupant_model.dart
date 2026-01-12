import 'package:cloud_firestore/cloud_firestore.dart';

/// Represents an authorized occupant/user on a lease
class Occupant {
  final String id;
  final String name;
  final String? email;
  final String? phone;
  final String? relationship; // e.g., "Spouse", "Co-tenant", "Authorized User"
  final bool isPrimary;
  final bool hasAccess; // Can access unit/gate
  final DateTime? dateOfBirth;
  final String? governmentIdType;
  final String? governmentIdNumber;
  final String? governmentIdState;
  final String? notes;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const Occupant({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    this.relationship,
    this.isPrimary = false,
    this.hasAccess = true,
    this.dateOfBirth,
    this.governmentIdType,
    this.governmentIdNumber,
    this.governmentIdState,
    this.notes,
    required this.createdAt,
    this.updatedAt,
  });

  factory Occupant.fromMap(Map<String, dynamic> data) {
    return Occupant(
      id: data['id'] ?? '',
      name: (data['name'] as String? ?? '').trim(),
      email: (data['email'] as String?)?.trim(),
      phone: (data['phone'] as String?)?.trim(),
      relationship: (data['relationship'] as String?)?.trim(),
      isPrimary: data['isPrimary'] ?? false,
      hasAccess: data['hasAccess'] ?? true,
      dateOfBirth: data['dateOfBirth'] != null
          ? (data['dateOfBirth'] as Timestamp).toDate()
          : null,
      governmentIdType: (data['governmentIdType'] as String?)?.trim(),
      governmentIdNumber: (data['governmentIdNumber'] as String?)?.trim(),
      governmentIdState: (data['governmentIdState'] as String?)?.trim(),
      notes: (data['notes'] as String?)?.trim(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: data['updatedAt'] != null
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      if (email != null && email!.isNotEmpty) 'email': email,
      if (phone != null && phone!.isNotEmpty) 'phone': phone,
      if (relationship != null && relationship!.isNotEmpty) 'relationship': relationship,
      'isPrimary': isPrimary,
      'hasAccess': hasAccess,
      if (dateOfBirth != null) 'dateOfBirth': Timestamp.fromDate(dateOfBirth!),
      if (governmentIdType != null && governmentIdType!.isNotEmpty) 'governmentIdType': governmentIdType,
      if (governmentIdNumber != null && governmentIdNumber!.isNotEmpty) 'governmentIdNumber': governmentIdNumber,
      if (governmentIdState != null && governmentIdState!.isNotEmpty) 'governmentIdState': governmentIdState,
      if (notes != null && notes!.isNotEmpty) 'notes': notes,
      'createdAt': Timestamp.fromDate(createdAt),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  Occupant copyWith({
    String? id,
    String? name,
    String? email,
    String? phone,
    String? relationship,
    bool? isPrimary,
    bool? hasAccess,
    DateTime? dateOfBirth,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Occupant(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      relationship: relationship ?? this.relationship,
      isPrimary: isPrimary ?? this.isPrimary,
      hasAccess: hasAccess ?? this.hasAccess,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      governmentIdType: governmentIdType ?? this.governmentIdType,
      governmentIdNumber: governmentIdNumber ?? this.governmentIdNumber,
      governmentIdState: governmentIdState ?? this.governmentIdState,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

