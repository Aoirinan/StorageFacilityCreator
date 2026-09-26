import 'dart:io';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/transfer_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/transfer_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/utils/unit_number.dart';

import 'support/fake_facility_collection.dart';
import 'support/fake_facility_firestore.dart';

final _day = DateTime(2026, 9, 1);

UnitModel _unit(String id, String number, UnitStatus status, String? tenantId) =>
    UnitModel(
      id: id,
      facilityId: 'f1',
      unitNumber: number,
      unitType: 'standard',
      status: status,
      tenantId: tenantId,
      monthlyRate: 100,
      createdAt: _day,
      updatedAt: _day,
      createdBy: 'owner',
    );

TenantModel _tenant(String id, String unitNumber) => TenantModel(
      id: id,
      facilityId: 'f1',
      name: 'Ada Park',
      email: '',
      phone: '',
      unitNumber: unitNumber,
      monthlyRate: 100,
      createdAt: _day,
    );

TransferModel _transfer() => TransferModel(
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

void main() {
  test('unitNumberKey: trimmed, ignoring case', () {
    expect(unitNumberKey(' 12A '), '12a');
    expect(sameUnitNumber('12a', ' 12A'), isTrue);
    expect(sameUnitNumber('12', '120'), isFalse);
  });

  group('UnitService unit numbers', () {
    late FakeFacilityFirestore db;

    void serve(List<FakeDoc> units, {List<FakeDoc> tenants = const []}) {
      db = FakeFacilityFirestore('f1', {'units': units, 'tenants': tenants});
      FacilitySubcollections.overrideForTesting((facilityId, name) {
        expect(facilityId, 'f1');
        return db.sub(name);
      });
    }

    List<(String, String, Map<String, dynamic>)> unitWrites() =>
        db.sub('units').log.writes;

    setUp(() {
      UnitService.authForTesting =
          MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner'));
    });
    tearDown(() {
      UnitService.authForTesting = null;
      FacilitySubcollections.overrideForTesting(null);
    });

    Future<String> create(String number) => UnitService.createUnit(
          facilityId: 'f1',
          unitNumber: number,
          unitType: 'standard',
          monthlyRate: 50,
        );

    test('createUnit refuses a number another unit has in another case or with spaces', () async {
      // The check was exact, so "12a" went in beside "12A".
      serve([FakeDoc('u1', {'unitNumber': '12A', 'status': 'available'})]);
      await expectLater(
        create('12a'),
        throwsA(isA<DuplicateUnitNumberException>().having((e) => e.message, 'message',
            'Unit number 12a already exists in this facility (as 12A). Nothing was saved. Use a different number.')),
      );
      await expectLater(create(' 12A '), throwsA(isA<DuplicateUnitNumberException>()));
      expect(unitWrites(), isEmpty);
    });

    test('createUnit still refuses an archived unit\'s number, as before', () async {
      serve([FakeDoc('u1', {'unitNumber': '12', 'archived': true})]);
      await expectLater(create('12'), throwsA(isA<DuplicateUnitNumberException>()));
      expect(unitWrites(), isEmpty);
    });

    test('createUnit makes a unit with a number no other unit has', () async {
      serve([FakeDoc('u1', {'unitNumber': '12', 'status': 'available'})]);
      await create('120');
      expect(unitWrites().single.$1, 'set');
    });

    test('renaming a unit onto another live unit\'s number is refused', () async {
      // It was not checked at all: the next tenant edit by number could
      // then take either unit.
      serve([
        FakeDoc('u1', {'unitNumber': '12', 'status': 'available'}),
        FakeDoc('u2', {'unitNumber': '14b', 'status': 'available'}),
      ]);
      await expectLater(
        UnitService.updateUnit(facilityId: 'f1', unitId: 'u1', unitNumber: '14B'),
        throwsA(isA<DuplicateUnitNumberException>()),
      );
      expect(unitWrites(), isEmpty);
    });

    test('renaming onto an archived unit\'s number, or saving an unchanged number, is allowed', () async {
      serve([
        FakeDoc('u1', {'unitNumber': '12', 'status': 'available'}),
        FakeDoc('u2', {'unitNumber': '14', 'archived': true}),
        FakeDoc('u3', {'unitNumber': '99', 'status': 'available'}),
        FakeDoc('u4', {'unitNumber': '99', 'status': 'available'}),
      ]);
      await UnitService.updateUnit(facilityId: 'f1', unitId: 'u1', unitNumber: '14');
      expect(db.data('units', 'u1')!['unitNumber'], '14');
      // A duplicate left from before is not checked on an unrelated save.
      await UnitService.updateUnit(
          facilityId: 'f1', unitId: 'u3', unitNumber: '99', notes: 'x');
      expect(db.data('units', 'u3')!['notes'], 'x');
    });

    test('renaming a unit renames its tenant\'s unit number, in one transaction', () async {
      // Renamed alone, the tenant's number named no unit and their next
      // edit created one.
      serve(
        [FakeDoc('u1', {'unitNumber': '12', 'status': 'occupied', 'tenantId': 't1'})],
        tenants: [FakeDoc('t1', {'name': 'Ada Park', 'unitNumber': '12'})],
      );
      await UnitService.updateUnit(facilityId: 'f1', unitId: 'u1', unitNumber: 'C3-12');
      expect(db.commits, 1);
      expect(db.data('units', 'u1')!['unitNumber'], 'C3-12');
      expect(db.data('tenants', 't1')!['unitNumber'], 'C3-12');
    });

    test('a case-only rename renames the tenant too', () async {
      serve(
        [FakeDoc('u1', {'unitNumber': '12a', 'status': 'occupied', 'tenantId': 't1'})],
        tenants: [FakeDoc('t1', {'unitNumber': '12A'})],
      );
      await UnitService.updateUnit(facilityId: 'f1', unitId: 'u1', unitNumber: '12A');
      expect(db.data('units', 'u1')!['unitNumber'], '12A');
      expect(db.data('tenants', 't1')!['unitNumber'], '12A');
    });

    test('a tenant whose unit number names another of their units is left alone', () async {
      serve(
        [FakeDoc('u1', {'unitNumber': '12', 'status': 'occupied', 'tenantId': 't1'})],
        tenants: [FakeDoc('t1', {'unitNumber': '7'})],
      );
      await UnitService.updateUnit(facilityId: 'f1', unitId: 'u1', unitNumber: '14');
      expect(db.data('units', 'u1')!['unitNumber'], '14');
      expect(db.data('tenants', 't1')!['unitNumber'], '7');
      expect(db.sub('tenants').log.writes, isEmpty);
    });

    test('renaming a unit nobody is in writes only the unit', () async {
      serve([FakeDoc('u1', {'unitNumber': '12', 'status': 'available'})],
          tenants: [FakeDoc('t1', {'unitNumber': '12'})]);
      await UnitService.updateUnit(facilityId: 'f1', unitId: 'u1', unitNumber: '14');
      expect(db.data('units', 'u1')!['unitNumber'], '14');
      expect(db.sub('tenants').log.writes, isEmpty);
    });
  });

  group('transfer: the unit moved out of', () {
    test("is one the tenant occupies, never another tenant's unit with their number", () {
      // The screen took the occupied unit numbered like the tenant (here
      // someone else's, their number being stale), and completing the
      // transfer freed it.
      final result = TransferService.transferFromUnit(_tenant('t1', '12'), [
        _unit('u12', '12', UnitStatus.occupied, 't2'),
        _unit('u7', '7', UnitStatus.occupied, 't1'),
      ]);
      expect(result.unit?.id, 'u7');
      expect(result.choices.map((u) => u.id), ['u7']);
    });

    test("with no unit of their own it is refused, not the facility's first unit", () {
      // It fell back to units.first: another tenant's unit.
      expect(
        () => TransferService.transferFromUnit(_tenant('t1', '12'), [
          _unit('u1', '1', UnitStatus.occupied, 't2'),
          _unit('u12', '12', UnitStatus.available, null),
        ]),
        throwsA(isA<TransferRefusedException>()
            .having((e) => e.message, 'message', startsWith('Ada Park has no unit assigned'))),
      );
    });

    test('several: the one with their unit number, else the operator picks', () {
      final units = [
        _unit('u7', '7', UnitStatus.occupied, 't1'),
        _unit('u12', '12', UnitStatus.lockout, 't1'),
      ];
      final named = TransferService.transferFromUnit(_tenant('t1', ' 12 '), units);
      expect(named.unit?.id, 'u12');
      expect(named.choices, hasLength(2));

      final unnamed = TransferService.transferFromUnit(_tenant('t1', '99'), units);
      expect(unnamed.unit, isNull);
      expect(unnamed.choices, hasLength(2));
    });

    test('completing is refused when the from-unit has changed hands since', () {
      final refusal = TransferService.completionRefusal(
        transfer: _transfer(),
        fromUnit: _unit('u12', '12', UnitStatus.occupied, 't2'),
        toUnit: _unit('u14', '14', UnitStatus.available, null),
      );
      expect(refusal?.message, startsWith('Unit 12 is no longer assigned to this tenant'));
      expect(
        TransferService.completionRefusal(
          transfer: _transfer(),
          fromUnit: null,
          toUnit: _unit('u14', '14', UnitStatus.available, null),
        ),
        isNotNull,
      );
    });

    test('completing is refused when the to-unit was taken since', () {
      final refusal = TransferService.completionRefusal(
        transfer: _transfer(),
        fromUnit: _unit('u12', '12', UnitStatus.occupied, 't1'),
        toUnit: _unit('u14', '14', UnitStatus.occupied, 't3'),
      );
      expect(refusal?.message, startsWith('Unit 14 is no longer available'));
    });

    test('completing goes ahead when both are as they were', () {
      expect(
        TransferService.completionRefusal(
          transfer: _transfer(),
          fromUnit: _unit('u12', '12', UnitStatus.occupied, 't1'),
          toUnit: _unit('u14', '14', UnitStatus.available, null),
        ),
        isNull,
      );
    });

    group("the tenant's rent and unit number after it", () {
      // _transfer(): unit 12 at $100 to unit 14 at $100; these use 14 at $80.
      TransferModel transfer() => _transfer().copyWith(toUnitRate: 80);

      test('their only unit: the new unit\'s rate and number, as before', () {
        final after = TransferService.tenantAfterTransfer(
          transfer: transfer(),
          currentRate: 95,
          currentUnitNumber: '12',
          otherUnits: const [],
        );
        expect(after.monthlyRate, 80);
        expect(after.unitNumber, '14');
      });

      test('with another unit: only the moved unit\'s rate changes, and a label on the kept unit stays', () {
        // Holding 7 and 12 at $200, moving 12 to 14: it set $80 and "14",
        // billing them for 14 alone while they held 7 and 14.
        final after = TransferService.tenantAfterTransfer(
          transfer: transfer(),
          currentRate: 200,
          currentUnitNumber: '7',
          otherUnits: [_unit('u7', '7', UnitStatus.occupied, 't1')],
        );
        expect(after.monthlyRate, 180);
        expect(after.unitNumber, isNull);
      });

      test('with another unit and the label on the unit they leave: the label moves', () {
        final after = TransferService.tenantAfterTransfer(
          transfer: transfer(),
          currentRate: 200,
          currentUnitNumber: '12',
          otherUnits: [_unit('u7', '7', UnitStatus.occupied, 't1')],
        );
        expect(after.monthlyRate, 180);
        expect(after.unitNumber, '14');
      });

      test('never below zero', () {
        // A discounted rent lower than the unit they leave: 10 - 100 + 80.
        final after = TransferService.tenantAfterTransfer(
          transfer: transfer(),
          currentRate: 10,
          currentUnitNumber: '7',
          otherUnits: [_unit('u7', '7', UnitStatus.occupied, 't1')],
        );
        expect(after.monthlyRate, 0);
      });

      test('completeTransfer uses it, with the other units read before the units change', () {
        final source = File('lib/services/transfer_service.dart').readAsStringSync();
        final complete = source.substring(source.indexOf('static Future<void> completeTransfer('));
        expect(complete, contains('tenantAfterTransfer('));
        expect(complete, isNot(contains('monthlyRate: transfer.toUnitRate')));
        expect(complete.indexOf('.linkedUnits(transfer.tenantId)'),
            lessThan(complete.indexOf("'status': TransferStatus.inProgress.name")));
      });
    });

    test('completeTransfer checks before it writes anything', () {
      // completeTransfer talks to Firestore directly, so pin the order in
      // its source: the refusal comes before the first write (the status
      // change), and the tenant's unit is then linked by id.
      final source = File('lib/services/transfer_service.dart').readAsStringSync();
      final check = source.indexOf('if (refusal != null) throw refusal;');
      final firstWrite = source.indexOf("'status': TransferStatus.inProgress.name");
      expect(check, greaterThan(0));
      expect(check, lessThan(firstWrite));
      expect(source, contains('unitId: transfer.toUnitId,'));
    });
  });
}
