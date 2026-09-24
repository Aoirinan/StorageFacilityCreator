import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/lien_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/detail_routes.dart';

LienModel _lien(String id, String facilityId) => LienModel(
      id: id,
      facilityId: facilityId,
      tenantId: 't1',
      unitId: 'u1',
      contractId: 'c1',
      currentStage: LienStage.noticeSent,
      status: LienStatus.active,
      totalAmount: 100,
      principalAmount: 100,
      lateFees: 0,
      createdAt: DateTime(2026, 1, 1),
      createdBy: 'owner',
    );

/// Lien reads by id, as LienService.getLien.
final _loads = <String>[];

/// How many more reads of 'flaky' fail before one succeeds.
int _flakyFailures = 0;

Future<LienModel?> _loadLien(String facilityId, String id) async {
  _loads.add('$facilityId/$id');
  if (id == 'boom') throw StateError('read failed');
  // What the rules answer for another account's facility.
  if (id == 'denied') {
    throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied');
  }
  if (id == 'offline') {
    throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
  }
  if (id == 'flaky' && _flakyFailures > 0) {
    _flakyFailures--;
    throw StateError('offline');
  }
  return id == 'missing' ? null : _lien(id, facilityId);
}

/// Times a detail page was built from scratch.
int _pageInits = 0;

class _DetailPage extends StatefulWidget {
  const _DetailPage(this.label);

  final String label;

  @override
  State<_DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<_DetailPage> {
  @override
  void initState() {
    super.initState();
    _pageInits++;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(widget.label),
        TextButton(
          onPressed: () => context.push('/other'),
          child: const Text('Open other'),
        ),
      ],
    );
  }
}

// Documents written without a facilityId field read back with ''.
final _paymentWithoutFacility = PaymentModel(
  id: 'p1',
  tenantId: 't1',
  facilityId: '',
  contractId: 'c1',
  amount: 100,
  status: PaymentStatus.pending,
  method: PaymentMethod.cash,
  dueDate: DateTime(2026, 1, 1),
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  createdBy: 'owner',
);

final _contractWithoutFacility = ContractModel(
  id: 'c1',
  facilityId: '',
  facilityOwnerUid: 'owner',
  tenantId: 't1',
  title: 'Lease',
  description: '',
  type: ContractType.lease,
  status: ContractStatus.signed,
  createdAt: DateTime(2026, 1, 1),
  createdBy: 'owner',
);

final _tenantWithoutFacility = TenantModel(
  id: 't1',
  facilityId: '',
  name: 'Pat Renter',
  email: 'pat@example.com',
  phone: '5550100',
  unitNumber: 'A1',
  monthlyRate: 100,
  createdAt: DateTime(2026, 1, 1),
);

GoRouter _router(String initialLocation) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(body: child),
        routes: [
          // The app's own routes (detail_routes.dart), with the reads and
          // the pages swapped for stand-ins.
          lienDetailRoute(
            load: _loadLien,
            page: (lien, facilityId) =>
                _DetailPage('LIEN ${lien.id} IN $facilityId'),
          ),
          paymentDetailRoute(
            load: (_, __) async => _paymentWithoutFacility,
            page: (payment) =>
                _DetailPage('PAYMENT ${payment.id} IN ${payment.facilityId}'),
          ),
          contractDetailRoute(
            load: (_, __) async => _contractWithoutFacility,
            page: (contract) => _DetailPage(
              'CONTRACT ${contract.id} IN ${contract.facilityId}',
            ),
          ),
          tenantDetailRoute(
            load: (_, __) async => _tenantWithoutFacility,
            page: (tenant) =>
                _DetailPage('TENANT ${tenant.id} IN ${tenant.facilityId}'),
          ),
          tenantLedgerRoute(
            load: (_, __) async => _tenantWithoutFacility,
            page: (tenant) =>
                _DetailPage('LEDGER ${tenant.id} IN ${tenant.facilityId}'),
          ),
          GoRoute(
            path: '/other',
            builder: (_, __) => const Text('OTHER'),
          ),
        ],
      ),
    ],
  );
}

