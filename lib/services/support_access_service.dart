import 'package:firebase_auth/firebase_auth.dart';

import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/services/active_facility_service.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';

/// Lets a super admin work inside a facility they do not own, in order to set
/// it up for the owner, without signing in as that owner.
///
/// The mechanism is deliberately boring: the super admin is granted a normal
/// manager role on the facility, exactly like any other staff member. That
/// means every screen, permission check and Firestore rule behaves as it
/// already does, with no special cases and no new access paths to audit. It
/// also means the access is *visible*: the owner sees a manager on their team
/// and an entry in their own audit log, rather than a silent session that
/// looks like them.
///
/// Compare impersonation, which mints a token for the owner. That hides who
/// really did the work, which is the wrong trade when the facility holds
/// tenant names and card data.
class SupportAccessService {
  /// Role granted for support work. Manager, not owner: it carries every
  /// permission needed to build out units and tenants, without implying the
  /// facility changed hands.
  static const RoleType supportRole = RoleType.manager;

  static User? get _currentUser => FirebaseAuth.instance.currentUser;

  static bool get isSuperAdmin => SuperAdminService.isSuperAdmin(_currentUser);

  /// Grants the current super admin manager access to [facilityId], records it
  /// in the facility's own audit log, and makes it the active facility so the
  /// normal screens open on it.
  static Future<void> start({
    required String facilityId,
    required String facilityName,
  }) async {
    final user = _currentUser;
    if (user == null) {
      throw Exception('Not signed in.');
    }
    if (!SuperAdminService.isSuperAdmin(user)) {
      throw Exception('Only super admins can start a support session.');
    }

    final result = await PermissionService.assignRole(
      userId: user.uid,
      facilityId: facilityId,
      roleType: supportRole,
      assignedBy: user.uid,
      userDisplayName: user.displayName ?? user.email ?? 'Platform support',
      userEmail: user.email,
    );
    if (!result.success) {
      throw Exception(result.errorMessage ?? 'Could not grant support access.');
    }

    // Written before anything is changed in the facility, so the owner's log
    // shows support arriving ahead of whatever support did.
    await AuditService.logEvent(
      facilityId: facilityId,
      eventType: 'support_access_started',
      targetType: 'facility',
      targetId: facilityId,
      actorRole: 'super_admin',
      metadata: {
        'facilityName': facilityName,
        'supportEmail': user.email ?? '',
        'role': supportRole.name,
      },
    );

    await ActiveFacilityService.setActiveFacilityId(facilityId);
  }

  /// Removes the support role again and steps back out to all facilities.
  static Future<void> end({
    required String facilityId,
    required String facilityName,
  }) async {
    final user = _currentUser;
    if (user == null) return;

    // Logged while the role still grants write access to the audit log.
    await AuditService.logEvent(
      facilityId: facilityId,
      eventType: 'support_access_ended',
      targetType: 'facility',
      targetId: facilityId,
      actorRole: 'super_admin',
      metadata: {
        'facilityName': facilityName,
        'supportEmail': user.email ?? '',
      },
    );

    await PermissionService.removeRole(
      userId: user.uid,
      facilityId: facilityId,
    );

    await ActiveFacilityService.setActiveFacilityId(null);
  }
}
