import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/permission_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/client_list_screen.dart';
import 'package:sfcapp/utils/unit_areas.dart';

// All names are made up. Ann holds two units on one record (A1 is the one
// the record names; A2 points at her through its tenantId).

UnitModel _unit(String number, String tenantId) => UnitModel(
      id: 'u-$number',
      facilityId: 'fac1',
      unitNumber: number,
      unitType: 'standard',
      status: UnitStatus.occupied,
      tenantId: tenantId,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner-1',
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

final _tenants = [
  _tenant('ann', 'Ann', 'A1'),
  _tenant('bo', 'Bo', 'B1'),
];

final _units = [
  _unit('A1', 'ann'),
  _unit('A2', 'ann'),
  _unit('B1', 'bo'),
];

void main() {
  group('tenantMatchesSearch', () {
    test('any unit the tenant holds, given the units; only the record\'s without', () {
      final ann = _tenants.first;
      final index = TenantUnitAreaIndex(_units);
      expect(tenantMatchesSearch(ann, 'a1', units: index), isTrue);
      expect(tenantMatchesSearch(ann, 'a2', units: index), isTrue);
      expect(tenantMatchesSearch(ann, 'b1', units: index), isFalse);
      expect(tenantMatchesSearch(ann, 'a2'), isFalse);
      expect(tenantMatchesSearch(ann, 'ann'), isTrue);
    });
  });

  testWidgets('the list names every unit a tenant holds and finds them by any of them',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final facility = FacilityModel(
      id: 'fac1',
      name: 'Test Storage',
      ownerUid: 'owner-1',
      createdAt: DateTime(2026, 1, 1),
    );
    final container = ProviderContainer(overrides: [
      authStateProvider
          .overrideWith((ref) => Stream.value(MockUser(uid: 'owner-1'))),
      userFacilitiesProvider('owner-1')
          .overrideWith((ref) => Stream.value([facility])),
      activeFacilityIdProvider.overrideWith(
        (ref) => ActiveFacilityNotifier.idle(const AsyncValue.data('fac1')),
      ),
      facilityUnitsProvider('fac1').overrideWith((ref) => Stream.value(_units)),
      facilityTenantsProvider('fac1')
          .overrideWith((ref) => Stream.value(_tenants)),
      canDeleteTenantAtFacilityProvider('fac1')
          .overrideWith((ref) async => false),
    ]);
    addTearDown(container.dispose);
    container.listen(authStateProvider, (_, __) {});
    container.listen(userFacilitiesProvider('owner-1'), (_, __) {});
    await tester.runAsync(() async {
      await container.read(authStateProvider.future);
      await container.read(userFacilitiesProvider('owner-1').future);
    });

    final router = GoRouter(
      initialLocation: AppRoute.tenants,
      routes: [
        GoRoute(
          path: AppRoute.tenants,
          builder: (_, __) => const Scaffold(body: ClientListScreen()),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    // The card's unit line, with no area on any unit: every unit held.
    expect(find.text('Unit: A1, A2'), findsOneWidget);
    expect(find.text('Unit: B1'), findsOneWidget);

    // Searching the second unit finds her; Units > Unit List was the only
    // way before.
    container.read(tenantSearchProvider.notifier).state = 'a2';
    await tester.pumpAndSettle();
    expect(find.text('Ann'), findsOneWidget);
    expect(find.text('Bo'), findsNothing);

    container.read(tenantSearchProvider.notifier).state = 'b1';
    await tester.pumpAndSettle();
    expect(find.text('Ann'), findsNothing);
    expect(find.text('Bo'), findsOneWidget);
  });
}
