import 'package:flutter/material.dart';

enum PermissionType {
  // Facility Management
  createFacility,
  editFacility,
  deleteFacility,
  viewFacility,
  
  // Tenant Management
  createTenant,
  editTenant,
  deleteTenant,
  viewTenant,
  
  // Contract Management
  createContract,
  editContract,
  deleteContract,
  viewContract,
  signContract,
  processMoveOut, // Process tenant move-out workflow
  
  // Payment Management
  createPayment,
  editPayment,
  deletePayment,
  viewPayment,
  processPayment,
  processRefund, // Process refunds (separate from regular payments)
  issueRefund, // Issue refunds (more restrictive than processRefund)
  viewBilling, // View billing/ledger information
  manageBilling, // Full billing management (charges, adjustments)
  
  // DNR System
  createDNR,
  editDNR,
  deleteDNR,
  viewDNR,
  
  // Unit Management
  createUnit,
  editUnit,
  deleteUnit,
  viewUnit,
  
  // Reminder Management
  createReminder,
  editReminder,
  deleteReminder,
  viewReminder,
  
  // Data Management
  viewReports,
  exportData,
  importData,
  manageSettings,
  
  // Admin Functions
  manageUsers,
  viewAuditLogs,
  systemAdmin,
}

enum RoleType {
  owner,
  manager,
  employee,
  viewer,
  admin,
}

class Permission {
  final String id;
  final PermissionType type;
  final String name;
  final String description;
  final IconData icon;
  final bool isEnabled;
  final List<RoleType> allowedRoles;

  const Permission({
    required this.id,
    required this.type,
    required this.name,
    required this.description,
    required this.icon,
    this.isEnabled = true,
    required this.allowedRoles,
  });

  Permission copyWith({
    String? id,
    PermissionType? type,
    String? name,
    String? description,
    IconData? icon,
    bool? isEnabled,
    List<RoleType>? allowedRoles,
  }) {
    return Permission(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      description: description ?? this.description,
      icon: icon ?? this.icon,
      isEnabled: isEnabled ?? this.isEnabled,
      allowedRoles: allowedRoles ?? this.allowedRoles,
    );
  }
}

class Role {
  final String id;
  final RoleType type;
  final String name;
  final String description;
  final Color color;
  final List<PermissionType> permissions;
  final int level; // Higher level = more permissions
  final bool isSystemRole;

  const Role({
    required this.id,
    required this.type,
    required this.name,
    required this.description,
    required this.color,
    required this.permissions,
    required this.level,
    this.isSystemRole = false,
  });

  Role copyWith({
    String? id,
    RoleType? type,
    String? name,
    String? description,
    Color? color,
    List<PermissionType>? permissions,
    int? level,
    bool? isSystemRole,
  }) {
    return Role(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      description: description ?? this.description,
      color: color ?? this.color,
      permissions: permissions ?? this.permissions,
      level: level ?? this.level,
      isSystemRole: isSystemRole ?? this.isSystemRole,
    );
  }
}

class UserRole {
  final String id;
  final String userId;
  final String facilityId;
  final RoleType roleType;
  final DateTime assignedAt;
  final String assignedBy;
  final DateTime? expiresAt;
  final bool isActive;

  const UserRole({
    required this.id,
    required this.userId,
    required this.facilityId,
    required this.roleType,
    required this.assignedAt,
    required this.assignedBy,
    this.expiresAt,
    this.isActive = true,
  });

  UserRole copyWith({
    String? id,
    String? userId,
    String? facilityId,
    RoleType? roleType,
    DateTime? assignedAt,
    String? assignedBy,
    DateTime? expiresAt,
    bool? isActive,
  }) {
    return UserRole(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      facilityId: facilityId ?? this.facilityId,
      roleType: roleType ?? this.roleType,
      assignedAt: assignedAt ?? this.assignedAt,
      assignedBy: assignedBy ?? this.assignedBy,
      expiresAt: expiresAt ?? this.expiresAt,
      isActive: isActive ?? this.isActive,
    );
  }
}

