import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/permission_model.dart';
import '../services/facility_service.dart';
import '../services/email_service.dart';
import '../services/superadmin_service.dart';

/// Result of creating a facility invite
class InviteResult {
  final bool success;
  final String? errorMessage;
  
  InviteResult({required this.success, this.errorMessage});
}

/// Result of sending invite email
class EmailSendResult {
  final bool success;
  final String? errorMessage;
  
  EmailSendResult({required this.success, this.errorMessage});
}

/// Result of assigning a role
class AssignRoleResult {
  final bool success;
  final String? errorMessage;
  
  AssignRoleResult({required this.success, this.errorMessage});
}

class PermissionService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static const String _userRolesCollection = 'user_roles';
  static String get userRolesCollection => _userRolesCollection;
  static const String _permissionsCollection = 'permissions';
  static const String _usersCollection = 'users';
  static const String _facilityInvitesCollection = 'invites';

  // Predefined roles with their permissions
  static final Map<RoleType, Role> _predefinedRoles = {
    RoleType.owner: Role(
      id: 'owner',
      type: RoleType.owner,
      name: 'Owner',
      description: 'Full access to all features and settings',
      color: const Color(0xFF8B5CF6), // Purple
      level: 100,
      isSystemRole: true,
      permissions: PermissionType.values, // All permissions
    ),
    RoleType.manager: Role(
      id: 'manager',
      type: RoleType.manager,
      name: 'Manager',
      description: 'Manage facilities, tenants, and daily operations',
      color: const Color(0xFF3B82F6), // Blue
      level: 80,
      isSystemRole: true,
      permissions: [
        // Facility Management
        PermissionType.createFacility,
        PermissionType.editFacility,
        PermissionType.viewFacility,
        // Tenant Management
        PermissionType.createTenant,
        PermissionType.editTenant,
        PermissionType.deleteTenant,
        PermissionType.viewTenant,
        // Contract Management
        PermissionType.createContract,
        PermissionType.editContract,
        PermissionType.viewContract,
        PermissionType.signContract,
        PermissionType.processMoveOut,
        // Payment Management
        PermissionType.createPayment,
        PermissionType.editPayment,
        PermissionType.viewPayment,
        PermissionType.processPayment,
        PermissionType.processRefund,
        PermissionType.viewBilling,
        PermissionType.manageBilling,
        // DNR System
        PermissionType.createDNR,
        PermissionType.editDNR,
        PermissionType.viewDNR,
        // Unit Management
        PermissionType.createUnit,
        PermissionType.editUnit,
        PermissionType.viewUnit,
        PermissionType.manageOverlock,
        // Reminder Management
        PermissionType.createReminder,
        PermissionType.editReminder,
        PermissionType.viewReminder,
        // Data Management
        PermissionType.viewReports,
        PermissionType.exportData,
        PermissionType.manageTemplates,
        PermissionType.manageAutomation,
      ],
    ),
    RoleType.employee: Role(
      id: 'employee',
      type: RoleType.employee,
      name: 'Employee',
      description: 'Basic operational tasks and data entry',
      color: const Color(0xFF10B981), // Green
      level: 60,
      isSystemRole: true,
      permissions: [
        // Tenant Management
        PermissionType.createTenant,
        PermissionType.editTenant,
        PermissionType.viewTenant,
        // Contract Management
        PermissionType.createContract,
        PermissionType.viewContract,
        // Payment Management
        PermissionType.createPayment,
        PermissionType.viewPayment,
        PermissionType.viewBilling,
        // DNR System
        PermissionType.viewDNR,
        // Unit Management
        PermissionType.viewUnit,
        // Reminder Management
        PermissionType.createReminder,
        PermissionType.viewReminder,
      ],
    ),
    RoleType.viewer: Role(
      id: 'viewer',
      type: RoleType.viewer,
      name: 'Viewer',
      description: 'Read-only access to facility data',
      color: const Color(0xFF6B7280), // Gray
      level: 20,
      isSystemRole: true,
      permissions: [
        PermissionType.viewFacility,
        PermissionType.viewTenant,
        PermissionType.viewContract,
        PermissionType.viewPayment,
        PermissionType.viewDNR,
        PermissionType.viewUnit,
        PermissionType.viewReminder,
        PermissionType.viewReports,
      ],
    ),
    RoleType.admin: Role(
      id: 'admin',
      type: RoleType.admin,
      name: 'System Admin',
      description: 'System administration and user management',
      color: const Color(0xFFDC2626), // Red
      level: 90,
      isSystemRole: true,
      permissions: [
        ...PermissionType.values.where((p) => p != PermissionType.systemAdmin),
        PermissionType.manageUsers,
        PermissionType.viewAuditLogs,
      ],
    ),
  };

  // Get all predefined roles
  static List<Role> getPredefinedRoles() {
    return _predefinedRoles.values.toList();
  }

  // Get role by type
  static Role? getRoleByType(RoleType type) {
    return _predefinedRoles[type];
  }

  static Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    try {
      final doc = await _firestore.collection(_usersCollection).doc(userId).get();
      if (!doc.exists) return null;
      return doc.data();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error fetching user profile for $userId: $e');
      }
      return null;
    }
  }

  /// Find user ID by email using Cloud Function (for security - Phase 2)
  /// This replaces direct Firestore queries to comply with user document read restrictions
  static Future<String?> findUserIdByEmail(String email) async {
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('lookupUserByEmail');
      
      final result = await callable.call({'email': email});
      final data = result.data as Map<String, dynamic>?;
      
      if (data == null || data['found'] != true) {
        return null;
      }
      
      return data['uid'] as String?;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error finding user by email $email: $e');
      }
      return null;
    }
  }

  // Check if user has permission for a specific action
  static Future<PermissionCheck> hasPermission({
    required PermissionType permission,
    String? facilityId,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return const PermissionCheck(
          hasPermission: false,
          reason: 'User not authenticated',
        );
      }

      // Get user's role for the facility
      final userRole = await _getUserRole(currentUser.uid, facilityId);
      if (userRole == null) {
        return const PermissionCheck(
          hasPermission: false,
          reason: 'No role assigned for this facility',
        );
      }

      // Get role definition
      final role = getRoleByType(userRole.roleType);
      if (role == null) {
        return const PermissionCheck(
          hasPermission: false,
          reason: 'Invalid role type',
        );
      }

      // Check if role has the required permission
      final hasPermission = role.permissions.contains(permission);
      
      return PermissionCheck(
        hasPermission: hasPermission,
        reason: hasPermission ? null : 'Insufficient permissions',
        requiredPermission: permission,
        userRole: userRole.roleType,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking permission: $e');
      }
      return PermissionCheck(
        hasPermission: false,
        reason: 'Error checking permissions: $e',
      );
    }
  }

  // Get user's role for a specific facility
  static Future<UserRole?> _getUserRole(String userId, String? facilityId) async {
    try {
      // For a specific facility: check owner/manager via direct Firestore read
      // (FacilityService.getFacility only returns the facility for the current owner,
      // which would skip managers and cause inconsistent permission results)
      if (facilityId != null) {
        final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
        if (facilityDoc.exists) {
          final facilityData = facilityDoc.data();
          final ownerUid = facilityData?['ownerUid'] as String?;
          final createdAt = (facilityData?['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
          if (ownerUid == userId) {
            return UserRole(
              id: 'owner-$facilityId',
              userId: userId,
              facilityId: facilityId,
              roleType: RoleType.owner,
              assignedAt: createdAt,
              assignedBy: ownerUid ?? 'system',
              isActive: true,
            );
          }
          final managers = facilityData?['managers'] as Map<String, dynamic>? ?? {};
          if (managers[userId] == true) {
            return UserRole(
              id: 'manager:$facilityId:$userId',
              userId: userId,
              facilityId: facilityId,
              roleType: RoleType.manager,
              assignedAt: createdAt,
              assignedBy: ownerUid ?? 'system',
              expiresAt: null,
              isActive: true,
            );
          }
        }
      }

      if (facilityId == null) {
        // For global permissions, get the highest level role
        final querySnapshot = await _firestore
            .collection(_userRolesCollection)
            .where('userId', isEqualTo: userId)
            .where('isActive', isEqualTo: true)
            .get();

        if (querySnapshot.docs.isEmpty) {
          return null;
        }

        // Find the role with highest level
        UserRole? highestRole;
        int highestLevel = 0;

        for (final doc in querySnapshot.docs) {
          final userRole = UserRole(
            id: doc.id,
            userId: doc.data()['userId'] ?? '',
            facilityId: doc.data()['facilityId'] ?? '',
            roleType: RoleType.values.firstWhere(
              (e) => e.name == doc.data()['roleType'],
              orElse: () => RoleType.viewer,
            ),
            assignedAt: (doc.data()['assignedAt'] as Timestamp).toDate(),
            assignedBy: doc.data()['assignedBy'] ?? '',
            expiresAt: doc.data()['expiresAt'] != null
                ? (doc.data()['expiresAt'] as Timestamp).toDate()
                : null,
            isActive: doc.data()['isActive'] ?? true,
          );

          final role = getRoleByType(userRole.roleType);
          if (role != null && role.level > highestLevel) {
            highestLevel = role.level;
            highestRole = userRole;
          }
        }

        return highestRole;
      } else {
        // For facility-specific permissions
        final querySnapshot = await _firestore
            .collection(_userRolesCollection)
            .where('userId', isEqualTo: userId)
            .where('facilityId', isEqualTo: facilityId)
            .where('isActive', isEqualTo: true)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          final doc = querySnapshot.docs.first;
          return UserRole(
            id: doc.id,
            userId: doc.data()['userId'] ?? '',
            facilityId: doc.data()['facilityId'] ?? '',
            roleType: RoleType.values.firstWhere(
              (e) => e.name == doc.data()['roleType'],
              orElse: () => RoleType.viewer,
            ),
            assignedAt: (doc.data()['assignedAt'] as Timestamp).toDate(),
            assignedBy: doc.data()['assignedBy'] ?? '',
            expiresAt: doc.data()['expiresAt'] != null
                ? (doc.data()['expiresAt'] as Timestamp).toDate()
                : null,
            isActive: doc.data()['isActive'] ?? true,
          );
        }

        // Fall back to facility ownership/managers if no explicit role exists
        final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
        if (!facilityDoc.exists) {
          return null;
        }

        final facilityData = facilityDoc.data();
        final ownerUid = facilityData?['ownerUid'] as String?;
        if (ownerUid == userId) {
          final createdAt = (facilityData?['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
          return UserRole(
            id: 'owner:$facilityId',
            userId: userId,
            facilityId: facilityId,
            roleType: RoleType.owner,
            assignedAt: createdAt,
            assignedBy: ownerUid ?? 'system',
            expiresAt: null,
          );
        }

        final managers = facilityData?['managers'] as Map<String, dynamic>? ?? {};
        final isManager = managers[userId] == true;
        if (isManager) {
          final createdAt = (facilityData?['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
          return UserRole(
            id: 'manager:$facilityId:$userId',
            userId: userId,
            facilityId: facilityId,
            roleType: RoleType.manager,
            assignedAt: createdAt,
            assignedBy: ownerUid ?? 'system',
            expiresAt: null,
          );
        }

        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting user role: $e');
      }
      return null;
    }
  }

  // Assign role to user
  static Future<AssignRoleResult> assignRole({
    required String userId,
    required String facilityId,
    required RoleType roleType,
    required String assignedBy,
    DateTime? expiresAt,
    String? userDisplayName,
    String? userEmail,
  }) async {
    try {
      // Check super admin status
      final currentUser = _auth.currentUser;
      final isSuperAdmin = currentUser != null && SuperAdminService.isSuperAdmin(currentUser);
      print('🔐 [PermissionService.assignRole] Super admin check: $isSuperAdmin (user: ${currentUser?.email})');
      
      // Preserve owner: the facility creator retains owner role
      final facility = await FacilityService.getFacility(facilityId);
      if (facility != null && facility.ownerUid == userId) {
        roleType = RoleType.owner;
      }

      // Always log for debugging
      print('🔄 [PermissionService.assignRole] Assigning role $roleType to user $userId for facility $facilityId');

      final facilityRef = _firestore.collection('facilities').doc(facilityId);

      // Check if user already has a role for this facility
      final existingRole = await _getUserRole(userId, facilityId);
      if (existingRole != null) {
        // Upsert: set with merge. existingRole.id can be synthetic (owner-$fid, etc.)
        // when derived from facility ownership; those docs don't exist yet. set+merge
        // creates the doc, avoiding [cloud_firestore/not-found] No document to update.
        final now = DateTime.now();
        final payload = <String, dynamic>{
          'userId': userId,
          'facilityId': facilityId,
          'roleType': roleType.name,
          'assignedBy': assignedBy,
          'assignedAt': Timestamp.fromDate(existingRole.assignedAt),
          'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt) : null,
          'updatedAt': Timestamp.fromDate(now),
          'isActive': true,
          if (userDisplayName != null) 'userDisplayName': userDisplayName,
          if (userEmail != null) 'userEmail': userEmail,
        };
        await _firestore
            .collection(_userRolesCollection)
            .doc(existingRole.id)
            .set(payload, SetOptions(merge: true));
      } else {
        // Create new role assignment
        await _firestore.collection(_userRolesCollection).add({
          'userId': userId,
          'facilityId': facilityId,
          'roleType': roleType.name,
          'assignedAt': Timestamp.fromDate(DateTime.now()),
          'assignedBy': assignedBy,
          'expiresAt': expiresAt != null ? Timestamp.fromDate(expiresAt) : null,
          'isActive': true,
          'createdAt': Timestamp.fromDate(DateTime.now()),
          'updatedAt': Timestamp.fromDate(DateTime.now()),
          if (userDisplayName != null) 'userDisplayName': userDisplayName,
          if (userEmail != null) 'userEmail': userEmail,
        });
      }

      await facilityRef.set({
        'roles': {
          userId: roleType.name,
        },
      }, SetOptions(merge: true));

      print('✅ [PermissionService.assignRole] Role assigned successfully');
      return AssignRoleResult(success: true);
    } catch (e, stackTrace) {
      // Always log errors for debugging
      print('❌ [PermissionService.assignRole] Error assigning role: $e');
      print('❌ [PermissionService.assignRole] Stack trace: $stackTrace');
      return AssignRoleResult(
        success: false,
        errorMessage: 'Error assigning role: $e',
      );
    }
  }

  // Remove role from user
  static Future<bool> removeRole({
    required String userId,
    required String facilityId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Removing role from user $userId for facility $facilityId');
      }

      final facilityRef = _firestore.collection('facilities').doc(facilityId);

      final querySnapshot = await _firestore
          .collection(_userRolesCollection)
          .where('userId', isEqualTo: userId)
          .where('facilityId', isEqualTo: facilityId)
          .where('isActive', isEqualTo: true)
          .get();

      for (final doc in querySnapshot.docs) {
        await doc.reference.set({
          'isActive': false,
          'updatedAt': Timestamp.fromDate(DateTime.now()),
        }, SetOptions(merge: true));
      }

      await facilityRef.set({
        'roles': {
          userId: FieldValue.delete(),
        },
      }, SetOptions(merge: true));

      if (kDebugMode) {
        print('✅ Role removed successfully');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error removing role: $e');
      }
      return false;
    }
  }

  // Get all users with roles for a facility
  static Future<List<UserRole>> getFacilityUsers(String facilityId) async {
    try {
      final querySnapshot = await _firestore
          .collection(_userRolesCollection)
          .where('facilityId', isEqualTo: facilityId)
          .where('isActive', isEqualTo: true)
          .get();

      return querySnapshot.docs.map((doc) {
        final data = doc.data();
        return UserRole(
          id: doc.id,
          userId: data['userId'] ?? '',
          facilityId: data['facilityId'] ?? '',
          roleType: RoleType.values.firstWhere(
            (e) => e.name == data['roleType'],
            orElse: () => RoleType.viewer,
          ),
          assignedAt: (data['assignedAt'] as Timestamp).toDate(),
          assignedBy: data['assignedBy'] ?? '',
          expiresAt: data['expiresAt'] != null
              ? (data['expiresAt'] as Timestamp).toDate()
              : null,
          isActive: data['isActive'] ?? true,
        );
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting facility users: $e');
      }
      return [];
    }
  }

  static Future<List<FacilityInvite>> getFacilityInvites(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection(_facilityInvitesCollection)
          .orderBy('invitedAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => FacilityInvite.fromFirestore(doc: doc, facilityId: facilityId))
          .toList();
    } catch (e) {
      // Suppress BloomFilter errors - these are Firestore SDK internal warnings
      // that don't affect functionality, just add noise to console
      final errorString = e.toString();
      if (errorString.contains('BloomFilter') || errorString.contains('BloomFilterError')) {
        if (kDebugMode) {
          print('⚠️ [PermissionService] Firestore BloomFilter warning (non-critical) - ignoring');
        }
        // Try again without orderBy as fallback
        try {
          final fallbackSnapshot = await _firestore
              .collection('facilities')
              .doc(facilityId)
              .collection(_facilityInvitesCollection)
              .get();
          
          final invites = fallbackSnapshot.docs
              .map((doc) => FacilityInvite.fromFirestore(doc: doc, facilityId: facilityId))
              .toList();
          
          // Sort in memory instead
          invites.sort((a, b) => b.invitedAt.compareTo(a.invitedAt));
          return invites;
        } catch (fallbackError) {
          if (kDebugMode) {
            print('❌ [PermissionService] Error loading facility invites (fallback also failed): $fallbackError');
          }
          return [];
        }
      }
      
      // Other errors - log and return empty list
      if (kDebugMode) {
        print('❌ [PermissionService] Error loading facility invites: $e');
      }
      return [];
    }
  }

  static Future<InviteResult> createFacilityInvite({
    required String facilityId,
    required String email,
    required RoleType roleType,
    required String invitedBy,
    String? invitedByEmail,
  }) async {
    final normalizedEmail = email.toLowerCase().trim();
    try {
      final invitesRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection(_facilityInvitesCollection);

      // Allow the facility owner to always invite
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return InviteResult(success: false, errorMessage: 'User not authenticated');
      }
      
      // Super admins bypass all permission checks
      final isSuperAdmin = SuperAdminService.isSuperAdmin(currentUser);
      // Always log super admin status for debugging
      print('🔐 [PermissionService] Super admin check: $isSuperAdmin (user: ${currentUser.email})');
      if (isSuperAdmin) {
        print('✅ [PermissionService] Super admin detected - bypassing permission checks for invite');
      }
      
      final facility = await FacilityService.getFacility(facilityId);
      final isOwner = facility != null && facility.ownerUid == currentUser.uid;
      
      // Check permissions only if not super admin and not owner
      if (!isSuperAdmin && !isOwner) {
        // Non-owners must already have a role with manageUsers permission
        final check = await hasPermission(
          permission: PermissionType.manageUsers,
          facilityId: facilityId,
        );
        if (!check.hasPermission) {
          return InviteResult(success: false, errorMessage: 'Insufficient permissions to invite users');
        }
      }

      // Reuse existing pending invite when possible
      final existingSnapshot = await invitesRef
          .where('emailLower', isEqualTo: normalizedEmail)
          .where('status', isEqualTo: 'pending')
          .limit(1)
          .get();

      String inviteId;
      if (existingSnapshot.docs.isNotEmpty) {
        print('🔄 [PermissionService] Updating existing invite for $email');
        try {
          inviteId = existingSnapshot.docs.first.id;
          await existingSnapshot.docs.first.reference.update({
            'roleType': roleType.name,
            'updatedAt': Timestamp.fromDate(DateTime.now()),
            'lastSentAt': Timestamp.fromDate(DateTime.now()),
            'facilityId': facilityId,
          });
          print('✅ [PermissionService] Invite updated successfully (ID: $inviteId)');
        } catch (updateError) {
          print('❌ [PermissionService] Error updating invite: $updateError');
          throw updateError;
        }
      } else {
        print('🆕 [PermissionService] Creating new invite for $email');
        try {
          final inviteDocRef = await invitesRef.add({
            'email': email,
            'emailLower': normalizedEmail,
            'roleType': roleType.name,
            'status': 'pending',
            'invitedAt': Timestamp.fromDate(DateTime.now()),
            'invitedBy': invitedBy,
            'invitedByEmail': invitedByEmail,
            'facilityName': facility?.name ?? '',
            'lastSentAt': Timestamp.fromDate(DateTime.now()),
            'facilityId': facilityId,
          });
          inviteId = inviteDocRef.id;
          print('✅ [PermissionService] Invite created successfully (ID: $inviteId)');
        } catch (createError) {
          print('❌ [PermissionService] Error creating invite: $createError');
          throw createError;
        }
      }

      // Try to send email - capture error message
      print('📧 [PermissionService] Attempting to send invite email...');
      final emailResult = await _sendInviteEmail(
        facilityId: facilityId,
        inviteId: inviteId,
        email: email,
        roleType: roleType,
        invitedByEmail: invitedByEmail,
      );
      
      print('📧 [PermissionService] Email result: success=${emailResult.success}, error=${emailResult.errorMessage}');
      
      // Invite is created in Firestore regardless of email result
      return InviteResult(
        success: emailResult.success,
        errorMessage: emailResult.errorMessage,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating facility invite: $e');
      }
      return InviteResult(success: false, errorMessage: 'Error creating invite: $e');
    }
  }

  static Future<void> cancelFacilityInvite({
    required String facilityId,
    required String inviteId,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 [PermissionService] Cancelling invite: inviteId=$inviteId, facilityId=$facilityId');
      }
      
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection(_facilityInvitesCollection)
          .doc(inviteId)
          .delete();
      
      if (kDebugMode) {
        print('✅ [PermissionService] Invite cancelled successfully: inviteId=$inviteId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PermissionService] Error cancelling invite: $e');
        print('   FacilityId: $facilityId');
        print('   InviteId: $inviteId');
      }
      rethrow;
    }
  }

  static Future<bool> resendFacilityInvite({
    required String facilityId,
    required String inviteId,
  }) async {
    try {
      final inviteRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection(_facilityInvitesCollection)
          .doc(inviteId);
      final inviteDoc = await inviteRef.get();
      if (!inviteDoc.exists) return false;
      final invite = FacilityInvite.fromFirestore(doc: inviteDoc, facilityId: facilityId);
      if (!invite.isPending) return false;

      await inviteRef.update({
        'lastSentAt': Timestamp.fromDate(DateTime.now()),
      });

      final emailResult = await _sendInviteEmail(
        facilityId: facilityId,
        inviteId: inviteId,
        email: invite.email,
        roleType: invite.roleType,
        invitedByEmail: invite.invitedByEmail,
      );
      
      if (!emailResult.success) {
        if (kDebugMode) {
          print('⚠️ Failed to resend invite email: ${emailResult.errorMessage}');
        }
        // Still return true because we updated the timestamp
      }
      
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error resending invite: $e');
      }
      return false;
    }
  }

  /// Fulfill a specific invite by inviteId (used when user explicitly accepts an invite)
  static Future<bool> fulfillSpecificInvite({
    required String facilityId,
    required String inviteId,
    required String userId,
    String? displayName,
    String? email,
  }) async {
    try {
      final inviteRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection(_facilityInvitesCollection)
          .doc(inviteId);
      
      final inviteDoc = await inviteRef.get();
      if (!inviteDoc.exists) {
        if (kDebugMode) {
          print('❌ [PermissionService] Invite not found: $inviteId');
        }
        return false;
      }
      
      final data = inviteDoc.data();
      if (data == null) {
        if (kDebugMode) {
          print('❌ [PermissionService] Invite data is null: $inviteId');
        }
        return false;
      }
      
      // Check if invite is still pending
      final status = data['status'] as String? ?? 'pending';
      if (status != 'pending') {
        if (kDebugMode) {
          print('⚠️ [PermissionService] Invite is not pending (status: $status): $inviteId');
        }
        return false;
      }
      
      // Get role type from invite
      final roleTypeName = data['roleType'] as String? ?? RoleType.viewer.name;
      final roleType = RoleType.values.firstWhere(
        (role) => role.name == roleTypeName,
        orElse: () => RoleType.viewer,
      );
      final invitedBy = data['invitedBy'] as String? ?? 'invite';
      final inviteEmail = data['email'] as String? ?? email ?? '';
      
      if (kDebugMode) {
        print('🔄 [PermissionService] Fulfilling specific invite: $inviteId for facility: $facilityId');
        print('   Email: $inviteEmail, Role: $roleTypeName');
      }
      
      // Assign the role
      final assigned = await assignRole(
        userId: userId,
        facilityId: facilityId,
        roleType: roleType,
        assignedBy: invitedBy,
        userDisplayName: displayName,
        userEmail: email ?? inviteEmail,
      );

      if (assigned.success) {
        // Mark invite as accepted
        await inviteRef.update({
          'status': 'accepted',
          'acceptedAt': Timestamp.fromDate(DateTime.now()),
          'acceptedBy': userId,
        });
        
        if (kDebugMode) {
          print('✅ [PermissionService] Invite fulfilled successfully: $inviteId');
        }
        return true;
      } else {
        if (kDebugMode) {
          print('❌ [PermissionService] Failed to assign role for invite: $inviteId');
          print('   Error: ${assigned.errorMessage}');
        }
        return false;
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PermissionService] Error fulfilling specific invite $inviteId: $e');
      }
      return false;
    }
  }

  /// Fulfill ALL pending invites for a user (used during signup/login)
  /// This auto-accepts all pending invites when a user first signs up or logs in
  static Future<void> fulfillPendingInvitesForUser({
    required String userId,
    required String emailLower,
    String? displayName,
    String? email,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 [PermissionService] Fulfilling ALL pending invites for: $emailLower');
      }
      
      final invitesSnapshot = await _firestore
          .collectionGroup(_facilityInvitesCollection)
          .where('emailLower', isEqualTo: emailLower)
          .where('status', isEqualTo: 'pending')
          .get();

      if (kDebugMode) {
        print('📧 [PermissionService] Found ${invitesSnapshot.docs.length} pending invite(s)');
      }

      for (final doc in invitesSnapshot.docs) {
        final facilityRef = doc.reference.parent.parent;
        if (facilityRef == null) continue;
        final facilityId = facilityRef.id;
        final data = doc.data();
        final roleTypeName = data['roleType'] as String? ?? RoleType.viewer.name;
        final roleType = RoleType.values.firstWhere(
          (role) => role.name == roleTypeName,
          orElse: () => RoleType.viewer,
        );
        final invitedBy = data['invitedBy'] as String? ?? 'invite';

        final assigned = await assignRole(
          userId: userId,
          facilityId: facilityId,
          roleType: roleType,
          assignedBy: invitedBy,
          userDisplayName: displayName,
          userEmail: email ?? emailLower,
        );

        if (assigned.success) {
          await doc.reference.update({
            'status': 'accepted',
            'acceptedAt': Timestamp.fromDate(DateTime.now()),
            'acceptedBy': userId,
          });
          
          if (kDebugMode) {
            print('✅ [PermissionService] Auto-accepted invite for facility: $facilityId');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PermissionService] Error fulfilling invites for $emailLower: $e');
      }
    }
  }

  static Future<EmailSendResult> _sendInviteEmail({
    required String facilityId,
    required String inviteId,
    required String email,
    required RoleType roleType,
    String? invitedByEmail,
  }) async {
    try {
      final facility = await FacilityService.getFacility(facilityId);
      final facilityName = facility?.name ?? 'your storage facility';
      final role = getRoleByType(roleType);
      final roleName = role?.name ?? roleType.name;

      // Improved subject line with platform context to reduce spam flags
      final subject = 'You\'ve been invited to access $facilityName (Storage Facility Creator)';
      
      // Use hash-based URL directly - SendGrid Link Branding will handle tracking
      final acceptUrl = 'https://app.storagefacilitycreator.com/#/accept-invite?facilityId=$facilityId&inviteId=$inviteId';
      
      // "Why you received this" explanation
      final whyReceivedExplanation = invitedByEmail != null
          ? 'You received this invitation because an administrator at $facilityName ($invitedByEmail) invited you to collaborate on their storage facility management.'
          : 'You received this invitation because an administrator at $facilityName invited you to collaborate on their storage facility management.';
      
      // Plain-text version with fallback link prominently displayed
      final text = '''
Hello,

$whyReceivedExplanation

You've been invited to join $facilityName as a $roleName.

ACCEPT YOUR INVITATION:
To accept this invitation, please use the link below:

$acceptUrl

If the button doesn't work, copy and paste the link above into your browser's address bar.

---

Why did I receive this?
$whyReceivedExplanation

If you were not expecting this invitation, you can safely ignore this message. No action is required.

---

Storage Facility Creator
Facility Management Platform
Support: support@storagefacilitycreator.com

This is an automated message from Storage Facility Creator.
Please do not reply directly to this email. For support, contact support@storagefacilitycreator.com
''';

      // HTML version with improved trust signals and anti-spam improvements
      final invitedByHtml = invitedByEmail != null
          ? '<p style="font-size: 14px; color: #666; margin-bottom: 20px;"><strong>Invited by:</strong> $invitedByEmail</p>'
          : '';
      
      final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Facility Invitation - Storage Facility Creator</title>
</head>
<body style="font-family: Arial, Helvetica, sans-serif; line-height: 1.6; color: #333333; margin: 0; padding: 0; background-color: #f5f5f5;">
  <div style="max-width: 600px; margin: 0 auto; padding: 20px; background-color: #ffffff;">
    <!-- Header -->
    <div style="background-color: #7B1FA2; padding: 25px; text-align: center; border-radius: 8px 8px 0 0;">
      <h1 style="color: #ffffff; margin: 0; font-size: 24px; font-weight: normal;">Facility Invitation</h1>
      <p style="color: #ffffff; margin: 8px 0 0 0; font-size: 14px; opacity: 0.9;">Storage Facility Creator</p>
    </div>
    
    <!-- Main Content -->
    <div style="padding: 30px 20px;">
      <p style="font-size: 16px; margin-bottom: 20px; color: #333333;">Hello,</p>
      
      <!-- Why you received this explanation -->
      <div style="background-color: #f8f9fa; border-left: 4px solid #7B1FA2; padding: 15px; margin-bottom: 25px; border-radius: 4px;">
        <p style="margin: 0 0 10px 0; font-weight: bold; color: #7B1FA2; font-size: 14px;">Why did I receive this?</p>
        <p style="margin: 0; font-size: 14px; color: #555555; line-height: 1.5;">
          $whyReceivedExplanation
        </p>
      </div>
      
      <p style="font-size: 16px; margin-bottom: 20px; color: #333333;">
        You've been invited to join <strong style="color: #7B1FA2;">$facilityName</strong> as a <strong>$roleName</strong>.
      </p>
      
      $invitedByHtml
      
      <!-- Primary CTA Button -->
      <div style="text-align: center; margin: 30px 0;">
        <a href="$acceptUrl" style="display: inline-block; background-color: #7B1FA2; color: #ffffff; padding: 14px 32px; text-decoration: none; border-radius: 6px; font-size: 16px; font-weight: bold; border: 2px solid #7B1FA2;">Accept Invitation</a>
      </div>
      
      <!-- Plain-text fallback link (prominently displayed) -->
      <div style="background-color: #f8f9fa; border: 1px solid #dee2e6; border-radius: 6px; padding: 20px; margin: 25px 0;">
        <p style="font-size: 13px; color: #666666; margin: 0 0 10px 0; font-weight: bold;">If the button doesn't work, copy and paste this link:</p>
        <p style="font-size: 13px; margin: 0; word-break: break-all; color: #7B1FA2; font-family: 'Courier New', Courier, monospace; background-color: #ffffff; padding: 12px; border-radius: 4px; border: 1px solid #dee2e6;">
          $acceptUrl
        </p>
      </div>
      
      <!-- Instructions -->
      <div style="background-color: #f8f9fa; padding: 15px; margin: 25px 0; border-radius: 4px;">
        <p style="margin: 0 0 10px 0; font-weight: bold; color: #333333; font-size: 14px;">To accept this invitation:</p>
        <ol style="margin: 0; padding-left: 20px; color: #555555; font-size: 14px;">
          <li style="margin-bottom: 8px;">Click the "Accept Invitation" button above, or copy the link if the button doesn't work.</li>
          <li style="margin-bottom: 8px;">Sign up or log in to Storage Facility Creator using this email address ($email).</li>
          <li style="margin-bottom: 0;">Your access to $facilityName will be automatically linked to your account.</li>
        </ol>
      </div>
      
      <!-- Safety notice -->
      <p style="font-size: 14px; color: #666666; margin-top: 25px; padding-top: 20px; border-top: 1px solid #e9ecef;">
        If you were not expecting this invitation, you can safely ignore this message. No action is required.
      </p>
    </div>
    
    <!-- Footer -->
    <div style="background-color: #f8f9fa; padding: 25px 20px; border-radius: 0 0 8px 8px; border-top: 1px solid #dee2e6;">
      <p style="font-size: 13px; color: #666666; margin: 0 0 10px 0; text-align: center;">
        <strong>Storage Facility Creator</strong><br>
        Facility Management Platform
      </p>
      <p style="font-size: 12px; color: #999999; margin: 15px 0 0 0; text-align: center; line-height: 1.6;">
        Support: <a href="mailto:support@storagefacilitycreator.com" style="color: #7B1FA2; text-decoration: none;">support@storagefacilitycreator.com</a><br>
        <br>
        This is an automated message from Storage Facility Creator.<br>
        Please do not reply directly to this email. For support inquiries, contact us at support@storagefacilitycreator.com
      </p>
    </div>
  </div>
</body>
</html>
''';

      if (kDebugMode) {
        print('📧 [PermissionService] Attempting to send invite email to: $email');
        print('📧 [PermissionService] Facility ID: $facilityId');
        print('📧 [PermissionService] Role Type: ${roleType.name}');
      }

      // Use dynamic From name: "{FacilityName} via Storage Facility Creator" for invitations
      final fromName = '$facilityName via Storage Facility Creator';
      
      final result = await EmailService.sendEmail(
        to: email,
        subject: subject,
        text: text,
        html: html,
        facilityId: facilityId,
        fromName: fromName,
      );

      if (kDebugMode) {
        print('📧 [PermissionService] EmailService.sendEmail returned: success=${result.success}');
        if (result.error != null) {
          print('📧 [PermissionService] Error: ${result.error}');
          print('📧 [PermissionService] Error Code: ${result.errorCode}');
        }
      }

      if (!result.success) {
        final errorMsg = result.error ?? 'Unknown email service error';
        final errorCode = result.errorCode;
        
        // Always log errors for debugging
        print('❌ [PermissionService] Error sending invite email: $errorMsg');
        print('❌ [PermissionService] Error code: $errorCode');
        print('❌ [PermissionService] Full error details: ${result.toString()}');
        
        // Format error message - don't duplicate error codes if already in message
        String formattedError;
        if (errorCode != null && errorMsg.contains(errorCode)) {
          formattedError = errorMsg;
        } else if (errorCode != null) {
          formattedError = '[$errorCode] $errorMsg';
        } else {
          formattedError = errorMsg;
        }
        
        return EmailSendResult(
          success: false,
          errorMessage: formattedError,
        );
      }

      if (kDebugMode) {
        print('✅ [PermissionService] Invite email sent successfully to $email');
        print('✅ [PermissionService] Message ID: ${result.messageId}');
      }
      return EmailSendResult(success: true);
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('❌ Exception sending invite email: $e');
        print('❌ Stack trace: $stackTrace');
      }
      return EmailSendResult(
        success: false,
        errorMessage: 'Exception: $e',
      );
    }
  }

  // Check if user is owner of facility
  static Future<bool> isFacilityOwner(String userId, String facilityId) async {
    final userRole = await _getUserRole(userId, facilityId);
    return userRole?.roleType == RoleType.owner;
  }

  // Get user's permissions for a facility
  static Future<List<PermissionType>> getUserPermissions({
    required String userId,
    String? facilityId,
  }) async {
    final userRole = await _getUserRole(userId, facilityId);
    if (userRole == null) return [];

    final role = getRoleByType(userRole.roleType);
    return role?.permissions ?? [];
  }

  // Create default owner role for new facility
  static Future<bool> createDefaultOwnerRole({
    required String facilityId,
    required String ownerId,
  }) async {
    final result = await assignRole(
      userId: ownerId,
      facilityId: facilityId,
      roleType: RoleType.owner,
      assignedBy: 'system',
    );
    return result.success;
  }
}

class FacilityInvite {
  final String id;
  final String facilityId;
  final String email;
  final String emailLower;
  final RoleType roleType;
  final String status;
  final DateTime invitedAt;
  final String? invitedBy;
  final String? invitedByEmail;
  final DateTime? acceptedAt;
  final String? acceptedBy;
  final DateTime? lastSentAt;

  const FacilityInvite({
    required this.id,
    required this.facilityId,
    required this.email,
    required this.emailLower,
    required this.roleType,
    required this.status,
    required this.invitedAt,
    this.invitedBy,
    this.invitedByEmail,
    this.acceptedAt,
    this.acceptedBy,
    this.lastSentAt,
  });

  bool get isPending => status == 'pending';

  factory FacilityInvite.fromFirestore({
    required DocumentSnapshot<Map<String, dynamic>> doc,
    required String facilityId,
  }) {
    final data = doc.data() ?? const <String, dynamic>{};
    return FacilityInvite(
      id: doc.id,
      facilityId: facilityId,
      email: data['email'] as String? ?? '',
      emailLower: data['emailLower'] as String? ?? '',
      roleType: RoleType.values.firstWhere(
        (role) => role.name == (data['roleType'] as String? ?? RoleType.viewer.name),
        orElse: () => RoleType.viewer,
      ),
      status: data['status'] as String? ?? 'pending',
      invitedAt: (data['invitedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      invitedBy: data['invitedBy'] as String?,
      invitedByEmail: data['invitedByEmail'] as String?,
      acceptedAt: (data['acceptedAt'] as Timestamp?)?.toDate(),
      acceptedBy: data['acceptedBy'] as String?,
      lastSentAt: (data['lastSentAt'] as Timestamp?)?.toDate(),
    );
  }
}
