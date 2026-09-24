// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';

import 'support/fake_facility_collection.dart';

class _FailingUnits extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future.error(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'));
}

FakeDoc _unit(String id, {String? unitNumber, Object? archived}) =>
    FakeDoc(id, {
      'facilityId': 'fac1',
      if (unitNumber != null) 'unitNumber': unitNumber,
      'unitType': 'standard',
      'status': 'available',
      if (archived != null) 'archived': archived,
    });

UnitModel _model(
  String id, {
  bool publicListingEnabled = true,
  bool internalUse = false,
}) =>
    UnitModel(
      id: id,
      facilityId: 'fac1',
      unitNumber: id,
      unitType: 'standard',
      status: UnitStatus.available,
      monthlyRate: 100,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'test',
      publicListingEnabled: publicListingEnabled,
      internalUse: internalUse,
    );

void main() {
  tearDown(() => FacilitySubcollections.overrideForTesting(null));

  test('the public map reads every non-archived unit, as the Units list does',
      () async {
    final log = FakeQueryLog();
    FacilitySubcollections.overrideForTesting((facilityId, name) {
      expect(facilityId, 'fac1');
      expect(name, 'units');
      return FakeCollection([
        // 100 archived units that sort first, then 350 live ones.
        for (var i = 0; i < 450; i++)
          _unit('u$i',
              unitNumber: 'U${i.toString().padLeft(3, '0')}',
              archived: i < 100),
        _unit('no-number', archived: false),
        _unit('stray', unitNumber: 'S1', archived: 'true'),
      ], log: log);
    });

    final units = await FacilityMapV2Service.fetchActiveUnitsForTesting('fac1');
    final ids = [for (final u in units) u.id];

    // Before: orderBy('unitNumber').limit(400) with archived units dropped
    // after the cap, so the last 50 live units and the one with no number
    // never reached the public map.
    expect(log.orderedBy, isEmpty);
    expect(ids, hasLength(351));
    expect(ids.first, 'no-number');
    expect(ids, containsAll(['u100', 'u449']));
    expect(ids, isNot(contains('u0')));
    expect(ids, isNot(contains('stray')));
  });

  test('a failed unit read fails the publish instead of publishing no units',
      () async {
    FacilitySubcollections.overrideForTesting((_, __) => _FailingUnits());

    // Before: [] came back, and publish or the inventory refresh wrote an
    // empty unit list over the live public map.
    await expectLater(
      FacilityMapV2Service.fetchActiveUnitsForTesting('fac1'),
      throwsA(isA<FirebaseException>()),
    );
  });

  test('the public map offers only listed units that are not internal use',
      () {
    final maps = FacilityMapV2Service.buildPublicUnitInventoryMaps(
      units: [
        _model('listed'),
        _model('unlisted', publicListingEnabled: false),
        _model('office', internalUse: true, publicListingEnabled: false),
        _model('residence', internalUse: true),
      ],
      publicSettings: null,
    );
    final byId = {for (final m in maps) m['unitId']: m};
    expect(byId['listed']!['isRentable'], isTrue);
    expect(byId['unlisted']!['isRentable'], isFalse);
    expect(byId['unlisted']!['status'], 'unavailable');
    expect(byId['office']!['isRentable'], isFalse);
    expect(byId['office']!['status'], 'unavailable');
    // Before: only the website switch counted, so internal-use space left
    // listed was advertised as rentable and the online hold then refused it
    // (isUnitOfferedOnline). It reads as unlisted, and still publishes its
    // own switch.
    expect(byId['residence']!['isRentable'], isFalse);
    expect(byId['residence']!['status'], 'unavailable');
    expect(byId['residence']!['publicListingEnabled'], isTrue);
  });
}
