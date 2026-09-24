import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/modern_navigation_service.dart';

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoute.tenants,
    routes: [
      // The app's shape: every section and its detail pages are siblings in
      // one ShellRoute, and detail pages are pushed over their section.
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          body: Column(
            children: [
              // AppShell's sidebar items.
              TextButton(
                onPressed: () => ModernNavigationService.navigateToRoute(
                  context,
                  AppRoute.tenants,
                ),
                child: const Text('Sidebar: Tenants'),
              ),
              TextButton(
                onPressed: () => ModernNavigationService.navigateToRoute(
                  context,
                  AppRoute.dashboard,
                ),
                child: const Text('Sidebar: Dashboard'),
              ),
              Expanded(child: child),
            ],
          ),
        ),
        routes: [
          GoRoute(
            path: AppRoute.dashboard,
            builder: (_, __) => const Text('DASHBOARD'),
          ),
          GoRoute(
            path: AppRoute.tenants,
            builder: (_, __) => const _TenantList(),
          ),
          GoRoute(
            path: AppRoute.tenantDetail,
            builder: (_, __) => const Text('DETAIL'),
          ),
          GoRoute(
            path: '/tenants/:tenantId/ledger',
            builder: (_, __) => const Text('LEDGER'),
          ),
        ],
      ),
    ],
  );
}

/// Stands in for the tenant list, with some state that a needless rebuild
/// would lose.
class _TenantList extends StatefulWidget {
  const _TenantList();

  @override
  State<_TenantList> createState() => _TenantListState();
}

class _TenantListState extends State<_TenantList> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => setState(() => _taps++),
      child: Text('LIST $_taps'),
    );
  }
}

void main() {
  Future<GoRouter> pumpApp(WidgetTester tester) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return router;
  }

  // navigateToRoute navigates from a post-frame callback, so pump a frame
  // before settling.
  Future<void> tapSidebar(WidgetTester tester, String label) async {
    await tester.tap(find.text('Sidebar: $label'));
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets("Tenants from a tenant's ledger shows the list", (tester) async {
    final router = await pumpApp(tester);
    unawaited(router.push(AppRoute.tenantDetail));
    await tester.pumpAndSettle();
    unawaited(router.push('/tenants/t1/ledger?facilityId=f1'));
    await tester.pumpAndSettle();
    expect(find.text('LEDGER'), findsOneWidget);

    // This did nothing: the URL still read /tenants, so it counted as
    // "already there".
    await tapSidebar(tester, 'Tenants');
    expect(find.text('LEDGER'), findsNothing);
    expect(find.text('LIST 0'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('Dashboard from a tenant opened on the dashboard shows it',
      (tester) async {
    final router = await pumpApp(tester);
    router.go(AppRoute.dashboard);
    await tester.pumpAndSettle();
    unawaited(router.push(AppRoute.tenantDetail));
    await tester.pumpAndSettle();
    expect(find.text('DETAIL'), findsOneWidget);

    await tapSidebar(tester, 'Dashboard');
    expect(find.text('DETAIL'), findsNothing);
    expect(find.text('DASHBOARD'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('Tenants on the list itself leaves the list as it is',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('LIST 0'));
    await tester.pumpAndSettle();
    expect(find.text('LIST 1'), findsOneWidget);

    await tapSidebar(tester, 'Tenants');
    expect(find.text('LIST 1'), findsOneWidget);
  });
}
