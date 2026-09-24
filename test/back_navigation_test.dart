import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/back_navigation.dart';

/// As the move-in wizard's "done": leave with a result.
class _Wizard extends StatelessWidget {
  const _Wizard();

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => popOrGo(context, AppRoute.tenants, true),
      child: const Text('Done'),
    );
  }
}

GoRouter _router() {
  return GoRouter(
    initialLocation: AppRoute.calendar,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(body: child),
        routes: [
          GoRoute(
            path: AppRoute.calendar,
            builder: (_, __) => const Text('CALENDAR'),
          ),
          GoRoute(
            path: AppRoute.tenants,
            builder: (_, __) => const Text('LIST'),
          ),
          GoRoute(
            path: AppRoute.moveInWizard,
            builder: (_, __) => const _Wizard(),
          ),
        ],
      ),
    ],
  );
}

void main() {
  Future<GoRouter> pumpApp(WidgetTester tester) async {
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('popOrGo hands its result to the page underneath',
      (tester) async {
    final router = await pumpApp(tester);
    final result = router.push<bool>(AppRoute.moveInWizard);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.text('CALENDAR'), findsOneWidget);
  });

  // The calendar opens the move-in wizard with go. A bare context.pop(true)
  // after a successful move-in threw "There is nothing to pop", and the
  // wizard reported the finished move-in as failed.
  testWidgets('popOrGo goes to the fallback when nothing is underneath',
      (tester) async {
    final router = await pumpApp(tester);
    router.go(AppRoute.moveInWizard);
    await tester.pumpAndSettle();
    expect(router.canPop(), isFalse);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('LIST'), findsOneWidget);
    expect(router.state.uri.path, AppRoute.tenants);
  });

  test('paymentDetailFor builds a location the detail route can read back',
      () {
    final uri = Uri.parse(
      AppRoute.paymentDetailFor(paymentId: 'p 1', facilityId: 'f&1'),
    );
    expect(uri.path, AppRoute.paymentDetail);
    expect(uri.queryParameters, {'paymentId': 'p 1', 'facilityId': 'f&1'});
  });
}
