import 'package:flutter/material.dart';

enum SecurityEventType {
  // Authentication Events
  login,
  logout,
  loginFailed,
  passwordChanged,
  emailChanged,
  
  // Data Access Events
  dataViewed,
  dataCreated,
  dataUpdated,
  dataDeleted,
  dataExported,
  dataImported,
  
  // Permission Events
  roleAssigned,
  roleRemoved,
  permissionGranted,
  permissionDenied,
  
  // System Events
  systemError,
  securityAlert,
  suspiciousActivity,
  dataBreach,
  
  // Facility Events
  facilityCreated,
  facilityDeleted,
  facilityAccessGranted,
  facilityAccessRevoked,
  
  // Tenant Events
  tenantCreated,
  tenantDeleted,
  tenantDataAccessed,
  tenantDataModified,
  
  // Payment Events
  paymentProcessed,
  paymentFailed,
  refundProcessed,
  paymentDataAccessed,
  
  // DNR Events
  dnrEntryCreated,
  dnrEntryDeleted,
  dnrScreeningPerformed,
  
  // Contract Events
  contractCreated,
  contractSigned,
  contractDeleted,
  contractViewed,
}

enum SecurityLevel {
  low,
  medium,
  high,
  critical,
}

enum SecurityAction {
  allow,
  block,
  requireApproval,
  logOnly,
}

class SecurityEvent {
  final String id;
  final SecurityEventType type;
  final SecurityLevel level;
  final String userId;
  final String? facilityId;
  final String? tenantId;
  final String? contractId;
  final String? paymentId;
  final String description;
  final Map<String, dynamic>? metadata;
  final String? ipAddress;
  final String? userAgent;
  final String? location;
  final DateTime timestamp;
  final bool isResolved;
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final String? resolution;

  const SecurityEvent({
    required this.id,
    required this.type,
    required this.level,
    required this.userId,
    this.facilityId,
    this.tenantId,
    this.contractId,
    this.paymentId,
    required this.description,
    this.metadata,
    this.ipAddress,
    this.userAgent,
    this.location,
    required this.timestamp,
    this.isResolved = false,
    this.resolvedBy,
    this.resolvedAt,
    this.resolution,
  });

  SecurityEvent copyWith({
    String? id,
    SecurityEventType? type,
    SecurityLevel? level,
    String? userId,
    String? facilityId,
    String? tenantId,
    String? contractId,
    String? paymentId,
    String? description,
    Map<String, dynamic>? metadata,
    String? ipAddress,
    String? userAgent,
    String? location,
    DateTime? timestamp,
    bool? isResolved,
    String? resolvedBy,
    DateTime? resolvedAt,
    String? resolution,
  }) {
    return SecurityEvent(
      id: id ?? this.id,
      type: type ?? this.type,
      level: level ?? this.level,
      userId: userId ?? this.userId,
      facilityId: facilityId ?? this.facilityId,
      tenantId: tenantId ?? this.tenantId,
      contractId: contractId ?? this.contractId,
      paymentId: paymentId ?? this.paymentId,
      description: description ?? this.description,
      metadata: metadata ?? this.metadata,
      ipAddress: ipAddress ?? this.ipAddress,
      userAgent: userAgent ?? this.userAgent,
      location: location ?? this.location,
      timestamp: timestamp ?? this.timestamp,
      isResolved: isResolved ?? this.isResolved,
      resolvedBy: resolvedBy ?? this.resolvedBy,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      resolution: resolution ?? this.resolution,
    );
  }
}

class SecurityRule {
  final String id;
  final String name;
  final String description;
  final SecurityEventType eventType;
  final SecurityLevel minimumLevel;
  final SecurityAction action;
  final Map<String, dynamic> conditions;
  final bool isEnabled;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdBy;

  const SecurityRule({
    required this.id,
    required this.name,
    required this.description,
    required this.eventType,
    required this.minimumLevel,
    required this.action,
    required this.conditions,
    this.isEnabled = true,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
  });

