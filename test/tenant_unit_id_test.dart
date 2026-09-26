import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/transfer_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/transfer_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/utils/unit_areas.dart';

import 'support/fake_facility_collection.dart';
import 'support/fake_facility_firestore.dart';

final _day = DateTime(2026, 9, 1);

UnitModel _unit(String id, String number, {String? area, String? tenantId}) => UnitModel(
      id: id,
      facilityId: 'f1',
      unitNumber: number,
      unitType: 'standard',
      status: tenantId == null ? UnitStatus.available : UnitStatus.occupied,
      tenantId: tenantId,
      monthlyRate: 100,
      createdAt: _day,
      updatedAt: _day,
      createdBy: 'owner',
      area: area,
    );

TenantModel _tenant(String id, String unitNumber, {String? unitId}) => TenantModel(
      id: id,
      facilityId: 'f1',
      name: 'Ada Park',
      email: '',
      phone: '',
      unitNumber: unitNumber,
      unitId: unitId,
      monthlyRate: 100,
      createdAt: _day,
    );

void main() {
  final deleted = FieldValue.delete();

  group('TenantModel.unitId and unitArea', () {
    TenantModel read(Map<String, dynamic> data) =>
        TenantModel.fromFirestore(FakeDoc('t1', {'unitNumber': '12', ...data}));

    test('read trimmed; blank, missing or not a string is null', () {
      final t = read({'unitId': ' u12 ', 'unitArea': '  Complex 2 '});
      expect(t.unitId, 'u12');
      expect(t.unitArea, 'Complex 2');
      for (final bad in [null, '', '   ', 7, true, <String>['u12']]) {
        final none = read({'unitId': bad, 'unitArea': bad});
        expect(none.unitId, isNull, reason: '$bad');
        expect(none.unitArea, isNull, reason: '$bad');
      }
      expect(read({}).unitId, isNull);
    });

    test('toFirestore writes them only when set', () {
      final withUnit = _tenant('t1', '12', unitId: 'u12').copyWith(unitArea: 'Complex 2').toFirestore();
      expect(withUnit['unitId'], 'u12');
      expect(withUnit['unitArea'], 'Complex 2');
      final none = _tenant('t1', '12').toFirestore();
      expect(none.containsKey('unitId'), isFalse);
      expect(none.containsKey('unitArea'), isFalse);
    });

    test('copyWith keeps, replaces or clears each', () {
      final t = _tenant('t1', '12', unitId: 'u12').copyWith(unitArea: 'Complex 2');
      expect(t.copyWith(name: 'Bo').unitId, 'u12');
      expect(t.copyWith(name: 'Bo').unitArea, 'Complex 2');
      expect(t.copyWith(unitId: 'u14').unitId, 'u14');
      expect(t.copyWith(clearUnitId: true).unitId, isNull);
      expect(t.copyWith(clearUnitArea: true).unitArea, isNull);
      expect(t.copyWith(clearUnitArea: true).unitId, 'u12');
    });

    test('primaryUnitUpdate: the unit and its area, or deletes', () {
      expect(TenantModel.primaryUnitUpdate(unitId: 'u12', unitArea: ' Complex 2 '),
          {'unitId': 'u12', 'unitArea': 'Complex 2'});
      expect(TenantModel.primaryUnitUpdate(unitId: 'u12', unitArea: ' '),
          {'unitId': 'u12', 'unitArea': deleted});
      expect(TenantModel.primaryUnitUpdate(), {'unitId': deleted, 'unitArea': deleted});
      // No unit, no area: an area alone would name nothing.
      expect(TenantModel.primaryUnitUpdate(unitId: '  ', unitArea: 'Complex 2'),
          {'unitId': deleted, 'unitArea': deleted});
    });

    test('primaryUnitCreate leaves out what has no value', () {
      expect(TenantModel.primaryUnitCreate(unitId: 'u12', unitArea: 'Complex 2'),
          {'unitId': 'u12', 'unitArea': 'Complex 2'});
      expect(TenantModel.primaryUnitCreate(unitId: 'u12'), {'unitId': 'u12'});
      expect(TenantModel.primaryUnitCreate(unitArea: 'Complex 2'), isEmpty);
    });
  });

  group('TenantUnitAreaIndex', () {
    test("prefers the tenant's unitId over their number", () {
      final index = TenantUnitAreaIndex([
        _unit('c2-12', 'C2-12', area: 'Complex 2'),
        _unit('c3-14', 'C3-14', area: 'Complex 3'),
      ]);
      // A label that names another unit (left stale): the unitId wins.
      final t = _tenant('t1', 'C2-12', unitId: 'c3-14');
      expect(index.namedUnit(t)?.id, 'c3-14');
      expect(index.areasFor(t), ['Complex 3']);
    });

    test('by number only when exactly one unit has it (trimmed, ignoring case)', () {
      final index = TenantUnitAreaIndex([
        _unit('c2-12', '12', area: 'Complex 2'),
        _unit('c3-12', ' 12 ', area: 'Complex 3'),
        _unit('u14', '14A', area: 'Outdoor'),
      ]);
      expect(index.namedUnit(_tenant('t1', '12')), isNull);
      expect(index.areasFor(_tenant('t1', '12')), isEmpty);
      expect(index.matches(_tenant('t1', '12'), 'Complex 2'), isFalse);
      expect(index.matches(_tenant('t1', '12'), noUnitAreaFilter), isTrue);
      expect(index.namedUnit(_tenant('t2', ' 14a'))?.id, 'u14');
      // With unitId the repeated number is no longer a guess.
      expect(index.areasFor(_tenant('t3', '12', unitId: 'c3-12')), ['Complex 3']);
    });

    test('a unitId that is not among the units falls back to the number', () {
      final index = TenantUnitAreaIndex([_unit('u14', '14', area: 'Outdoor')]);
      expect(index.namedUnit(_tenant('t1', '14', unitId: 'gone'))?.id, 'u14');
    });

    test('units they hold still count, each once', () {
      final index = TenantUnitAreaIndex([
        _unit('u12', '12', area: 'Complex 2', tenantId: 't1'),
        _unit('u14', '14', area: 'Complex 3', tenantId: 't1'),
      ]);
      expect(index.unitsFor(_tenant('t1', '12', unitId: 'u12')).map((u) => u.id), ['u12', 'u14']);
    });
  });

  group('UnitService.tenantFieldsForUnitChange', () {
    Map<String, dynamic>? fields(Map<String, dynamic> tenant,
            {bool isHolder = true, String? renamedTo, String? areaAfter = 'Complex 3'}) =>
        UnitService.tenantFieldsForUnitChange(
          unitId: 'u12',
          tenant: tenant,
          isHolder: isHolder,
          numberBefore: '12',
          renamedTo: renamedTo,
          areaAfter: areaAfter,
        );

    test('the tenant naming the unit by id gets its area, whether or not they are in it', () {
      expect(fields({'unitNumber': '12', 'unitId': 'u12'}, isHolder: false),
          {'unitId': 'u12', 'unitArea': 'Complex 3'});
      expect(fields({'unitNumber': '12', 'unitId': 'u12'}, areaAfter: null),
          {'unitId': 'u12', 'unitArea': deleted});
    });

    test('with no unitId: the tenant in it whose number names it, and they get the unitId too', () {
      expect(fields({'unitNumber': ' 12 '}), {'unitId': 'u12', 'unitArea': 'Complex 3'});
      expect(fields({'unitNumber': '12'}, isHolder: false), isNull);
      expect(fields({'unitNumber': '7'}), isNull);
      expect(fields({'unitNumber': ''}), isNull);
    });

    test('a tenant whose unitId names another unit is left alone by an area change', () {
      expect(fields({'unitNumber': '12', 'unitId': 'u7'}), isNull);
    });

    test('a rename renames the label that named it, as before, and links it by id', () {
      expect(fields({'unitNumber': '12'}, renamedTo: 'C3-12'),
          {'unitNumber': 'C3-12', 'unitId': 'u12', 'unitArea': 'Complex 3'});
      // Their label names another of their units: only the id link, if any.
      expect(fields({'unitNumber': '7', 'unitId': 'u12'}, renamedTo: 'C3-12'),
          {'unitId': 'u12', 'unitArea': 'Complex 3'});
      expect(fields({'unitNumber': '7'}, renamedTo: 'C3-12'), isNull);
    });
  });

  group('UnitService keeps tenants in step with their unit', () {
    late FakeFacilityFirestore db;

    void serve(List<FakeDoc> units, List<FakeDoc> tenants) {
      db = FakeFacilityFirestore('f1', {'units': units, 'tenants': tenants});
      FacilitySubcollections.overrideForTesting((facilityId, name) {
        expect(facilityId, 'f1');
        return db.sub(name);
      });
    }

    setUp(() {
      UnitService.authForTesting =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner'));
    });
    tearDown(() {
      UnitService.authForTesting = null;
      FacilitySubcollections.overrideForTesting(null);
    });

    test("Set area writes the tenant's unitArea in the same transaction", () async {
      serve(
        [FakeDoc('u12', {'unitNumber': '12', 'status': 'occupied', 'tenantId': 't1'})],
        [
          FakeDoc('t1', {'unitNumber': '12', 'unitId': 'u12'}),
          FakeDoc('t2', {'unitNumber': '9'}),
        ],
      );
      await UnitService.setUnitArea(facilityId: 'f1', unitId: 'u12', area: ' Complex 2 ');
      expect(db.commits, 1);
      expect(db.data('units', 'u12')!['area'], 'Complex 2');
      expect(db.data('tenants', 't1')!['unitArea'], 'Complex 2');
      expect(db.sub('tenants').log.writes.map((w) => w.$2), ['t1']);

      await UnitService.setUnitArea(facilityId: 'f1', unitId: 'u12', area: null);
      expect(db.data('tenants', 't1')!['unitArea'], deleted);
    });

    test('a tenant with no unitId in the unit, whose number names it, gets unitArea and unitId', () async {
      serve(
        [FakeDoc('u12', {'unitNumber': '12', 'status': 'occupied', 'tenantId': 't1'})],
        [FakeDoc('t1', {'unitNumber': '12'})],
      );
      await UnitService.setUnitArea(facilityId: 'f1', unitId: 'u12', area: 'Complex 2');
      expect(db.data('tenants', 't1')!['unitId'], 'u12');
      expect(db.data('tenants', 't1')!['unitArea'], 'Complex 2');
    });

    test('an area on a unit nobody names writes only the unit', () async {
      serve(
        [FakeDoc('u12', {'unitNumber': '12', 'status': 'available'})],
        [FakeDoc('t1', {'unitNumber': '12'})],
      );
      await UnitService.setUnitArea(facilityId: 'f1', unitId: 'u12', area: 'Complex 2');
      expect(db.sub('tenants').log.writes, isEmpty);
    });

    test('Edit Unit: a new area reaches the tenant too', () async {
      serve(
        [FakeDoc('u12', {'unitNumber': '12', 'status': 'occupied', 'tenantId': 't1'})],
        [FakeDoc('t1', {'unitNumber': '12', 'unitId': 'u12'})],
      );
      await UnitService.updateUnit(facilityId: 'f1', unitId: 'u12', area: 'Complex 3', notes: 'x');
      expect(db.commits, 1);
      expect(db.data('units', 'u12')!['notes'], 'x');
      expect(db.data('tenants', 't1')!['unitArea'], 'Complex 3');
    });

    test('Edit Unit without an area or number change touches no tenant', () async {
      serve(
        [FakeDoc('u12', {'unitNumber': '12', 'status': 'occupied', 'tenantId': 't1'})],
        [FakeDoc('t1', {'unitNumber': '12', 'unitId': 'u12'})],
      );
      await UnitService.updateUnit(facilityId: 'f1', unitId: 'u12', notes: 'x');
      expect(db.commits, 0);
      expect(db.sub('tenants').log.writes, isEmpty);
    });

    test('a rename renames the label and keeps unitId and the unit area on the tenant', () async {
      serve(
        [FakeDoc('u12', {'unitNumber': '12', 'status': 'occupied', 'tenantId': 't1', 'area': 'Complex 2'})],
        [FakeDoc('t1', {'unitNumber': '12'})],
      );
      await UnitService.updateUnit(facilityId: 'f1', unitId: 'u12', unitNumber: 'C2-12');
      expect(db.commits, 1);
      expect(db.data('tenants', 't1')!['unitNumber'], 'C2-12');
      expect(db.data('tenants', 't1')!['unitId'], 'u12');
      expect(db.data('tenants', 't1')!['unitArea'], 'Complex 2');
    });
  });

  test('a transfer that moves the label names the to-unit by id', () {
    final transfer = TransferModel(
      id: 'x1',
      facilityId: 'f1',
      tenantId: 't1',
      fromUnitId: 'u12',
      toUnitId: 'u14',
      fromUnitNumber: '12',
      toUnitNumber: '14',
      status: TransferStatus.pending,
      transferDate: _day,
      fromUnitProratedRent: 0,
      toUnitProratedRent: 0,
      fromUnitRate: 100,
      toUnitRate: 100,
      netAmount: 0,
      ledgerEntryIds: const [],
      createdAt: _day,
      createdBy: 'owner',
    );
    final only = TransferService.tenantAfterTransfer(
        transfer: transfer, currentRate: 100, currentUnitNumber: '12', otherUnits: const []);
    expect(only.unitId, 'u14');
    final moves = TransferService.tenantAfterTransfer(
        transfer: transfer,
        currentRate: 200,
        currentUnitNumber: '12',
        otherUnits: [_unit('u7', '7', tenantId: 't1')]);
    expect(moves.unitNumber, '14');
    expect(moves.unitId, 'u14');
    final stays = TransferService.tenantAfterTransfer(
        transfer: transfer,
        currentRate: 200,
        currentUnitNumber: '7',
        otherUnits: [_unit('u7', '7', tenantId: 't1')]);
    expect(stays.unitNumber, isNull);
    expect(stays.unitId, isNull);
  });
}
