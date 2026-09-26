import 'dart:async';
import 'dart:io';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/unit_label_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/screens/facility_edit_screen.dart';
import 'package:sfcapp/screens/move_in_wizard_screen.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/move_in_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/utils/bulk_action.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/unit_label.dart';
import 'package:sfcapp/widgets/tenant_facility_unit_picker.dart';
import 'package:sfcapp/widgets/unit_numbers_repeat_setting.dart';

import 'support/fake_facility_collection.dart';
import 'support/fake_facility_firestore.dart';

final _day = DateTime(2026, 9, 1);

UnitModel _unit(String id, String number,
        {String? area, UnitStatus status = UnitStatus.available, double rate = 100}) =>
    UnitModel(
      id: id,
      facilityId: 'f1',
      unitNumber: number,
      unitType: 'standard',
      status: status,
      monthlyRate: rate,
      createdAt: _day,
      updatedAt: _day,
      createdBy: 'owner',
      area: area,
    );

void main() {
  group('UnitService unit-number rule', () {
    late FakeFacilityFirestore db;

    /// Serves [units] (and [tenants]) for facility f1, with "Unit numbers
    /// repeat across areas" [repeat].
    void serve(List<FakeDoc> units,
        {required bool repeat, List<FakeDoc> tenants = const []}) {
      db = FakeFacilityFirestore('f1', {'units': units, 'tenants': tenants});
      FacilitySubcollections.overrideForTesting(
        (facilityId, name) {
          expect(facilityId, 'f1');
          return db.sub(name);
        },
        facility: (_) => {if (repeat) 'unitNumbersRepeatAcrossAreas': true},
      );
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

    Future<String> create(String number, {String? area}) => UnitService.createUnit(
          facilityId: 'f1',
          unitNumber: number,
          unitType: 'standard',
          monthlyRate: 50,
          area: area,
        );

    FakeDoc live(String id, String number, {String? area}) => FakeDoc(id, {
          'unitNumber': number,
          'status': 'available',
          'archived': false,
          'isActive': true,
          if (area != null) 'area': area,
        });

    FakeDoc archived(String id, String number, {String? area}) => FakeDoc(id, {
          'unitNumber': number,
          'archived': true,
          'isActive': false,
          if (area != null) 'area': area,
        });

    group('setting off: facility-wide, as before', () {
      test('another area does not free a number', () async {
        serve([live('u1', '12', area: 'Complex 2')], repeat: false);
        await expectLater(
          create('12', area: 'Complex 3'),
          throwsA(isA<DuplicateUnitNumberException>().having((e) => e.message, 'message',
              'Unit number 12 already exists in this facility. Nothing was saved. Use a different number.')),
        );
        expect(unitWrites(), isEmpty);
      });

      test('case and spaces do not matter', () async {
        serve([live('u1', '12A')], repeat: false);
        await expectLater(create(' 12a '), throwsA(isA<DuplicateUnitNumberException>()));
        expect(unitWrites(), isEmpty);
      });

      test("an archived unit's number is still refused for a new unit", () async {
        serve([archived('u1', '12', area: 'Complex 2')], repeat: false);
        await expectLater(
          create('12', area: 'Complex 3'),
          throwsA(isA<DuplicateUnitNumberException>()
              .having((e) => e.archived, 'archived', isTrue)
              .having((e) => e.area, 'area', isNull)),
        );
      });

      test('a unit with no area and a free number is made', () async {
        serve([live('u1', '12')], repeat: false);
        await create('13');
        expect(unitWrites().single.$1, 'set');
      });

      test('area changes are not checked', () async {
        serve([live('u1', '12', area: 'Complex 2'), live('u2', '12', area: 'Complex 3')],
            repeat: false);
        // Left from before; the setting is off, so areas are free text.
        await UnitService.setUnitArea(facilityId: 'f1', unitId: 'u2', area: '');
        await UnitService.updateUnit(facilityId: 'f1', unitId: 'u1', area: '');
        expect(unitWrites(), hasLength(2));
      });

      test('renaming onto another area\'s number is refused', () async {
        serve([live('u1', '12', area: 'Complex 2'), live('u2', '14', area: 'Complex 3')],
            repeat: false);
        await expectLater(
          UnitService.updateUnit(facilityId: 'f1', unitId: 'u2', unitNumber: '12'),
          throwsA(isA<DuplicateUnitNumberException>()),
        );
      });
    });

    group('setting on: unique per area', () {
      test('the same number in a different area is made', () async {
        serve([live('u1', '12', area: 'Complex 2')], repeat: true);
        await create('12', area: 'Complex 3');
        final written = unitWrites().single;
        expect(written.$1, 'set');
        expect(written.$3['unitNumber'], '12');
        expect(written.$3['area'], 'Complex 3');
      });

      test('the same number in the same area is refused, ignoring case and spaces', () async {
        serve([live('u1', '12A', area: 'Complex 2')], repeat: true);
        await expectLater(
          create(' 12a ', area: ' complex 2 '),
          throwsA(isA<DuplicateUnitNumberException>().having((e) => e.message, 'message',
              'Unit number 12a already exists in complex 2 (as 12A). Nothing was saved. '
              'Use a different number or area.')),
        );
        expect(unitWrites(), isEmpty);
      });

      test('a repeated number with no area on the new unit is refused', () async {
        serve([live('u1', '12', area: 'Complex 2')], repeat: true);
        await expectLater(
          create('12'),
          throwsA(isA<UnitNumberNeedsAreaException>().having((e) => e.message, 'message',
              'Unit number 12 is already used by another unit (in Complex 2). Units with a '
              'repeated number must have an area. Nothing was saved. Enter an area for this '
              'unit, or use a different number.')),
        );
        expect(unitWrites(), isEmpty);
      });

      test('a repeated number is refused while the other unit with it has no area', () async {
        serve([live('u1', '12')], repeat: true);
        await expectLater(
          create('12', area: 'Complex 3'),
          throwsA(isA<UnitNumberNeedsAreaException>()
              .having((e) => e.otherUnitHasNoArea, 'otherUnitHasNoArea', isTrue)
              .having((e) => e.message, 'message', startsWith(
                  'Unit number 12 is already used by a unit with no area.'))),
        );
        expect(unitWrites(), isEmpty);
      });

      test('a number no other unit has needs no area', () async {
        serve([live('u1', '12', area: 'Complex 2')], repeat: true);
        await create('13');
        expect(unitWrites().single.$3.containsKey('area'), isFalse);
      });

      test('an archived unit keeps its number in its area, not in others', () async {
        serve([archived('u1', '12', area: 'Complex 2')], repeat: true);
        await expectLater(
          create('12', area: 'COMPLEX 2'),
          throwsA(isA<DuplicateUnitNumberException>()
              .having((e) => e.archived, 'archived', isTrue)
              .having((e) => e.message, 'message', startsWith(
                  'Unit number 12 in COMPLEX 2 belongs to an archived unit.'))),
        );
        await create('12', area: 'Complex 3');
        expect(unitWrites().single.$3['area'], 'Complex 3');
      });

      test('an archived unit with no area does not need one, but keeps its number from another without', () async {
        serve([archived('u1', '12')], repeat: true);
        await expectLater(create('12'), throwsA(isA<DuplicateUnitNumberException>()));
        await create('12', area: 'Complex 3');
        expect(unitWrites(), hasLength(1));
      });

      test('bulk create: every number goes in where only another area has it', () async {
        // Units > Add > Create multiple units creates each number in turn.
        serve([live('u1', '12', area: 'Complex 2'), live('u2', '14', area: 'Complex 3')],
            repeat: true);
        final failed = <String, Object>{};
        for (final n in ['12', '13', '14']) {
          try {
            await create(n, area: 'Complex 3');
          } catch (e) {
            failed[n] = e;
          }
        }
        expect(failed.keys, ['14']);
        expect(failed['14'], isA<DuplicateUnitNumberException>());
        expect(unitWrites().map((w) => w.$3['unitNumber']), ['12', '13']);
      });

      test('bulk create with the setting off refuses the number another area has', () async {
        serve([live('u1', '12', area: 'Complex 2')], repeat: false);
        final failed = <String>[];
        for (final n in ['12', '13']) {
          try {
            await create(n, area: 'Complex 3');
          } catch (_) {
            failed.add(n);
          }
        }
        expect(failed, ['12']);
      });

      group('rename', () {
        test('onto a number another area has: allowed', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '14', area: 'Complex 3')],
              repeat: true);
          await UnitService.updateUnit(facilityId: 'f1', unitId: 'u2', unitNumber: '12');
          expect(db.data('units', 'u2')!['unitNumber'], '12');
        });

        test('onto a number its own area has: refused', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '14', area: 'complex 2')],
              repeat: true);
          await expectLater(
            UnitService.updateUnit(facilityId: 'f1', unitId: 'u2', unitNumber: '12'),
            throwsA(isA<DuplicateUnitNumberException>()),
          );
          expect(unitWrites(), isEmpty);
        });

        test('onto a repeated number without an area: refused', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '14')], repeat: true);
          await expectLater(
            UnitService.updateUnit(facilityId: 'f1', unitId: 'u2', unitNumber: '12'),
            throwsA(isA<UnitNumberNeedsAreaException>()),
          );
        });

        test('with a new area in the same save: checked against the new area', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '14')], repeat: true);
          await UnitService.updateUnit(
              facilityId: 'f1', unitId: 'u2', unitNumber: '12', area: 'Complex 3');
          expect(db.data('units', 'u2')!['area'], 'Complex 3');
        });

        test('onto an archived unit\'s number and area: allowed, as before', () async {
          serve([archived('u1', '12', area: 'Complex 2'), live('u2', '14', area: 'Complex 2')],
              repeat: true);
          await UnitService.updateUnit(facilityId: 'f1', unitId: 'u2', unitNumber: '12');
          expect(db.data('units', 'u2')!['unitNumber'], '12');
        });
      });

      group('area change', () {
        test('Edit Unit: into an area that has the number is refused', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '12', area: 'Complex 3')],
              repeat: true);
          await expectLater(
            UnitService.updateUnit(facilityId: 'f1', unitId: 'u2', area: 'complex 2'),
            throwsA(isA<DuplicateUnitNumberException>()),
          );
          expect(unitWrites(), isEmpty);
        });

        test('Edit Unit: removing the area of a repeated number is refused', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '12', area: 'Complex 3')],
              repeat: true);
          await expectLater(
            UnitService.updateUnit(facilityId: 'f1', unitId: 'u2', area: ''),
            throwsA(isA<UnitNumberNeedsAreaException>().having((e) => e.message, 'message',
                'Unit 12 needs an area: another unit is also numbered 12 (in Complex 2). '
                'Nothing was saved. Keep an area on this unit, or renumber one of them.')),
          );
          expect(unitWrites(), isEmpty);
        });

        test('Edit Unit: moving to a third area, or saving the same area, is allowed', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '12', area: 'Complex 3')],
              repeat: true);
          await UnitService.updateUnit(facilityId: 'f1', unitId: 'u2', area: 'Outdoor');
          expect(db.data('units', 'u2')!['area'], 'Outdoor');
          await UnitService.updateUnit(
              facilityId: 'f1', unitId: 'u1', area: 'Complex 2', notes: 'x');
          expect(db.data('units', 'u1')!['notes'], 'x');
        });

        test('Set area: removing it from a repeated number is refused', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '12', area: 'Complex 3')],
              repeat: true);
          await expectLater(
            UnitService.setUnitArea(facilityId: 'f1', unitId: 'u1', area: null),
            throwsA(isA<UnitNumberNeedsAreaException>()),
          );
          expect(unitWrites(), isEmpty);
        });

        test('Set area on a unit whose number is not repeated: allowed, even blank', () async {
          serve([live('u1', '12', area: 'Complex 2'), live('u2', '13', area: 'Complex 3')],
              repeat: true);
          await UnitService.setUnitArea(facilityId: 'f1', unitId: 'u1', area: null);
          expect(unitWrites(), hasLength(1));
        });

        test('bulk Set area: the second unit numbered alike into one area is refused', () async {
          // Units > select units > Set area runs setUnitArea unit by unit.
          serve([
            live('u1', '12', area: 'Complex 2'),
            live('u2', '12', area: 'Complex 3'),
            live('u3', '14', area: 'Complex 3'),
          ], repeat: true);
          final result = await runBulkAction(
            ['u1', 'u2', 'u3'],
            (id) => UnitService.setUnitArea(facilityId: 'f1', unitId: id, area: 'Outdoor'),
          );
          expect(result.done, ['u1', 'u3']);
          expect(result.failed.keys, ['u2']);
          expect(result.failed['u2'], isA<DuplicateUnitNumberException>());
          expect(db.data('units', 'u2')!['area'], 'Complex 3');
        });
      });
    });

    group('turning the setting off', () {
      test('is refused while two live units share a number, ignoring case and spaces', () async {
        serve([
          live('u1', '12', area: 'Complex 2'),
          live('u2', ' 12 ', area: 'Complex 3'),
          live('u3', '7b', area: 'Complex 2'),
          live('u4', '7B', area: 'Complex 3'),
          live('u5', '9', area: 'Complex 3'),
        ], repeat: true);
        await expectLater(
          UnitService.checkCanStopRepeatingUnitNumbers('f1'),
          throwsA(isA<RepeatedUnitNumbersException>()
              .having((e) => e.unitNumbers, 'unitNumbers', ['12', '7b'])
              .having((e) => e.message, 'message',
                  '"Unit numbers repeat across areas" can only be turned off when every '
                  'unit number is used once. Unit numbers 12, 7b are used by more than '
                  'one unit. Nothing was saved. Renumber those units (Units > unit > '
                  'Edit), then turn this off.')),
        );
      });

      test('is allowed once every live number is used once; archived repeats do not count', () async {
        serve([
          live('u1', '12', area: 'Complex 2'),
          archived('u2', '12', area: 'Complex 3'),
          live('u3', '14', area: 'Complex 3'),
        ], repeat: true);
        await UnitService.checkCanStopRepeatingUnitNumbers('f1');
      });

      test('the refusal reads as written on screen', () {
        expect(
          ErrorMessageHelper.getUserFriendlyMessage(
              const RepeatedUnitNumbersException(['12'])),
          startsWith('"Unit numbers repeat across areas" can only be turned off when '
              'every unit number is used once. Unit number 12 is used by more than one unit.'),
        );
      });

      test('Update Facility writes the field only when given, and checks before turning it off', () {
        final source = File('lib/services/facility_service.dart').readAsStringSync();
        final update = source.substring(source.indexOf('static Future<void> updateFacility('));
        final check = update.indexOf('UnitService.checkCanStopRepeatingUnitNumbers(facilityId)');
        final write = update.indexOf('.doc(facilityId).update(updateData)');
        expect(check, greaterThan(0));
        expect(check, lessThan(write));
        expect(update, contains('if (unitNumbersRepeatAcrossAreas != null) {'));
        // Edit Facility passes it only when the owner changed it.
        final screen = File('lib/screens/facility_edit_screen.dart')
            .readAsStringSync()
            .replaceAll('\r\n', '\n');
        expect(screen, contains('unitNumbersRepeatAcrossAreas: _unitNumbersRepeat ==\n'
            '                widget.facility.unitNumbersRepeatAcrossAreas\n'
            '            ? null\n'
            '            : _unitNumbersRepeat,'));
      });
    });

    test('a tenant typed onto a new number with the setting on makes an area-less unit only when the number is free', () async {
      serve([live('u1', '12', area: 'Complex 2')], repeat: true);
      expect(await UnitService.unitNumberWriteConflict('f1', '13'), isNull);
      expect(await UnitService.unitNumberWriteConflict('f1', '12'),
          isA<UnitNumberNeedsAreaException>());
    });
  });

  group('typed numbers several units have', () {
    test('the refusal names their areas and says to pick from the list', () {
      expect(
        () => TenantService.unitForNumber(
          [_unit('c2', '12', area: 'Complex 2'), _unit('c3', '12', area: 'Complex 3')],
          '12',
          tenantId: 't1',
        ),
        throwsA(isA<AmbiguousUnitNumberException>().having((e) => e.message, 'message',
            'More than one unit is numbered 12 (in Complex 2, Complex 3). Nothing was saved. '
            'Pick the unit from the list instead of typing its number: the list shows each '
            "unit's area.")),
      );
    });

    test("an unchanged number's notice names them too", () {
      expect(
        TenantService.ambiguousUnitNumberNotice(
            const AmbiguousUnitNumberException(
                unitNumber: '12', count: 2, areas: ['Complex 2', 'Complex 3']),
            'Ada Park'),
        'More than one unit is numbered 12 (in Complex 2, Complex 3), so none was linked '
        'to Ada Park. Pick their unit from the list to link it.',
      );
    });
  });

  group('CSV tenant import: the Area column', () {
    final units = [
      _unit('c2-12', '12', area: 'Complex 2'),
      _unit('c3-12', '12A', area: 'Complex 3'),
      _unit('u14', '14', area: 'Complex 3'),
    ];
    // Two units read "12a" ignoring case.
    final repeated = [
      _unit('c2-12', '12', area: 'Complex 2'),
      _unit('c3-12', '12', area: 'Complex 3'),
      _unit('u14', '14', area: 'Complex 3'),
    ];

    String? match(List<UnitModel> units, String number, String? area, {bool repeat = true}) =>
        TenantService.csvImportUnitId(units,
            unitNumber: number, area: area, repeatAcrossAreas: repeat);

    test('setting on, a repeated number: the unit in the row\'s area, ignoring case and spaces', () {
      expect(match(repeated, '12', 'Complex 3'), 'c3-12');
      expect(match(repeated, ' 12 ', ' complex 2 '), 'c2-12');
    });

    test('setting on, a number one unit has: linked by number as before, area not needed', () {
      expect(match(repeated, '14', null), isNull);
      expect(match(repeated, '14', 'Somewhere else'), isNull);
      expect(match(units, '12', null), isNull);
      expect(match(repeated, '', 'Complex 2'), isNull);
    });

    test('setting off: the area column is not used', () {
      expect(match(repeated, '12', 'Complex 3', repeat: false), isNull);
    });

    test('setting on, a repeated number with no area: the row error says to add one', () {
      Object? error;
      try {
        match(repeated, '12', '  ');
      } catch (e) {
        error = e;
      }
      expect(error, isA<AmbiguousUnitNumberException>());
      expect(TenantService.csvImportRowError(3, error!),
          'Row 3: More than one unit is numbered 12 (in Complex 2, Complex 3), so this tenant '
          "was not imported. Put the unit's area in an Area column, or add them with Add "
          'Tenant and pick their unit from the list.');
    });

    test('setting on, an area none of them is in: a row error naming theirs', () {
      Object? error;
      try {
        match(repeated, '12', 'Outdoor');
      } catch (e) {
        error = e;
      }
      expect(error, isA<CsvUnitAreaNotFoundException>());
      expect(TenantService.csvImportRowError(4, error!),
          'Row 4: No unit numbered 12 is in area Outdoor. It is in Complex 2, Complex 3. '
          'This tenant was not imported. Fix the Area column, or add them with Add Tenant '
          'and pick their unit from the list.');
    });

    test('setting on, two units with the number in the row\'s area: still ambiguous', () {
      expect(
        () => match([
          _unit('a', '12', area: 'Complex 2'),
          _unit('b', '12', area: 'complex 2'),
        ], '12', 'Complex 2'),
        throwsA(isA<AmbiguousUnitNumberException>()),
      );
    });

    test('the duplicate check keys a unit by number, and by area where numbers repeat', () {
      String key(String n, String? a, bool repeat) =>
          TenantService.csvImportUnitKey(n, area: a, repeatAcrossAreas: repeat);
      expect(key(' 12A ', 'Complex 2', false), '12a');
      expect(key('12', 'Complex 2', false), key('12', 'Complex 3', false));
      expect(key('12', 'Complex 2', true), isNot(key('12', 'Complex 3', true)));
      expect(key('12', ' complex 2 ', true), key('12', 'Complex 2', true));
      expect(key('', 'Complex 2', true), '');
    });

    test('the wizard maps an Area column and passes the matched unit by id', () {
      final source =
          File('lib/screens/tenant_csv_import_wizard_screen.dart').readAsStringSync();
      expect(source, contains("{'key': 'area', 'label': 'Area'"));
      expect(source, contains('TenantService.csvImportUnitId('));
      expect(source, contains('unitId: unitId,'));
      expect(source, contains('TenantService.csvImportUnitKey('));
    });
  });

  group('unit lists show the area', () {
    test('unitPickerLabel: with the area whenever the unit has one', () {
      expect(unitPickerLabel(_unit('a', '12', area: ' Complex 2 ')), 'Unit 12 (Complex 2)');
      expect(unitPickerLabel(_unit('a', '12')), 'Unit 12');
      expect(unitPickerLabel(_unit('a', '12', area: 'Complex 2'), style: UnitLabelStyle.plain),
          '12 (Complex 2)');
      expect(unitPickerLabel(_unit('a', '')), 'Unit');
    });

    testWidgets('the tenant unit picker tells two unit 12s apart', (tester) async {
      final number = TextEditingController();
      final rate = TextEditingController();
      addTearDown(number.dispose);
      addTearDown(rate.dispose);
      String? picked;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          facilityUnitsProvider('f1').overrideWith((ref) => Stream.value([
                _unit('c2-12', '12', area: 'Complex 2', rate: 90),
                _unit('c3-12', '12', area: 'Complex 3', rate: 110),
              ])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Form(
              child: TenantFacilityUnitPicker(
                facilityId: 'f1',
                unitNumberController: number,
                monthlyRateController: rate,
                onUnitIdChanged: (id) => picked = id,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text(r'Unit 12 (Complex 2) - $90.00/mo'), findsWidgets);
      expect(find.text(r'Unit 12 (Complex 3) - $110.00/mo'), findsWidgets);
      await tester.tap(find.text(r'Unit 12 (Complex 3) - $110.00/mo').last);
      await tester.pumpAndSettle();
      expect(picked, 'c3-12');
      expect(number.text, '12');
    });

    testWidgets('the move-in wizard unit list and the picked unit show the area', (tester) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final services = MoveInWizardServices(
        getFacility: (_) async => null,
        getUnits: (_) async => [
          _unit('c2-12', '12', area: 'Complex 2'),
          _unit('c3-12', '12', area: 'Complex 3'),
        ],
        getTenants: (_) async => const <TenantModel>[],
        createLeaseContract: ({
          required String facilityId,
          required String tenantId,
          required String unitNumber,
        }) async =>
            throw UnimplementedError(),
        completeMoveIn: ({
          required MoveInData moveInData,
          String? paymentMethod,
          String? paymentReferenceId,
          bool skipPayment = false,
        }) async =>
            throw UnimplementedError(),
      );
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MoveInWizardScreen(facilityId: 'f1', services: services),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Select Unit'));
      await tester.pumpAndSettle();
      expect(find.text('Unit 12 (Complex 2)'), findsOneWidget);
      expect(find.text('Unit 12 (Complex 3)'), findsOneWidget);
      await tester.tap(find.text('Unit 12 (Complex 3)'));
      await tester.pumpAndSettle();
      expect(find.text('Unit 12 (Complex 3)'), findsOneWidget);
      expect(find.text('Unit 12 (Complex 2)'), findsNothing);
    });

    test('the transfer screen and the Assign Tenant dialog name units with their area', () {
      final transfer = File('lib/screens/transfer_workflow_screen.dart').readAsStringSync();
      expect(transfer, contains('unitPickerLabel(unit, style: UnitLabelStyle.plain)'));
      // The To and From lists use it, and the tenant's current unit shows its area.
      expect(RegExp(r'_unitLabel\(unit\)').allMatches(transfer).length, 2);
      expect(transfer, contains('area: _tenant!.unitArea,'));

      final detail = File('lib/screens/unit_detail_screen.dart').readAsStringSync();
      expect(detail, contains('unitLabel: unitPickerLabel(_unit!),'));
      expect(detail, contains("'Select a tenant to assign to \${widget.unitLabel}'"));
    });
  });

  group('the unit label setting reaches open screens', () {
    tearDown(() => unitLabelFacilityDocForTesting = null);

    test('the provider follows the facility doc, and is dropped when unwatched', () async {
      final docs = StreamController<Map<String, dynamic>?>.broadcast();
      var listens = 0;
      unitLabelFacilityDocForTesting = (id) {
        expect(id, 'f1');
        listens++;
        return docs.stream;
      };
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final seen = <bool?>[];
      final sub = container.listen<AsyncValue<bool>>(
        unitLabelsIncludeAreaProvider('f1'),
        (_, next) => seen.add(next.value),
        fireImmediately: true,
      );
      await Future<void>.delayed(Duration.zero);
      docs.add({});
      await Future<void>.delayed(Duration.zero);
      docs.add({'unitNumbersRepeatAcrossAreas': true});
      await Future<void>.delayed(Duration.zero);
      // An unreadable facility counts as off, not an error.
      docs.addError(StateError('denied'));
      await Future<void>.delayed(Duration.zero);
      docs.add({'unitNumbersRepeatAcrossAreas': true});
      await Future<void>.delayed(Duration.zero);
      docs.add({'unitNumbersRepeatAcrossAreas': 'true'});
      await Future<void>.delayed(Duration.zero);
      expect(seen.whereType<bool>().toList(), [false, true, false, true, false]);
      expect(container.read(unitLabelsIncludeAreaProvider('f1')).hasError, isFalse);

      // Unwatched, it is disposed: watched again, it listens afresh rather
      // than serving a value cached for the session.
      sub.close();
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      final again = container.listen<AsyncValue<bool>>(
          unitLabelsIncludeAreaProvider('f1'), (_, __) {});
      addTearDown(again.close);
      await Future<void>.delayed(Duration.zero);
      expect(listens, 2);
      await docs.close();
    });

    test("'all' and '' are off without a read", () async {
      unitLabelFacilityDocForTesting = (_) => fail('read');
      final container = ProviderContainer();
      addTearDown(container.dispose);
      for (final id in ['all', '']) {
        final sub = container.listen(unitLabelsIncludeAreaProvider(id), (_, __) {});
        expect(await container.read(unitLabelsIncludeAreaProvider(id).future), isFalse);
        sub.close();
      }
    });
  });

  group('Edit Facility screen', () {
    late FakeFacilityFirestore db;

    setUp(() {
      db = FakeFacilityFirestore('f1', {
        'units': [
          FakeDoc('u1', {'unitNumber': '12', 'area': 'Complex 2'}),
          FakeDoc('u2', {'unitNumber': '12', 'area': 'Complex 3'}),
        ],
      });
      FacilitySubcollections.overrideForTesting((_, name) => db.sub(name));
    });
    tearDown(() => FacilitySubcollections.overrideForTesting(null));

    Future<void> pump(WidgetTester tester, {required bool repeat}) async {
      tester.view.physicalSize = const Size(1000, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          authStateProvider.overrideWith((ref) => Stream.value(MockUser(uid: 'owner'))),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FacilityEditScreen(
              facility: FacilityModel(
                id: 'f1',
                name: 'Test Storage',
                ownerUid: 'owner',
                createdAt: DateTime(2026, 1, 1),
                unitNumbersRepeatAcrossAreas: repeat,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    SwitchListTile toggle(WidgetTester tester) => tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('unitNumbersRepeatAcrossAreas')));

    testWidgets('turning it off is refused while two units share a number', (tester) async {
      await pump(tester, repeat: true);
      expect(toggle(tester).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('unitNumbersRepeatAcrossAreas')));
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isTrue);
      expect(find.textContaining('Unit number 12 is used by more than one unit.'),
          findsOneWidget);
    });

    testWidgets('turning it on needs no check', (tester) async {
      await pump(tester, repeat: false);
      await tester.tap(find.byKey(const ValueKey('unitNumbersRepeatAcrossAreas')));
      await tester.pumpAndSettle();
      expect(toggle(tester).value, isTrue);
      expect(find.textContaining('used by more than one unit'), findsNothing);
    });
  });

  group('Edit Facility switch', () {
    Future<void> pump(WidgetTester tester,
        {required bool value, bool online = false, String? error}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: UnitNumbersRepeatSetting(
              value: value,
              onChanged: (_) {},
              error: error,
              onlineRentalsEnabled: online,
            ),
          ),
        ),
      ));
    }

    testWidgets('title and help text', (tester) async {
      await pump(tester, value: false);
      expect(find.text('Unit numbers repeat across areas'), findsOneWidget);
      expect(
          find.text('Turn on if the same door number is used in more than one area, e.g. '
              'unit 12 in Complex 2 and unit 12 in Complex 3. Units with a repeated number '
              'must have an area. Statements, invoices and texts will show the area next '
              'to the unit number.'),
          findsOneWidget);
    });

    testWidgets('on at a facility with online rentals: a warning, not a block', (tester) async {
      const warning = ValueKey('unitNumbersRepeatOnlineRentalsWarning');
      await pump(tester, value: true, online: true);
      expect(find.byKey(warning), findsOneWidget);
      expect(find.textContaining('may be understated'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.onChanged, isNotNull);

      await pump(tester, value: true, online: false);
      expect(find.byKey(warning), findsNothing);
      await pump(tester, value: false, online: true);
      expect(find.byKey(warning), findsNothing);
    });

    testWidgets('a refusal to turn it off is shown under it', (tester) async {
      await pump(tester, value: true, error: const RepeatedUnitNumbersException(['12']).message);
      expect(find.textContaining('Unit number 12 is used by more than one unit.'), findsOneWidget);
    });
  });
}
