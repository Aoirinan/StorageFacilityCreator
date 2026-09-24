import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/overlock_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/unit_service.dart';

import 'support/fake_facility_collection.dart';

UnitModel _read(Map<String, dynamic> data) =>
    UnitModel.fromFirestore(FakeDoc('u1', {'unitNumber': '1', ...data}));

UnitModel _built(UnitStatus status) => UnitModel(
      id: 'u1',
      facilityId: 'fac1',
      unitNumber: '1',
      unitType: 'standard',
      status: status,
      monthlyRate: 100,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'test',
    );

void main() {
  group('UnitModel status', () {
    test('status still reads anything unrecognised as available', () {
      // The dashboard, Units list and map read status this way, and the stats
      // function compares the raw string exactly; only the public rental list
      // goes by storedStatus.
      for (final raw in [null, '', 'Available', 'Occupied', 1]) {
        expect(_read({'status': raw}).status, UnitStatus.available,
            reason: '$raw');
      }
      expect(_read({}).status, UnitStatus.available);
      expect(_read({'status': 'occupied'}).status, UnitStatus.occupied);
    });

    test('storedStatus is the stored string, or empty when there is none', () {
      expect(_read({'status': 'Available'}).storedStatus, 'Available');
      expect(_read({'status': ' reserved '}).storedStatus, ' reserved ');
      expect(_read({}).storedStatus, '');
      for (final raw in [null, 1, true, <String>['available']]) {
        expect(_read({'status': raw}).storedStatus, '', reason: '$raw');
      }
      expect(_built(UnitStatus.occupied).storedStatus, isNull);
    });

    test('copyWith keeps storedStatus unless it sets the status', () {
      final unit = _read({'status': 'Available'});
      expect(unit.copyWith(monthlyRate: 5).storedStatus, 'Available');
      final moved = unit.copyWith(status: UnitStatus.occupied);
      expect(moved.status, UnitStatus.occupied);
      expect(moved.storedStatus, isNull);
    });

    test('a unit built in code is published by its status', () {
      final maps = FacilityMapV2Service.buildPublicUnitInventoryMaps(
        units: [
          _built(UnitStatus.reserved),
          _built(UnitStatus.outOfOrder).copyWith(id: 'u2'),
          _read({}).copyWith(id: 'u3', status: UnitStatus.available),
        ],
        publicSettings: null,
      );
      final byId = {for (final m in maps) m['unitId']: m};
      expect(byId['u1']!['isRentable'], isTrue);
      expect(byId['u1']!['status'], 'reserved');
      expect(byId['u1']!['internalStatus'], 'reserved');
      expect(byId['u2']!['isRentable'], isFalse);
      expect(byId['u2']!['status'], 'unavailable');
      expect(byId['u2']!['internalStatus'], 'outOfOrder');
      expect(byId['u3']!['isRentable'], isTrue);
    });
  });

  // Before, each of these threw (a TypeError or NoSuchMethodError), and
  // UnitService builds a facility's units in one pass: one such unit emptied
  // the Units list (getUnitsForFacility returns [] on a throw) and failed the
  // public map publish and refresh.
  group('UnitModel reads a field of the wrong type without throwing', () {
    test('unitNumber: a number as its text, as the server String()s it', () {
      expect(_read({'unitNumber': 101}).unitNumber, '101');
      expect(_read({'unitNumber': 12.5}).unitNumber, '12.5');
      expect(_read({'unitNumber': {'n': 1}}).unitNumber, '');
      expect(_read({'unitNumber': null}).unitNumber, '');
    });

    test('monthlyRate: a string holding a number is that number, else 0', () {
      expect(_read({'monthlyRate': '100'}).monthlyRate, 100);
      expect(_read({'monthlyRate': ' 75.50 '}).monthlyRate, 75.5);
      for (final raw in ['call us', '', true, <int>[100], double.nan]) {
        expect(_read({'monthlyRate': raw}).monthlyRate, 0, reason: '$raw');
      }
      expect(_read({'securityDeposit': '50'}).securityDeposit, 50);
      expect(_read({'securityDeposit': 'none'}).securityDeposit, isNull);
    });

    test('text fields: a number or bool as its text, anything else missing',
        () {
      final unit = _read({
        'facilityId': 7,
        'unitType': 5,
        'tenantName': 42,
        'description': 12,
        'notes': true,
        'reservedBy': 3,
        'createdBy': 4,
        'updatedBy': 6,
      });
      expect(unit.facilityId, '7');
      expect(unit.unitType, '5');
      expect(unit.tenantName, '42');
      expect(unit.description, '12');
      expect(unit.notes, 'true');
      expect(unit.reservedBy, '3');
      expect(unit.createdBy, '4');
      expect(unit.updatedBy, '6');

      final junk = _read({
        for (final f in [
          'facilityId',
          'unitType',
          'tenantName',
          'description',
          'notes',
          'reservedBy',
          'createdBy',
          'updatedBy',
        ])
          f: <String>['x'],
      });
      expect(junk.facilityId, '');
      expect(junk.unitType, 'standard');
      expect(junk.tenantName, isNull);
      expect(junk.description, isNull);
      expect(junk.notes, isNull);
      expect(junk.reservedBy, isNull);
      expect(junk.createdBy, '');
      expect(junk.updatedBy, isNull);
    });

    test('tenantId: only a string links a tenant, as the server reads it', () {
      // The public map sync and the stats function ignore a non-string
      // tenantId; reading 5 as '5' would mark the unit rented only here.
      expect(_read({'tenantId': 5}).tenantId, isNull);
      expect(_read({'tenantId': true}).tenantId, isNull);
      expect(_read({'tenantId': 't1'}).tenantId, 't1');
    });

    test('features, dimensions and customFields', () {
      expect(_read({'features': ['Alarm', 1, null, <String, int>{}]}).features,
          ['Alarm', '1']);
      expect(_read({'features': 'climate'}).features, isNull);
      expect(_read({'dimensions': '10x10'}).dimensions, isNull);
      expect(_read({'customFields': 'none'}).customFields, isNull);
      expect(
        _read({
          'dimensions': {'width': 10, 'depth': '15'},
        }).dimensions,
        {'width': 10, 'depth': '15'},
      );
    });

    test('dates: a string or number reads as no date', () {
      final unit = _read({
        'lastMaintenance': '2026-01-01',
        'nextMaintenance': 5,
        'moveInDate': 1700000000000,
        'moveOutDate': true,
        'moveOutNoticeDate': <String>[],
        'reservationExpiry': '2026-02-01',
      });
      expect(unit.lastMaintenance, isNull);
      expect(unit.nextMaintenance, isNull);
      expect(unit.moveInDate, isNull);
      expect(unit.moveOutDate, isNull);
      expect(unit.moveOutNoticeDate, isNull);
      expect(unit.reservationExpiry, isNull);

      // createdAt and updatedAt fall back to now, as when they are missing.
      final before = DateTime.now();
      final stamped = _read({'createdAt': '2026-01-01', 'updatedAt': 5});
      expect(stamped.createdAt.isBefore(before), isFalse);
      expect(stamped.updatedAt.isBefore(before), isFalse);

      // A DateTime (what a test or local write holds) is kept.
      expect(_read({'moveInDate': DateTime(2026, 3, 4)}).moveInDate,
          DateTime(2026, 3, 4));
    });

    test('mapLayout and overlock', () {
      expect(_read({'mapLayout': 'left'}).mapX, isNull);
      final laid = _read({
        'mapLayout': {'x': '5', 'y': 'top', 'width': 40, 'height': null},
      });
      expect(laid.mapX, 5);
      expect(laid.mapY, isNull);
      expect(laid.mapWidth, 40);
      expect(laid.mapHeight, isNull);

      expect(_read({'overlock': 'yes'}).overlock, isNull);
      final locked = _read({
        'overlock': {
          'isOverlocked': true,
          'updatedAt': 'yesterday',
          'updatedByUid': 9,
          'updatedByName': <String>[],
          'reasonNote': 'late',
          'lastAction': 1,
        },
      }).overlock!;
      expect(locked.isOverlocked, isTrue);
      expect(locked.updatedAt, isNull);
      expect(locked.updatedByUid, '9');
      expect(locked.updatedByName, isNull);
      expect(locked.reasonNote, 'late');
      expect(locked.lastAction, isNull);
    });

    test('a well-formed doc reads exactly as before', () {
      final t = DateTime(2026, 5, 6, 7, 8);
      final unit = _read({
        'facilityId': 'fac1',
        'unitNumber': 'A1',
        'unitType': 'climateControlled',
        'status': 'occupied',
        'tenantId': 't1',
        'tenantName': 'Al',
        'monthlyRate': 125,
        'securityDeposit': 50.5,
        'description': 'Corner',
        'dimensions': {'width': 10, 'height': 8, 'depth': 15},
        'features': ['Alarm'],
        'notes': '',
        'moveInDate': Timestamp.fromDate(t),
        'reservedBy': 'u9',
        'customFields': {'gate': '12'},
        'createdAt': Timestamp.fromDate(t),
        'updatedAt': Timestamp.fromDate(t),
        'createdBy': 'owner-1',
        'updatedBy': 'owner-2',
        'mapLayout': {'x': 1, 'y': 2.5, 'width': 30, 'height': 20},
        'overlock': {
          'isOverlocked': true,
          'updatedAt': Timestamp.fromDate(t),
          'updatedByUid': 'owner-1',
          'lastAction': 'OVERLOCKED',
        },
      });
      expect(unit.facilityId, 'fac1');
      expect(unit.unitNumber, 'A1');
      expect(unit.unitType, 'climateControlled');
      expect(unit.status, UnitStatus.occupied);
      expect(unit.tenantId, 't1');
      expect(unit.tenantName, 'Al');
      expect(unit.monthlyRate, 125.0);
      expect(unit.securityDeposit, 50.5);
      expect(unit.description, 'Corner');
      expect(unit.dimensions, {'width': 10, 'height': 8, 'depth': 15});
      expect(unit.dimensionsDisplay, '10" × 8" × 15"');
      expect(unit.features, ['Alarm']);
      expect(unit.notes, '');
      expect(unit.moveInDate, t);
      expect(unit.lastMaintenance, isNull);
      expect(unit.reservedBy, 'u9');
      expect(unit.customFields, {'gate': '12'});
      expect(unit.createdAt, t);
      expect(unit.updatedAt, t);
      expect(unit.createdBy, 'owner-1');
      expect(unit.updatedBy, 'owner-2');
      expect([unit.mapX, unit.mapY, unit.mapWidth, unit.mapHeight],
          [1, 2.5, 30, 20]);
      expect(unit.overlock!.isOverlocked, isTrue);
      expect(unit.overlock!.updatedAt, t);
      expect(unit.overlock!.lastAction, OverlockAction.overlocked);

      final bare = _read({});
      expect(bare.facilityId, '');
      expect(bare.unitType, 'standard');
      expect(bare.monthlyRate, 0);
      expect(bare.securityDeposit, isNull);
      expect(bare.tenantId, isNull);
      expect(bare.dimensions, isNull);
      expect(bare.features, isNull);
      expect(bare.overlock, isNull);
      expect(bare.mapX, isNull);
    });

    test('one malformed unit no longer empties the facility read', () async {
      FacilitySubcollections.overrideForTesting(
        (facilityId, name) => FakeCollection([
          FakeDoc('good', {'unitNumber': 'A1', 'monthlyRate': 100}),
          FakeDoc('imported', {
            'unitNumber': 101,
            'monthlyRate': '95',
            'createdAt': '2026-01-01',
            'features': 'climate',
          }),
        ]),
      );
      addTearDown(() => FacilitySubcollections.overrideForTesting(null));

      final units = await UnitService.readFacilityUnits('fac1');

      expect({for (final u in units) u.id: u.unitNumber},
          {'good': 'A1', 'imported': '101'});
      expect(units.firstWhere((u) => u.id == 'imported').monthlyRate, 95);
    });
  });

  group('UnitModel.publicListingEnabled', () {
    test('only an exact false unlists, and nothing else fails the read', () {
      expect(_read({'publicListingEnabled': false}).publicListingEnabled,
          isFalse);
      // Before: `as bool?` threw on 'false' and 0, failing the whole unit
      // read, so the Units list came back empty and the public map publish
      // failed.
      for (final raw in [true, null, 'false', 0, 'no']) {
        expect(_read({'publicListingEnabled': raw}).publicListingEnabled,
            isTrue,
            reason: '$raw');
      }
      expect(_read({}).publicListingEnabled, isTrue);
    });
  });
}
