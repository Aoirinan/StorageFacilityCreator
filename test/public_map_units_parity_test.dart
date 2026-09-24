import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/tenant_service.dart';

import 'support/fake_facility_collection.dart';

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

  setUp(() {
    TenantService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
  });
  tearDown(() {
    TenantService.authForTesting = null;
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

      // What publish and refreshPublicMapInventoryFromLiveUnits do between
      // reading the public settings (none here: the defaults) and writing.
      final units =
          await FacilityMapV2Service.fetchActiveUnitsForTesting('fac1');
      final tenants = await TenantService.getTenantsForFacility('fac1');
      final maps = FacilityMapV2Service.buildPublicUnitInventoryMaps(
        units: units,
        publicSettings: null,
        tenantClaimedUnitNumbers:
            FacilityMapV2Service.claimedUnitNumbersFromActiveTenants(tenants),
      );

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
