import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';

/// The facility a super admin is currently working inside on someone else's
/// behalf, or null when there is no such session.
///
/// "Someone else's" is the whole test: a super admin working in their own
/// facility is just an owner, and should see no banner.
final supportSessionFacilityProvider = FutureProvider<FacilityModel?>((ref) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null || !SuperAdminService.isSuperAdmin(user)) return null;

  final activeId = ref.watch(activeFacilityIdProvider).asData?.value;
  if (activeId == null || activeId.isEmpty) return null;

  final facility = await FacilityService.getFacility(activeId);
  if (facility == null) return null;
  if (facility.ownerUid == user.uid) return null;

  return facility;
});
