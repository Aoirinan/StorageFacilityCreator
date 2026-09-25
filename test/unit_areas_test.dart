import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/screens/unit_creation_screen.dart';
import 'package:sfcapp/screens/unit_list_screen.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/utils/unit_areas.dart';

import 'support/fake_facility_collection.dart';

UnitModel _unit(
  String id,
  String number, {
  String? area,
  String? tenantId,
}) =>
    UnitModel(
      id: id,
      facilityId: 'fac1',
      unitNumber: number,
      unitType: 'standard',
      status: tenantId == null ? UnitStatus.available : UnitStatus.occupied,
      tenantId: tenantId,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner-1',
      area: area,
    );

TenantModel _tenant(String id, String name, String unitNumber) => TenantModel(
      id: id,
      facilityId: 'fac1',
      name: name,
      email: '$id@example.com',
      phone: '',
      unitNumber: unitNumber,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
    );

FakeQueryLog _serveUnits(List<FakeDoc> docs) {
  final log = FakeQueryLog();
  final units = FakeCollection(docs, log: log);
  FacilitySubcollections.overrideForTesting((facilityId, name) {
    expect(facilityId, 'fac1');
    expect(name, 'units');
    return units;
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

  group('UnitModel.area', () {
    test('reads trimmed, and blank or non-string as no area', () {
      String? read(Object? value) => UnitModel.fromFirestore(
              FakeDoc('u1', {'unitNumber': '1', 'area': value}))
          .area;
      expect(read('  Complex 2 '), 'Complex 2');
      expect(read('Rental house'), 'Rental house');
      for (final none in [null, '', '   ', 5, true]) {
        expect(read(none), isNull, reason: '$none');
      }
      expect(
          UnitModel.fromFirestore(FakeDoc('u2', {'unitNumber': '2'})).area,
          isNull);
    });

    test('round-trips through toFirestore and fromFirestore', () {
      final unit = _unit('u1', 'C2-12', area: 'Complex 2');
      final map = unit.toFirestore();
      expect(map['area'], 'Complex 2');
      expect(UnitModel.fromFirestore(FakeDoc('u1', map)).area, 'Complex 2');

      final none = _unit('u2', '5').toFirestore();
      expect(none['area'], isNull);
      expect(UnitModel.fromFirestore(FakeDoc('u2', none)).area, isNull);
    });

    test('copyWith keeps, replaces or clears it', () {
      final unit = _unit('u1', 'C2-12', area: 'Complex 2');
      expect(unit.copyWith(notes: 'x').area, 'Complex 2');
      expect(unit.copyWith(area: 'Complex 3').area, 'Complex 3');
      expect(unit.copyWith(clearArea: true).area, isNull);
    });
  });

  group('area helpers', () {
    final units = [
      _unit('1', 'C3-1', area: 'Complex 3'),
      _unit('2', 'C2-1', area: 'Complex 2'),
      _unit('3', 'C2-2', area: 'complex 2'),
      _unit('4', 'OUT-1', area: 'Outdoor Storage'),
      _unit('5', '7'),
    ];

    test('distinct areas ignore case and sort A-Z', () {
      expect(distinctUnitAreas(units),
          ['Complex 2', 'Complex 3', 'Outdoor Storage']);
      expect(distinctUnitAreas([_unit('5', '7')]), isEmpty);
    });

    test('a typed area takes the spelling of an existing one', () {
      final existing = distinctUnitAreas(units);
      expect(canonicalUnitArea('  COMPLEX 3 ', existing), 'Complex 3');
      expect(canonicalUnitArea('Rental House', existing), 'Rental House');
      expect(canonicalUnitArea('   ', existing), isNull);
      expect(canonicalUnitArea(null, existing), isNull);
    });

    test('filter options: each area, then No area when a unit has none', () {
      expect(unitAreaFilterOptions(units),
          ['Complex 2', 'Complex 3', 'Outdoor Storage', noUnitAreaFilter]);
      expect(unitAreaFilterOptions(units.take(4)),
          ['Complex 2', 'Complex 3', 'Outdoor Storage']);
      // No areas at all: no options, so the dropdown is hidden.
      expect(unitAreaFilterOptions([_unit('5', '7')]), isEmpty);
      expect(unitAreaFilterLabel(noUnitAreaFilter), 'No area');
      expect(unitAreaFilterLabel('Complex 2'), 'Complex 2');
    });

    test('a selected area no unit has any more falls back to All areas', () {
      final options = unitAreaFilterOptions(units);
      expect(effectiveUnitAreaFilter('Complex 2', options), 'Complex 2');
      expect(effectiveUnitAreaFilter('Complex 9', options), isNull);
      expect(effectiveUnitAreaFilter(null, options), isNull);
    });

    test('units match by area ignoring case, No area, or all', () {
      List<String> ids(String? filter) => [
            for (final u in units)
              if (unitMatchesAreaFilter(u, filter)) u.id
          ];
      expect(ids(null), ['1', '2', '3', '4', '5']);
      expect(ids('Complex 2'), ['2', '3']);
      expect(ids(noUnitAreaFilter), ['5']);
    });
  });

  group('tenants by area', () {
    final units = [
      _unit('u1', 'C2-12', area: 'Complex 2', tenantId: 't1'),
      _unit('u2', 'C3-4', area: 'Complex 3', tenantId: 't2'),
      _unit('u3', 'House', area: 'Rental house'),
      _unit('u4', 'OUT-1', area: 'Outdoor', tenantId: 't2'),
      _unit('u5', '9'),
    ];
    final tenants = [
      _tenant('t1', 'Ann', 'C2-12'),
      // Holds two units in two areas (unit number is the first).
      _tenant('t2', 'Bo', 'C3-4'),
      // Linked only by unit number, typed differently.
      _tenant('t3', 'Cy', ' house '),
      // Unit without an area.
      _tenant('t4', 'Di', '9'),
      // No matching unit at all.
      _tenant('t5', 'Ed', 'Z-1'),
    ];

    List<String> names(String? filter) => filterTenantsByUnitArea(
          tenants,
          units,
          filter,
        ).map((t) => t.name).toList();

    test('by the unit that names the tenant, and by unit number', () {
      expect(names(null), ['Ann', 'Bo', 'Cy', 'Di', 'Ed']);
      expect(names('Complex 2'), ['Ann']);
      expect(names('complex 3'), ['Bo']);
      expect(names('Outdoor'), ['Bo']);
      expect(names('Rental house'), ['Cy']);
      expect(names(noUnitAreaFilter), ['Di', 'Ed']);
    });

    test('a tenant shows every area of their units', () {
      final index = TenantUnitAreaIndex(units);
      expect(index.areasFor(tenants[1]), ['Complex 3', 'Outdoor']);
      expect(index.areasFor(tenants[2]), ['Rental house']);
      expect(index.areasFor(tenants[3]), isEmpty);
    });

    test('filteredTenantsProvider applies area with search and sort',
        () async {
      final container = ProviderContainer(overrides: [
        facilityTenantsProvider('fac1')
            .overrideWith((ref) => Stream.value(tenants)),
        facilityUnitsProvider('fac1').overrideWith((ref) => Stream.value(units)),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(filteredTenantsProvider('fac1'), (_, __) {});
      addTearDown(sub.close);

      Future<List<String>> read() async {
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        return container
            .read(filteredTenantsProvider('fac1'))
            .requireValue
            .map((t) => t.name)
            .toList();
      }

      expect(await read(), ['Ann', 'Bo', 'Cy', 'Di', 'Ed']);

      container.read(tenantAreaFilterProvider.notifier).state = noUnitAreaFilter;
      container.read(tenantSortProvider.notifier).state =
          TenantSortOption.nameDesc;
      expect(await read(), ['Ed', 'Di']);

      container.read(tenantSearchProvider.notifier).state = 'di';
      expect(await read(), ['Di']);

      // An area this facility does not have filters nothing.
      container.read(tenantSearchProvider.notifier).state = '';
      container.read(tenantAreaFilterProvider.notifier).state = 'Complex 9';
      expect(await read(), ['Ed', 'Di', 'Cy', 'Bo', 'Ann']);
    });
  });

  group('UnitService writes area', () {
    test('createUnit stores it trimmed, and leaves it out when blank',
        () async {
      final log = _serveUnits([]);
      await UnitService.createUnit(
        facilityId: 'fac1',
        unitNumber: 'C2-12',
        unitType: 'standard',
        monthlyRate: 50,
        area: '  Complex 2 ',
      );
      await UnitService.createUnit(
        facilityId: 'fac1',
        unitNumber: 'A1',
        unitType: 'standard',
        monthlyRate: 50,
        area: '  ',
      );
      expect(log.writes[0].$3['area'], 'Complex 2');
      expect(log.writes[1].$3.containsKey('area'), isFalse);
    });

    test('updateUnit sets it, removes it when blank, else leaves it',
        () async {
      final log = _serveUnits([
        FakeDoc('u1', {'unitNumber': 'C2-12', 'status': 'available'}),
      ]);
      await UnitService.updateUnit(
          facilityId: 'fac1', unitId: 'u1', area: 'Complex 2');
      await UnitService.updateUnit(facilityId: 'fac1', unitId: 'u1', area: '');
      await UnitService.updateUnit(
          facilityId: 'fac1', unitId: 'u1', notes: 'x');
      expect(log.writes[0].$3['area'], 'Complex 2');
      expect(log.writes[1].$3['area'], FieldValue.delete());
      expect(log.writes[2].$3.containsKey('area'), isFalse);
    });

    test('setUnitArea writes only the area and the update stamp', () async {
      final log = _serveUnits([
        FakeDoc('u1', {'unitNumber': 'C2-12', 'status': 'occupied'}),
      ]);
      await UnitService.setUnitArea(
          facilityId: 'fac1', unitId: 'u1', area: ' Complex 2 ');
      await UnitService.setUnitArea(
          facilityId: 'fac1', unitId: 'u1', area: null);
      expect(log.writes[0].$3.keys.toSet(),
          {'area', 'updatedAt', 'updatedBy'});
      expect(log.writes[0].$3['area'], 'Complex 2');
      expect(log.writes[1].$3['area'], FieldValue.delete());
    });

    test('an area longer than the limit is refused', () async {
      final log = _serveUnits([
        FakeDoc('u1', {'unitNumber': 'C2-12', 'status': 'available'}),
      ]);
      await expectLater(
        UnitService.setUnitArea(
            facilityId: 'fac1',
            unitId: 'u1',
            area: 'x' * (unitAreaMaxLength + 1)),
        throwsException,
      );
      expect(log.writes, isEmpty);
    });
  });

  group('UnitCreationScreen Area field', () {
    Future<void> openScreen(WidgetTester tester, {UnitModel? unit}) async {
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateProvider.overrideWith(
              (ref) => Stream.value(
                  MockUser(uid: 'owner-1', isEmailVerified: true)),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(authStateProvider);
                return Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            UnitCreationScreen(facilityId: 'fac1', unit: unit),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> tapVisible(WidgetTester tester, Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('a new unit is saved with the area, spelled as the existing one',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u9', {
          'unitNumber': 'C2-1',
          'status': 'available',
          'area': 'Complex 2',
        }),
      ]);
      await openScreen(tester);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Unit Number *'), 'C2-12');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Monthly Rate *'), '50');
      await tester.enterText(
          find.byKey(const ValueKey('unit-area-field')), 'complex 2');
      await tester.pumpAndSettle();
      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Create Unit'));

      final created = log.writes.single;
      expect(created.$1, 'set');
      expect(created.$3['unitNumber'], 'C2-12');
      expect(created.$3['area'], 'Complex 2');
    });

    testWidgets('editing starts from the unit area and clearing removes it',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'C2-12',
          'status': 'available',
          'area': 'Complex 2',
        }),
      ]);
      await openScreen(tester, unit: _unit('u1', 'C2-12', area: 'Complex 2'));

      final field = find.byKey(const ValueKey('unit-area-field'));
      expect(
          tester.widget<TextFormField>(field).controller?.text, 'Complex 2');
      await tester.enterText(field, '');
      await tester.pumpAndSettle();
      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));

      expect(log.writes.single.$1, 'update');
      expect(log.writes.single.$3['area'], FieldValue.delete());
    });

    testWidgets('Enter saves the area as typed, not the first suggestion',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {'unitNumber': 'C2-12', 'status': 'available'}),
        FakeDoc('u2', {
          'unitNumber': 'C20-1',
          'status': 'available',
          'area': 'Complex 20',
        }),
      ]);
      await openScreen(tester, unit: _unit('u1', 'C2-12'));

      final field = find.byKey(const ValueKey('unit-area-field'));
      await tester.enterText(field, 'Complex 2');
      await tester.pumpAndSettle();
      // "Complex 20" is offered...
      expect(find.widgetWithText(ListTile, 'Complex 20'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      // ...but Enter does not take it.
      expect(tester.widget<TextFormField>(field).controller?.text, 'Complex 2');
      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));

      expect(log.writes.single.$3['area'], 'Complex 2');
    });

    testWidgets('the only unit in an area can change its capitals',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'C2-12',
          'status': 'available',
          'area': 'complex 2',
        }),
      ]);
      await openScreen(tester, unit: _unit('u1', 'C2-12', area: 'complex 2'));

      await tester.enterText(
          find.byKey(const ValueKey('unit-area-field')), 'Complex 2');
      await tester.pumpAndSettle();
      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));

      // Before: its own "complex 2" held the spelling and nothing changed.
      expect(log.writes.single.$3['area'], 'Complex 2');
    });

    testWidgets('an edit that leaves the area alone does not send it',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'C2-12',
          'status': 'available',
          'area': 'Complex 2',
        }),
      ]);
      await openScreen(tester, unit: _unit('u1', 'C2-12', area: 'Complex 2'));
      await tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));

      expect(log.writes.single.$1, 'update');
      expect(log.writes.single.$3.containsKey('area'), isFalse);
    });
  });

  group('Units list Area filter and Set area', () {
    Future<FakeQueryLog> pumpList(
      WidgetTester tester,
      List<UnitModel> units, {
      double width = 1600,
    }) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = _serveUnits([
        for (final u in units)
          FakeDoc(u.id, {'unitNumber': u.unitNumber, 'area': u.area}),
      ]);
      final facility = FacilityModel(
        id: 'fac1',
        name: 'Caprock Storage',
        ownerUid: 'owner-1',
        createdAt: DateTime(2026, 1, 1),
      );
      final container = ProviderContainer(
        overrides: [
          authStateProvider.overrideWith(
            (ref) => Stream.value(MockUser(uid: 'owner-1')),
          ),
          userFacilitiesProvider('owner-1').overrideWith(
            (ref) => Stream.value([facility]),
          ),
          activeFacilityIdProvider.overrideWith(
            (ref) => ActiveFacilityNotifier.idle(const AsyncValue.data('fac1')),
          ),
          facilityUnitsProvider('fac1')
              .overrideWith((ref) => Stream.value(units)),
          facilityTenantsProvider('fac1').overrideWith(
            (ref) => Stream.value(const <TenantModel>[]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(authStateProvider, (_, __) {});
      container.listen(userFacilitiesProvider('owner-1'), (_, __) {});
      await tester.runAsync(() async {
        await container.read(authStateProvider.future);
        await container.read(userFacilitiesProvider('owner-1').future);
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: UnitListScreen())),
        ),
      );
      await tester.pumpAndSettle();
      return log;
    }

    /// Row checkboxes follow the header's, in unit number order.
    Future<void> tick(WidgetTester tester, int index) async {
      await tester.tap(find.byType(Checkbox).at(index));
      await tester.pumpAndSettle();
    }

    Future<void> setAreaWithEnter(WidgetTester tester, String text) async {
      await tester.tap(find.widgetWithText(OutlinedButton, 'Set area'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('unit-area-field')), text);
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
    }

    testWidgets('blank + Enter in Set area removes the area', (tester) async {
      final log = await pumpList(tester, [
        _unit('u1', 'A1', area: 'Complex 2'),
        _unit('u2', 'A2', area: 'Complex 20'),
      ]);
      await tick(tester, 0); // header: both
      await setAreaWithEnter(tester, '');

      // Before: Enter picked the first suggestion and both became
      // "Complex 2".
      expect(log.writes.map((w) => (w.$2, w.$3['area'])), [
        ('u1', FieldValue.delete()),
        ('u2', FieldValue.delete()),
      ]);
    });

    testWidgets('"Complex 2" + Enter saves Complex 2 with Complex 20 there',
        (tester) async {
      final log = await pumpList(tester, [
        _unit('u1', 'A1', area: 'Complex 20'),
        _unit('u2', 'A2'),
      ]);
      await tick(tester, 2); // A2
      await setAreaWithEnter(tester, 'Complex 2');

      expect(log.writes.map((w) => (w.$2, w.$3['area'])),
          [('u2', 'Complex 2')]);
    });

    testWidgets('capitals change when every unit in the area is set',
        (tester) async {
      final log = await pumpList(tester, [
        _unit('u1', 'A1', area: 'complex 2'),
        _unit('u2', 'A2', area: 'complex 2'),
      ]);
      await tick(tester, 0);
      await setAreaWithEnter(tester, 'Complex 2');

      expect(log.writes.map((w) => w.$3['area']), ['Complex 2', 'Complex 2']);
    });

    testWidgets(
        'changing the Area filter clears the selection, and Set area '
        'only touches units shown', (tester) async {
      final log = await pumpList(tester, [
        _unit('u1', 'A1', area: 'Complex 2'),
        _unit('u2', 'A2', area: 'Complex 3'),
        _unit('u3', 'A3', area: 'Complex 2'),
      ]);
      await tick(tester, 0);
      expect(find.text('3 selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('unit-area-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Complex 2').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('selected'), findsNothing);
      expect(find.text('A2'), findsNothing);

      await tick(tester, 0);
      expect(find.text('2 selected'), findsOneWidget);
      await setAreaWithEnter(tester, 'Building A');

      expect(log.writes.map((w) => w.$2), ['u1', 'u3']);
    });

    testWidgets('the Area filter fits a narrow window', (tester) async {
      await pumpList(
        tester,
        [
          _unit('u1', 'A1', area: 'Complex 2'),
          _unit('u2', 'A2', area: 'Outdoor Storage'),
        ],
        width: 640,
      );
      // An overflow is reported as an exception.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('unit-area-filter')), findsOneWidget);
    });

    testWidgets('no Area filter when no unit has an area', (tester) async {
      await pumpList(tester, [_unit('u1', 'A1'), _unit('u2', 'A2')]);
      expect(find.byKey(const ValueKey('unit-area-filter')), findsNothing);
    });
  });
}
