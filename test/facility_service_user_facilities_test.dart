import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/facility_service.dart';

FacilityModel _facility(String id, String name, {bool active = true}) {
  return FacilityModel(
    id: id,
    name: name,
    ownerUid: 'owner-1',
    createdAt: DateTime(2026),
    active: active,
  );
}

void main() {
  group('facilityBackfillUpdates (same rules as the old separate backfill query)', () {
    const uid = 'owner-1';

    test('fills a missing active flag and the owner role on owned facilities', () {
      final updates = FacilityService.facilityBackfillUpdates(uid, {
        'needs-both': {'ownerUid': uid, 'name': 'A'},
        'already-fine': {
          'ownerUid': uid,
          'active': true,
          'roles': {uid: 'owner'},
        },
        'wrong-role': {
          'ownerUid': uid,
          'active': false,
          'roles': {uid: 'manager', 'someone-else': 'staff'},
        },
      });

      expect(updates, {
        'needs-both': {'active': true, 'roles.$uid': 'owner'},
        'wrong-role': {'roles.$uid': 'owner'},
      });
    });

    test('never writes to a facility the user does not own', () {
      final updates = FacilityService.facilityBackfillUpdates(uid, {
        'other-owner': {'ownerUid': 'someone-else'},
        'no-owner': {'active': null},
      });
      expect(updates, isEmpty);
    });

    test('treats an archived facility as owned too (the query has no active filter)', () {
      final updates = FacilityService.facilityBackfillUpdates(uid, {
        'archived': {'ownerUid': uid, 'active': false},
      });
      expect(updates, {
        'archived': {'roles.$uid': 'owner'},
      });
    });
  });

  group('mergeUserFacilities', () {
    final owned = [
      _facility('z', 'Zeta Storage'),
      _facility('a', 'Alpha Storage', active: false),
      _facility('m', 'Mid Storage'),
    ];
    final fromRoles = [
      _facility('b', 'Beta Storage'),
      _facility('m', 'Mid Storage'), // also owned: ownership wins
      _facility('g', 'Gamma Storage', active: false),
    ];

    test('drops archived facilities in memory and sorts by name', () {
      // The owner query no longer filters active == true or orders by
      // (active, name) (an index firestore.indexes.json never declared), so
      // both jobs happen here.
      final list = FacilityService.mergeUserFacilities(
        owned: owned,
        fromRoles: fromRoles,
        includeArchived: false,
      );
      expect(list.map((f) => f.name), ['Beta Storage', 'Mid Storage', 'Zeta Storage']);
      expect(
        {for (final f in list) f.id: f.currentUserOwnsFacility},
        {'b': false, 'm': true, 'z': true},
      );
    });

    test('keeps archived facilities when asked', () {
      final list = FacilityService.mergeUserFacilities(
        owned: owned,
        fromRoles: fromRoles,
        includeArchived: true,
      );
      expect(list.map((f) => f.id), ['a', 'b', 'g', 'm', 'z']);
    });

    test('a facility with no active field counts as active, as the backfill makes it', () {
      // FacilityModel reads a missing `active` as true.
      final list = FacilityService.mergeUserFacilities(
        owned: [_facility('n', 'No Flag')],
        fromRoles: const [],
        includeArchived: false,
      );
      expect(list.map((f) => f.id), ['n']);
    });
  });

  group('facility list cache is per account', () {
    tearDown(FacilityService.clearFacilitiesCache);

    test('a cached list is never handed to a different uid', () {
      // The bug: one unkeyed static list, so the next account to sign in on
      // the tab was shown the previous account's facilities for 2 minutes.
      FacilityService.debugSeedFacilitiesCache('uid-A', [_facility('f1', 'A Storage')]);

      expect(FacilityService.cachedFacilitiesFor('uid-A'), hasLength(1));
      expect(FacilityService.cachedFacilitiesFor('uid-B'), isNull);
    });

    test('clearFacilitiesCache empties it', () {
      FacilityService.debugSeedFacilitiesCache('uid-A', [_facility('f1', 'A Storage')]);
      FacilityService.clearFacilitiesCache();
      expect(FacilityService.cachedFacilitiesFor('uid-A'), isNull);
    });
  });
}
