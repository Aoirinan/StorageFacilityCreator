// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_public_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/tenant_service.dart';

import 'support/fake_facility_collection.dart';
import 'support/fake_firestore_store.dart';

/// Serves [FakeStore]'s documents as Firestore.
class _StoreFirestore extends Fake implements FirebaseFirestore {
  _StoreFirestore(this.store);

  final FakeStore store;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      store.collection(path);
}

/// A tenants collection whose read fails the way one does offline.
class _UnreadableCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) =>
      this;

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future.error(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'));
}

const _metaPath = 'facilities/fac1/mapEngine/meta';
const _publicMapPath = 'publicFacilityMaps/main-street-storage';

/// Unit 101 is free on its own doc (available, no tenantId); only Al's unit
/// number says it is taken. Unit 102 is free.
final _units = [
  FakeDoc('u101', {
    'unitNumber': '101',
    'status': 'available',
    'unitType': 'standard',
  }),
  FakeDoc('u102', {
    'unitNumber': '102',
    'status': 'available',
    'unitType': 'standard',
  }),
];

final _tenants = [
  FakeDoc('al', {'name': 'Al', 'isActive': true, 'unitNumber': '101'}),
];

/// What the last good publish listed. A published map names its facility
/// (the snapshot writes facilityId), and the refresh leaves a doc that names
/// another facility, or none, alone (fix/public-slug-pointers), so without it
/// both refresh tests below passed without reading a tenant.
const Map<String, dynamic> _published = {
  'facilityId': 'fac1',
  'units': [
    {'unitId': 'u101', 'isRentable': false, 'status': 'rented'},
    {'unitId': 'u102', 'isRentable': true, 'status': 'available'},
  ],
  'unitsTotal': 2,
  'unitsOmitted': 0,
};

void main() {
  late FakeStore store;

  setUp(() {
    store = FakeStore();
    final firestore = _StoreFirestore(store);
    final auth =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
    FacilityPublicService.firestoreForTesting = firestore;
    FacilityPublicService.authForTesting = auth;
    FacilityMapV2Service.firestoreForTesting = firestore;
    FacilityMapV2Service.authForTesting = auth;
    TenantService.authForTesting = auth;
  });

  tearDown(() {
    FacilityPublicService.firestoreForTesting = null;
    FacilityPublicService.authForTesting = null;
    FacilityMapV2Service.firestoreForTesting = null;
    FacilityMapV2Service.authForTesting = null;
    TenantService.authForTesting = null;
    FacilitySubcollections.overrideForTesting(null);
  });

  void serveTenants(CollectionReference<Map<String, dynamic>> tenants) {
    final units = FakeCollection(_units);
    FacilitySubcollections.overrideForTesting(
      (facilityId, name) => name == 'tenants' ? tenants : units,
    );
  }

  Map<String, Object?> rentability(String path) => {
        for (final u in (store.data(path)!['units'] as List).cast<Map>())
          u['unitId'] as String: (u['isRentable'], u['status']),
      };

  group('when the tenants cannot be read', () {
    setUp(() => serveTenants(_UnreadableCollection()));

    test('a publish fails and writes nothing', () async {
      // No meta doc yet, which the publish would otherwise create.
      await expectLater(
        FacilityMapV2Service.publishCurrentDraft(facilityId: 'fac1'),
        throwsA(isA<FirebaseException>()
            .having((e) => e.code, 'code', 'unavailable')),
      );

      expect(store.writes, isEmpty);
    });

    test('the live-units refresh leaves the published units alone', () async {
      store.put(_metaPath, {
        'facilityId': 'fac1',
        'publicSlug': 'main-street-storage',
      });
      store.put(_publicMapPath, _published);

      await FacilityMapV2Service.refreshPublicMapInventoryFromLiveUnits(
          'fac1');

      // It used to see no tenants and list unit 101 as rentable.
      expect(store.writes, isEmpty);
      expect(store.data(_publicMapPath), _published);
    });

    test('getTenantsForFacility still returns [] for its display callers',
        () async {
      expect(await TenantService.getTenantsForFacility('fac1'), isEmpty);
      await expectLater(
        TenantService.getTenantsForFacilityOrThrow('fac1'),
        throwsA(isA<FirebaseException>()),
      );
    });
  });

  group('when the facility has more active tenants than one read returns', () {
    setUp(() => serveTenants(FakeCollection([
          for (var i = 0; i < FacilitySubcollections.readLimit; i++)
            FakeDoc('t$i', {'isActive': true, 'unitNumber': 'Z$i'}),
        ])));

    test('a publish fails and writes nothing', () async {
      // Past the cap a tenant holding unit 101 could be missing, and the
      // publish would list 101 as rentable.
      await expectLater(
        FacilityMapV2Service.publishCurrentDraft(facilityId: 'fac1'),
        throwsA(isA<StateError>()),
      );

      expect(store.writes, isEmpty);
    });

    test('the live-units refresh leaves the published units alone', () async {
      store.put(_metaPath, {
        'facilityId': 'fac1',
        'publicSlug': 'main-street-storage',
      });
      store.put(_publicMapPath, _published);

      await FacilityMapV2Service.refreshPublicMapInventoryFromLiveUnits(
          'fac1');

      expect(store.writes, isEmpty);
      expect(store.data(_publicMapPath), _published);
    });
  });

  test('only active tenants are read for claims, as the server counts them',
      () async {
    final log = FakeQueryLog();
    serveTenants(FakeCollection(_tenants, log: log));

    await FacilityMapV2Service.readActiveTenantsOrThrow('fac1');

    expect(log.equalityFilters, [('isActive', true)]);
  });

  test('the refresh lists a unit taken by a tenant\'s unit number as rented',
      () async {
    serveTenants(FakeCollection(_tenants));
    store.put(_metaPath, {
      'facilityId': 'fac1',
      'publicSlug': 'main-street-storage',
    });
    store.put(_publicMapPath, {
      ..._published,
      'units': [
        {'unitId': 'u101', 'isRentable': true, 'status': 'available'},
        {'unitId': 'u102', 'isRentable': true, 'status': 'available'},
      ],
    });

    await FacilityMapV2Service.refreshPublicMapInventoryFromLiveUnits('fac1');

    expect(store.writes, ['update $_publicMapPath']);
    expect(rentability(_publicMapPath), {
      'u101': (false, 'rented'),
      'u102': (true, 'available'),
    });
  });
}
