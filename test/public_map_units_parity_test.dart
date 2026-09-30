// ignore_for_file: subtype_of_sealed_class

import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_public_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';

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

const _publicMapPath = 'publicFacilityMaps/fac1-storage';

/// The unit and tenant docs of one fixture case, as fake collections.
List<FakeDoc> _docs(Object? raw) => [
      for (final d in (raw! as List<Object?>).cast<Map<String, Object?>>())
        FakeDoc(
          d['id']! as String,
          Map<String, dynamic>.from(d['data']! as Map),
        ),
    ];

void main() {
  // The same file functions-public-website/src/test/
  // publicFacilityMapInventorySync.test.ts runs through the Cloud Function
  // sync. Both write publicFacilityMaps/{slug}.units, and have disagreed
  // before (tenant isActive, archived); a rule changed on one side only fails
  // that side's test.
  final fixture = jsonDecode(
    File('test/fixtures/public_map_units.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = fixture['cases']! as List<Object?>;

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
  });
  tearDown(() {
    FacilityPublicService.firestoreForTesting = null;
    FacilityPublicService.authForTesting = null;
    FacilityMapV2Service.firestoreForTesting = null;
    FacilityMapV2Service.authForTesting = null;
    FacilitySubcollections.overrideForTesting(null);
  });

  test('the fixture has the cases the two sides share', () {
    expect(cases.length, greaterThanOrEqualTo(10));
  });

  for (final raw in cases) {
    final c = raw! as Map<String, Object?>;
    test('app publish matches the Cloud Function sync: ${c['name']}',
        () async {
      final collections = {
        'units': FakeCollection(_docs(c['units'])),
        'tenants': FakeCollection(_docs(c['tenants'])),
      };
      FacilitySubcollections.overrideForTesting(
        (facilityId, name) => collections[name]!,
      );

      // The app's own refresh (refreshPublicMapInventoryFromLiveUnits, run
      // after every unit write), with no settings doc (the defaults): its
      // unit and tenant reads, the tenant claims and the list it writes. The
      // publish builds the list through the same publicUnitInventory.
      store.put('facilities/fac1/mapEngine/meta', {
        'facilityId': 'fac1',
        'publicSlug': 'fac1-storage',
      });
      store.put(_publicMapPath, {'facilityId': 'fac1', 'units': <Object>[]});
      await FacilityMapV2Service.refreshPublicMapInventoryFromLiveUnits('fac1');
      final maps = (store.data(_publicMapPath)!['units'] as List)
          .cast<Map<String, dynamic>>();

      // The fields each unit's entry names (isRentable and status in all of
      // them); a unit the fixture does not expect shows up as an extra key.
      final expected = c['expected']! as Map<String, Object?>;
      expect(
        {
          for (final m in maps)
            m['unitId']: {
              for (final field in (expected[m['unitId']] as Map?)?.keys ??
                  const ['isRentable', 'status'])
                field: m[field],
            },
        },
        expected,
      );
    });
  }
}
