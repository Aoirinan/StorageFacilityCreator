import 'dart:async';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/payment_links_management_screen.dart';
import 'package:sfcapp/services/public_payment_link_service.dart';
import 'package:sfcapp/widgets/modern_page_wrapper.dart';
import 'package:sfcapp/widgets/modern_sidebar.dart';
import 'package:sfcapp/widgets/shell_page.dart';

final _facilities = [
  FacilityModel(id: 'fac-a', name: 'Test Storage North', ownerUid: 'owner-1', createdAt: DateTime(2026, 1, 1)),
  FacilityModel(id: 'fac-b', name: 'Test Storage South', ownerUid: 'owner-1', createdAt: DateTime(2026, 1, 1)),
];

final _tenant = TenantModel(
  id: 'tenant-1',
  facilityId: 'fac-a',
  name: 'Sam Example',
  email: 'sam@example.com',
  phone: '(555) 010-0000',
  unitNumber: 'B-7',
  monthlyRate: 60,
  createdAt: DateTime(2026, 8, 1),
);

PublicPaymentLink _link(String facilityId) => PublicPaymentLink(
      id: 'link-1',
      facilityId: facilityId,
      tenantId: 'tenant-1',
      amount: 42.5,
      description: 'September rent',
      token: 'tok-1',
      status: 'pending',
      createdAt: DateTime(2026, 9, 1),
      expiresAt: DateTime(2026, 10, 1),
      createdBy: 'owner-1',
    );

/// Link reads as (facilityId, status filter).
final _loads = <(String, String?)>[];

Future<List<PublicPaymentLink>> _loadLinks(String facilityId, String? status) async {
  _loads.add((facilityId, status));
  return [_link(facilityId)];
}

Future<List<TenantModel>> _loadTenants(String facilityId) async => [_tenant];

/// The page at /payment-links?facilityId=fac-a, as the ShellRoute builds it
/// (AppShell's Scaffold stands in for the shell; its sidebar is not drawn).
Future<(GoRouter, ActiveFacilityNotifier)> _pump(
  WidgetTester tester, {
  Future<String?> Function()? loadSaved,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final picker = ActiveFacilityNotifier(
    load: loadSaved ?? () async => null,
    save: (_) async {},
  );
  final router = GoRouter(
    initialLocation: '${AppRoute.paymentLinks}?facilityId=fac-a',
    routes: [
      GoRoute(
        path: AppRoute.paymentLinks,
        builder: (context, state) => Scaffold(
          body: PaymentLinksManagementScreen(
            facilityId: state.uri.queryParameters['facilityId']!,
            loadLinks: _loadLinks,
            loadTenants: _loadTenants,
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authStateProvider.overrideWith((ref) => Stream.value(MockUser(uid: 'owner-1'))),
      userFacilitiesProvider.overrideWith((ref, uid) => Stream.value(_facilities)),
      activeFacilityIdProvider.overrideWith((ref) => picker),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return (router, picker);
}

String _facilityParam(GoRouter router) =>
    router.routeInformationProvider.value.uri.queryParameters['facilityId']!;

void main() {
  setUp(_loads.clear);

  testWidgets('draws no sidebar of its own: AppShell already has one', (tester) async {
    await _pump(tester);

    // ModernPageWrapper here put a second sidebar inside AppShell's.
    expect(find.byType(ModernPageWrapper), findsNothing);
    expect(find.byType(ModernSidebar), findsNothing);
    expect(find.byType(ShellPage), findsOneWidget);
  });

  testWidgets('keeps its title, Refresh, Create Link and the status chips', (tester) async {
    await _pump(tester);

    expect(find.text('Payment Links'), findsOneWidget);
    // Which facility, since the top bar's picker may read All Facilities.
    expect(find.text('Test Storage North'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Create Link'), findsOneWidget);
    for (final label in ['All', 'Pending', 'Paid', 'Revoked']) {
      expect(find.widgetWithText(FilterChip, label), findsOneWidget);
    }
    expect(find.text('Sam Example'), findsOneWidget);
    expect(_loads, [('fac-a', null)]);

    await tester.tap(find.widgetWithText(FilterChip, 'Paid'));
    await tester.pumpAndSettle();
    expect(_loads.last, ('fac-a', 'paid'));

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(_loads.last, ('fac-a', 'paid'));
  });

  testWidgets('picking a facility in the top bar shows its links; All Facilities keeps the page',
      (tester) async {
    final (router, picker) = await _pump(tester);

    await picker.setActiveFacilityId('fac-b');
    await tester.pumpAndSettle();
    expect(_facilityParam(router), 'fac-b');
    expect(_loads.last, ('fac-b', null));
    expect(find.text('Test Storage South'), findsOneWidget);

    await picker.setActiveFacilityId(null);
    await tester.pumpAndSettle();
    expect(_facilityParam(router), 'fac-b');
  });

  testWidgets('the saved pick arriving on first load does not redirect a link to another facility',
      (tester) async {
    final saved = Completer<String?>();
    final (router, _) = await _pump(tester, loadSaved: () => saved.future);

    saved.complete('fac-b');
    await tester.pumpAndSettle();

    expect(_facilityParam(router), 'fac-a');
    expect(_loads, [('fac-a', null)]);
  });
}
