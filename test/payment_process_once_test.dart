import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/providers/payment_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/payment_detail_screen.dart';
import 'package:sfcapp/services/payment_service.dart';

final _payment = PaymentModel(
  id: 'p1',
  tenantId: 't1',
  facilityId: 'f1',
  contractId: 'c1',
  amount: 100,
  status: PaymentStatus.pending,
  method: PaymentMethod.cash,
  dueDate: DateTime(2026, 9, 1),
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 1),
  createdBy: 'owner',
);

/// Processing marks the payment paid, moves the tenant's paidThrough on by
/// the months it buys and emails a receipt. Each call here is one of those.
class _FakeOperations extends PaymentOperationsNotifier {
  _FakeOperations(this.result);

  final Future<void> Function() result;
  int processCalls = 0;

  @override
  Future<void> processPayment({
    required String facilityId,
    required String paymentId,
    required PaymentMethod method,
    String? transactionId,
  }) {
    processCalls++;
    return result();
  }
}

void main() {
  late _FakeOperations operations;
  late Completer<void> processing;

  Future<GoRouter> pumpDetail(
    WidgetTester tester, {
    PaymentModel? payment,
  }) async {
    // In the test's zone, so pump sees it complete.
    processing = Completer<void>();
    operations = _FakeOperations(() => processing.future);
    final router = GoRouter(
      initialLocation: AppRoute.payments,
      routes: [
        GoRoute(
          path: AppRoute.payments,
          builder: (_, __) => const Text('PAYMENTS'),
        ),
        GoRoute(
          path: AppRoute.paymentDetail,
          builder: (_, __) => PaymentDetailScreen(payment: payment ?? _payment),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          facilityTenantsProvider('f1').overrideWith(
            (ref) => Stream.value(const []),
          ),
          paymentOperationsProvider.overrideWith((ref) => operations),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => Scaffold(body: child),
        ),
      ),
    );
    unawaited(router.push(AppRoute.paymentDetail));
    await tester.pumpAndSettle();
    return router;
  }

  Finder processIcon() => find.byTooltip('Process payment');

  // The payment still reads pending while it is processed, and the page's
  // Process stayed live: a second one moved paidThrough on another month.
  testWidgets('Process on the page is off while one is running',
      (tester) async {
    await pumpDetail(tester);
    await tester.tap(processIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Process'));
    await tester.pumpAndSettle();
    expect(find.text('Process Payment'), findsNothing);

    final icon = tester.widget<IconButton>(
      find.ancestor(of: processIcon(), matching: find.byType(IconButton)),
    );
    expect(icon.onPressed, isNull);
    await tester.tap(processIcon(), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Process Payment'), findsNothing);

    processing.complete();
    await tester.pumpAndSettle();
    expect(operations.processCalls, 1);
    expect(find.text('PAYMENTS'), findsOneWidget);
  });

  testWidgets('a failed Process can be tried again', (tester) async {
    await pumpDetail(tester);
    await tester.tap(processIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Process'));
    await tester.pump();
    processing.completeError(Exception('offline'));
    await tester.pumpAndSettle();

    await tester.tap(processIcon());
    await tester.pumpAndSettle();
    expect(find.text('Process Payment'), findsOneWidget);
  });

  // An Edit, Cancel or Delete could be picked while the Process was still
  // writing, and raced it.
  testWidgets('the Edit/Cancel/Delete menu is off while Process runs',
      (tester) async {
    await pumpDetail(tester);
    PopupMenuButton<String> menu() =>
        tester.widget(find.byType(PopupMenuButton<String>));
    expect(menu().enabled, isTrue);

    await tester.tap(processIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Process'));
    await tester.pumpAndSettle();
    expect(menu().enabled, isFalse);
    await tester.tap(find.byIcon(Icons.more_vert), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);

    // Back once the Process has failed.
    processing.completeError(Exception('offline'));
    await tester.pumpAndSettle();
    expect(menu().enabled, isTrue);
  });

  // PaymentService refuses a payment already paid elsewhere; the page said
  // only "An error occurred".
  testWidgets('a refused Process says why', (tester) async {
    await pumpDetail(tester);
    await tester.tap(processIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Process'));
    await tester.pump();
    processing.completeError(
      const PaymentNotProcessableException(
        'This payment is already paid, so it cannot be processed.',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('This payment is already paid, so it cannot be processed.'),
      findsOneWidget,
    );
    // The page showed the copy it was opened with and kept offering
    // Process, so the operator could only retry. Back to the list, which
    // reloads.
    expect(find.text('PAYMENTS'), findsOneWidget);
    expect(processIcon(), findsNothing);
  });

  // A failure that is not a refusal stays, so Process can be tried again.
  testWidgets('a Process that fails for another reason stays on the page',
      (tester) async {
    await pumpDetail(tester);
    await tester.tap(processIcon());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Process'));
    await tester.pump();
    processing.completeError(Exception('offline'));
    await tester.pumpAndSettle();
    expect(find.text('PAYMENTS'), findsNothing);
    expect(processIcon(), findsOneWidget);
  });

  // Disputed and part-refunded payments read as pending, so the page offered
  // Process (and Cancel) on them.
  for (final status in [
    PaymentStatus.disputed,
    PaymentStatus.partiallyRefunded,
    PaymentStatus.other,
  ]) {
    testWidgets('no Process or Cancel on a ${status.name} payment',
        (tester) async {
      await pumpDetail(
        tester,
        payment: _payment.copyWith(status: status, storedStatus: 'on_hold'),
      );
      expect(processIcon(), findsNothing);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Delete'), findsOneWidget);
    });
  }
}
