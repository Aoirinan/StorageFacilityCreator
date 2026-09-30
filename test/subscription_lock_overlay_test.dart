import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/owner_account_standing.dart';
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

FacilityCreatorAccountModel _active() {
  final now = DateTime.now();
  return FacilityCreatorAccountModel(
    accountId: 'acct_1',
    ownerUid: 'owner_1',
    ownerEmail: 'owner@example.com',
    ownerName: 'Owner',
    subscriptionStatus: SubscriptionStatus.active,
    subscriptionCurrentPeriodEnd: now.add(const Duration(days: 20)),
    createdAt: now,
    updatedAt: now,
  );
}

/// A facility the signed-in team member works at, whose owner's account the
/// backend copied onto it as [standing].
FacilityModel _teamFacility(OwnerAccountStanding standing) => FacilityModel(
      id: 'fac_team',
      name: 'Owner Storage',
      ownerUid: 'owner_1',
      createdAt: DateTime(2026),
      facilityCreatorAccountId: 'acct_owner',
      ownerAccountStanding: standing,
      currentUserOwnsFacility: false,
    );

void main() {
  const subscribe = 'Subscribe your facility (\$75/mo)';

  /// The overlay in the shell on /dashboard, deciding the lock with the real
  /// shellLock rule over the account [account] returns (read from a fake)
  /// and the facilities [facilities] returns.
  Future<List<String>> pumpOverlay(
    WidgetTester tester,
    FacilityCreatorAccountModel? account, {
    FacilityCreatorAccountModel? Function()? accountNow,
    List<FacilityModel> Function()? facilities,
  }) async {
    final contacted = <String>[];
    final router = GoRouter(initialLocation: '/dashboard', routes: [
      GoRoute(
        path: '/dashboard',
        builder: (_, __) => SubscriptionLockOverlay(
          currentUser: () => MockUser(uid: 'owner_1', email: 'owner@example.com'),
          shellLock: (uid) => SubscriptionGuardService.shellLock(
            uid,
            accountProvider: (_) async => accountNow != null ? accountNow() : account,
            facilitiesProvider: () async => facilities != null ? facilities() : const [],
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

  testWidgets('re-checks every 10 seconds: paying elsewhere unlocks, a suspension locks',
      (tester) async {
    // Nothing re-evaluated the lock after the first check once the chain of
    // delayed calls was a timer, so an owner who paid in another tab stayed
    // locked, and an account suspended mid-session stayed open.
    var account = _account(suspended: false);
    await pumpOverlay(tester, null, accountNow: () => account);
    expect(find.text('Subscription Required'), findsOneWidget);

    account = _active();
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();
    expect(find.text('Subscription Required'), findsOneWidget, reason: 'not yet');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Subscription Required'), findsNothing);
    expect(find.text('the app'), findsOneWidget);

    account = _account(suspended: true);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(find.text('Account Suspended'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a team member of a lapsed owner is told to ask the owner, not to subscribe',
      (tester) async {
    // With no account of their own, staff were offered Subscribe your
    // facility and Manage Subscription for a facility they do not own.
    var standing = const OwnerAccountStanding(
      accountId: 'acct_owner',
      subscriptionStatus: SubscriptionStatus.cancelled,
    );
    final contacted =
        await pumpOverlay(tester, null, facilities: () => [_teamFacility(standing)]);

    expect(find.text('Team Access Paused'), findsOneWidget);
    expect(find.textContaining('Ask the owner to renew it'), findsOneWidget);
    expect(find.text(subscribe), findsNothing);
    expect(find.text('Manage Subscription'), findsNothing);
    expect(find.text('Contact support'), findsNothing);

    // The owner renews; Check again lets them straight back in.
    standing = const OwnerAccountStanding(
      accountId: 'acct_owner',
      subscriptionStatus: SubscriptionStatus.active,
    );
    await tester.tap(find.text('Check again'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Team Access Paused'), findsNothing);
    expect(find.text('the app'), findsOneWidget);
    expect(contacted, isEmpty);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("and a suspended owner's team member is not told to have it renewed",
      (tester) async {
    await pumpOverlay(tester, null, facilities: () => [
          _teamFacility(const OwnerAccountStanding(
            accountId: 'acct_owner',
            subscriptionStatus: SubscriptionStatus.cancelled,
            suspended: true,
          )),
        ]);

    expect(find.text('Team Access Paused'), findsOneWidget);
    expect(find.textContaining("owner's account is suspended"), findsOneWidget);
    expect(find.textContaining('renew'), findsNothing);
    expect(find.text(subscribe), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
