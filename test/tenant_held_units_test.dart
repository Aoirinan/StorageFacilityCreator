import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/utils/unit_areas.dart';
import 'package:sfcapp/utils/unit_label.dart';

// All names are made up. One tenant record holds several units: each unit's
// tenantId points at the record, and the record's unitNumber names only the
// first. The screens showed that one alone, so a person renting two units
// looked like a person renting one.

UnitModel _unit(
  String id,
  String number, {
  String? tenantId = 't1',
  String? area,
  UnitStatus status = UnitStatus.occupied,
}) =>
    UnitModel(
      id: id,
      facilityId: 'f1',
      unitNumber: number,
      unitType: 'standard',
      status: status,
      tenantId: tenantId,
      monthlyRate: 55,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner',
      area: area,
    );

TenantModel _tenant({
  String unitNumber = 'C2-6',
  String? unitId = 'u6',
  String? unitArea,
}) =>
    TenantModel(
      id: 't1',
      facilityId: 'f1',
      name: 'Pat Example',
      email: '',
      phone: '',
      unitNumber: unitNumber,
      unitId: unitId,
      unitArea: unitArea,
      monthlyRate: 110,
      createdAt: DateTime(2026, 3, 25),
    );

void main() {
  group('the units a tenant holds beyond the one their record names', () {
    test('by number, leaving out the named unit, a freed unit whose tenantId was left behind, and other tenants\' units', () {
      final index = TenantUnitAreaIndex([
        _unit('u6', 'C2-6'),
        _unit('u10', 'C2-10'),
        _unit('u7', 'C2-7'),
        _unit('u12', 'C2-12', status: UnitStatus.available),
        _unit('u8', 'C2-8', tenantId: 't2'),
        _unit('u9', 'C2-9', tenantId: null),
      ]);
      expect(index.otherUnitsFor(_tenant()).map((u) => u.unitNumber), ['C2-7', 'C2-10']);
    });

    test('an imported record with no unitId names its unit by number', () {
      final index = TenantUnitAreaIndex([_unit('u6', 'C2-6'), _unit('u7', 'C2-7')]);
      expect(index.otherUnitsFor(_tenant(unitId: null)).map((u) => u.unitNumber), ['C2-7']);
    });

    test('a record with no unit number holds its units all the same', () {
      final index = TenantUnitAreaIndex([_unit('u6', 'C2-6'), _unit('u7', 'C2-7')]);
      expect(index.otherUnitsFor(_tenant(unitNumber: '', unitId: null)).map((u) => u.unitNumber), ['C2-6', 'C2-7']);
    });
  });

  group('tenantHeldUnitLabels', () {
    final index = TenantUnitAreaIndex([
      _unit('u6', 'C2-6', area: 'Complex 2'),
      _unit('u7', 'C2-7', area: 'Complex 2'),
      _unit('o1', 'OUT-1', area: 'Outdoor'),
    ]);

    test('the record\'s unit first, then the rest, each with its unit doc', () {
      final labels = tenantHeldUnitLabels(_tenant(), units: index, includeArea: false);
      expect(labels.map((l) => l.label), ['C2-6', 'C2-7', 'OUT-1']);
      expect(labels.map((l) => l.unit?.id), ['u6', 'u7', 'o1']);
    });

    test('with the area setting on, each label carries its area', () {
      expect(
        tenantHeldUnitLabels(_tenant(), units: index, includeArea: true).map((l) => l.label),
        ['C2-6 (Complex 2)', 'C2-7 (Complex 2)', 'OUT-1 (Outdoor)'],
      );
    });

    test('units not loaded: the record\'s unit alone, with nothing to link to', () {
      expect(tenantHeldUnitLabels(_tenant(), units: null, includeArea: false), [(label: 'C2-6', unit: null)]);
      expect(tenantHeldUnitLabels(_tenant(unitNumber: ''), units: null, includeArea: false), isEmpty);
    });

    test('a record with no unit number lists what it holds; none at all is empty', () {
      expect(
        tenantHeldUnitLabels(_tenant(unitNumber: '', unitId: null), units: index, includeArea: false).map((l) => l.label),
        ['C2-6', 'C2-7', 'OUT-1'],
      );
      expect(
        tenantHeldUnitLabels(_tenant(unitNumber: '', unitId: null), units: TenantUnitAreaIndex(const []), includeArea: false),
        isEmpty,
      );
    });

    test('two units numbered alike read as one with the setting off, two with it on', () {
      final alike = TenantUnitAreaIndex([
        _unit('a12', '12', area: 'Complex 2'),
        _unit('b12', '12', area: 'Outdoor'),
      ]);
      final t = _tenant(unitNumber: '12', unitId: 'a12', unitArea: 'Complex 2');
      expect(tenantHeldUnitLabels(t, units: alike, includeArea: false).map((l) => l.label), ['12']);
      expect(
        tenantHeldUnitLabels(t, units: alike, includeArea: true).map((l) => l.label),
        ['12 (Complex 2)', '12 (Outdoor)'],
      );
    });

    test('a record with no unitId holding two units numbered alike: no third, bare entry', () {
      // The number names neither unit (TenantUnitAreaIndex.namedUnit is
      // null), so both are "other" units; the record's bare "12" used to be
      // listed in front of them.
      final alike = TenantUnitAreaIndex([
        _unit('a12', '12', area: 'Complex 2'),
        _unit('b12', '12', area: 'Outdoor'),
      ]);
      final t = _tenant(unitNumber: '12', unitId: null);
      final on = tenantHeldUnitLabels(t, units: alike, includeArea: true);
      expect(on.map((l) => l.label), ['12 (Complex 2)', '12 (Outdoor)']);
      expect(on.map((l) => l.unit?.id), ['a12', 'b12']);
      final off = tenantHeldUnitLabels(t, units: alike, includeArea: false);
      expect(off.map((l) => l.label), ['12']);
      expect(off.single.unit?.id, 'a12');
    });
  });

  group('the Assign Tenant picker\'s unit line', () {
    test('always names the area, like the unit being assigned', () {
      final index = TenantUnitAreaIndex([
        _unit('u6', 'C2-6', area: 'Complex 2'),
        _unit('u7', 'C2-7', area: 'Complex 2'),
      ]);
      expect(tenantPickerUnitsText(_tenant(), index), 'Units C2-6 (Complex 2), C2-7 (Complex 2)');
      expect(
        tenantPickerUnitsText(_tenant(), TenantUnitAreaIndex([_unit('u6', 'C2-6')])),
        'Unit C2-6',
      );
      expect(tenantPickerUnitsText(_tenant(unitNumber: '', unitId: null), TenantUnitAreaIndex(const [])), 'No unit');
    });
  });

  group('Tenants list unit line with every held unit', () {
    final other = _unit('u7', 'C2-7', area: 'Complex 2');
    final outdoor = _unit('o1', 'OUT-1', area: 'Outdoor');

    test('off: the numbers, then the areas as before', () {
      expect(tenantListUnitLine(_tenant(), includeArea: false, otherUnits: [other]), 'Unit: C2-6, C2-7');
      expect(
        tenantListUnitLine(_tenant(), includeArea: false, areas: const ['Complex 2'], otherUnits: [other]),
        'Unit: C2-6, C2-7 · Complex 2',
      );
      // No leading comma for a record with no unit number of its own.
      expect(tenantListUnitLine(_tenant(unitNumber: ''), includeArea: false, otherUnits: [other]), 'Unit: C2-7');
    });

    test('on: each label carries its area, so only areas of units not listed follow the dot', () {
      expect(
        tenantListUnitLine(_tenant(unitArea: 'Complex 2'),
            includeArea: true, areas: const ['Complex 2'], otherUnits: [other]),
        'Unit: C2-6 (Complex 2), C2-7 (Complex 2)',
      );
      expect(
        tenantListUnitLine(_tenant(unitArea: 'Complex 2'),
            includeArea: true, areas: const ['Complex 2', 'Outdoor'], otherUnits: [outdoor]),
        'Unit: C2-6 (Complex 2), OUT-1 (Outdoor)',
      );
      // The record's own unit has no area on file: that area still follows.
      expect(
        tenantListUnitLine(_tenant(), includeArea: true, areas: const ['Complex 2', 'Outdoor'], otherUnits: [outdoor]),
        'Unit: C2-6, OUT-1 (Outdoor) · Complex 2',
      );
    });

    test('a record with no unitId holding two units numbered alike: no third, bare number', () {
      // The list has no unit for the label (namedUnit is null), and both
      // held units are "other" units carrying the record's number.
      final complex = _unit('a12', '12', area: 'Complex 2');
      final outdoor12 = _unit('b12', '12', area: 'Outdoor');
      final t = _tenant(unitNumber: '12', unitId: null);
      expect(
        tenantListUnitLine(t,
            includeArea: true, areas: const ['Complex 2', 'Outdoor'], otherUnits: [complex, outdoor12]),
        'Unit: 12 (Complex 2), 12 (Outdoor)',
      );
      expect(
        tenantListUnitLine(t,
            includeArea: false, areas: const ['Complex 2', 'Outdoor'], otherUnits: [complex, outdoor12]),
        'Unit: 12, 12 · Complex 2, Outdoor',
      );
      // With a unit behind the label, the same two units read as before.
      final named = _tenant(unitNumber: '12', unitId: 'a12', unitArea: 'Complex 2');
      expect(
        tenantListUnitLine(named,
            includeArea: true, areas: const ['Complex 2', 'Outdoor'], labelUnit: complex, otherUnits: [outdoor12]),
        'Unit: 12 (Complex 2), 12 (Outdoor)',
      );
    });
  });
}
