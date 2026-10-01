import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/permission_model.dart';
import '../services/permission_service.dart';

/// Whether the signed-in user may permanently delete tenants at this facility.
final canDeleteTenantAtFacilityProvider = FutureProvider.family<bool, String>((ref, facilityId) async {
  if (facilityId.isEmpty || facilityId == 'all') return false;
  final check = await PermissionService.hasPermission(
    permission: PermissionType.deleteTenant,
    facilityId: facilityId,
  );
  return check.hasPermission;
});

/// Whether the signed-in user may run a move-out at this facility. The
/// processMoveOut callable admits the owner and managers, the roles that
/// hold [PermissionType.processMoveOut].
final canProcessMoveOutAtFacilityProvider = FutureProvider.family<bool, String>((ref, facilityId) async {
  if (facilityId.isEmpty || facilityId == 'all') return false;
  final check = await PermissionService.hasPermission(
    permission: PermissionType.processMoveOut,
    facilityId: facilityId,
  );
  return check.hasPermission;
});

/// Whether the signed-in user may refund a tenant's card payment from the
/// ledger at this facility. The processRefund callable admits the
/// facility's owner and its managers, the roles that hold
/// [PermissionType.processRefund]. [PermissionType.issueRefund] is the
/// owner's alone (no other role lists it), so it would hide Refund from
/// managers the server lets refund.
final canRefundCardPaymentsAtFacilityProvider = FutureProvider.family<bool, String>((ref, facilityId) async {
  if (facilityId.isEmpty || facilityId == 'all') return false;
  final check = await PermissionService.hasPermission(
    permission: PermissionType.processRefund,
    facilityId: facilityId,
  );
  return check.hasPermission;
});

/// Whether [role] may write tenant docs in bulk. The tenants update rule
/// (firestore-rules-src/facilities/01-tenants.rules) admits owners and
/// managers only, so an employee's bulk save would be refused part way.
bool canBulkUpdateTenantsForRole(RoleType? role) =>
    role == RoleType.owner || role == RoleType.manager;

/// Whether the signed-in user may run bulk tenant updates (Paid through)
/// at this facility: owners and managers, as the Firestore rules allow.
final canBulkUpdateTenantsAtFacilityProvider = FutureProvider.family<bool, String>((ref, facilityId) async {
  if (facilityId.isEmpty || facilityId == 'all') return false;
  final check = await PermissionService.hasPermission(
    permission: PermissionType.editTenant,
    facilityId: facilityId,
  );
  return check.hasPermission && canBulkUpdateTenantsForRole(check.userRole);
});
