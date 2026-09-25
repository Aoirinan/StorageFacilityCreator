import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/tenant_navigation_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/detail_routes.dart';
import 'package:sfcapp/screens/ledger_screen.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';
import 'package:sfcapp/widgets/tenant_prev_next.dart';

TenantModel _t(String id, String unit, {bool isActive = true}) => TenantModel(
      id: id,
      facilityId: 'f1',
      name: 'Tenant $id',
      email: '',
      phone: '',
      unitNumber: unit,
      monthlyRate: 50,
      createdAt: DateTime(2026, 1, 1),
      isActive: isActive,
    );

// By unit: a (A1), b (A2), c (A10); z is archived.
final _a = _t('a', 'A1');
final _b = _t('b', 'A2');
final _c = _t('c', 'A10');
final _z = _t('z', 'A3', isActive: false);
final _facility = [_c, _z, _a, _b];

Future<TenantModel?> _load(String facilityId, String tenantId) async {
  for (final t in _facility) {
    if (t.facilityId == facilityId && t.id == tenantId) return t;
  }
  return null;
}

/// Times a stand-in page's State was created, by tenant id.
final _inits = <String, int>{};

class _DetailPage extends StatefulWidget {
  const _DetailPage(this.tenant);

  final TenantModel tenant;

  @override
  State<_DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<_DetailPage> {
  // Set once, as the real page's DNR result and month edits are: a State
  // reused for the next tenant would still show this one.
  late final String _openedFor = widget.tenant.id;

  @override
  void initState() {
    super.initState();
    _inits.update(widget.tenant.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Text('DETAIL $_openedFor'),
        TenantPrevNextControls(tenant: widget.tenant, page: TenantPage.detail),
        TextButton(
          onPressed: () => context.push(
            AppRoute.tenantLedgerFor(
              tenantId: widget.tenant.id,
              facilityId: widget.tenant.facilityId,
            ),
            extra: widget.tenant,
          ),
          child: const Text('View Ledger'),
        ),
        const SizedBox(width: 200, child: TextField(key: Key('notes'))),
      ],
    );
  }
}

class _LedgerPage extends StatefulWidget {
  const _LedgerPage(this.tenant);

  final TenantModel tenant;

  @override
  State<_LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends State<_LedgerPage> {
  late final String _openedFor = widget.tenant.id;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Text('LEDGER $_openedFor'),
        TenantPrevNextControls(tenant: widget.tenant, page: TenantPage.ledger),
        IconButton(
          key: const Key('ledger-back'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => backToTenantFromLedger(context, widget.tenant),
        ),
        // As the ledger's Add entry.
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              content: const TextField(key: Key('amount'), autofocus: true),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
          child: const Text('Add entry'),
        ),
      ],
    );
  }
}

GoRouter _router({String initialLocation = AppRoute.tenants}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          body: Column(
            children: [
              // AppShell's top-bar back.
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
              // AppShell's page area, which takes the keyboard for
              // Up / Down scrolling.
              Expanded(child: KeyboardScrollable(child: child)),
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
            // Scrolls, as the real list does, so KeyboardScrollable takes
            // the focus before a tenant is opened.
            builder: (_, __) => ListView(children: const [Text('LIST')]),
          ),
          tenantDetailRoute(load: _load, page: (t) => _DetailPage(t)),
          tenantLedgerRoute(load: _load, page: (t) => _LedgerPage(t)),
        ],
      ),
    ],
  );
}

