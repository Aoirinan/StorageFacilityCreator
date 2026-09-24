// ignore_for_file: subtype_of_sealed_class

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
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

  group('fitUnitsToDocument (port of the server guard)', () {
    Map<String, dynamic> unitMap(int n) => {
          'unitId': 'unit-$n',
          'unitNumber': '$n',
          'displayName': 'Unit $n',
          'status': 'available',
          'unitType': 'Climate Controlled 10x10',
          'description':
              'A reasonably wordy description, of the sort a real listing carries.',
          'monthlyRate': 129.0,
          'isRentable': true,
        };
    int bytes(List<Map<String, dynamic>> list) =>
        utf8.encode(jsonEncode(list)).length;

    test('a list that fits is published whole', () {
      final units = [for (var i = 0; i < 50; i++) unitMap(i)];
      final fitted = FacilityMapV2Service.fitUnitsToDocument(units);
      expect(fitted.published, hasLength(50));
      expect(fitted.omitted, 0);
    });

    test('a list that does not fit is trimmed from the end and counted', () {
      final units = [for (var i = 0; i < 5000; i++) unitMap(i)];
      final fitted =
          FacilityMapV2Service.fitUnitsToDocument(units, maxBytes: 50000);

      expect(fitted.published, isNotEmpty);
      expect(fitted.published.length, lessThan(units.length));
      expect(fitted.omitted, units.length - fitted.published.length);
      expect(bytes(fitted.published), lessThanOrEqualTo(50000));
      expect(
        [for (final u in fitted.published) u['unitId']],
        [for (final u in units.take(fitted.published.length)) u['unitId']],
      );
    });

    test('trimming stops at one unit when even one is over the ceiling', () {
      final units = [for (var i = 0; i < 8; i++) unitMap(i)];
      final fitted = FacilityMapV2Service.fitUnitsToDocument(units, maxBytes: 10);
      expect(fitted.published, hasLength(1));
      expect(fitted.omitted, 7);
    });

    test('the default ceiling matches the server', () {
      expect(FacilityMapV2Service.maxPublishedUnitsBytes, 700000);
      // The whole of the Firestore document cap (1 MiB) is never budgeted
      // to the list alone.
      expect(FacilityMapV2Service.maxPublishedUnitsBytes, lessThan(1048576));
    });
  });

  test('the publish and refresh payload is trimmed to fit and says so', () {
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);

    final units = [for (var i = 0; i < 400; i++) _model('u$i')];
    final inventory = FacilityMapV2Service.publicUnitInventory(
      facilityId: 'fac1',
      units: units,
      publicSettings: null,
      maxBytes: 20000,
    );

    // Before: the app wrote every unit, and a list past the document cap
    // failed the publish outright.
    expect(utf8.encode(jsonEncode(inventory.units)).length,
        lessThanOrEqualTo(20000));
    expect(inventory.units.length, lessThan(400));
    expect(inventory.unitsTotal, 400);
    expect(inventory.unitsOmitted, 400 - inventory.units.length);
    expect(reported, hasLength(1));
    expect(reported.single.exception.toString(), contains('fac1'));
  });

  test('a payload that fits is whole and reports nothing', () {
    final reported = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previous);

    final inventory = FacilityMapV2Service.publicUnitInventory(
      facilityId: 'fac1',
      units: [_model('A1'), _model('A2')],
      publicSettings: null,
    );

    expect([for (final u in inventory.units) u['unitId']], ['A1', 'A2']);
    expect(inventory.unitsTotal, 2);
    expect(inventory.unitsOmitted, 0);
    expect(reported, isEmpty);
  });
}
