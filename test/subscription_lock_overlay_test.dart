import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';
import 'package:sfcapp/widgets/subscription_lock_overlay.dart';

FacilityCreatorAccountModel _account({required bool suspended}) {
  final now = DateTime.now();
  return FacilityCreatorAccountModel(
    accountId: 'acct_1',
    ownerUid: 'owner_1',
    ownerEmail: 'owner@example.com',
    ownerName: 'Owner',
    // Suspending also cancels the account; the lapsed one's period is over.
    subscriptionStatus: SubscriptionStatus.cancelled,
    suspended: suspended,
    subscriptionCurrentPeriodEnd:
        suspended ? now.add(const Duration(days: 10)) : now.subtract(const Duration(days: 10)),
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  const subscribe = 'Subscribe your facility (\$75/mo)';

  /// The overlay in the shell on /dashboard, deciding the lock with the real
  /// shellLock rule over [account] (read from a fake).
  Future<List<String>> pumpOverlay(WidgetTester tester, FacilityCreatorAccountModel account) async {
    final contacted = <String>[];
    final router = GoRouter(initialLocation: '/dashboard', routes: [
      GoRoute(
        path: '/dashboard',
        builder: (_, __) => SubscriptionLockOverlay(
          currentUser: () => MockUser(uid: 'owner_1', email: 'owner@example.com'),
          shellLock: (uid) => SubscriptionGuardService.shellLock(
            uid,
            accountProvider: (_) async => account,
            facilitiesProvider: () async => const [],
          ),
          contactSupport: () async => contacted.add('support'),
          child: const Text('the app'),
        ),
      ),
      GoRoute(path: '/subscription', builder: (_, __) => const Text('subscription page')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    return contacted;
  }

  testWidgets('a suspended account is told so, and pointed at support instead of billing',
      (tester) async {
    // The widget passed the rule's reason only with no account, so a
    // suspended (cancelled) account was told to reactivate, and it was offered
    // Subscribe and Manage Subscription, although paying lifts no suspension.
    final contacted = await pumpOverlay(tester, _account(suspended: true));

    expect(find.text('Account Suspended'), findsOneWidget);
    expect(find.text('This account is suspended. Contact support to restore access.'),
        findsOneWidget);
    expect(find.textContaining('reactivate'), findsNothing);
    expect(find.text(subscribe), findsNothing);
    expect(find.text('Manage Subscription'), findsNothing);
    expect(find.text(SubscriptionLockOverlay.supportEmail), findsOneWidget);

    await tester.tap(find.text('Contact support'));
    await tester.pump();
    expect(contacted, ['support']);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a lapsed account still gets Subscribe and Manage Subscription', (tester) async {
    final contacted = await pumpOverlay(tester, _account(suspended: false));

    expect(find.text('Subscription Required'), findsOneWidget);
    expect(find.textContaining('cancelled'), findsOneWidget);
    expect(find.text('Contact support'), findsNothing);
    expect(find.text(subscribe), findsOneWidget);

    await tester.tap(find.text('Manage Subscription'));
    await tester.pumpAndSettle();
    expect(find.text('subscription page'), findsOneWidget);
    expect(contacted, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });
}
