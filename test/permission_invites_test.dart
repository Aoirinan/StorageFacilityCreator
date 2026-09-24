import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/services/permission_service.dart';

import 'support/fake_firestore_store.dart';

Timestamp _daysAgo(int days) =>
    Timestamp.fromDate(DateTime.now().subtract(Duration(days: days)));

void main() {
  late FakeStore store;
  User? signedIn;

  setUp(() {
    store = FakeStore();
    signedIn = null;
    PermissionService.overrideForTesting(
      collection: store.collection,
      collectionGroup: store.collectionGroup,
      currentUser: () => signedIn,
    );
  });
  tearDown(PermissionService.overrideForTesting);

  void invite(
    String facilityId,
    String id,
    String emailLower, {
    String status = 'pending',
    Timestamp? invitedAt,
    Timestamp? lastSentAt,
    bool noSendTimes = false,
    String? acceptedBy,
  }) {
    store.put('facilities/$facilityId/invites/$id', {
      'facilityId': facilityId,
      'email': emailLower,
      'emailLower': emailLower,
      'roleType': 'employee',
      'status': status,
      'invitedBy': 'owner',
      if (!noSendTimes) 'invitedAt': invitedAt ?? _daysAgo(2),
      if (!noSendTimes) 'lastSentAt': lastSentAt ?? invitedAt ?? _daysAgo(2),
      if (acceptedBy != null) 'acceptedBy': acceptedBy,
    });
  }

  String? statusOf(String facilityId, String id) =>
      store.data('facilities/$facilityId/invites/$id')?['status'] as String?;

  List<Map<String, dynamic>> roleRowsOf(String uid) => [
        for (final id in store.idsIn('user_roles'))
          if (store.data('user_roles/$id')!['userId'] == uid) store.data('user_roles/$id')!,
      ];

  group('fulfillPendingInvitesForUser (acceptance without the link)', () {
    Future<bool> fulfil(String uid, String emailLower) =>
        PermissionService.fulfillPendingInvitesForUser(userId: uid, emailLower: emailLower);

    setUp(() => signedIn = MockUser(uid: 'newbie', email: 'new@example.com'));

    test("a genuinely new invitee's pending invites are all accepted", () async {
      invite('f1', 'inv_1', 'new@example.com');
      invite('f2', 'inv_2', 'new@example.com');
      invite('f1', 'inv_x', 'someone@example.com');

      expect(await fulfil('newbie', 'new@example.com'), isTrue);
      expect(statusOf('f1', 'inv_1'), 'accepted');
      expect(statusOf('f2', 'inv_2'), 'accepted');
      expect(statusOf('f1', 'inv_x'), 'pending');
      expect(roleRowsOf('newbie').map((r) => (r['facilityId'], r['isActive'], r['inviteId'])),
          unorderedEquals([('f1', true, 'inv_1'), ('f2', true, 'inv_2')]));
    });

    test('anyone who has had a role anywhere, or owns a facility, accepts through the link instead',
        () async {
      // Every verified user with no owner account got every pending invite
      // accepted on their next load: existing staff were put on teams without
      // a click, and a removed team member's old invite gave access back.
      final histories = <String, void Function()>{
        'a team member elsewhere': () => store.put('user_roles/r1',
            {'userId': 'newbie', 'facilityId': 'f9', 'isActive': true, 'roleType': 'employee'}),
        'a removed team member': () => store.put('user_roles/r1',
            {'userId': 'newbie', 'facilityId': 'f1', 'isActive': false, 'roleType': 'employee'}),
        'an owner with no role rows': () =>
            store.put('facilities/mine', {'ownerUid': 'newbie', 'name': 'Mine'}),
      };
      for (final entry in histories.entries) {
        store = FakeStore();
        PermissionService.overrideForTesting(
          collection: store.collection,
          collectionGroup: store.collectionGroup,
          currentUser: () => signedIn,
        );
        entry.value();
        invite('f1', 'inv_1', 'new@example.com');

        expect(await fulfil('newbie', 'new@example.com'), isTrue,
            reason: '${entry.key}: nothing it should have accepted');
        expect(statusOf('f1', 'inv_1'), 'pending', reason: entry.key);
        expect(store.writes, isEmpty, reason: entry.key);
      }
    });

    test('only invites sent within the auto-accept window, and never a cancelled one', () async {
      invite('f1', 'fresh', 'new@example.com', invitedAt: _daysAgo(3));
      invite('f2', 'stale', 'new@example.com', invitedAt: _daysAgo(31));
      invite('f3', 'resent', 'new@example.com', invitedAt: _daysAgo(90), lastSentAt: _daysAgo(1));
      invite('f4', 'untimed', 'new@example.com', noSendTimes: true);
      invite('f5', 'cancelled', 'new@example.com', status: 'cancelled');

      expect(await fulfil('newbie', 'new@example.com'), isTrue);
      expect(statusOf('f1', 'fresh'), 'accepted');
      expect(statusOf('f3', 'resent'), 'accepted');
      expect(statusOf('f2', 'stale'), 'pending', reason: 'still acceptable through its link');
      expect(statusOf('f4', 'untimed'), 'pending');
      expect(statusOf('f5', 'cancelled'), 'cancelled');
      expect(roleRowsOf('newbie').map((r) => r['facilityId']), unorderedEquals(['f1', 'f3']));
    });

    test('the window is inviteAutoAcceptWindow from the last send', () {
      final now = DateTime(2026, 9, 23, 12);
      Map<String, dynamic> sentAt(DateTime at, {String status = 'pending'}) =>
          {'status': status, 'invitedAt': Timestamp.fromDate(at)};
      final edge = now.subtract(PermissionService.inviteAutoAcceptWindow);
      expect(PermissionService.inviteAutoAcceptable(sentAt(edge), now), isTrue);
      expect(
          PermissionService.inviteAutoAcceptable(
              sentAt(edge.subtract(const Duration(minutes: 1))), now),
          isFalse);
      expect(PermissionService.inviteAutoAcceptable(sentAt(now, status: 'accepted'), now), isFalse);
    });

    test('says so when an invite it should have accepted was not', () async {
      invite('f1', 'inv_1', 'new@example.com');
      store.refuseWrite = (path) => path.startsWith('user_roles/');

      expect(await fulfil('newbie', 'new@example.com'), isFalse);
      expect(statusOf('f1', 'inv_1'), 'pending');
    });

    test('costs the one invite read for someone with nothing pending', () async {
      // It runs on every signed-in user's first load.
      invite('f1', 'inv_x', 'someone@example.com');
      expect(await fulfil('newbie', 'new@example.com'), isTrue);
      expect(store.queries, ['invites emailLower=new@example.com status=pending']);
    });

    test('and when the invite read fails', () async {
      PermissionService.overrideForTesting(
        collection: store.collection,
        collectionGroup: (_) =>
            throw FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
        currentUser: () => signedIn,
      );
      expect(await fulfil('newbie', 'new@example.com'), isFalse);
    });
  });

  group('removeRole', () {
    setUp(() {
      signedIn = MockUser(uid: 'owner', email: 'owner@example.com');
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner', 'u1': 'employee'},
      });
      // Invited again after joining (say, to change the role): the second
      // invite is still pending when the owner removes them.
      invite('f1', 'inv_new', 'staff@example.com');
      invite('f2', 'inv_elsewhere', 'staff@example.com');
      invite('f1', 'inv_someone', 'someone@example.com');
    });

    void acceptedInvite() =>
        invite('f1', 'inv_old', 'staff@example.com', status: 'accepted', acceptedBy: 'u1');

    void roleRow({String? userEmail = 'Staff@Example.com'}) => store.put('user_roles/r1', {
          'userId': 'u1',
          'facilityId': 'f1',
          'roleType': 'employee',
          'isActive': true,
          'assignedAt': _daysAgo(10),
          if (userEmail != null) 'userEmail': userEmail,
        });

    test('cancels their pending invites there, so its link cannot give the access back', () async {
      roleRow();
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);

      expect(statusOf('f1', 'inv_new'), 'cancelled');
      expect(store.data('facilities/f1/invites/inv_new')!['cancelledReason'], 'access_removed');
      expect(statusOf('f2', 'inv_elsewhere'), 'pending', reason: 'another facility is theirs to keep');
      expect(statusOf('f1', 'inv_someone'), 'pending');
      expect(store.data('user_roles/r1')!['isActive'], isFalse);
      expect((store.data('facilities/f1')!['roles'] as Map).containsKey('u1'), isFalse);

      // The removed team member opens the old email link.
      expect(
        await PermissionService.fulfillSpecificInvite(
            facilityId: 'f1', inviteId: 'inv_new', userId: 'u1', email: 'staff@example.com'),
        isFalse,
      );
      expect(store.data('user_roles/r1')!['isActive'], isFalse);
    });

    test('finds the address through an accepted invite when the role row has none', () async {
      roleRow(userEmail: null);
      acceptedInvite();
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(statusOf('f1', 'inv_new'), 'cancelled');
    });

    test('removes nothing when the invites cannot be cancelled, so it can be tried again',
        () async {
      roleRow();
      acceptedInvite();
      store.refuseWrite = (path) => path.startsWith('facilities/f1/invites/');
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isFalse);
      expect(store.data('user_roles/r1')!['isActive'], isTrue);
      expect((store.data('facilities/f1')!['roles'] as Map)['u1'], 'employee');
    });
  });

  group('createFacilityInvite', () {
    setUp(() {
      signedIn = MockUser(uid: 'owner', email: 'owner@example.com');
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'name': 'Keepsake Storage',
        'roles': {'owner': 'owner', 'u1': 'employee'},
      });
      invite('f1', 'inv_old', 'staff@example.com', status: 'accepted', acceptedBy: 'u1');
    });

    Future<InviteResult> inviteTo(String email) => PermissionService.createFacilityInvite(
          facilityId: 'f1',
          email: email,
          roleType: RoleType.manager,
          invitedBy: 'owner',
          invitedByEmail: 'owner@example.com',
        );

    test('refuses an address that already has a role there, and saves nothing', () async {
      // A second, pending invite for a current team member outlived their
      // removal and gave the access back through its link.
      final result = await inviteTo('Staff@Example.com');
      expect(result.success, isFalse);
      expect(result.inviteSaved, isFalse);
      expect(result.errorMessage, contains('already has access'));
      expect(store.idsIn('facilities/f1/invites'), ['inv_old']);
    });

    test('so does the legacy managers map, which removeRole leaves', () async {
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner'},
        'managers': {'u1': true},
      });
      expect((await inviteTo('staff@example.com')).inviteSaved, isFalse);
      expect(store.idsIn('facilities/f1/invites'), ['inv_old']);
    });

    test('and the inviter\'s own address', () async {
      expect((await inviteTo('Owner@Example.com')).inviteSaved, isFalse);
      expect(store.idsIn('facilities/f1/invites'), ['inv_old']);
    });

    test('invites someone removed from the team, and a newcomer, as before', () async {
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner'},
      });
      final again = await inviteTo('staff@example.com');
      final newcomer = await inviteTo('new@example.com');
      // The email itself fails here (no Functions in tests); the invite is saved.
      expect(again.inviteSaved, isTrue);
      expect(newcomer.inviteSaved, isTrue);
      final pending = [
        for (final id in store.idsIn('facilities/f1/invites'))
          if (statusOf('f1', id) == 'pending') store.data('facilities/f1/invites/$id')!['emailLower'],
      ];
      expect(pending, unorderedEquals(['staff@example.com', 'new@example.com']));
    });
  });
}