class PermissionCheck {
  final bool hasPermission;
  final String? reason;
  final PermissionType? requiredPermission;
  final RoleType? userRole;

  const PermissionCheck({
    required this.hasPermission,
    this.reason,
    this.requiredPermission,
    this.userRole,
  });

  PermissionCheck copyWith({
    bool? hasPermission,
    String? reason,
    PermissionType? requiredPermission,
    RoleType? userRole,
  }) {
    return PermissionCheck(
      hasPermission: hasPermission ?? this.hasPermission,
      reason: reason ?? this.reason,
      requiredPermission: requiredPermission ?? this.requiredPermission,
      userRole: userRole ?? this.userRole,
    );
  }
}

// Extensions for display names
extension PermissionTypeExtension on PermissionType {
  String get displayName {
    switch (this) {
      case PermissionType.createFacility:
        return 'Create Facility';
      case PermissionType.editFacility:
        return 'Edit Facility';
      case PermissionType.deleteFacility:
        return 'Delete Facility';
      case PermissionType.viewFacility:
        return 'View Facility';
      case PermissionType.createTenant:
        return 'Create Tenant';
      case PermissionType.editTenant:
        return 'Edit Tenant';
      case PermissionType.deleteTenant:
        return 'Delete Tenant';
      case PermissionType.viewTenant:
        return 'View Tenant';
      case PermissionType.createContract:
        return 'Create Contract';
      case PermissionType.editContract:
        return 'Edit Contract';
      case PermissionType.deleteContract:
        return 'Delete Contract';
      case PermissionType.viewContract:
        return 'View Contract';
      case PermissionType.signContract:
        return 'Sign Contract';
      case PermissionType.processMoveOut:
        return 'Process Move-Out';
      case PermissionType.createPayment:
        return 'Create Payment';
      case PermissionType.editPayment:
        return 'Edit Payment';
      case PermissionType.deletePayment:
        return 'Delete Payment';
      case PermissionType.viewPayment:
        return 'View Payment';
      case PermissionType.processPayment:
        return 'Process Payment';
      case PermissionType.processRefund:
        return 'Process Refund';
      case PermissionType.issueRefund:
        return 'Issue Refund';
      case PermissionType.viewBilling:
        return 'View Billing';
      case PermissionType.manageBilling:
        return 'Manage Billing';
      case PermissionType.createDNR:
        return 'Create DNR Entry';
      case PermissionType.editDNR:
        return 'Edit DNR Entry';
      case PermissionType.deleteDNR:
        return 'Delete DNR Entry';
      case PermissionType.viewDNR:
        return 'View DNR List';
      case PermissionType.createUnit:
        return 'Create Unit';
      case PermissionType.editUnit:
        return 'Edit Unit';
      case PermissionType.deleteUnit:
        return 'Delete Unit';
      case PermissionType.viewUnit:
        return 'View Unit';
      case PermissionType.createReminder:
        return 'Create Reminder';
      case PermissionType.editReminder:
        return 'Edit Reminder';
      case PermissionType.deleteReminder:
        return 'Delete Reminder';
      case PermissionType.viewReminder:
        return 'View Reminder';
      case PermissionType.viewReports:
        return 'View Reports';
      case PermissionType.exportData:
        return 'Export Data';
      case PermissionType.importData:
        return 'Import Data';
      case PermissionType.manageSettings:
        return 'Manage Settings';
      case PermissionType.manageUsers:
        return 'Manage Users';
      case PermissionType.viewAuditLogs:
        return 'View Audit Logs';
      case PermissionType.systemAdmin:
        return 'System Admin';
    }
  }
}

extension RoleTypeExtension on RoleType {
  String get displayName {
    switch (this) {
      case RoleType.owner:
        return 'Owner';
      case RoleType.manager:
        return 'Manager';
      case RoleType.employee:
        return 'Employee';
      case RoleType.viewer:
        return 'Viewer';
      case RoleType.admin:
        return 'Admin';
    }
  }
}
