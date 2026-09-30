import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/widgets/pending_invitations_card.dart';

import 'support/fake_firestore_store.dart';

Timestamp _daysAgo(int days) =>
    Timestamp.fromDate(DateTime.now().subtract(Duration(days: days)));

void main() {
  late FakeStore store;
  final User invitee = MockUser(uid: 'newbie', email: 'new@example.com', isEmailVerified: true);

  setUp(() {
    store = FakeStore();
    PermissionService.overrideForTesting(
      collection: store.collection,
      collectionGroup: store.collectionGroup,
      batch: store.batch,
      currentUser: () => invitee,
    );
  });
  tearDown(PermissionService.overrideForTesting);

  void invite(String facilityId, String id, {required int sentDaysAgo, String? facilityName}) =>
      store.put('facilities/$facilityId/invites/$id', {
        'facilityId': facilityId,
        'email': 'new@example.com',
        'emailLower': 'new@example.com',
        'roleType': 'manager',
        'status': 'pending',
        'invitedBy': 'owner',
        'invitedByEmail': 'owner@example.com',
        'invitedAt': _daysAgo(sentDaysAgo),
        if (facilityName != null) 'facilityName': facilityName,
      });

  /// The card on a dashboard route, reading through PermissionService's own
  /// query (on the fake store), with the invite link's route beside it.
  Future<void> pumpCard(WidgetTester tester, {User? user}) async {
    final router = GoRouter(initialLocation: '/dashboard', routes: [
      GoRoute(
        path: '/dashboard',
        builder: (_, __) => Scaffold(
          body: Column(children: [
            PendingInvitationsCard(user: user ?? invitee),
            const Text('dashboard'),
          ]),
        ),
      ),
      GoRoute(
        path: AppRoute.acceptInvite,
        builder: (_, state) => Text('accept ${state.uri.queryParameters['facilityId']}/'
            '${state.uri.queryParameters['inviteId']}'),
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
  }

  testWidgets('an invitation too old for the guard to accept shows its link, and says so',
      (tester) async {
    // A new invitee whose only invite was older than the auto-accept window
    // got no role and no account, and nothing in the app said why.
    invite('fac-maple', 'inv_1', sentDaysAgo: 45, facilityName: 'Maple Storage');
    await pumpCard(tester);

    expect(find.text('You have an invitation'), findsOneWidget);
    expect(find.text('Join Maple Storage as Manager'), findsOneWidget);
    expect(find.textContaining('it was not accepted automatically'), findsOneWidget);
    expect(find.textContaining('ask the owner to send a new one'), findsOneWidget);

    await tester.tap(find.text('Open invitation'));
    await tester.pumpAndSettle();
    expect(find.text('accept fac-maple/inv_1'), findsOneWidget);
  });

  testWidgets('lists every pending invitation, a recent one with who sent it', (tester) async {
    invite('fac-maple', 'inv_1', sentDaysAgo: 2, facilityName: 'Maple Storage');
    invite('fac-birch', 'inv_2', sentDaysAgo: 40);
    await pumpCard(tester);

    expect(find.text('You have 2 invitations'), findsOneWidget);
    expect(find.text('Invited by owner@example.com'), findsOneWidget);
    expect(find.text('Join a facility as Manager'), findsOneWidget);
    expect(find.text('Open invitation'), findsNWidgets(2));
  });

  testWidgets('shows nothing with no invitation, or an unverified address', (tester) async {
    await pumpCard(tester);
    expect(find.byType(Card), findsNothing);
    expect(find.text('dashboard'), findsOneWidget);

    invite('fac-maple', 'inv_1', sentDaysAgo: 2);
    await pumpCard(tester,
        user: MockUser(uid: 'newbie', email: 'new@example.com', isEmailVerified: false));
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('another login on the same dashboard sees its own invitations', (tester) async {
    // Reloaded only when first built, the card kept the last login's
    // invitations on screen after a switch of account.
    final other = MockUser(uid: 'other', email: 'other@example.com', isEmailVerified: true);
    invite('fac-maple', 'inv_1', sentDaysAgo: 2, facilityName: 'Maple Storage');
    store.put('facilities/fac-birch/invites/inv_2', {
      ...store.data('facilities/fac-maple/invites/inv_1')!,
      'facilityId': 'fac-birch',
      'email': 'other@example.com',
      'emailLower': 'other@example.com',
      'facilityName': 'Birch Storage',
    });
    final signedIn = ValueNotifier<User>(invitee);
    addTearDown(signedIn.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<User>(
          valueListenable: signedIn,
          builder: (_, user, __) => PendingInvitationsCard(user: user),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Join Maple Storage as Manager'), findsOneWidget);

    signedIn.value = other;
    await tester.pumpAndSettle();
    expect(find.text('Join Maple Storage as Manager'), findsNothing);
    expect(find.text('Join Birch Storage as Manager'), findsOneWidget);
  });

  testWidgets("keeps the facility's name, which its sender chose, to two lines", (tester) async {
    // Shown on the dashboard of whoever it was sent to; anyone can create a
    // facility with any name and invite any address.
    invite('fac-maple', 'inv_1', sentDaysAgo: 2, facilityName: 'Maple ' * 60);
    await pumpCard(tester);
    final join = tester.widget<Text>(find.textContaining('Join Maple'));
    expect(join.maxLines, 2);
    expect(join.overflow, TextOverflow.ellipsis);
  });

  testWidgets('a failed read leaves the dashboard as it was', (tester) async {
    PermissionService.overrideForTesting(
      collection: store.collection,
      collectionGroup: (_) =>
          throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      batch: store.batch,
    );
    await pumpCard(tester);
    expect(find.byType(Card), findsNothing);
    expect(find.text('dashboard'), findsOneWidget);
  });

  test('the link is the one the invite email carries', () {
    final link = PendingInvitationsCard.linkFor(FacilityInvite(
      id: 'inv 1',
      facilityId: 'fac-maple',
      email: 'new@example.com',
      emailLower: 'new@example.com',
      roleType: RoleType.manager,
      status: 'pending',
      invitedAt: DateTime(2026, 9, 1),
    ));
    expect(Uri.parse(link).path, AppRoute.acceptInvite);
    expect(Uri.parse(link).queryParameters, {'facilityId': 'fac-maple', 'inviteId': 'inv 1'});
  });
}
