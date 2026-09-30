import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/screens/subscription_test_screen.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/widgets/subscription_lock_overlay.dart';

FacilityCreatorAccountModel _suspended({bool billingExempt = false}) {
  final now = DateTime.now();
  return FacilityCreatorAccountModel(
    accountId: 'acct_1',
    ownerUid: 'owner_1',
    ownerEmail: 'owner@example.com',
    ownerName: 'Owner',
    // What suspending writes: cancelled, with the period and trial cleared.
    subscriptionStatus: SubscriptionStatus.cancelled,
    suspended: true,
    billingExempt: billingExempt,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  /// /subscription's Subscription tab, with the owner's account from [load].
  Future<List<String>> pumpScreen(
    WidgetTester tester,
    Future<FacilityCreatorAccountModel> Function() load,
  ) async {
    final contacted = <String>[];
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: SubscriptionTestScreen(
            loadAccount: load,
            contactSupport: () async => contacted.add('support'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return contacted;
  }

  testWidgets('a suspended owner is sent to support, with nothing to buy', (tester) async {
    // The guard sends a suspended account to /subscription, where the lock
    // overlay steps aside; this page offered Stripe checkout, which took $75
    // and lifted nothing.
    final contacted = await pumpScreen(tester, () async => _suspended());

    expect(find.text('Account Suspended'), findsOneWidget);
    expect(find.textContaining('contact support'), findsOneWidget);
    expect(find.text(SubscriptionLockOverlay.supportEmail), findsOneWidget);
    expect(find.textContaining('Subscribe'), findsNothing);
    expect(find.textContaining('Start'), findsNothing);
    expect(find.textContaining(r'$75'), findsNothing);

    await tester.tap(find.text('Contact support'));
    await tester.pump();
    expect(contacted, ['support']);
  });

  testWidgets('a team member is told billing is the owner\'s, not "Error loading account"',
      (tester) async {
    final contacted =
        await pumpScreen(tester, () async => throw const InvitedStaffAccountException());

    expect(find.text("Billing is handled by the facility's owner"), findsOneWidget);
    expect(find.textContaining('ask the facility owner'), findsOneWidget);
    expect(find.text('No account found'), findsNothing);
    expect(find.text('Contact support'), findsNothing);
    expect(contacted, isEmpty);
  });
}
