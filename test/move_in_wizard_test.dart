import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/move_in_wizard_screen.dart';
import 'package:sfcapp/services/move_in_service.dart';

final _tenant = TenantModel(
  id: 't1',
  facilityId: 'f1',
  name: 'Pat Renter',
  email: 'pat@example.com',
  phone: '5550100',
  unitNumber: '',
  monthlyRate: 0,
  createdAt: DateTime(2026, 1, 1),
);

UnitModel _unit({
  UnitStatus status = UnitStatus.available,
  String? tenantId,
  String? tenantName,
}) =>
    UnitModel(
      id: 'u1',
      facilityId: 'f1',
      unitNumber: 'A1',
      unitType: 'standard',
      status: status,
      tenantId: tenantId,
      tenantName: tenantName,
      monthlyRate: 100,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner',
    );

final _lease = ContractModel(
  id: 'c1',
  facilityId: 'f1',
  facilityOwnerUid: 'owner',
  tenantId: 't1',
  title: 'Storage Lease - A1',
  description: 'Move-in contract for unit A1',
  type: ContractType.lease,
  status: ContractStatus.draft,
  createdAt: DateTime(2026, 1, 1),
  createdBy: 'owner',
);

void main() {
  group('move-in wizard', () {
    late int leases;
    late int moveIns;
    late Completer<MoveInResult> moveIn;
    late MoveInWizardServices services;

    setUp(() {
      leases = 0;
      moveIns = 0;
      services = MoveInWizardServices(
        getFacility: (_) async => null,
        getUnits: (_) async => [_unit()],
        getTenants: (_) async => [_tenant],
        createLeaseContract: ({
          required String facilityId,
          required String tenantId,
          required String unitNumber,
        }) async {
          leases++;
          return _lease;
        },
        completeMoveIn: ({
          required MoveInData moveInData,
          String? paymentMethod,
          String? paymentReferenceId,
          bool skipPayment = false,
        }) {
          moveIns++;
          return moveIn.future;
        },
      );
    });

    // The calendar opens the wizard with go; nothing is underneath it.
    // [shell]: an outer Scaffold, as the app shell gives, so a snackbar
    // shown while leaving is still on screen on the page left to.
    Future<GoRouter> pumpWizard(WidgetTester tester, {bool shell = false}) async {
      // Made in the test's fake-async zone, or its completion is never seen
      // by pump.
      moveIn = Completer<MoveInResult>();
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: AppRoute.moveInWizard,
        routes: [
          GoRoute(
            path: AppRoute.moveInWizard,
            builder: (_, __) => MoveInWizardScreen(
              facilityId: 'f1',
              unitId: 'u1',
              tenantId: 't1',
              services: services,
            ),
          ),
          GoRoute(
            path: AppRoute.tenantDetail,
            builder: (_, state) => Text(
              'TENANT ${state.uri.queryParameters['tenantId']}',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            routerConfig: router,
            builder: shell ? (context, child) => Scaffold(body: child) : null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    Finder continueButton() =>
        find.widgetWithText(TextButton, 'Continue').hitTestable();

    Future<void> continueToReview(WidgetTester tester) async {
      // Tenant & unit, financial, contract, payment.
      for (var step = 0; step < 4; step++) {
        await tester.tap(continueButton());
        await tester.pumpAndSettle();
      }
      expect(tester.widget<Stepper>(find.byType(Stepper)).currentStep, 4);
    }

    testWidgets('two quick Continue taps on the last step complete it once',
        (tester) async {
      await pumpWizard(tester);
      await continueToReview(tester);

      // The second tap lands before the rebuild that disables the button.
      await tester.tap(continueButton());
      await tester.tap(continueButton(), warnIfMissed: false);
      await tester.pump();

      expect(moveIns, 1);
      expect(leases, 1);
      // And the step buttons stay disabled while it runs.
      final buttons = tester.widgetList<TextButton>(
        find.ancestor(
          of: find.text('Continue'),
          matching: find.byType(TextButton),
        ),
      );
      expect(buttons, isNotEmpty);
      expect(buttons.every((b) => b.onPressed == null), isTrue);

      moveIn.complete(MoveInResult(success: true, tenantId: 't1'));
      await tester.pumpAndSettle();
      expect(moveIns, 1);
      // Opened with go, so it lands on the tenant's page.
      expect(find.text('TENANT t1'), findsOneWidget);
    });

    testWidgets("a unit added to an existing tenant's shows their new rent", (tester) async {
      await pumpWizard(tester, shell: true);
      await continueToReview(tester);
      await tester.tap(continueButton());
      await tester.pump();
      moveIn.complete(MoveInResult(
        success: true,
        tenantId: 't1',
        notice: r'Monthly rent is now $200.00 for units 101 and A1.',
      ));
      await tester.pumpAndSettle();
      expect(find.text('TENANT t1'), findsOneWidget);
      expect(
        find.text(r'Move-in completed. Monthly rent is now $200.00 for units 101 and A1.'),
        findsOneWidget,
      );
    });

    testWidgets('a first unit keeps the plain success message', (tester) async {
      await pumpWizard(tester, shell: true);
      await continueToReview(tester);
      await tester.tap(continueButton());
      await tester.pump();
      moveIn.complete(MoveInResult(success: true, tenantId: 't1'));
      await tester.pumpAndSettle();
      expect(find.text('Move-in completed successfully!'), findsOneWidget);
    });

    testWidgets('a failed move-in can be tried again', (tester) async {
      await pumpWizard(tester);
      await continueToReview(tester);

      await tester.tap(continueButton());
      await tester.pump();
      moveIn.complete(MoveInResult(success: false, error: 'Unit is busy'));
      await tester.pumpAndSettle();
      expect(find.text('Unit is busy'), findsOneWidget);

      moveIn = Completer<MoveInResult>();
      await tester.tap(continueButton());
      await tester.pump();
      expect(moveIns, 2);
      // The lease from the first attempt is reused.
      expect(leases, 1);
    });
  });

  group('leaveAfterMoveIn', () {
    GoRouter router(String initialLocation) => GoRouter(
          initialLocation: initialLocation,
          routes: [
            GoRoute(
              path: AppRoute.calendar,
              builder: (_, __) => const Text('CALENDAR'),
            ),
            GoRoute(
              path: AppRoute.moveInWizard,
              builder: (context, _) => TextButton(
                onPressed: () => leaveAfterMoveIn(
                  context,
                  facilityId: 'f1',
                  tenantId: 't1',
                ),
                child: const Text('Finish'),
              ),
            ),
            GoRoute(
              path: AppRoute.tenantDetail,
              builder: (_, state) => Text(
                'TENANT ${state.uri.queryParameters['tenantId']} '
                'IN ${state.uri.queryParameters['facilityId']}',
              ),
            ),
          ],
        );

    Future<GoRouter> pump(WidgetTester tester, String location) async {
      final r = router(location);
      addTearDown(r.dispose);
      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: r,
          builder: (context, child) => Scaffold(body: child),
        ),
      );
      await tester.pumpAndSettle();
      return r;
    }

    testWidgets('pops back to the page that pushed the wizard with true',
        (tester) async {
      final r = await pump(tester, AppRoute.calendar);
      final result = r.push<bool>(AppRoute.moveInWizard);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(find.text('CALENDAR'), findsOneWidget);
    });

    testWidgets('opens the tenant page when nothing is underneath',
        (tester) async {
      await pump(tester, AppRoute.moveInWizard);

      await tester.tap(find.text('Finish'));
      await tester.pumpAndSettle();
      // A bare pop threw here, after the move-in had been written.
      expect(tester.takeException(), isNull);
      expect(find.text('TENANT t1 IN f1'), findsOneWidget);
    });
  });

  group('moveInUnitConflict', () {
    test('lets a move-in into an available unit run', () {
      expect(moveInUnitConflict(unit: _unit(), tenantId: 't1'), isNull);
    });

    test('lets it run when the unit could not be read', () {
      expect(moveInUnitConflict(unit: null, tenantId: 't1'), isNull);
    });

    test('lets a reservation for this tenant be moved in', () {
      expect(
        moveInUnitConflict(
          unit: _unit(status: UnitStatus.reserved, tenantId: 't1'),
          tenantId: 't1',
        ),
        isNull,
      );
    });

    test('refuses a move-in this tenant has already finished', () {
      expect(
        moveInUnitConflict(
          unit: _unit(status: UnitStatus.occupied, tenantId: 't1'),
          tenantId: 't1',
        ),
        contains('already moved into Unit A1'),
      );
    });

    test('refuses a unit another tenant is in', () {
      for (final status in [
        UnitStatus.occupied,
        UnitStatus.overlocked,
        UnitStatus.lockout,
        UnitStatus.auction,
      ]) {
        expect(
          moveInUnitConflict(
            unit: _unit(status: status, tenantId: 't2', tenantName: 'Sam'),
            tenantId: 't1',
          ),
          'Unit A1 is already occupied by Sam.',
          reason: status.name,
        );
      }
    });
  });
}
