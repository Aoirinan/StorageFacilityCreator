import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/screens/unit_list_screen.dart';
import 'package:sfcapp/utils/bulk_action.dart';

UnitModel _unit(String id) => UnitModel(
      id: id,
      facilityId: 'f1',
      unitNumber: id,
      unitType: 'standard',
      status: UnitStatus.available,
      monthlyRate: 100,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'test',
    );

/// Archives and deletes every unit but those in [refuse].
class _FakeUnitOperations extends UnitOperationsNotifier {
  _FakeUnitOperations(this.refuse);

  final Set<String> refuse;
  final archived = <String>[];
  final deleted = <String>[];

  @override
  Future<void> archiveUnit(String facilityId, String unitId) async {
    if (refuse.contains(unitId)) throw Exception('permission-denied');
    archived.add(unitId);
  }

  @override
  Future<void> deleteUnit(String facilityId, String unitId) async {
    if (refuse.contains(unitId)) throw Exception('permission-denied');
    deleted.add(unitId);
  }
}

void main() {
  group('runBulkAction', () {
    test('carries on past a failure and says which were done', () async {
      final result = await runBulkAction(['a', 'b', 'c'], (id) async {
        if (id == 'b') throw Exception('network-request-failed');
      });
      expect(result.done, ['a', 'c']);
      expect(result.failed.keys, ['b']);
      expect(result.attempted, 3);
      expect(
        bulkActionMessage(
          result,
          verb: 'Archived',
          noun: 'units',
          allDone: 'all archived',
        ),
        'Archived 2 of 3 units. 1 was not: Network connection error. '
        'Please check your internet connection and try again.',
      );
    });

    test('says the all-done message when nothing failed', () async {
      final result = await runBulkAction(['a', 'b'], (_) async {});
      expect(
        bulkActionMessage(
          result,
          verb: 'Archived',
          noun: 'units',
          allDone: '2 unit(s) archived',
        ),
        '2 unit(s) archived',
      );
    });
  });

  // Bulk Archive and Delete stopped at the first failure and said only
  // "Error archiving units": the units done stayed archived or deleted,
  // still selected, and nothing said how many.
  group('the Units list', () {
    late _FakeUnitOperations operations;

    Future<void> pumpList(WidgetTester tester, {Set<String> refuse = const {}}) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      operations = _FakeUnitOperations(refuse);
      final facility = FacilityModel(
        id: 'f1',
        name: 'Oak Storage',
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
            (ref) => ActiveFacilityNotifier.idle(const AsyncValue.data('f1')),
          ),
          facilityUnitsProvider('f1').overrideWith(
            (ref) => Stream.value([_unit('A1'), _unit('A2'), _unit('A3')]),
          ),
          facilityTenantsProvider('f1').overrideWith(
            (ref) => Stream.value(const []),
          ),
          unitOperationsProvider.overrideWith((ref) => operations),
        ],
      );
      addTearDown(container.dispose);
      // Signed in, with the facility list loaded, as the page is reached in
      // the app: it picks its facility from them when it opens.
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
    }

    Future<void> selectAll(WidgetTester tester) async {
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
    }

    testWidgets('Archive reports how many of how many, and keeps the rest '
        'selected', (tester) async {
      await pumpList(tester, refuse: {'A2'});
      await selectAll(tester);
      await tester.tap(find.text('Archive 3'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
      await tester.pumpAndSettle();

      expect(operations.archived, ['A1', 'A3']);
      expect(find.textContaining('Archived 2 of 3 units. 1 was not:'),
          findsOneWidget);
      // The one not archived stays selected, to try again.
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('Delete permanently reports how many of how many',
        (tester) async {
      await pumpList(tester, refuse: {'A1'});
      await selectAll(tester);
      await tester.tap(find.text('Delete 3 permanently'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
      await tester.pumpAndSettle();

      expect(operations.deleted, ['A2', 'A3']);
      expect(find.textContaining('Deleted 2 of 3 units. 1 was not:'),
          findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets('all archived: the old message, and nothing left selected',
        (tester) async {
      await pumpList(tester);
      await selectAll(tester);
      await tester.tap(find.text('Archive 3'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Archive'));
      await tester.pumpAndSettle();

      expect(operations.archived, ['A1', 'A2', 'A3']);
      expect(find.text('3 unit(s) archived'), findsOneWidget);
      expect(find.textContaining('selected'), findsNothing);
    });
  });
}
