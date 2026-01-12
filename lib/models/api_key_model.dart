import 'package:cloud_firestore/cloud_firestore.dart';

/// API key for third-party integrations
class ApiKey {
  final String id;
  final String facilityId;
  final String name; // User-friendly name for the key
  final String keyHash; // Hashed version of the key (never store plain text)
  final String? description;
  final List<String> permissions; // What this key can access
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;
  final bool isActive;
  final int? rateLimit; // Requests per minute (null = unlimited)
  final Map<String, dynamic>? metadata;

  const ApiKey({
    required this.id,
    required this.facilityId,
    required this.name,
    required this.keyHash,
    this.description,
    this.permissions = const [],
    required this.createdAt,
    this.lastUsedAt,
    this.expiresAt,
    this.isActive = true,
    this.rateLimit,
    this.metadata,
  });

  Map<String, dynamic> toMap() {
    return {
      'facilityId': facilityId,
      'name': name,
      'keyHash': keyHash,
      'description': description,
      'permissions': permissions,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastUsedAt': lastUsedAt != null ? Timestamp.fromDate(lastUsedAt!) : null,
      'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt!) : null,
      'isActive': isActive,
      'rateLimit': rateLimit,
      'metadata': metadata,
    };
  }

  factory ApiKey.fromMap(String id, Map<String, dynamic> map) {
    return ApiKey(
      id: id,
      facilityId: map['facilityId'] as String,
      name: map['name'] as String,
      keyHash: map['keyHash'] as String,
      description: map['description'] as String?,
      permissions: List<String>.from(map['permissions'] ?? []),
      createdAt: (map['createdAt'] as Timestamp).toDate(),
      lastUsedAt: (map['lastUsedAt'] as Timestamp?)?.toDate(),
      expiresAt: (map['expiresAt'] as Timestamp?)?.toDate(),
      isActive: map['isActive'] as bool? ?? true,
      rateLimit: map['rateLimit'] as int?,
      metadata: map['metadata'] as Map<String, dynamic>?,
    );
  }

  bool get isValid {
    if (!isActive) return false;
    if (expiresAt != null && DateTime.now().isAfter(expiresAt!)) return false;
    return true;
  }

  bool hasPermission(String permission) {
    return permissions.contains(permission) || permissions.contains('*'); // '*' = all permissions
  }
}

/// API permission scopes
enum ApiPermission {
  readTenants,
  writeTenants,
  readUnits,
  writeUnits,
  readPayments,
  writePayments,
  readContracts,
  writeContracts,
  readReports,
  sendMessages,
  all, // Full access
}

extension ApiPermissionExtension on ApiPermission {
  String get name {
    switch (this) {
      case ApiPermission.readTenants:
        return 'read:tenants';
      case ApiPermission.writeTenants:
        return 'write:tenants';
      case ApiPermission.readUnits:
        return 'read:units';
      case ApiPermission.writeUnits:
        return 'write:units';
      case ApiPermission.readPayments:
        return 'read:payments';
      case ApiPermission.writePayments:
        return 'write:payments';
      case ApiPermission.readContracts:
        return 'read:contracts';
      case ApiPermission.writeContracts:
        return 'write:contracts';
      case ApiPermission.readReports:
        return 'read:reports';
      case ApiPermission.sendMessages:
        return 'send:messages';
      case ApiPermission.all:
        return '*';
    }
  }
}

