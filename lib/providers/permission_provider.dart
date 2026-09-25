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
