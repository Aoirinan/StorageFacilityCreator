import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/screens/unit_detail_screen.dart';

/// Records Remove Lockout's write; no tenant doc, so nothing else is read.
class _FakeActions extends UnitDetailActions {
  final written = <UnitStatus>[];

  @override
  Future<TenantModel?> tenant(String facilityId, String tenantId) async => null;

  @override
  Future<double> balance(String facilityId, String tenantId) async => 0;

  @override
  Future<void> setStatus(String facilityId, String unitId, UnitStatus status) async =>
      written.add(status);
}

/// The unit screen's menu, opened for real. Remove Lockout was only offered
/// on occupied units, and Set Lockout moves a unit to lockout, so it
/// vanished when needed; and it always set the unit occupied, even with no
/// tenant on it.
void main() {
  final day = DateTime(2026, 9, 1);

  UnitModel unit(UnitStatus status, String? tenantId) => UnitModel(
        id: 'u7',
        facilityId: 'f1',
        unitNumber: '7',
        unitType: 'standard',
        status: status,
        tenantId: tenantId,
        tenantName: tenantId == null ? null : 'Ada Park',
        monthlyRate: 100,
        createdAt: day,
        updatedAt: day,
        createdBy: 'owner',
      );

  Future<_FakeActions> openMenu(WidgetTester tester, UnitModel u) async {
    final actions = _FakeActions();
    await tester.pumpWidget(ProviderScope(
      overrides: [unitDetailActionsProvider.overrideWithValue(actions)],
      child: MaterialApp(home: UnitDetailScreen.fromUnit(u)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    return actions;
  }

  testWidgets('a locked-out unit offers Remove Lockout, which leaves it occupied by its tenant',
      (tester) async {
    final actions = await openMenu(tester, unit(UnitStatus.lockout, 't1'));
    expect(find.text('Remove Lockout'), findsOneWidget);
    await tester.tap(find.text('Remove Lockout'));
    await tester.pumpAndSettle();
    expect(actions.written, [UnitStatus.occupied]);
  });

  testWidgets('with no tenant on the unit, Remove Lockout makes it available', (tester) async {
    final actions = await openMenu(tester, unit(UnitStatus.overlocked, null));
    await tester.tap(find.text('Remove Lockout'));
    await tester.pumpAndSettle();
    expect(actions.written, [UnitStatus.available]);
  });

  testWidgets('occupied or available units without a lockout do not offer it', (tester) async {
    await openMenu(tester, unit(UnitStatus.occupied, 't1'));
    expect(find.text('Remove Lockout'), findsNothing);
    expect(find.text('Unassign Tenant'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await openMenu(tester, unit(UnitStatus.available, null));
    expect(find.text('Remove Lockout'), findsNothing);
  });

  test('statusAfterRemovingLockout', () {
    expect(statusAfterRemovingLockout(unit(UnitStatus.lockout, 't1')), UnitStatus.occupied);
    expect(statusAfterRemovingLockout(unit(UnitStatus.lockout, null)), UnitStatus.available);
    expect(statusAfterRemovingLockout(unit(UnitStatus.lockout, ' ')), UnitStatus.available);
  });
}
