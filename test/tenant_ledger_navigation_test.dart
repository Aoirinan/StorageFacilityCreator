import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/dnr_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/back_navigation.dart';
import 'package:sfcapp/screens/ledger_screen.dart';
import 'package:sfcapp/widgets/dnr_blocking_dialog.dart';

final _tenant = TenantModel(
  id: 't1',
  facilityId: 'f1',
  name: 'Pat Renter',
  email: 'pat@example.com',
  phone: '5550100',
  unitNumber: 'A1',
  monthlyRate: 100,
  createdAt: DateTime(2026, 1, 1),
);

final _dnrMatch = DNRModel(
  id: 'd1',
  name: 'Pat Renter',
  nameLower: 'pat renter',
  email: 'pat@example.com',
  emailLower: 'pat@example.com',
  phone: '5550100',
  phoneDigits: '5550100',
  reason: 'Unpaid balance',
  active: true,
  addedAt: DateTime(2026, 1, 1),
  addedByUid: 'owner',
  facilityId: 'f1',
);

const _ledgerLocation = '/tenants/t1/ledger?facilityId=f1';

/// Times a tenant page was built from scratch. Each one re-runs the real
/// page's DNR check and gate-access load.
int _detailInits = 0;

/// What the tenant page does once it is on screen; set per test.
void Function(BuildContext pageContext)? _onDetailOpened;

GoRouter _router(
  GlobalKey<NavigatorState> shellKey, {
  String initialLocation = AppRoute.tenants,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      // The app's shape: list, tenant page and ledger are siblings in one
      // ShellRoute, and the tenant page and ledger are pushed over the list.
      ShellRoute(
        navigatorKey: shellKey,
        builder: (context, state, child) => Scaffold(
          body: Column(
            children: [
              // AppShell's top-bar back (_goBack).
              IconButton(
                key: const Key('top-back'),
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  if (GoRouter.of(context).canPop()) {
                    context.pop();
                  } else {
                    context.go(AppRoute.dashboard);
                  }
                },
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
            builder: (_, __) => const Text('LIST'),
          ),
          GoRoute(
            path: AppRoute.tenantDetail,
            builder: (_, __) => const _TenantPage(),
          ),
          GoRoute(
            path: '/tenants/:tenantId/ledger',
            builder: (_, state) => _LedgerPage(
              state.extra is TenantModel ? state.extra! as TenantModel : _tenant,
            ),
          ),
        ],
      ),
    ],
  );
}

class _TenantPage extends StatefulWidget {
  const _TenantPage();

  @override
  State<_TenantPage> createState() => _TenantPageState();
}

class _TenantPageState extends State<_TenantPage> {
  @override
  void initState() {
    super.initState();
    _detailInits++;
    final opened = _onDetailOpened;
    if (opened != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) opened(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text('DETAIL'),
        // As ClientDetailScreen's "View Ledger".
        TextButton(
          onPressed: () => context.push(_ledgerLocation, extra: _tenant),
          child: const Text('View Ledger'),
        ),
      ],
    );
  }
}

class _LedgerPage extends StatelessWidget {
  const _LedgerPage(this.tenant);

  final TenantModel tenant;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text('LEDGER'),
        IconButton(
          key: const Key('ledger-back'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => backToTenantFromLedger(context, tenant),
        ),
      ],
    );
  }
}

