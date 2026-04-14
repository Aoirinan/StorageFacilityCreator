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
