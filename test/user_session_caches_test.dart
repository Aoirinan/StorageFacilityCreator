import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/active_facility_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';
import 'package:sfcapp/services/user_session_caches.dart';

typedef _SavedSelection = ({bool exists, String? facilityId});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserSessionCaches.clearAll();
  });
  tearDown(UserSessionCaches.clearAll);

  /// The production facility-list path with a counting fake read.
  var facilityReads = 0;
  Future<List<FacilityModel>> facilitiesFor(String uid) {
    return FacilityService.loadUserFacilitiesFor(
      currentUid: () => uid,
      fetch: (uid, {required includeArchived}) async {
        facilityReads += 1;
        return [
          FacilityModel(id: 'f-$uid', name: '$uid Storage', ownerUid: uid, createdAt: DateTime(2026)),
        ];
      },
    );
  }

  /// The production active-facility path with a fake users/{uid} doc.
  Future<String?> activeFacilityFor(
    String uid, {
    _SavedSelection saved = (exists: true, facilityId: null),
  }) {
    return ActiveFacilityService.activeFacilityIdFor(
      currentUid: () => uid,
      readUserDoc: (_) async => saved,
    );
  }

  test('sign-out clears the facility list, route-guard result and active facility', () async {
    // None of these were cleared on sign-out before, so the next account on
    // the same tab inherited all three.
    await facilitiesFor('uid-A');
    SubscriptionGuardService.routeGuardCache
        .store('uid-A', const SubscriptionAccessResult(canAccess: true));
    expect(await activeFacilityFor('uid-A', saved: (exists: true, facilityId: 'f1')), 'f1');

    UserSessionCaches.clearAll();

    facilityReads = 0;
    await facilitiesFor('uid-A');
    expect(facilityReads, 1, reason: 'the list is read again, not served from cache');
    expect(SubscriptionGuardService.routeGuardCache.freshFor('uid-A'), isNull);
    // With the in-memory copy gone the users doc decides again.
    SharedPreferences.setMockInitialValues({});
    expect(await activeFacilityFor('uid-A', saved: (exists: true, facilityId: 'f2')), 'f2');
  });

  group('active facility selection is per account', () {
    test('the in-memory id is only returned for the account that set it', () async {
      expect(await activeFacilityFor('uid-A', saved: (exists: true, facilityId: 'f1')), 'f1');
      // Same tab, next account, nothing cleared in between (a direct
      // FirebaseAuth.signOut). uid-A's selection is in memory and in
      // localStorage; neither may be used for uid-B.
      expect(await activeFacilityFor('uid-B', saved: (exists: false, facilityId: null)), isNull);
      expect(await activeFacilityFor('uid-B', saved: (exists: true, facilityId: 'f9')), 'f9');
    });

    test('the in-memory id is still served to its own account without a read', () async {
      var reads = 0;
      Future<String?> read() => ActiveFacilityService.activeFacilityIdFor(
            currentUid: () => 'uid-A',
            readUserDoc: (_) async {
              reads += 1;
              return (exists: true, facilityId: 'f1');
            },
          );
      expect(await read(), 'f1');
      expect(await read(), 'f1');
      expect(reads, 1);
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
