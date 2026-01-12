import 'package:cloud_firestore/cloud_firestore.dart';

class GateAccessModel {
  final String id;
  final String facilityId;
  final String? tenantId;
  final String? tenantName;
  final String accessCode;
  final bool isActive;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final List<String> allowedDays; // e.g. Mon, Tue
  final String? allowedStartTime; // HH:mm
  final String? allowedEndTime; // HH:mm
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;
  final String? updatedBy;

  const GateAccessModel({
    required this.id,
    required this.facilityId,
    this.tenantId,
    this.tenantName,
    required this.accessCode,
    required this.isActive,
    this.validFrom,
    this.validUntil,
    this.allowedDays = const [],
    this.allowedStartTime,
    this.allowedEndTime,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
    this.updatedBy,
  });

  factory GateAccessModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return GateAccessModel(
      id: doc.id,
      facilityId: data['facilityId'] ?? '',
      tenantId: data['tenantId'],
      tenantName: data['tenantName'],
      accessCode: data['accessCode'] ?? '',
      isActive: data['isActive'] ?? true,
      validFrom: (data['validFrom'] as Timestamp?)?.toDate(),
      validUntil: (data['validUntil'] as Timestamp?)?.toDate(),
      allowedDays: List<String>.from(data['allowedDays'] ?? const []),
      allowedStartTime: data['allowedStartTime'],
      allowedEndTime: data['allowedEndTime'],
      notes: data['notes'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdBy: data['createdBy'] ?? '',
      updatedBy: data['updatedBy'],
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'facilityId': facilityId,
      'tenantId': tenantId,
      'tenantName': tenantName,
      'accessCode': accessCode,
      'isActive': isActive,
      'validFrom': validFrom != null ? Timestamp.fromDate(validFrom!) : null,
      'validUntil': validUntil != null ? Timestamp.fromDate(validUntil!) : null,
      'allowedDays': allowedDays,
      'allowedStartTime': allowedStartTime,
      'allowedEndTime': allowedEndTime,
      'notes': notes,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'createdBy': createdBy,
      'updatedBy': updatedBy,
    };
  }

  GateAccessModel copyWith({
    String? id,
    String? facilityId,
    String? tenantId,
    String? tenantName,
    String? accessCode,
    bool? isActive,
    DateTime? validFrom,
    DateTime? validUntil,
    List<String>? allowedDays,
    String? allowedStartTime,
    String? allowedEndTime,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    String? updatedBy,
  }) {
    return GateAccessModel(
      id: id ?? this.id,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      tenantName: tenantName ?? this.tenantName,
      accessCode: accessCode ?? this.accessCode,
      isActive: isActive ?? this.isActive,
      validFrom: validFrom ?? this.validFrom,
      validUntil: validUntil ?? this.validUntil,
      allowedDays: allowedDays ?? this.allowedDays,
      allowedStartTime: allowedStartTime ?? this.allowedStartTime,
      allowedEndTime: allowedEndTime ?? this.allowedEndTime,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }

  String get scheduleSummary {
    final days = allowedDays.isNotEmpty ? allowedDays.join(', ') : 'All days';
    final window = (allowedStartTime != null && allowedEndTime != null)
        ? '$allowedStartTime – $allowedEndTime'
        : '24 hours';
    return '$days • $window';
  }
}

