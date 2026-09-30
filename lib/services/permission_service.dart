import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/permission_model.dart';
import 'package:sfcapp/services/audit_service.dart';
import '../services/facility_service.dart';
import '../services/email_service.dart';
import '../services/superadmin_service.dart';
import 'package:sfcapp/utils/verified_email_token.dart';

/// Result of creating a facility invite
class InviteResult {
  final bool success;
  final String? errorMessage;

  /// Whether the invite was saved. False when it was refused (the invitee
  /// already has access, the caller may not invite) or the write failed; the
  /// team screen said "Invite created but email failed to send" for those too.
  final bool inviteSaved;

  InviteResult({required this.success, this.errorMessage, this.inviteSaved = false});
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

  // Where this service's collections, collection groups, write batches,
  // signed-in user and user lookups come from: Firestore, Auth and the
  // lookupUserByEmail callable, unless a test points them at fakes so the
  // service's own queries and writes run.
  static CollectionReference<Map<String, dynamic>> Function(String path) _collection =
      _firestoreCollection;
  static Query<Map<String, dynamic>> Function(String collectionId) _collectionGroup =
      _firestoreCollectionGroup;
  static WriteBatch Function() _newBatch = _firestoreBatch;
  static User? Function() _currentUser = _authCurrentUser;
  static Future<String?> Function(String email, String facilityId) _lookupUserId =
      _callableLookupUserId;

  static CollectionReference<Map<String, dynamic>> _firestoreCollection(String path) =>
      _firestore.collection(path);
  static Query<Map<String, dynamic>> _firestoreCollectionGroup(String collectionId) =>
      _firestore.collectionGroup(collectionId);
  static WriteBatch _firestoreBatch() => _firestore.batch();
  static User? _authCurrentUser() => _auth.currentUser;