void main() {
  late ProviderContainer container;

  setUp(() {
    _inits.clear();
    container = ProviderContainer(overrides: [
      facilityTenantsProvider('f1')
          .overrideWith((ref) => Stream.value(_facility)),
    ]);
  });

  tearDown(() => container.dispose());

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    String initialLocation = AppRoute.tenants,
  }) async {
    final router = _router(initialLocation: initialLocation);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    return router;
  }

  /// As the tenant list: its order, then the tenant's page over it.
  Future<void> openFromList(
    GoRouter router,
    WidgetTester tester,
    TenantModel tenant,
    List<TenantModel> shown,
  ) async {
    container.read(tenantListOrderProvider.notifier).state = shown;
    unawaited(router.push(AppRoute.tenantDetail, extra: tenant));
    await tester.pumpAndSettle();
  }

  Finder button(String tooltip) => find.widgetWithIcon(
        IconButton,
        tooltip == previousTenantTooltip
            ? Icons.chevron_left
            : Icons.chevron_right,
      );

  bool enabled(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(button(tooltip)).onPressed != null;

  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  group('tenant page', () {
    testWidgets('steps through the list order and Back returns to the list',
        (tester) async {
      final router = await pumpApp(tester);
      // As the list showed them: not unit order.
      await openFromList(router, tester, _c, [_c, _z, _a]);
      expect(find.text('DETAIL c'), findsOneWidget);
      expect(find.text('1 of 3'), findsOneWidget);
      expect(enabled(tester, previousTenantTooltip), isFalse);
      expect(enabled(tester, nextTenantTooltip), isTrue);

      await tapAndSettle(tester, button(nextTenantTooltip));
      expect(find.text('DETAIL z'), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);

      await tapAndSettle(tester, button(nextTenantTooltip));
      expect(find.text('DETAIL a'), findsOneWidget);
      expect(find.text('3 of 3'), findsOneWidget);
      expect(enabled(tester, nextTenantTooltip), isFalse);
      expect(enabled(tester, previousTenantTooltip), isTrue);

      // Replaced, not pushed: one Back to the list.
      await tapAndSettle(tester, find.byKey(const Key('top-back')));
      expect(find.text('LIST'), findsOneWidget);
      expect(router.canPop(), isFalse);
    });

    testWidgets('each tenant gets a new page, not the last one\'s State',
        (tester) async {
      final router = await pumpApp(tester);
      await openFromList(router, tester, _a, [_a, _b]);
      await tapAndSettle(tester, button(nextTenantTooltip));
      expect(find.text('DETAIL b'), findsOneWidget);
      await tapAndSettle(tester, button(previousTenantTooltip));
      expect(find.text('DETAIL a'), findsOneWidget);
      expect(_inits, {'a': 2, 'b': 1});
    });

    testWidgets('falls back to active tenants by unit without the list',
        (tester) async {
      await pumpApp(
        tester,
        initialLocation:
            AppRoute.tenantDetailFor(tenantId: 'b', facilityId: 'f1'),
      );
      expect(find.text('DETAIL b'), findsOneWidget);
      // A1, A2, A10; the archived tenant is left out.
      expect(find.text('2 of 3'), findsOneWidget);

      await tapAndSettle(tester, button(nextTenantTooltip));
      expect(find.text('DETAIL c'), findsOneWidget);
      expect(find.text('3 of 3'), findsOneWidget);
      expect(enabled(tester, nextTenantTooltip), isFalse);
    });

    testWidgets('no buttons for an archived tenant opened from elsewhere',
        (tester) async {
      await pumpApp(
        tester,
        initialLocation:
            AppRoute.tenantDetailFor(tenantId: 'z', facilityId: 'f1'),
      );
      expect(find.text('DETAIL z'), findsOneWidget);
      expect(find.byTooltip(nextTenantTooltip), findsNothing);
      expect(find.byTooltip(previousTenantTooltip), findsNothing);
    });

    testWidgets('Left and Right arrow keys move, and stop at the ends',
        (tester) async {
      final router = await pumpApp(tester);
      await openFromList(router, tester, _a, [_a, _b, _c]);

      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('DETAIL a'), findsOneWidget);

      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('DETAIL b'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('DETAIL c'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('DETAIL c'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowLeft);
      expect(find.text('DETAIL b'), findsOneWidget);

      await tapAndSettle(tester, find.byKey(const Key('top-back')));
      expect(find.text('LIST'), findsOneWidget);
    });

    testWidgets('arrow keys stay in a text field', (tester) async {
      final router = await pumpApp(tester);
      await openFromList(router, tester, _a, [_a, _b]);
      await tapAndSettle(tester, find.byKey(const Key('notes')));

      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('DETAIL a'), findsOneWidget);

      // A click off the field lets go of it, and the arrows move again.
      await tester.tap(find.text('DETAIL a'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('DETAIL b'), findsOneWidget);
    });

    testWidgets('Alt+Right (the browser\'s Forward) does nothing here',
        (tester) async {
      final router = await pumpApp(tester);
      await openFromList(router, tester, _a, [_a, _b]);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.text('DETAIL a'), findsOneWidget);
    });
  });

  group('ledger', () {
    Future<GoRouter> openLedger(WidgetTester tester) async {
      final router = await pumpApp(tester);
      await openFromList(router, tester, _a, [_a, _b, _c]);
      await tapAndSettle(tester, find.text('View Ledger'));
      expect(find.text('LEDGER a'), findsOneWidget);
      return router;
    }

    testWidgets('moves to the next tenant\'s ledger', (tester) async {
      await openLedger(tester);
      expect(find.text('1 of 3'), findsOneWidget);

      await tapAndSettle(tester, button(nextTenantTooltip));
      expect(find.text('LEDGER b'), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);

      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('LEDGER c'), findsOneWidget);
      expect(enabled(tester, nextTenantTooltip), isFalse);
    });

    testWidgets(
        'back arrow shows the tenant just worked on, then Back reaches the list',
        (tester) async {
      final router = await openLedger(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('LEDGER c'), findsOneWidget);

      await tapAndSettle(tester, find.byKey(const Key('ledger-back')));
      expect(find.text('DETAIL c'), findsOneWidget);
      expect(find.text('3 of 3'), findsOneWidget);

      await tapAndSettle(tester, find.byKey(const Key('top-back')));
      expect(find.text('LIST'), findsOneWidget);
      expect(router.canPop(), isFalse);
    });

    testWidgets('the top bar\'s back does the same', (tester) async {
      final router = await openLedger(tester);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('LEDGER b'), findsOneWidget);

      await tapAndSettle(tester, find.byKey(const Key('top-back')));
      expect(find.text('DETAIL b'), findsOneWidget);
      await tapAndSettle(tester, find.byKey(const Key('top-back')));
      expect(find.text('LIST'), findsOneWidget);
      expect(router.canPop(), isFalse);
    });

    testWidgets('back without moving keeps the same tenant page',
        (tester) async {
      await openLedger(tester);
      await tapAndSettle(tester, find.byKey(const Key('ledger-back')));
      expect(find.text('DETAIL a'), findsOneWidget);
      // Not rebuilt from scratch: its DNR check ran once.
      expect(_inits, {'a': 1});
    });

    testWidgets('after the add-entry dialog closes the keys move on',
        (tester) async {
      await openLedger(tester);
      await tapAndSettle(tester, find.text('Add entry'));
      expect(find.byKey(const Key('amount')), findsOneWidget);

      // In the dialog, arrows are the amount field's.
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('LEDGER a'), findsOneWidget);

      await tapAndSettle(tester, find.text('Save'));
      expect(find.byKey(const Key('amount')), findsNothing);

      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('LEDGER b'), findsOneWidget);
      expect(find.text('LEDGER a'), findsNothing);

      // And again from the next tenant's ledger.
      await tapAndSettle(tester, find.text('Add entry'));
      await tapAndSettle(tester, find.text('Save'));
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('LEDGER c'), findsOneWidget);
    });

    testWidgets('opened by link, moving then back opens that tenant\'s page',
        (tester) async {
      final router = await pumpApp(
        tester,
        initialLocation:
            AppRoute.tenantLedgerFor(tenantId: 'a', facilityId: 'f1'),
      );
      expect(find.text('LEDGER a'), findsOneWidget);
      await key(tester, LogicalKeyboardKey.arrowRight);
      expect(find.text('LEDGER b'), findsOneWidget);

      await tapAndSettle(tester, find.byKey(const Key('ledger-back')));
      expect(find.text('DETAIL b'), findsOneWidget);
      expect(router.canPop(), isFalse);
    });
  });
}
