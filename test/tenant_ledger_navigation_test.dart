import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/dnr_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/back_navigation.dart';
import 'package:sfcapp/router/detail_routes.dart';
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

/// Tenant reads by id (TenantService.getTenantById in the app).
int _tenantLoads = 0;

Future<TenantModel?> _loadTenant(String facilityId, String tenantId) async {
  _tenantLoads++;
  return facilityId == _tenant.facilityId && tenantId == _tenant.id
      ? _tenant
      : null;
}

/// What the tenant page does once it is on screen; set per test. The DNR
/// tests run the real page's check, runTenantDnrCheck.
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
          // The app's tenant-detail and tenant-ledger routes, with the read
          // and the pages swapped for stand-ins.
          tenantDetailRoute(
            load: _loadTenant,
            page: (_) => const _TenantPage(),
          ),
          tenantLedgerRoute(
            load: _loadTenant,
            page: (tenant) => _LedgerPage(tenant),
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
    _tenantLoads = 0;
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

  final byIdLocation = AppRoute.tenantDetailFor(tenantId: 't1', facilityId: 'f1');

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

  // Calendar tenant events, Unit detail's "View Details", the Dashboard's
  // move-outs and the ledger's fallback all open the tenant page by id.
  group('tenant page opened by id', () {
    testWidgets('is built and loaded once over a ledger round trip',
        (tester) async {
      await pumpApp(tester, initialLocation: byIdLocation);
      expect(find.text('DETAIL'), findsOneWidget);
      expect(_detailInits, 1);

      await tapAndSettle(tester, find.text('View Ledger'));
      expect(find.text('LEDGER'), findsOneWidget);
      await tapAndSettle(tester, find.byKey(const Key('ledger-back')));
      expect(find.text('DETAIL'), findsOneWidget);

      // The route's FutureBuilder started a new read on every navigation
      // and rebuilt the page from scratch: 3 inits for this round trip.
      expect(_detailInits, 1);
      expect(_tenantLoads, 1);
    });

    testWidgets('does not show the DNR alert again after an Override',
        (tester) async {
      var overrides = 0;
      _onDetailOpened = (pageContext) => runTenantDnrCheck(
            pageContext,
            findMatches: () async => [_dnrMatch],
            onMatches: (_) {},
            onOverride: (_) => overrides++,
          );
      await pumpApp(tester, initialLocation: byIdLocation);
      await tapAndSettle(tester, find.text('Override & Continue'));
      expect(overrides, 1);

      await tapAndSettle(tester, find.text('View Ledger'));
      expect(find.text('DNR Alert'), findsNothing);
      await tapAndSettle(tester, find.byKey(const Key('ledger-back')));
      expect(find.text('DNR Alert'), findsNothing);
      expect(find.text('DETAIL'), findsOneWidget);
      expect(overrides, 1);
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
      _onDetailOpened = (pageContext) => runTenantDnrCheck(
            pageContext,
            findMatches: () async => [_dnrMatch],
            onMatches: (_) {},
            onOverride: (_) => overrides++,
          );
    });

    testWidgets('no alert for a tenant who is not on the list',
        (tester) async {
      List<DNRModel>? banner;
      _onDetailOpened = (pageContext) => runTenantDnrCheck(
            pageContext,
            findMatches: () async => [],
            onMatches: (matches) => banner = matches,
            onOverride: (_) => overrides++,
          );
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();
      expect(banner, isEmpty);
      expect(find.text('DNR Alert'), findsNothing);
      expect(find.text('DETAIL'), findsOneWidget);
    });

    testWidgets('a lookup that ends after the page has gone shows nothing',
        (tester) async {
      final lookup = Completer<void>();
      var bannerUpdates = 0;
      _onDetailOpened = (pageContext) => runTenantDnrCheck(
            pageContext,
            findMatches: () async {
              await lookup.future;
              return [_dnrMatch];
            },
            // The page's setState, which throws once it is gone.
            onMatches: (_) => bannerUpdates++,
            onOverride: (_) => overrides++,
          );
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      lookup.complete();
      await tester.pumpAndSettle();
      expect(bannerUpdates, 0);
      expect(find.text('DNR Alert'), findsNothing);
      expect(find.text('LIST'), findsOneWidget);
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
      final router = await pumpApp(tester, initialLocation: byIdLocation);
      expect(find.text('DNR Alert'), findsOneWidget);

      await tapAndSettle(tester, find.text('Cancel'));
      expect(tester.takeException(), isNull);
      expect(find.text('LIST'), findsOneWidget);
      expect(router.state.uri.path, AppRoute.tenants);
    });

    testWidgets('Cancel over a page pushed on the tenant page leaves both',
        (tester) async {
      // The owner taps View Ledger before the DNR lookup comes back, so the
      // alert comes up over the ledger.
      final lookup = Completer<void>();
      _onDetailOpened = (pageContext) => runTenantDnrCheck(
            pageContext,
            findMatches: () async {
              await lookup.future;
              return [_dnrMatch];
            },
            onMatches: (_) {},
            onOverride: (_) => overrides++,
          );
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();
      await tapAndSettle(tester, find.text('View Ledger'));
      lookup.complete();
      await tester.pumpAndSettle();
      expect(find.text('DNR Alert'), findsOneWidget);

      // Cancel used to pop the ledger and leave the flagged tenant's page
      // open underneath.
      await tapAndSettle(tester, find.text('Cancel'));
      expect(tester.takeException(), isNull);
      expect(find.text('LIST'), findsOneWidget);
      expect(find.text('LEDGER'), findsNothing);
      expect(find.text('DETAIL'), findsNothing);
      expect(router.state.uri.path, AppRoute.tenants);
      expect(router.canPop(), isFalse);
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

    testWidgets('a second Override tap does nothing', (tester) async {
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();

      // Two taps before the alert has animated out.
      final override = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Override & Continue'),
      );
      override.onPressed!();
      override.onPressed!();
      await tester.pumpAndSettle();

      // One audit record, and the second pop no longer takes the page (or
      // the app shell) with it.
      expect(overrides, 1);
      expect(tester.takeException(), isNull);
      expect(find.text('DETAIL'), findsOneWidget);
      expect(router.canPop(), isTrue);
    });

    testWidgets('the alert closes even when onOverride throws',
        (tester) async {
      // As the tenant page's setState once the page is gone.
      _onDetailOpened = (pageContext) => runTenantDnrCheck(
            pageContext,
            findMatches: () async => [_dnrMatch],
            onMatches: (_) {},
            onOverride: (_) => throw StateError('page gone'),
          );
      final router = await pumpApp(tester);
      unawaited(router.push(AppRoute.tenantDetail, extra: _tenant));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Override & Continue'));
      expect(tester.takeException(), isStateError);
      await tester.pumpAndSettle();
      expect(find.text('DNR Alert'), findsNothing);
      expect(find.text('DETAIL'), findsOneWidget);
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
