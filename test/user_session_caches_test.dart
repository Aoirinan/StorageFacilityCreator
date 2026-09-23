import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/active_facility_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';
import 'package:sfcapp/services/user_session_caches.dart';

void main() {
  tearDown(UserSessionCaches.clearAll);

  test('sign-out clears the facility list, route-guard result and active facility', () {
    // None of these were cleared on sign-out before, so the next account on
    // the same tab inherited all three.
    FacilityService.debugSeedFacilitiesCache('uid-A', [
      FacilityModel(id: 'f1', name: 'A Storage', ownerUid: 'uid-A', createdAt: DateTime(2026)),
    ]);
    SubscriptionGuardService.routeGuardCache
        .store('uid-A', const SubscriptionAccessResult(canAccess: true));
    ActiveFacilityService.debugSeedCache('uid-A', 'f1');

    UserSessionCaches.clearAll();

    expect(FacilityService.cachedFacilitiesFor('uid-A'), isNull);
    expect(SubscriptionGuardService.routeGuardCache.freshFor('uid-A'), isNull);
    expect(ActiveFacilityService.cachedActiveFacilityIdFor('uid-A'), isNull);
  });

  group('active facility selection is per account', () {
    test('the in-memory id is only returned for the account that set it', () {
      ActiveFacilityService.debugSeedCache('uid-A', 'f1');
      expect(ActiveFacilityService.cachedActiveFacilityIdFor('uid-A'), 'f1');
      expect(ActiveFacilityService.cachedActiveFacilityIdFor('uid-B'), isNull);
    });

    test('a selection saved by another account is not used', () {
      expect(
        ActiveFacilityService.localSelectionBelongsTo(savedByUid: 'uid-A', currentUid: 'uid-B'),
        isFalse,
      );
      expect(
        ActiveFacilityService.localSelectionBelongsTo(savedByUid: 'uid-A', currentUid: 'uid-A'),
        isTrue,
      );
    });

    test('a selection saved before the owner was recorded still works, as before', () {
      expect(
        ActiveFacilityService.localSelectionBelongsTo(savedByUid: null, currentUid: 'uid-A'),
        isTrue,
      );
      // Read before auth has restored: keep today's behaviour rather than
      // dropping every signed-in user to "All Facilities".
      expect(
        ActiveFacilityService.localSelectionBelongsTo(savedByUid: 'uid-A', currentUid: null),
        isTrue,
      );
    });
  });
}
