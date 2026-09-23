import 'package:sfcapp/services/active_facility_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';

/// The static caches that hold one signed-in account's data.
///
/// None of them were cleared on sign-out, so a second account signing in on
/// the same tab was served the first account's facility list and route-guard
/// access result for up to 2 minutes, and started on its active facility.
/// Each cache is now also keyed by uid, so a sign-out path that skips this
/// (several call FirebaseAuth.signOut directly) still cannot leak across
/// accounts; clearing here just frees the memory straight away.
class UserSessionCaches {
  UserSessionCaches._();

  static void clearAll() {
    FacilityService.clearFacilitiesCache();
    ActiveFacilityService.clearCache();
    SubscriptionGuardService.routeGuardCache.clear();
  }
}
