import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/accept_invite_screen.dart';
import 'package:sfcapp/services/permission_service.dart';

import 'support/fake_firestore_store.dart';

/// Signed in, with the sign-in event already spent: it arrived while the
/// screen was still loading the invite, which is when it is ignored.
class _EventSpentAuth extends MockFirebaseAuth {
  _EventSpentAuth(MockUser user) : super(signedIn: true, mockUser: user);

  @override
  Stream<User?> authStateChanges() => const Stream.empty();
}

void main() {
  late FakeStore store;
  final invitee = MockUser(uid: 'newbie', email: 'new@example.com');

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

  void invite({required String status, String? acceptedBy, String? facilityName}) =>
      store.put('facilities/fac-maple/invites/inv_1', {
        'facilityId': 'fac-maple',
        'email': 'new@example.com',
        'emailLower': 'new@example.com',
        'roleType': 'employee',
        'status': status,
        'invitedBy': 'owner',
        'invitedAt': Timestamp.fromDate(DateTime(2026, 9, 20)),
        if (acceptedBy != null) 'acceptedBy': acceptedBy,
        if (facilityName != null) 'facilityName': facilityName,
      });

  /// The invite link, opened by [signedIn] (or signed out, with [auth]).
  Future<void> openLink(WidgetTester tester, {MockUser? signedIn, MockFirebaseAuth? auth}) async {
    auth ??= MockFirebaseAuth(signedIn: signedIn != null, mockUser: signedIn);
    final router = GoRouter(
      initialLocation: '${AppRoute.acceptInvite}?facilityId=fac-maple&inviteId=inv_1',
      routes: [
        GoRoute(
          path: AppRoute.acceptInvite,
          builder: (_, state) => AcceptInviteScreen(
            facilityId: state.uri.queryParameters['facilityId']!,
            inviteId: state.uri.queryParameters['inviteId']!,
            auth: auth,
          ),
        ),
        GoRoute(path: AppRoute.dashboard, builder: (_, __) => const Text('dashboard')),
        GoRoute(path: AppRoute.login, builder: (_, __) => const Text('login')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
  }

  testWidgets('an invite this login already accepted goes straight to the dashboard',
      (tester) async {
    // A signup through the link has the invite accepted (on signup, or by
    // the route guard) before this screen loads, and was told "This
    // invitation has already been accepted or cancelled".
    invite(status: 'accepted', acceptedBy: 'newbie');
    store.put('facilities/fac-maple', {
      'ownerUid': 'owner',
      'roles': {'owner': 'owner', 'newbie': 'employee'},
    });
    await openLink(tester, signedIn: invitee);

    expect(find.text('dashboard'), findsOneWidget);
    expect(find.textContaining('already been accepted'), findsNothing);
  });

  testWidgets('the load itself finishes it, without waiting on a sign-in event', (tester) async {
    invite(status: 'accepted', acceptedBy: 'newbie');
    store.put('facilities/fac-maple', {
      'ownerUid': 'owner',
      'roles': {'owner': 'owner', 'newbie': 'employee'},
    });
    await openLink(tester, auth: _EventSpentAuth(invitee));
    expect(find.text('dashboard'), findsOneWidget);
  });

  testWidgets('but not if they have been removed since: they are told to ask again',
      (tester) async {
    invite(status: 'accepted', acceptedBy: 'newbie');
    store.put('facilities/fac-maple', {
      'ownerUid': 'owner',
      'roles': {'owner': 'owner'},
    });
    await openLink(tester, signedIn: invitee);

    expect(find.text('dashboard'), findsNothing);
    expect(find.textContaining('no longer have access'), findsOneWidget);
    expect(find.textContaining('send you a new invitation'), findsOneWidget);
  });

  testWidgets("someone else's acceptance is not theirs", (tester) async {
    invite(status: 'accepted', acceptedBy: 'someone-else');
    store.put('facilities/fac-maple', {
      'ownerUid': 'owner',
      'roles': {'owner': 'owner', 'newbie': 'employee', 'someone-else': 'employee'},
    });
    await openLink(tester, signedIn: invitee);

    expect(find.text('dashboard'), findsNothing);
    expect(find.textContaining('already been accepted or cancelled'), findsOneWidget);
  });

  testWidgets('a cancelled invite says to ask for a new one', (tester) async {
    invite(status: 'cancelled');
    await openLink(tester, signedIn: invitee);

    expect(find.text('dashboard'), findsNothing);
    expect(
      find.text('This invitation was cancelled. Ask the facility owner to send you a new one.'),
      findsOneWidget,
    );
  });

  testWidgets('an acceptance read before the sign-in was restored still ends on the dashboard',
      (tester) async {
    invite(status: 'accepted', acceptedBy: 'newbie');
    store.put('facilities/fac-maple', {
      'ownerUid': 'owner',
      'roles': {'owner': 'owner', 'newbie': 'employee'},
    });
    final auth = MockFirebaseAuth(mockUser: invitee);
    await openLink(tester, auth: auth);
    expect(find.text('dashboard'), findsNothing);

    await auth.signInWithEmailAndPassword(email: 'new@example.com', password: 'pw');
    await tester.pumpAndSettle();
    expect(find.text('dashboard'), findsOneWidget);
  });

  testWidgets('a pending invite is accepted on sign-in, all in one commit', (tester) async {
    invite(status: 'pending');
    store.put('facilities/fac-maple', {
      'ownerUid': 'owner',
      'roles': {'owner': 'owner'},
    });
    final auth = MockFirebaseAuth(mockUser: invitee);
    await openLink(tester, auth: auth);
    expect(find.text('Facility Invitation'), findsOneWidget);

    await auth.signInWithEmailAndPassword(email: 'new@example.com', password: 'pw');
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('dashboard'), findsOneWidget);
    expect(store.data('facilities/fac-maple/invites/inv_1')!['status'], 'accepted');
    expect((store.data('facilities/fac-maple')!['roles'] as Map)['newbie'], 'employee');
    expect(store.commits, hasLength(1));
  });

  testWidgets('an unverified login is asked to verify first, and nothing is written',
      (tester) async {
    // The rules take an acceptance only from a verified address: an
    // unverified account can carry anyone's, and the link was enough to
    // accept an invite it never received. The rules' refusal read as
    // "Error accepting invitation: permission-denied".
    invite(status: 'pending');
    store.put('facilities/fac-maple', {
      'ownerUid': 'owner',
      'roles': {'owner': 'owner'},
    });
    final unverified = MockUser(uid: 'newbie', email: 'new@example.com', isEmailVerified: false);
    PermissionService.overrideForTesting(
      collection: store.collection,
      collectionGroup: store.collectionGroup,
      batch: store.batch,
      currentUser: () => unverified,
    );
    final auth = MockFirebaseAuth(mockUser: unverified);
    await openLink(tester, auth: auth);

    await auth.signInWithEmailAndPassword(email: 'new@example.com', password: 'pw');
    await tester.pumpAndSettle();
    expect(find.text('dashboard'), findsNothing);
    expect(find.textContaining('Verify your email address before accepting'), findsOneWidget);
    expect(find.textContaining('new@example.com'), findsWidgets);
    expect(store.commits, isEmpty);
    expect(store.data('facilities/fac-maple/invites/inv_1')!['status'], 'pending');
  });

  testWidgets('names the facility from the invite, which the invitee cannot read yet',
      (tester) async {
    invite(status: 'pending', facilityName: 'Maple Storage');
    await openLink(tester, auth: _EventSpentAuth(invitee));
    expect(find.text('Maple Storage'), findsOneWidget);
    expect(find.text('Unknown Facility'), findsNothing);
  });

  testWidgets('an acceptance that lost the race to the guard still ends on the dashboard',
      (tester) async {
    // The route guard accepted the invite for this login between the
    // screen's read and its own write, which the rules then refused: the
    // screen said "Failed to accept invitation" to someone who was in.
    invite(status: 'pending');
    store.put('facilities/fac-maple', {
      'ownerUid': 'owner',
      'roles': {'owner': 'owner'},
    });
    PermissionService.overrideForTesting(
      collection: store.collection,
      collectionGroup: store.collectionGroup,
      batch: () {
        invite(status: 'accepted', acceptedBy: 'newbie');
        store.put('facilities/fac-maple', {
          'ownerUid': 'owner',
          'roles': {'owner': 'owner', 'newbie': 'employee'},
        });
        return store.batch();
      },
      currentUser: () => invitee,
    );
    store.refuseWrite = (path) => path.startsWith('user_roles/');
    final auth = MockFirebaseAuth(mockUser: invitee);
    await openLink(tester, auth: auth);

    await auth.signInWithEmailAndPassword(email: 'new@example.com', password: 'pw');
    await tester.pumpAndSettle();
    expect(find.text('dashboard'), findsOneWidget);
    expect(find.textContaining('Failed to accept'), findsNothing);
    expect(store.commits, isEmpty);
  });
}
