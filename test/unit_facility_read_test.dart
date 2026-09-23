import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/unit_service.dart';

import 'support/fake_facility_collection.dart';

FakeDoc _unit(String id, {String? unitNumber, Object? archived}) => FakeDoc(id, {
      'facilityId': 'fac1',
      if (unitNumber != null) 'unitNumber': unitNumber,
      'unitType': 'standard',
      'status': 'available',
      if (archived != null) 'archived': archived,
    });

/// 100 archived units that sort first by number, 350 live ones, one live
/// unit with no unitNumber, one with no archived field, and one whose
/// archived field is a stray string.
List<FakeDoc> _bigFacility() => [
      for (var i = 0; i < 450; i++)
        _unit('u$i', unitNumber: 'U${i.toString().padLeft(3, '0')}', archived: i < 100),
      _unit('no-number', archived: false),
      _unit('legacy', unitNumber: 'L1'),
      _unit('stray', unitNumber: 'S1', archived: 'true'),
    ];

FakeQueryLog _serveUnits(List<FakeDoc> docs) {
  final log = FakeQueryLog();
  FacilitySubcollections.overrideForTesting((facilityId, name) {
    expect(name, 'units');
    return FakeCollection(docs, log: log);
  });
  return log;
}

void main() {
  setUp(() {
    UnitService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
  });
  tearDown(() {
    UnitService.authForTesting = null;
    FacilitySubcollections.overrideForTesting(null);
  });

  void expectEveryLiveUnit(List<String> ids, FakeQueryLog log) {
    // Before: orderBy('unitNumber').limit(400), with archived units dropped
    // after the cap: the 100 archived units used up a quarter of it, the
    // last 50 live units and the unit with no unitNumber were never read.
    expect(log.orderedBy, isEmpty);
    expect(ids, hasLength(352));
    expect(ids.first, 'no-number');
    expect(ids, containsAll(['u100', 'u449', 'legacy']));
    // Archived (and the stray non-boolean, as the Cloud Function treats it)
    // left out.
    expect(ids, isNot(contains('u0')));
    expect(ids, isNot(contains('stray')));
  }

  test('getUnitsForFacility reads every non-archived unit, sorted by number', () async {
    final log = _serveUnits(_bigFacility());

    final units = await UnitService.getUnitsForFacility('fac1');

    expectEveryLiveUnit([for (final u in units) u.id], log);
    expect(units[1].unitNumber, 'L1');
  });

  test('getUnitsForFacilityStream reads the same way', () async {
    final log = _serveUnits(_bigFacility());

    final units = await UnitService.getUnitsForFacilityStream('fac1').first;

    expectEveryLiveUnit([for (final u in units) u.id], log);
  });

  test('a facility that reaches the read bound is reported, not silently cut', () async {
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);

    const bound = FacilitySubcollections.readLimit;
    final log = _serveUnits([
      for (var i = 0; i < bound + 10; i++) _unit('u$i', unitNumber: '$i'),
    ]);

    final units = await UnitService.getUnitsForFacility('fac-huge-units');
    await UnitService.getUnitsForFacility('fac-huge-units');

    expect(log.limits.toSet(), {bound});
    expect(units, hasLength(bound));
    expect(reported, hasLength(1));
    expect(reported.single.exception.toString(), contains('fac-huge-units'));
  });
}
