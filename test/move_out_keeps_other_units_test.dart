import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/move_out_service.dart';
import 'package:sfcapp/services/unit_service.dart';

import 'support/fake_facility_collection.dart';

/// Whether a tenant moving out keeps another unit decides the rate the
/// move-out prorates: the vacated unit's while they keep one, else theirs.
/// processMoveOut decides it again (isHeld in moveOutTenantFields.ts) and
/// refuses a net that differs from the screen's. A linked unit with no
/// status read as available here and as kept there, so such a move-out was
/// refused every time. Both sides run the same table.
void main() {
  final fixture = jsonDecode(File(
          'functions-tenant-lifecycle/src/test/fixtures/moveOutKeepsOtherUnits.json')
      .readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
  final tenantRate = ((fixture['tenant'] as Map)['monthlyRate'] as num).toDouble();
  final vacated = (fixture['vacated'] as Map).cast<String, dynamic>();
  final defaults = (fixture['otherDefaults'] as Map).cast<String, dynamic>();

  tearDown(() => FacilitySubcollections.overrideForTesting(null));

  test('the table has the cases both sides share', () {
    expect(cases.length, greaterThan(10));
  });

  for (final c in cases) {
    test('the screen decides as processMoveOut does: ${c['name']}', () async {
      final units = FakeCollection([
        FakeDoc(vacated['id'] as String,
            (vacated['data'] as Map).cast<String, dynamic>()),
        FakeDoc('u2', {...defaults, ...(c['data'] as Map).cast<String, dynamic>()}),
      ]);
      FacilitySubcollections.overrideForTesting((facilityId, name) {
        expect(name, 'units');
        return units;
      });

      // What the move-out screen does: the facility's units as the Units
      // list reads them, the tenant's choices, then the rate.
      final read = await UnitService.readFacilityUnits('fac1');
      final picked = MoveOutService.moveOutUnitChoices(
        tenantId: 't1',
        tenantUnitNumber: '1',
        tenantUnitId: 'u1',
        units: read,
        preferredUnitId: 'u1',
      );
      final unit = picked.initial;
      expect(unit?.id, 'u1', reason: c['name'] as String);
      final keeps = MoveOutService.keepsOtherUnits(
        tenantId: 't1',
        vacated: unit,
        units: picked.choices,
      );
      expect(keeps, c['keepsOtherUnits'], reason: c['name'] as String);
      // The same over every unit read, not only the choices: the rule is
      // keepsOtherUnits' own, not an accident of the picker's filter.
      expect(
        MoveOutService.keepsOtherUnits(
            tenantId: 't1', vacated: unit, units: read),
        c['keepsOtherUnits'],
        reason: '${c['name']} (all units)',
      );
      expect(
        MoveOutService.prorationRate(
          tenantRate: tenantRate,
          unitRate: unit?.monthlyRate,
          keepsOtherUnits: keeps,
        ),
        (c['rate'] as num).toDouble(),
        reason: c['name'] as String,
      );
    });
  }

  test('the move-out screen asks MoveOutService.keepsOtherUnits', () {
    // The rule is only shared if the screen uses it.
    final screen = File('lib/screens/move_out_screen.dart').readAsStringSync();
    expect(screen, contains('MoveOutService.keepsOtherUnits('));
    expect(screen, contains('keepsOtherUnits: _keepsOtherUnits,'));
  });
}