void main() {
  setUp(() {
    _loads.clear();
    _flakyFailures = 0;
    _pageInits = 0;
  });

  Future<GoRouter> pumpApp(WidgetTester tester, String location) async {
    final router = _router(location);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return router;
  }

  String lienAt(String lienId, [String facilityId = 'f1']) => Uri(
        path: AppRoute.lienDetail,
        queryParameters: {'lienId': lienId, 'facilityId': facilityId},
      ).toString();

  // The calendar links lien, auction and contract events by id; these
  // routes needed `extra` and showed "Page not found".
  testWidgets('a link by id opens the page', (tester) async {
    await pumpApp(tester, lienAt('l1'));
    expect(find.text('LIEN l1 IN f1'), findsOneWidget);
    expect(_loads, ['f1/l1']);
  });

  testWidgets('the page opened with extra is not loaded again',
      (tester) async {
    final router = await pumpApp(tester, '/other');
    router.go(
      AppRoute.lienDetail,
      extra: <String, dynamic>{'lien': _lien('l1', 'f1'), 'facilityId': 'f1'},
    );
    await tester.pumpAndSettle();
    expect(find.text('LIEN l1 IN f1'), findsOneWidget);
    expect(_loads, isEmpty);
  });

  testWidgets('is loaded and built once while pages come and go over it',
      (tester) async {
    final router = await pumpApp(tester, lienAt('l1'));
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Open other'));
      await tester.pumpAndSettle();
      expect(find.text('OTHER'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('LIEN l1 IN f1'), findsOneWidget);
    }
    // go_router re-runs the route builder on every navigation; a load
    // started there ran again each time and rebuilt the page.
    expect(_loads, ['f1/l1']);
    expect(_pageInits, 1);
  });

  testWidgets('loads again when the same page is reused for other ids',
      (tester) async {
    final router = await pumpApp(tester, lienAt('l1'));
    // Only the query string differs, so go_router keeps the same page.
    router.go(lienAt('l2'));
    await tester.pumpAndSettle();
    expect(find.text('LIEN l2 IN f1'), findsOneWidget);
    expect(find.text('LIEN l1 IN f1'), findsNothing);
    expect(_loads, ['f1/l1', 'f1/l2']);
    expect(_pageInits, 2);
  });

  testWidgets('shows Page not found without the facility', (tester) async {
    await pumpApp(tester, '${AppRoute.lienDetail}?lienId=l1');
    expect(find.text('Page not found'), findsOneWidget);
    expect(_loads, isEmpty);
  });

  testWidgets('shows Page not found when nothing is there', (tester) async {
    await pumpApp(tester, lienAt('missing'));
    expect(find.text('Page not found'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  group('a failed read', () {
    // It used to show "Page not found", as if the lien were gone, with no
    // way to try again but reloading the app.
    testWidgets('is not shown as Page not found', (tester) async {
      await pumpApp(tester, lienAt('boom'));
      expect(find.text('Page not found'), findsNothing);
      expect(find.text("Couldn't load this page"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('Retry reads again and opens the page', (tester) async {
      _flakyFailures = 1;
      await pumpApp(tester, lienAt('flaky'));
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('LIEN flaky IN f1'), findsOneWidget);
      expect(_loads, ['f1/flaky', 'f1/flaky']);
    });

    // A link into another account's facility, or a role since removed. It
    // said "Check your connection" and offered a Retry the rules refuse.
    testWidgets('refused by the rules says so, with no Retry', (tester) async {
      await pumpApp(tester, lienAt('denied'));
      expect(find.text("You don't have access to this page"), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text("Couldn't load this page"), findsNothing);
      expect(find.text('Page not found'), findsNothing);
    });

    testWidgets('other Firebase errors keep Retry', (tester) async {
      await pumpApp(tester, lienAt('offline'));
      expect(find.text("Couldn't load this page"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text("You don't have access to this page"), findsNothing);
    });
  });

  group('a page opened by id takes the facility from the link', () {
    // The pages act through model.facilityId, which is '' on documents
    // written without one.
    testWidgets('payment', (tester) async {
      await pumpApp(
        tester,
        AppRoute.paymentDetailFor(paymentId: 'p1', facilityId: 'f1'),
      );
      expect(find.text('PAYMENT p1 IN f1'), findsOneWidget);
    });

    testWidgets('contract', (tester) async {
      await pumpApp(tester, '${AppRoute.contractDetail}?contractId=c1&facilityId=f1');
      expect(find.text('CONTRACT c1 IN f1'), findsOneWidget);
    });

    testWidgets('tenant and ledger', (tester) async {
      final router = await pumpApp(
        tester,
        AppRoute.tenantDetailFor(tenantId: 't1', facilityId: 'f1'),
      );
      expect(find.text('TENANT t1 IN f1'), findsOneWidget);

      router.go('/tenants/t1/ledger?facilityId=f1');
      await tester.pumpAndSettle();
      expect(find.text('LEDGER t1 IN f1'), findsOneWidget);
    });

    testWidgets('but a model passed as extra is used as it is',
        (tester) async {
      final router = await pumpApp(tester, '/other');
      router.go(AppRoute.paymentDetail, extra: _paymentWithoutFacility);
      await tester.pumpAndSettle();
      expect(find.text('PAYMENT p1 IN '), findsOneWidget);
    });
  });

  // The tests above run detail_routes.dart. An inline copy of one of these
  // routes in app_router.dart would go untested, as the by-id loads did.
  test('app_router uses the shared detail routes', () {
    final router = File('lib/router/app_router.dart').readAsStringSync();
    for (final route in [
      'tenantDetailRoute()',
      'tenantLedgerRoute()',
      'contractDetailRoute()',
      'paymentDetailRoute()',
      'lienDetailRoute()',
    ]) {
      expect(router, contains(route));
    }
    for (final path in [
      'path: AppRoute.tenantDetail,',
      "path: '/tenants/:tenantId/ledger',",
      'path: AppRoute.contractDetail,',
      'path: AppRoute.paymentDetail,',
      'path: AppRoute.lienDetail,',
    ]) {
      expect(router, isNot(contains(path)));
    }
  });
}