  /// Serves [collection], [collectionGroup], [batch], [currentUser] and
  /// [findUserIdByEmail] instead of Firestore, Auth and the callable; null
  /// restores them.
  @visibleForTesting
  static void overrideForTesting({
    CollectionReference<Map<String, dynamic>> Function(String path)? collection,
    Query<Map<String, dynamic>> Function(String collectionId)? collectionGroup,
    WriteBatch Function()? batch,
    User? Function()? currentUser,
    Future<String?> Function(String email, String facilityId)? findUserIdByEmail,
  }) {
    _collection = collection ?? _firestoreCollection;
    _collectionGroup = collectionGroup ?? _firestoreCollectionGroup;
    _newBatch = batch ?? _firestoreBatch;
    _currentUser = currentUser ?? _authCurrentUser;
    _lookupUserId = findUserIdByEmail ?? _callableLookupUserId;
  }

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
        PermissionType.deleteDNR,
        PermissionType.viewDNR,
        // Unit Management
        PermissionType.createUnit,
        PermissionType.editUnit,
        PermissionType.deleteUnit,
        PermissionType.viewUnit,
        PermissionType.manageOverlock,
        // Reminder Management
        PermissionType.createReminder,
        PermissionType.editReminder,
        PermissionType.deleteReminder,
        PermissionType.viewReminder,
        // Data Management
        PermissionType.viewReports,
        PermissionType.exportData,
        PermissionType.importData,
        PermissionType.manageTemplates,
        PermissionType.manageAutomation,
        // Contracts / payments (manager ops; owner retains full via PermissionType.values)
        PermissionType.deleteContract,
        PermissionType.deletePayment,
        // Stays (short-term rentals)
        PermissionType.viewStays,
        PermissionType.manageStays,
        PermissionType.manageStayChannels,
        PermissionType.manageStayMoney,
        PermissionType.manageStaySettings,
        PermissionType.workStayTasks,
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
        // Stays: views stays, checks guests in and out, works turnovers.
        // Walk-up booking and cash are owner switches the server enforces.
        PermissionType.viewStays,
        PermissionType.workStayTasks,
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
        // Stays: read-only calendar, listings and turnovers.
        PermissionType.viewStays,
      ],
    ),
  };

  /// Roles that can be assigned or invited (excludes owner).
  static List<Role> getAssignableRoles() {
    final list = _predefinedRoles.values.toList()
      ..sort((a, b) => b.level.compareTo(a.level));
    return list;
  }

  // Get all predefined roles (for Roles tab reference cards)
  static List<Role> getPredefinedRoles() {
    return getAssignableRoles();
  }

  // Get role by type.
  static Role? getRoleByType(RoleType type) {
    return _predefinedRoles[type];
  }

  /// Maps Firestore `roleType` strings to [RoleType]. Legacy value `admin` → [RoleType.manager].
  static RoleType roleTypeFromFirestoreString(String? raw) {
    final name = (raw ?? '').trim();
    if (name.isEmpty) return RoleType.viewer;
    if (name == 'admin') return RoleType.manager;
    return RoleType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => RoleType.viewer,
    );
  }

  static Future<CurrentFacilityRoleSummary?> getCurrentUserRoleSummary(String facilityId) async {
    final user = _currentUser();
    if (user == null || facilityId.isEmpty) return null;
    final userRole = await _getUserRole(user.uid, facilityId);
    if (userRole == null) {
      return CurrentFacilityRoleSummary(
        email: user.email ?? '',
        roleTypeLabel: 'No facility role',
        canDeleteTenants: false,
      );
    }
    final def = getRoleByType(userRole.roleType);
    final canDel = def?.permissions.contains(PermissionType.deleteTenant) ?? false;
    return CurrentFacilityRoleSummary(
      email: user.email ?? '',
      roleTypeLabel: userRole.roleType.displayName,
      canDeleteTenants: canDel,
    );
  }

  static Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    try {
      final doc = await _collection(_usersCollection).doc(userId).get();
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
  /// This replaces direct Firestore queries to comply with user document read restrictions.
  /// Caller must have staff access to [facilityId].
  static Future<String?> findUserIdByEmail(String email, {required String facilityId}) =>
      _lookupUserId(email, facilityId);

  static Future<String?> _callableLookupUserId(String email, String facilityId) async {
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('lookupUserByEmail');
      
      final result = await callable.call({
        'email': email,
        'facilityId': facilityId,
      });
      // Any map: on the web a callable's result is not always
      // Map<String, dynamic>, and the cast threw into "not found".
      final data = result.data;
      if (data is! Map || data['found'] != true) {
        return null;
      }
      final uid = data['uid'];
      return uid is String && uid.isNotEmpty ? uid : null;
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
      final currentUser = _currentUser();
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
        final facilityDoc = await _collection('facilities').doc(facilityId).get();
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
        final querySnapshot = await _collection(_userRolesCollection)
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
            roleType: roleTypeFromFirestoreString(doc.data()['roleType'] as String?),
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
        final querySnapshot = await _collection(_userRolesCollection)
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
            roleType: roleTypeFromFirestoreString(doc.data()['roleType'] as String?),
            assignedAt: (doc.data()['assignedAt'] as Timestamp).toDate(),
            assignedBy: doc.data()['assignedBy'] ?? '',
            expiresAt: doc.data()['expiresAt'] != null
                ? (doc.data()['expiresAt'] as Timestamp).toDate()
                : null,
            isActive: doc.data()['isActive'] ?? true,
          );
        }

        // Fall back to facility ownership/managers if no explicit role exists
        final facilityDoc = await _collection('facilities').doc(facilityId).get();
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
  /// When [fulfilledInviteId] is set (invite acceptance), Firestore rules validate against
  /// `facilities/{facilityId}/invites/{id}` so the invitee can write without being owner yet,
  /// and that invite is marked accepted by [userId].
  ///
  /// The role row, the facility's roles map (the one the rules read) and the
  /// invite are one batch: all written or none. Written one after another, an
  /// acceptance that failed after the row (a dropped connection, a closed tab)
  /// left an active row the rules ignore and the invite still pending, and
  /// that row made the invitee look like existing staff, so nothing retried.
  static Future<AssignRoleResult> assignRole({
    required String userId,
    required String facilityId,
    required RoleType roleType,
    required String assignedBy,
    DateTime? expiresAt,
    String? userDisplayName,
    String? userEmail,
    String? fulfilledInviteId,
  }) async {
    try {
      // Check super admin status
      final currentUser = _currentUser();
      final isSuperAdmin = currentUser != null && SuperAdminService.isSuperAdmin(currentUser);
      print('🔐 [PermissionService.assignRole] Super admin check: $isSuperAdmin (user: ${currentUser?.email})');

      if (fulfilledInviteId != null &&
          await holdsRoleAt(facilityId: facilityId, userId: userId)) {
        // Already on the team: the invite (left over from before they joined,
        // or from an acceptance that stopped part-way and was promoted since)
        // is spent, and their role stays. Accepting it rewrote the role row
        // and roles map with the invite's role, so a manager promoted since
        // was made an employee again on their next load.
        await _collection('facilities')
            .doc(facilityId)
            .collection(_facilityInvitesCollection)
            .doc(fulfilledInviteId)
            .update({
          'status': 'accepted',
          'acceptedAt': Timestamp.fromDate(DateTime.now()),
          'acceptedBy': userId,
        });
        return AssignRoleResult(success: true);
      }

      // Preserve owner: the facility creator retains owner role
      final facility = await FacilityService.getFacility(facilityId);
      if (facility != null && facility.ownerUid == userId) {
        roleType = RoleType.owner;
      }

      // Always log for debugging
      print('🔄 [PermissionService.assignRole] Assigning role $roleType to user $userId for facility $facilityId');

      final facilityRef = _collection('facilities').doc(facilityId);

      final batch = _newBatch();

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
          if (fulfilledInviteId != null) 'inviteId': fulfilledInviteId,
        };
        batch.set(
          _collection(_userRolesCollection).doc(existingRole.id),
          payload,
          SetOptions(merge: true),
        );
        if (fulfilledInviteId == null) {
          // A role change reaches every active row here, not just the first
          // one read. The callables that charge cards take any active row
          // (limit 1, in no set order) as access, so a second manager row (an
          // invitee's acceptance may write several) kept a demoted viewer a
          // manager there.
          final activeRows = await _collection(_userRolesCollection)
              .where('userId', isEqualTo: userId)
              .where('facilityId', isEqualTo: facilityId)
              .where('isActive', isEqualTo: true)
              .get();
          for (final doc in activeRows.docs) {
            if (doc.id == existingRole.id) continue;
            batch.set(doc.reference, {
              'roleType': roleType.name,
              'assignedBy': assignedBy,
              'updatedAt': Timestamp.fromDate(now),
            }, SetOptions(merge: true));
          }
        }
      } else {
        // Create new role assignment
        batch.set(_collection(_userRolesCollection).doc(), {
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
          if (fulfilledInviteId != null) 'inviteId': fulfilledInviteId,
        });
      }

      final facilityPayload = <String, dynamic>{
        'roles': {
          userId: roleType.name,
        },
      };
      if (fulfilledInviteId != null) {
        facilityPayload['acceptingInviteId'] = fulfilledInviteId;
      }
      batch.set(facilityRef, facilityPayload, SetOptions(merge: true));

      if (fulfilledInviteId != null) {
        // The rules check every write in a batch against the invite as it
        // was before the batch, so this still counts as a pending invite for
        // the role row and roles map above.
        batch.update(facilityRef.collection(_facilityInvitesCollection).doc(fulfilledInviteId), {
          'status': 'accepted',
          'acceptedAt': Timestamp.fromDate(DateTime.now()),
          'acceptedBy': userId,
        });
      }
      await batch.commit();

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

      final facilityRef = _collection('facilities').doc(facilityId);
      final facility = (await facilityRef.get()).data() ?? const <String, dynamic>{};

      final querySnapshot = await _collection(_userRolesCollection)
          .where('userId', isEqualTo: userId)
          .where('facilityId', isEqualTo: facilityId)
          .where('isActive', isEqualTo: true)
          .get();

      // Their pending invites here are cancelled with the rest: one left
      // pending gave a removed team member their access straight back
      // through its link. So are the ones they sent: a manager could invite
      // a second login of their own, and it let them back in after removal.
      final (:pendingInvites, :knownEmail) = await _pendingInvitesOf(
        userId: userId,
        facilityId: facilityId,
        roleDocs: querySnapshot.docs,
      );

      // One batch, so a removal that fails part-way removes nothing and the
      // owner can try again. Written one by one, a failure after the role
      // rows left the user in the roles map the rules read, still with
      // access, while the team screen no longer listed them.
      final batch = _newBatch();
      final now = Timestamp.fromDate(DateTime.now());
      for (final invite in pendingInvites) {
        batch.update(invite, {
          'status': 'cancelled',
          'cancelledAt': now,
          'cancelledReason': 'access_removed',
          // The rules take an owner's or manager's edit only when the invite
          // names this facility after it. One an invitee pointed at a
          // facility of their own (before the rules stopped that) is put
          // back, or the whole removal was refused and they stayed.
          'facilityId': facilityId,
        });
      }
      for (final doc in querySnapshot.docs) {
        batch.set(doc.reference, {
          'isActive': false,
          'updatedAt': now,
        }, SetOptions(merge: true));
      }
      // The legacy managers map too: the rules still grant a manager's
      // access from it, so a manager removed only from roles kept theirs.
      batch.set(facilityRef, {
        'roles': {
          userId: FieldValue.delete(),
        },
        'managers': {
          userId: FieldValue.delete(),
        },
      }, SetOptions(merge: true));
      // Logged in the same batch: managers may remove team members too, and
      // the owner saw nothing of who removed whom.
      final removal = _removalAuditEntry(
        facilityId: facilityId,
        facility: facility,
        userId: userId,
        roleDocs: querySnapshot.docs,
        knownEmail: knownEmail,
        invitesCancelled: pendingInvites.length,
        at: now.toDate(),
      );
      if (removal != null) {
        batch.set(facilityRef.collection('auditLogs').doc(), removal.toFirestore());
      }
      await batch.commit();

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

  /// The pending invites at [facilityId] that removing [userId] cancels:
  /// those addressed to them, and those they sent. Invites are keyed by
  /// email, so "addressed to them" goes by the addresses they are known by
  /// there that they could not have written themselves:
  /// - the address of each invite they accepted there (the rules matched it
  ///   to their sign-in address when they accepted);
  /// - the address of the invite each of their role rows ([roleDocs]) was
  ///   written for, while it is pending (the rules let an invitee write a row
  ///   only for an invite addressed to them);
  /// - the userEmail of a row someone else wrote for them: one with no
  ///   inviteId and not assigned by themselves (the owner's or a super
  ///   admin's; an invitee writes a row only with an inviteId);
  /// - their own verified sign-in address, when they are removing themselves
  ///   (a support session ending).
  /// Never the userEmail of a row written through an invite: the invitee
  /// writes that one, and with someone else's address there had that
  /// person's invites cancelled along with their own removal.
  ///
  /// Only pending ones are returned: an accepted invite is what ties an
  /// address to a user here ([_hasAccessAt], and the next removal).
  /// [knownEmail] is one of those addresses (for the audit log), or null.
  static Future<
      ({List<DocumentReference<Map<String, dynamic>>> pendingInvites, String? knownEmail})>
      _pendingInvitesOf({
    required String userId,
    required String facilityId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> roleDocs,
  }) async {
    final invitesRef =
        _collection('facilities').doc(facilityId).collection(_facilityInvitesCollection);
    final self = _currentUser();
    final emails = <String>{
      for (final doc in roleDocs)
        if (!_writtenThroughInvite(doc.data(), userId))
          if (_normalizedEmail(doc.data()['userEmail']) case final email?) email,
      if (self != null && self.uid == userId && self.emailVerified)
        if (_normalizedEmail(self.email) case final email?) email,
    };
    final accepted = await invitesRef.where('acceptedBy', isEqualTo: userId).get();
    for (final doc in accepted.docs) {
      if (_normalizedEmail(doc.data()['emailLower']) case final email?) emails.add(email);
    }
    // The facility's pending invites, listed rather than read by id: the
    // rules refuse a get of an invite that no longer exists (Cancel Invite
    // deletes it), even to the owner, and one refused read failed the whole
    // removal, so a row naming a cancelled invite made its user unremovable.
    final pending = (await invitesRef.where('status', isEqualTo: 'pending').get()).docs;
    // And the address on the invite each row was written for. Before the
    // rules made an acceptance spend its invite, a row could be written with
    // no address and the invite left pending, and with nothing else to find
    // it by it survived the removal and let them straight back in. Its
    // address also finds any other pending invite to them.
    final rowInviteIds = <String>{
      for (final doc in roleDocs)
        if (doc.data()['inviteId'] case final String id when id.isNotEmpty) id,
    };
    for (final doc in pending) {
      if (!rowInviteIds.contains(doc.id)) continue;
      if (_normalizedEmail(doc.data()['emailLower']) case final email?) emails.add(email);
    }
    return (
      pendingInvites: [
        for (final doc in pending)
          if (emails.contains(_normalizedEmail(doc.data()['emailLower'])) ||
              doc.data()['invitedBy'] == userId)
            doc.reference,
      ],
      knownEmail: emails.isEmpty ? null : (emails.toList()..sort()).first,
    );
  }

  /// Whether the role row [row] of [userId] may carry an address the member
  /// wrote: one written through an invite (it names one; only an invitee's
  /// acceptance writes that), or one they assigned themselves.
  static bool _writtenThroughInvite(Map<String, dynamic> row, String userId) {
    final inviteId = row['inviteId'];
    return (inviteId is String && inviteId.isNotEmpty) || row['assignedBy'] == userId;
  }

  /// The auditLogs entry for [userId]'s removal from [facilityId] by the
  /// signed-in user, as [AuditService] writes one (the fields
  /// functions-shared's writeAuditLog writes, eventType and timestamp among
  /// them, plus those the rules require). Null when the signed-in user holds
  /// no role there: the rules take an entry only from the facility's staff,
  /// and a super admin with no role may still remove someone.
  static AuditLogEntry? _removalAuditEntry({
    required String facilityId,
    required Map<String, dynamic> facility,
    required String userId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> roleDocs,
    required String? knownEmail,
    required int invitesCancelled,
    required DateTime at,
  }) {
    final actor = _currentUser();
    if (actor == null) return null;
    final roles = facility['roles'];
    final managers = facility['managers'];
    String? mapRole(String uid) => roles is Map && roles[uid] is String ? roles[uid] as String : null;
    bool legacyManager(String uid) => managers is Map && managers[uid] == true;
    // Who the rules count as staff (isFacilityStaff).
    final actorRole = facility['ownerUid'] == actor.uid
        ? 'owner'
        : const {'owner', 'manager', 'admin', 'employee'}.contains(mapRole(actor.uid))
            ? mapRole(actor.uid)
            : legacyManager(actor.uid)
                ? 'manager'
                : null;
    if (actorRole == null) return null;
    final removedRole = mapRole(userId) ??
        (legacyManager(userId) ? 'manager' : null) ??
        (roleDocs.isEmpty ? null : roleDocs.first.data()['roleType'] as String?);
    return AuditLogEntry(
      eventType: removedMemberEventType,
      actorUid: actor.uid,
      actorEmail: actor.email,
      actorRole: actorRole,
      targetType: 'user',
      targetId: userId,
      facilityId: facilityId,
      before: {'role': removedRole},
      after: {'role': null},
      timestamp: at,
      metadata: {
        'removedUserId': userId,
        if (removedRole != null) 'removedRole': removedRole,
        if (knownEmail != null) 'removedEmail': knownEmail,
        'invitesCancelled': invitesCancelled,
      },
    );
  }

  /// The audit log's event type for a team member's removal ([removeRole]).
  static const String removedMemberEventType = 'team.memberRemoved';

  static String? _normalizedEmail(Object? raw) {
    if (raw is! String) return null;
    final email = raw.trim().toLowerCase();
    return email.isEmpty ? null : email;
  }

  // Get all users with roles for a facility
  static Future<List<UserRole>> getFacilityUsers(String facilityId) async {
    try {
      final querySnapshot = await _collection(_userRolesCollection)
          .where('facilityId', isEqualTo: facilityId)
          .where('isActive', isEqualTo: true)
          .get();

      return querySnapshot.docs.map((doc) {
        final data = doc.data();
        return UserRole(
          id: doc.id,
          userId: data['userId'] ?? '',
          facilityId: data['facilityId'] ?? '',
          roleType: roleTypeFromFirestoreString(data['roleType'] as String?),
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
      final snapshot = await _collection('facilities')
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
          final fallbackSnapshot = await _collection('facilities')
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

  /// Load a single invite by document id (works for signed-out users on pending invites; see Firestore rules).
  static Future<FacilityInvite?> getFacilityInviteById({
    required String facilityId,
    required String inviteId,
  }) async {
    try {
      final doc = await _collection('facilities')
          .doc(facilityId)
          .collection(_facilityInvitesCollection)
          .doc(inviteId)
          .get();
      if (!doc.exists) return null;
      return FacilityInvite.fromFirestore(doc: doc, facilityId: facilityId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PermissionService] getFacilityInviteById: $e');
      }
      return null;
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
      final invitesRef = _collection('facilities')
          .doc(facilityId)
          .collection(_facilityInvitesCollection);

      // Allow the facility owner to always invite
      final currentUser = _currentUser();
      if (currentUser == null) {
        return InviteResult(success: false, errorMessage: 'User not authenticated');
      }

      // Saved, and put in the email, only as the signed-in user's own verified
      // address, which is all the rules take: the invitee is shown who sent
      // it, and anyone can create a facility and invite any address.
      final senderEmail = currentUser.emailVerified && invitedByEmail == currentUser.email
          ? invitedByEmail
          : null;
      if (senderEmail != null) await refreshStaleEmailVerifiedClaim(currentUser);

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

      // Someone already on the team needs no invite, and one left pending for
      // them outlived their removal: its link gave the access back.
      if (await _hasAccessAt(
        facilityId: facilityId,
        emailLower: normalizedEmail,
        inviter: currentUser,
      )) {
        return InviteResult(
          success: false,
          errorMessage: '$email already has access to this facility. To change '
              'what they can do, use Change role on the Users tab.',
        );
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
            'invitedByEmail': senderEmail,
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
        invitedByEmail: senderEmail,
      );
      
      print('📧 [PermissionService] Email result: success=${emailResult.success}, error=${emailResult.errorMessage}');
      
      // Invite is created in Firestore regardless of email result
      return InviteResult(
        success: emailResult.success,
        errorMessage: emailResult.errorMessage,
        inviteSaved: true,
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating facility invite: $e');
      }
      return InviteResult(success: false, errorMessage: 'Error creating invite: $e');
    }
  }

  /// Whether [emailLower] already has a role at [facilityId]: it is the
  /// [inviter]'s own address, or it belongs to a user who holds a role there
  /// now (its owner, or in the facility's roles map, which [assignRole] and
  /// [removeRole] keep, or its legacy managers map). An address is tied to a
  /// user through an invite to it accepted there, the owner's users doc
  /// (readable by the owner and a super admin, who send the app's invites),
  /// or else its account, looked up server-side ([findUserIdByEmail]). The
  /// owner's own address was let through: assignRole keeps the owner role
  /// whatever an invite says, so that invite sat pending for ever.
  static Future<bool> _hasAccessAt({
    required String facilityId,
    required String emailLower,
    required User inviter,
  }) async {
    if (_normalizedEmail(inviter.email) == emailLower) return true;
    final facilityRef = _collection('facilities').doc(facilityId);
    final facility = (await facilityRef.get()).data() ?? const <String, dynamic>{};
    final roles = facility['roles'];
    final managers = facility['managers'];
    bool holdsRole(Object? uid) =>
        uid is String &&
        (uid == facility['ownerUid'] ||
            (roles is Map && roles[uid] != null) ||
            (managers is Map && managers[uid] == true));

    final accepted = await facilityRef
        .collection(_facilityInvitesCollection)
        .where('emailLower', isEqualTo: emailLower)
        .where('status', isEqualTo: 'accepted')
        .get();
    if (accepted.docs.any((doc) => holdsRole(doc.data()['acceptedBy']))) return true;
    final ownerUid = facility['ownerUid'];
    if (ownerUid is String && await _emailLowerOfUser(ownerUid) == emailLower) return true;
    // Last, as it is a round trip: null when there is no such account or the
    // lookup failed, which leaves the invite to go ahead as before.
    return holdsRole(await findUserIdByEmail(emailLower, facilityId: facilityId));
  }

  /// The email on `users/{uid}`, lower-cased, or null when there is none or
  /// the caller may not read it.
  static Future<String?> _emailLowerOfUser(String uid) async {
    if (uid.isEmpty) return null;
    try {
      final data = (await _collection(_usersCollection).doc(uid).get()).data();
      return _normalizedEmail(data?['emailLower']) ?? _normalizedEmail(data?['email']);
    } catch (_) {
      return null;
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
      
      await _collection('facilities')
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
      final inviteRef = _collection('facilities')
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
      final inviteRef = _collection('facilities')
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
      final roleType = roleTypeFromFirestoreString(roleTypeName);
      final invitedBy = data['invitedBy'] as String? ?? 'invite';
      final inviteEmail = data['email'] as String? ?? email ?? '';
      
      if (kDebugMode) {
        print('🔄 [PermissionService] Fulfilling specific invite: $inviteId for facility: $facilityId');
        print('   Email: $inviteEmail, Role: $roleTypeName');
      }
      
      // Assign the role; the same batch marks the invite accepted.
      final assigned = await assignRole(
        userId: userId,
        facilityId: facilityId,
        roleType: roleType,
        assignedBy: invitedBy,
        userDisplayName: displayName,
        userEmail: email ?? inviteEmail,
        fulfilledInviteId: inviteId,
      );

      if (assigned.success) {
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

  /// How long after it was last sent an invite may still be accepted without
  /// the invitee opening its link ([fulfillPendingInvitesForUser]). An older
  /// one still works through its link.
  static const Duration inviteAutoAcceptWindow = Duration(days: 30);

  /// Whether the invite [data] may be accepted without the invitee opening
  /// its link at [now]: pending, and sent within [inviteAutoAcceptWindow].
  /// With no send time it may not.
  static bool inviteAutoAcceptable(Map<String, dynamic> data, DateTime now) {
    if (data['status'] != 'pending') return false;
    final sent = data['lastSentAt'] ?? data['invitedAt'];
    if (sent is! Timestamp) return false;
    return now.difference(sent.toDate()) <= inviteAutoAcceptWindow;
  }

  /// Accepts the pending invites addressed to [emailLower] without the
  /// invitee opening a link (on signup, and on the route guard's first load),
  /// but only for a genuinely new invitee: no role row at any facility,
  /// active or not, and no facility of their own. Anyone else accepts through
  /// the invite's link ([fulfillSpecificInvite]). This used to accept every
  /// pending invite for every verified user with no owner account: existing
  /// staff were put on teams without a click, and a removed team member whose
  /// old invite was still pending got their access back.
  ///
  /// Only invites [inviteAutoAcceptable] are accepted. Never throws: false
  /// when a read failed or an invite it should have accepted was not, true
  /// otherwise (including when there was nothing it should accept).
  static Future<bool> fulfillPendingInvitesForUser({
    required String userId,
    required String emailLower,
    String? displayName,
    String? email,
  }) async {
    try {
      final invitesSnapshot = await _collectionGroup(_facilityInvitesCollection)
          .where('emailLower', isEqualTo: emailLower)
          .where('status', isEqualTo: 'pending')
          .get();

      if (kDebugMode) {
        print('📧 [PermissionService] Found ${invitesSnapshot.docs.length} pending invite(s)');
      }
      if (invitesSnapshot.docs.isEmpty) return true;

      if (!await _isNewInvitee(userId, {for (final doc in invitesSnapshot.docs) doc.id})) {
        if (kDebugMode) {
          print('⏭️ [PermissionService] $userId already has a role or facility; '
              'their invites are accepted through the link');
        }
        return true;
      }

      final now = DateTime.now();
      var allAccepted = true;
      var anyInviteAccepted = false;
      for (final doc in invitesSnapshot.docs) {
        final data = doc.data();
        if (!inviteAutoAcceptable(data, now)) continue;
        final facilityRef = doc.reference.parent.parent;
        if (facilityRef == null) continue;
        final facilityId = facilityRef.id;
        final roleTypeName = data['roleType'] as String? ?? RoleType.viewer.name;
        final roleType = roleTypeFromFirestoreString(roleTypeName);
        final invitedBy = data['invitedBy'] as String? ?? 'invite';

        try {
          // Marks the invite accepted in the same batch as the role.
          final assigned = await assignRole(
            userId: userId,
            facilityId: facilityId,
            roleType: roleType,
            assignedBy: invitedBy,
            userDisplayName: displayName,
            userEmail: email ?? emailLower,
            fulfilledInviteId: doc.id,
          );
          if (!assigned.success) {
            allAccepted = false;
            continue;
          }
          anyInviteAccepted = true;

          if (kDebugMode) {
            print('✅ [PermissionService] Auto-accepted invite for facility: $facilityId');
          }
        } catch (e) {
          allAccepted = false;
          if (kDebugMode) {
            print('❌ [PermissionService] Error accepting invite ${doc.id}: $e');
          }
        }
      }
      if (anyInviteAccepted) {
        FacilityService.clearFacilitiesCache();
      }
      return allAccepted;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [PermissionService] Error fulfilling invites for $emailLower: $e');
      }
      return false;
    }
  }

  /// The pending invites addressed to [user]'s email, for showing them their
  /// invitation links: whoever [fulfillPendingInvitesForUser] leaves alone
  /// (anyone who has had a role or a facility, and invites older than
  /// [inviteAutoAcceptWindow]) accepts through the link, and had no way to
  /// find it in the app. Empty for an unverified email, whose invites the
  /// rules will not list.
  static Future<List<FacilityInvite>> pendingInvitesFor(User user) async {
    final emailLower = user.emailVerified ? _normalizedEmail(user.email) : null;
    if (emailLower == null) return const [];
    await refreshStaleEmailVerifiedClaim(user);
    final snapshot = await _collectionGroup(_facilityInvitesCollection)
        .where('emailLower', isEqualTo: emailLower)
        .where('status', isEqualTo: 'pending')
        .get();
    final invites = [
      for (final doc in snapshot.docs)
        if (doc.reference.parent.parent case final facility?)
          FacilityInvite.fromFirestore(doc: doc, facilityId: facility.id),
    ];
    // Not one to a facility they are on already (left over from before they
    // joined): it offered a manager "Join X as Employee", and opening it
    // rewrote their role with the invite's.
    final onTeam = await Future.wait([
      for (final invite in invites) holdsRoleAt(facilityId: invite.facilityId, userId: user.uid),
    ]);
    return [
      for (var i = 0; i < invites.length; i++)
        if (!onTeam[i]) invites[i],
    ];
  }

  /// Whether [userId] holds a role at [facilityId] now: its owner, or in its
  /// roles or legacy managers map (what the rules read). False when the
  /// facility cannot be read, which is what the rules do to anyone without
  /// one.
  static Future<bool> holdsRoleAt({
    required String facilityId,
    required String userId,
  }) async {
    try {
      final facility = (await _collection('facilities').doc(facilityId).get()).data();
      if (facility == null) return false;
      final roles = facility['roles'];
      final managers = facility['managers'];
      return facility['ownerUid'] == userId ||
          (roles is Map && roles[userId] != null) ||
          (managers is Map && managers[userId] == true);
    } catch (_) {
      return false;
    }
  }

  /// No role row for [userId] at any facility, active or not, and no
  /// facility of their own. An active row written for one of
  /// [pendingInviteIds] does not count: that is an acceptance that stopped
  /// part-way before [assignRole] wrote everything in one batch (the row, but
  /// not the roles map or the invite), and treating it as a role left the
  /// invitee locked out with nothing to retry it.
  static Future<bool> _isNewInvitee(String userId, Set<String> pendingInviteIds) async {
    final results = await Future.wait([
      // Not limit(1): the first row may be a half-accepted one, and a row
      // after it a real role. Bounded all the same.
      _collection(_userRolesCollection).where('userId', isEqualTo: userId).limit(20).get(),
      _collection('facilities').where('ownerUid', isEqualTo: userId).limit(1).get(),
    ]);
    final onlyHalfAccepted = results[0].docs.every((doc) =>
        doc.data()['isActive'] == true && pendingInviteIds.contains(doc.data()['inviteId']));
    return onlyHalfAccepted && results[1].docs.isEmpty;
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
        final hint = EmailService.staffEmailFailureHint(result);
        print('❌ [PermissionService] Error sending invite email: $hint');
        print('❌ [PermissionService] Error code: ${result.errorCode}');
        return EmailSendResult(
          success: false,
          errorMessage: hint,
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

  /// The facility's name when the invite was written (for the invitee, who
  /// cannot read the facility until they join).
  final String? facilityName;

  /// Whether [PermissionService.fulfillPendingInvitesForUser] may accept it
  /// without the link, as of when it was read. Pending but not this: it is
  /// older than [PermissionService.inviteAutoAcceptWindow] and only its link
  /// accepts it.
  final bool autoAcceptable;

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
    this.facilityName,
    this.autoAcceptable = false,
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
      roleType: PermissionService.roleTypeFromFirestoreString(
        data['roleType'] as String? ?? RoleType.viewer.name,
      ),
      status: data['status'] as String? ?? 'pending',
      invitedAt: (data['invitedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      invitedBy: data['invitedBy'] as String?,
      invitedByEmail: data['invitedByEmail'] as String?,
      acceptedAt: (data['acceptedAt'] as Timestamp?)?.toDate(),
      acceptedBy: data['acceptedBy'] as String?,
      lastSentAt: (data['lastSentAt'] as Timestamp?)?.toDate(),
      facilityName: data['facilityName'] as String?,
      autoAcceptable: PermissionService.inviteAutoAcceptable(data, DateTime.now()),
    );
  }
}