  SecurityRule copyWith({
    String? id,
    String? name,
    String? description,
    SecurityEventType? eventType,
    SecurityLevel? minimumLevel,
    SecurityAction? action,
    Map<String, dynamic>? conditions,
    bool? isEnabled,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
  }) {
    return SecurityRule(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      eventType: eventType ?? this.eventType,
      minimumLevel: minimumLevel ?? this.minimumLevel,
      action: action ?? this.action,
      conditions: conditions ?? this.conditions,
      isEnabled: isEnabled ?? this.isEnabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}

class SecurityAlert {
  final String id;
  final String title;
  final String description;
  final SecurityLevel level;
  final SecurityEventType eventType;
  final String userId;
  final String? facilityId;
  final Map<String, dynamic>? metadata;
  final DateTime timestamp;
  final bool isAcknowledged;
  final String? acknowledgedBy;
  final DateTime? acknowledgedAt;
  final String? acknowledgmentNote;

  const SecurityAlert({
    required this.id,
    required this.title,
    required this.description,
    required this.level,
    required this.eventType,
    required this.userId,
    this.facilityId,
    this.metadata,
    required this.timestamp,
    this.isAcknowledged = false,
    this.acknowledgedBy,
    this.acknowledgedAt,
    this.acknowledgmentNote,
  });

  SecurityAlert copyWith({
    String? id,
    String? title,
    String? description,
    SecurityLevel? level,
    SecurityEventType? eventType,
    String? userId,
    String? facilityId,
    Map<String, dynamic>? metadata,
    DateTime? timestamp,
    bool? isAcknowledged,
    String? acknowledgedBy,
    DateTime? acknowledgedAt,
    String? acknowledgmentNote,
  }) {
    return SecurityAlert(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      level: level ?? this.level,
      eventType: eventType ?? this.eventType,
      userId: userId ?? this.userId,
      facilityId: facilityId ?? this.facilityId,
      metadata: metadata ?? this.metadata,
      timestamp: timestamp ?? this.timestamp,
      isAcknowledged: isAcknowledged ?? this.isAcknowledged,
      acknowledgedBy: acknowledgedBy ?? this.acknowledgedBy,
      acknowledgedAt: acknowledgedAt ?? this.acknowledgedAt,
      acknowledgmentNote: acknowledgmentNote ?? this.acknowledgmentNote,
    );
  }
}

class SecuritySettings {
  final String id;
  final bool enableAuditLogging;
  final bool enableRealTimeMonitoring;
  final bool enableSuspiciousActivityDetection;
  final bool enableDataEncryption;
  final bool enableTwoFactorAuth;
  final bool enableSessionTimeout;
  final int sessionTimeoutMinutes;
  final bool enableIPWhitelist;
  final List<String> allowedIPs;
  final bool enableLocationTracking;
  final bool enableDeviceFingerprinting;
  final bool enablePasswordPolicy;
  final int passwordMinLength;
  final bool requireSpecialCharacters;
  final bool requireNumbers;
  final bool requireUppercase;
  final int passwordExpiryDays;
  final bool enableAccountLockout;
  final int maxLoginAttempts;
  final int lockoutDurationMinutes;
  final DateTime updatedAt;
  final String updatedBy;

  const SecuritySettings({
    required this.id,
    this.enableAuditLogging = true,
    this.enableRealTimeMonitoring = true,
    this.enableSuspiciousActivityDetection = true,
    this.enableDataEncryption = true,
    this.enableTwoFactorAuth = false,
    this.enableSessionTimeout = true,
    this.sessionTimeoutMinutes = 30,
    this.enableIPWhitelist = false,
    this.allowedIPs = const [],
    this.enableLocationTracking = false,
    this.enableDeviceFingerprinting = false,
    this.enablePasswordPolicy = true,
    this.passwordMinLength = 8,
    this.requireSpecialCharacters = true,
    this.requireNumbers = true,
    this.requireUppercase = true,
    this.passwordExpiryDays = 90,
    this.enableAccountLockout = true,
    this.maxLoginAttempts = 5,
    this.lockoutDurationMinutes = 30,
    required this.updatedAt,
    required this.updatedBy,
  });

  SecuritySettings copyWith({
    String? id,
    bool? enableAuditLogging,
    bool? enableRealTimeMonitoring,
    bool? enableSuspiciousActivityDetection,
    bool? enableDataEncryption,
    bool? enableTwoFactorAuth,
    bool? enableSessionTimeout,
    int? sessionTimeoutMinutes,
    bool? enableIPWhitelist,
    List<String>? allowedIPs,
    bool? enableLocationTracking,
    bool? enableDeviceFingerprinting,
    bool? enablePasswordPolicy,
    int? passwordMinLength,
    bool? requireSpecialCharacters,
    bool? requireNumbers,
    bool? requireUppercase,
    int? passwordExpiryDays,
    bool? enableAccountLockout,
    int? maxLoginAttempts,
    int? lockoutDurationMinutes,
    DateTime? updatedAt,
    String? updatedBy,
  }) {
    return SecuritySettings(
      id: id ?? this.id,
      enableAuditLogging: enableAuditLogging ?? this.enableAuditLogging,
      enableRealTimeMonitoring: enableRealTimeMonitoring ?? this.enableRealTimeMonitoring,
      enableSuspiciousActivityDetection: enableSuspiciousActivityDetection ?? this.enableSuspiciousActivityDetection,
      enableDataEncryption: enableDataEncryption ?? this.enableDataEncryption,
      enableTwoFactorAuth: enableTwoFactorAuth ?? this.enableTwoFactorAuth,
      enableSessionTimeout: enableSessionTimeout ?? this.enableSessionTimeout,
      sessionTimeoutMinutes: sessionTimeoutMinutes ?? this.sessionTimeoutMinutes,
      enableIPWhitelist: enableIPWhitelist ?? this.enableIPWhitelist,
      allowedIPs: allowedIPs ?? this.allowedIPs,
      enableLocationTracking: enableLocationTracking ?? this.enableLocationTracking,
      enableDeviceFingerprinting: enableDeviceFingerprinting ?? this.enableDeviceFingerprinting,
      enablePasswordPolicy: enablePasswordPolicy ?? this.enablePasswordPolicy,
      passwordMinLength: passwordMinLength ?? this.passwordMinLength,
      requireSpecialCharacters: requireSpecialCharacters ?? this.requireSpecialCharacters,
      requireNumbers: requireNumbers ?? this.requireNumbers,
      requireUppercase: requireUppercase ?? this.requireUppercase,
      passwordExpiryDays: passwordExpiryDays ?? this.passwordExpiryDays,
      enableAccountLockout: enableAccountLockout ?? this.enableAccountLockout,
      maxLoginAttempts: maxLoginAttempts ?? this.maxLoginAttempts,
      lockoutDurationMinutes: lockoutDurationMinutes ?? this.lockoutDurationMinutes,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }
}

// Extensions for display names
extension SecurityEventTypeExtension on SecurityEventType {
  String get displayName {
    switch (this) {
      case SecurityEventType.login:
        return 'User Login';
      case SecurityEventType.logout:
        return 'User Logout';
      case SecurityEventType.loginFailed:
        return 'Failed Login Attempt';
      case SecurityEventType.passwordChanged:
        return 'Password Changed';
      case SecurityEventType.emailChanged:
        return 'Email Changed';
      case SecurityEventType.dataViewed:
        return 'Data Viewed';
      case SecurityEventType.dataCreated:
        return 'Data Created';
      case SecurityEventType.dataUpdated:
        return 'Data Updated';
      case SecurityEventType.dataDeleted:
        return 'Data Deleted';
      case SecurityEventType.dataExported:
        return 'Data Exported';
      case SecurityEventType.dataImported:
        return 'Data Imported';
      case SecurityEventType.roleAssigned:
        return 'Role Assigned';
      case SecurityEventType.roleRemoved:
        return 'Role Removed';
      case SecurityEventType.permissionGranted:
        return 'Permission Granted';
      case SecurityEventType.permissionDenied:
        return 'Permission Denied';
      case SecurityEventType.systemError:
        return 'System Error';
      case SecurityEventType.securityAlert:
        return 'Security Alert';
      case SecurityEventType.suspiciousActivity:
        return 'Suspicious Activity';
      case SecurityEventType.dataBreach:
        return 'Data Breach';
      case SecurityEventType.facilityCreated:
        return 'Facility Created';
      case SecurityEventType.facilityDeleted:
        return 'Facility Deleted';
      case SecurityEventType.facilityAccessGranted:
        return 'Facility Access Granted';
      case SecurityEventType.facilityAccessRevoked:
        return 'Facility Access Revoked';
      case SecurityEventType.tenantCreated:
        return 'Tenant Created';
      case SecurityEventType.tenantDeleted:
        return 'Tenant Deleted';
      case SecurityEventType.tenantDataAccessed:
        return 'Tenant Data Accessed';
      case SecurityEventType.tenantDataModified:
        return 'Tenant Data Modified';
      case SecurityEventType.paymentProcessed:
        return 'Payment Processed';
      case SecurityEventType.paymentFailed:
        return 'Payment Failed';
      case SecurityEventType.refundProcessed:
        return 'Refund Processed';
      case SecurityEventType.paymentDataAccessed:
        return 'Payment Data Accessed';
      case SecurityEventType.dnrEntryCreated:
        return 'DNR Entry Created';
      case SecurityEventType.dnrEntryDeleted:
        return 'DNR Entry Deleted';
      case SecurityEventType.dnrScreeningPerformed:
        return 'DNR Screening Performed';
      case SecurityEventType.contractCreated:
        return 'Contract Created';
      case SecurityEventType.contractSigned:
        return 'Contract Signed';
      case SecurityEventType.contractDeleted:
        return 'Contract Deleted';
      case SecurityEventType.contractViewed:
        return 'Contract Viewed';
    }
  }
}

extension SecurityLevelExtension on SecurityLevel {
  String get displayName {
    switch (this) {
      case SecurityLevel.low:
        return 'Low';
      case SecurityLevel.medium:
        return 'Medium';
      case SecurityLevel.high:
        return 'High';
      case SecurityLevel.critical:
        return 'Critical';
    }
  }

  Color get color {
    switch (this) {
      case SecurityLevel.low:
        return Colors.green;
      case SecurityLevel.medium:
        return Colors.orange;
      case SecurityLevel.high:
        return Colors.red;
      case SecurityLevel.critical:
        return Colors.purple;
    }
  }
}

extension SecurityActionExtension on SecurityAction {
  String get displayName {
    switch (this) {
      case SecurityAction.allow:
        return 'Allow';
      case SecurityAction.block:
        return 'Block';
      case SecurityAction.requireApproval:
        return 'Require Approval';
      case SecurityAction.logOnly:
        return 'Log Only';
    }
  }
}
