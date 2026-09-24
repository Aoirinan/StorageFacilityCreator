import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_stats_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';

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
  // The same file functions-facility-ops/src/test/facility_stats.test.ts
  // runs through the Cloud Function's read and count. A rule changed on one
  // side only fails that side's test.
  final fixture = jsonDecode(
    File('test/fixtures/unit_occupancy_counts.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = fixture['cases']! as List<Object?>;

  setUp(() {
    final auth =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
    UnitService.authForTesting = auth;
    TenantService.authForTesting = auth;
  });
  tearDown(() {
    UnitService.authForTesting = null;
    TenantService.authForTesting = null;
    FacilitySubcollections.overrideForTesting(null);
  });

  test('the fixture has the cases the two sides share', () {
    expect(cases.length, greaterThanOrEqualTo(5));
  });

  for (final raw in cases) {
    final c = raw! as Map<String, Object?>;
    test('app counts match the Cloud Function: ${c['name']}', () async {
      final collections = {
        'units': FakeCollection(_docs(c['units'])),
        'tenants': FakeCollection(_docs(c['tenants'])),
      };
      FacilitySubcollections.overrideForTesting(
        (facilityId, name) => collections[name]!,
      );

      // What the facility cards and yield screen call: the real unit and
      // tenant reads, then countUnits.
      final counts = await FacilityStatsService.computeUnitCounts('fac1');

      final expected = c['expected']! as Map<String, Object?>;
      expect(
        {
          'totalUnits': counts.totalUnits,
          'occupiedUnits': counts.occupiedUnits
        },
        expected,
      );
    });
  }
}
