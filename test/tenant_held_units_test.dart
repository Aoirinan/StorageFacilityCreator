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
      monthlyRate: 72,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner',
      area: area,
    );

TenantModel _tenant({
  String unitNumber = 'B-14',
  String? unitId = 'u14',
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
      monthlyRate: 144,
      createdAt: DateTime(2026, 4, 18),
    );

void main() {
  group('the units a tenant holds beyond the one their record names', () {
    test('by number, leaving out the named unit, a freed unit whose tenantId was left behind, and other tenants\' units', () {
      final index = TenantUnitAreaIndex([
        _unit('u14', 'B-14'),
        _unit('u104', 'B-104'),
        _unit('u15', 'B-15'),
        _unit('u16', 'B-16', status: UnitStatus.available),
        _unit('u17', 'B-17', tenantId: 't2'),
        _unit('u19', 'B-19', tenantId: null),
      ]);
      expect(index.otherUnitsFor(_tenant()).map((u) => u.unitNumber), ['B-15', 'B-104']);
    });

    test('an imported record with no unitId names its unit by number', () {
      final index = TenantUnitAreaIndex([_unit('u14', 'B-14'), _unit('u15', 'B-15')]);
      expect(index.otherUnitsFor(_tenant(unitId: null)).map((u) => u.unitNumber), ['B-15']);
    });

    test('a record with no unit number holds its units all the same', () {
      final index = TenantUnitAreaIndex([_unit('u14', 'B-14'), _unit('u15', 'B-15')]);
      expect(index.otherUnitsFor(_tenant(unitNumber: '', unitId: null)).map((u) => u.unitNumber), ['B-14', 'B-15']);
    });
  });

  group('tenantHeldUnitLabels', () {
    final index = TenantUnitAreaIndex([
      _unit('u14', 'B-14', area: 'Building B'),
      _unit('u15', 'B-15', area: 'Building B'),
      _unit('d3', 'D-3', area: 'Building D'),
    ]);

    test('the record\'s unit first, then the rest, each with its unit doc', () {
      final labels = tenantHeldUnitLabels(_tenant(), units: index, includeArea: false);
      expect(labels.map((l) => l.label), ['B-14', 'B-15', 'D-3']);
      expect(labels.map((l) => l.unit?.id), ['u14', 'u15', 'd3']);
    });

    test('with the area setting on, each label carries its area', () {
      expect(
        tenantHeldUnitLabels(_tenant(), units: index, includeArea: true).map((l) => l.label),
        ['B-14 (Building B)', 'B-15 (Building B)', 'D-3 (Building D)'],
      );
    });

    test('units not loaded: the record\'s unit alone, with nothing to link to', () {
      expect(tenantHeldUnitLabels(_tenant(), units: null, includeArea: false), [(label: 'B-14', unit: null)]);
      expect(tenantHeldUnitLabels(_tenant(unitNumber: ''), units: null, includeArea: false), isEmpty);
    });

    test('a record with no unit number lists what it holds; none at all is empty', () {
      expect(
        tenantHeldUnitLabels(_tenant(unitNumber: '', unitId: null), units: index, includeArea: false).map((l) => l.label),
        ['B-14', 'B-15', 'D-3'],
      );
      expect(
        tenantHeldUnitLabels(_tenant(unitNumber: '', unitId: null), units: TenantUnitAreaIndex(const []), includeArea: false),
        isEmpty,
      );
    });

    test('two units numbered alike read as one with the setting off, two with it on', () {
      final alike = TenantUnitAreaIndex([
        _unit('a12', '12', area: 'Building B'),
        _unit('b12', '12', area: 'Building D'),
      ]);
      final t = _tenant(unitNumber: '12', unitId: 'a12', unitArea: 'Building B');
      expect(tenantHeldUnitLabels(t, units: alike, includeArea: false).map((l) => l.label), ['12']);
      expect(
        tenantHeldUnitLabels(t, units: alike, includeArea: true).map((l) => l.label),
        ['12 (Building B)', '12 (Building D)'],
      );
    });

    test('a record with no unitId holding two units numbered alike: no third, bare entry', () {
      // The number names neither unit (TenantUnitAreaIndex.namedUnit is
      // null), so both are "other" units; the record's bare "12" used to be
      // listed in front of them.
      final alike = TenantUnitAreaIndex([
        _unit('a12', '12', area: 'Building B'),
        _unit('b12', '12', area: 'Building D'),
      ]);
      final t = _tenant(unitNumber: '12', unitId: null);
      final on = tenantHeldUnitLabels(t, units: alike, includeArea: true);
      expect(on.map((l) => l.label), ['12 (Building B)', '12 (Building D)']);
      expect(on.map((l) => l.unit?.id), ['a12', 'b12']);
      final off = tenantHeldUnitLabels(t, units: alike, includeArea: false);
      expect(off.map((l) => l.label), ['12']);
      expect(off.single.unit?.id, 'a12');
    });
  });

  group('the Assign Tenant picker\'s unit line', () {
    test('always names the area, like the unit being assigned', () {
      final index = TenantUnitAreaIndex([
        _unit('u14', 'B-14', area: 'Building B'),
        _unit('u15', 'B-15', area: 'Building B'),
      ]);
      expect(tenantPickerUnitsText(_tenant(), index), 'Units B-14 (Building B), B-15 (Building B)');
      expect(
        tenantPickerUnitsText(_tenant(), TenantUnitAreaIndex([_unit('u14', 'B-14')])),
        'Unit B-14',
      );
      expect(tenantPickerUnitsText(_tenant(unitNumber: '', unitId: null), TenantUnitAreaIndex(const [])), 'No unit');
    });
  });

  group('Tenants list unit line with every held unit', () {
    final other = _unit('u15', 'B-15', area: 'Building B');
    final d3 = _unit('d3', 'D-3', area: 'Building D');

    test('off: the numbers, then the areas as before', () {
      expect(tenantListUnitLine(_tenant(), includeArea: false, otherUnits: [other]), 'Unit: B-14, B-15');
      expect(
        tenantListUnitLine(_tenant(), includeArea: false, areas: const ['Building B'], otherUnits: [other]),
        'Unit: B-14, B-15 · Building B',
      );
      // No leading comma for a record with no unit number of its own.
      expect(tenantListUnitLine(_tenant(unitNumber: ''), includeArea: false, otherUnits: [other]), 'Unit: B-15');
    });

    test('on: each label carries its area, so only areas of units not listed follow the dot', () {
      expect(
        tenantListUnitLine(_tenant(unitArea: 'Building B'),
            includeArea: true, areas: const ['Building B'], otherUnits: [other]),
        'Unit: B-14 (Building B), B-15 (Building B)',
      );
      expect(
        tenantListUnitLine(_tenant(unitArea: 'Building B'),
            includeArea: true, areas: const ['Building B', 'Building D'], otherUnits: [d3]),
        'Unit: B-14 (Building B), D-3 (Building D)',
      );
      // The record's own unit has no area on file: that area still follows.
      expect(
        tenantListUnitLine(_tenant(), includeArea: true, areas: const ['Building B', 'Building D'], otherUnits: [d3]),
        'Unit: B-14, D-3 (Building D) · Building B',
      );
    });

    test('a record with no unitId holding two units numbered alike: no third, bare number', () {
      // The list has no unit for the label (namedUnit is null), and both
      // held units are "other" units carrying the record's number.
      final buildingB12 = _unit('a12', '12', area: 'Building B');
      final buildingD12 = _unit('b12', '12', area: 'Building D');
      final t = _tenant(unitNumber: '12', unitId: null);
      expect(
        tenantListUnitLine(t,
            includeArea: true, areas: const ['Building B', 'Building D'], otherUnits: [buildingB12, buildingD12]),
        'Unit: 12 (Building B), 12 (Building D)',
      );
      expect(
        tenantListUnitLine(t,
            includeArea: false, areas: const ['Building B', 'Building D'], otherUnits: [buildingB12, buildingD12]),
        'Unit: 12, 12 · Building B, Building D',
      );
      // With a unit behind the label, the same two units read as before.
      final named = _tenant(unitNumber: '12', unitId: 'a12', unitArea: 'Building B');
      expect(
        tenantListUnitLine(named,
            includeArea: true, areas: const ['Building B', 'Building D'], labelUnit: buildingB12, otherUnits: [buildingD12]),
        'Unit: 12 (Building B), 12 (Building D)',
      );
    });
  });
}
