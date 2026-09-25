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
import 'package:sfcapp/providers/tenant_navigation_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/client_list_screen.dart';

UnitModel _unit(String number, String tenantId, String area) => UnitModel(
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

final _tenants = [
  _tenant('di', 'Di', 'A10'),
  _tenant('cy', 'Cy', 'B1'),
  _tenant('bo', 'Bo', 'A2'),
  _tenant('ann', 'Ann', 'A1'),
];

final _units = [
  _unit('A1', 'ann', 'Complex 3'),
  _unit('A2', 'bo', 'Complex 3'),
  _unit('A10', 'di', 'Complex 3'),
  _unit('B1', 'cy', 'Outdoor'),
];

void main() {
  // Previous / next on the tenant's page walk the list as the owner saw it:
  // the facility's tenants in the chosen Area, matching the search, in the
  // chosen sort.
  testWidgets('opening a tenant records the area-filtered, sorted list',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final facility = FacilityModel(
      id: 'fac1',
      name: 'Caprock Storage',
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
        GoRoute(
          path: AppRoute.dashboard,
          builder: (_, __) => const Text('DASHBOARD'),
        ),
        GoRoute(
          path: AppRoute.tenantDetail,
          builder: (_, state) =>
              Text('DETAIL ${(state.extra! as TenantModel).name}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Cy'), findsOneWidget);

    // As the owner picking an Area and the Unit sort. (Set after the list
    // has picked its facility, which clears the Area.)
    container.read(tenantAreaFilterProvider.notifier).state = 'Complex 3';
    container.read(tenantSortProvider.notifier).state =
        TenantSortOption.unitNumberAsc;
    await tester.pumpAndSettle();

    // Cy is in Outdoor: not shown, so not stepped to.
    expect(find.text('Cy'), findsNothing);
    await tester.tap(find.text('Bo'));
    await tester.pumpAndSettle();
    expect(find.text('DETAIL Bo'), findsOneWidget);

    final order = container.read(tenantListOrderProvider);
    expect(order?.map((t) => t.name), ['Ann', 'Bo', 'Di']);
    final neighbors = tenantNeighbors(
      facilityId: 'fac1',
      tenantId: 'bo',
      listOrder: order,
      facilityTenants: _tenants,
    )!;
    expect(neighbors.positionLabel, '2 of 3');
    expect(neighbors.previous?.name, 'Ann');
    expect(neighbors.next?.name, 'Di');

    // Leaving the list (the sidebar's go) drops its order: a tenant opened
    // from elsewhere then walks the facility's tenants by unit.
    router.go(AppRoute.dashboard);
    await tester.pumpAndSettle();
    expect(find.text('DASHBOARD'), findsOneWidget);
    expect(container.read(tenantListOrderProvider), isNull);
  });
}
