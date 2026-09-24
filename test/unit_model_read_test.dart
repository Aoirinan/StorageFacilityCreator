import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';

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