void main() {
  late GlobalKey<NavigatorState> shellKey;

  setUp(() {
    shellKey = GlobalKey<NavigatorState>();
    _detailInits = 0;
    _onDetailOpened = null;
  });

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    String initialLocation = AppRoute.tenants,
  }) async {
    final router = _router(shellKey, initialLocation: initialLocation);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return router;
  }

  int shellPages() => shellKey.currentState!.widget.pages.length;

  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('ledger back arrow', () {
    testWidgets('returns to the tenant page, and top back then reaches the list',
        (tester) async {
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();
      await tapAndSettle(tester, find.text('View Ledger'));
      expect(find.text('LEDGER'), findsOneWidget);

      await tapAndSettle(tester, find.byKey(const Key('ledger-back')));
      expect(find.text('DETAIL'), findsOneWidget);
      expect(find.text('LEDGER'), findsNothing);

      // This used to show the ledger again: its back arrow had pushed a
      // second tenant page on top of it.
      await tapAndSettle(tester, find.byKey(const Key('top-back')));
      expect(find.text('LIST'), findsOneWidget);
      expect(find.text('LEDGER'), findsNothing);
      expect(router.canPop(), isFalse);
    });

    testWidgets('round trips keep one tenant page under the ledger',
        (tester) async {
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();
      expect(shellPages(), 2);

      for (var i = 0; i < 3; i++) {
        await tapAndSettle(tester, find.text('View Ledger'));
        expect(shellPages(), 3);
        await tapAndSettle(tester, find.byKey(const Key('ledger-back')));
        expect(find.text('DETAIL'), findsOneWidget);
        expect(shellPages(), 2, reason: 'round trip ${i + 1}');
      }
      // The same tenant page throughout, so its DNR check ran once.
      expect(_detailInits, 1);
    });

    testWidgets('opens the tenant page by id when nothing is underneath',
        (tester) async {
      final router = await pumpApp(tester, initialLocation: _ledgerLocation);
      expect(find.text('LEDGER'), findsOneWidget);
      expect(router.canPop(), isFalse);

      await tapAndSettle(tester, find.byKey(const Key('ledger-back')));
      expect(
        router.state.uri.toString(),
        '/tenants/detail?tenantId=t1&facilityId=f1',
      );
      expect(find.text('DETAIL'), findsOneWidget);
    });
  });

  test('tenantDetailFor builds a location the detail route can read back', () {
    final uri = Uri.parse(
      AppRoute.tenantDetailFor(tenantId: 't 1', facilityId: 'f&1'),
    );
    expect(uri.path, AppRoute.tenantDetail);
    expect(uri.queryParameters, {'tenantId': 't 1', 'facilityId': 'f&1'});
  });

  group('DNR alert on the tenant page', () {
    var overrides = 0;

    setUp(() {
      overrides = 0;
      _onDetailOpened = (pageContext) => showDnrBlockingDialog(
            pageContext,
            matches: [_dnrMatch],
            onOverride: () => overrides++,
          );
    });

    testWidgets('Cancel goes back to the list and keeps the app shell',
        (tester) async {
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();
      expect(find.text('DNR Alert'), findsOneWidget);

      await tapAndSettle(tester, find.text('Cancel'));
      expect(tester.takeException(), isNull);
      expect(find.text('DNR Alert'), findsNothing);
      expect(find.text('LIST'), findsOneWidget);
      expect(find.byKey(const Key('top-back')), findsOneWidget);
      expect(router.canPop(), isFalse);
      expect(overrides, 0);
    });

    testWidgets('Cancel opens the list when nothing is underneath',
        (tester) async {
      final router = await pumpApp(
        tester,
        initialLocation: AppRoute.tenantDetailFor(tenantId: 't1', facilityId: 'f1'),
      );
      expect(find.text('DNR Alert'), findsOneWidget);

      await tapAndSettle(tester, find.text('Cancel'));
      expect(tester.takeException(), isNull);
      expect(find.text('LIST'), findsOneWidget);
      expect(router.state.uri.path, AppRoute.tenants);
    });

    testWidgets('Override keeps the tenant page open', (tester) async {
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();

      await tapAndSettle(tester, find.text('Override & Continue'));
      expect(find.text('DNR Alert'), findsNothing);
      expect(find.text('DETAIL'), findsOneWidget);
      expect(router.canPop(), isTrue);
      expect(overrides, 1);
    });
  });

  // The facility wizard's and the trial dialog's buttons close their dialog
  // and call popOrGo in the same tap.
  testWidgets('popOrGo straight after closing a dialog leaves the page only',
      (tester) async {
    _onDetailOpened = (pageContext) => showDialog<void>(
          context: pageContext,
          builder: (dialogContext) => TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              popOrGo(pageContext, AppRoute.dashboard);
            },
            child: const Text('Leave'),
          ),
        );
    final router = await pumpApp(tester);
    unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
    await tester.pumpAndSettle();

    await tapAndSettle(tester, find.text('Leave'));
    expect(tester.takeException(), isNull);
    expect(find.text('LIST'), findsOneWidget);
    expect(find.byKey(const Key('top-back')), findsOneWidget);
    expect(router.canPop(), isFalse);
  });
}
