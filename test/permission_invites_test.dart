import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/services/superadmin_service.dart';

import 'support/fake_firestore_store.dart';

Timestamp _daysAgo(int days) =>
    Timestamp.fromDate(DateTime.now().subtract(Duration(days: days)));

void main() {
  late FakeStore store;
  User? signedIn;

  // The account lookupUserByEmail would find for an address, by address.
  late Map<String, String> accounts;

  void serve() => PermissionService.overrideForTesting(
        collection: store.collection,
        collectionGroup: store.collectionGroup,
        batch: store.batch,
        currentUser: () => signedIn,
        findUserIdByEmail: (email, _) async => accounts[email],
      );

  setUp(() {
    store = FakeStore();
    signedIn = null;
    accounts = {};
    serve();
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
    String invitedBy = 'owner',
  }) {
    store.put('facilities/$facilityId/invites/$id', {
      'facilityId': facilityId,
      'email': emailLower,
      'emailLower': emailLower,
      'roleType': 'employee',
      'status': status,
      'invitedBy': invitedBy,
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
        serve();
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
        batch: store.batch,
        currentUser: () => signedIn,
      );
      expect(await fulfil('newbie', 'new@example.com'), isFalse);
    });

    test('an acceptance is all written or none of it: role row, roles map and invite', () async {
      // Written one after another, a failure after the role row (a dropped
      // connection, a closed tab) left an active row the rules ignore, no
      // roles-map entry and the invite pending. That row made the invitee
      // look like existing staff, so nothing ever retried it.
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner'},
      });
      invite('f1', 'inv_1', 'new@example.com');
      store.refuseWrite = (path) => path == 'facilities/f1';

      expect(await fulfil('newbie', 'new@example.com'), isFalse);
      expect(roleRowsOf('newbie'), isEmpty);
      expect(statusOf('f1', 'inv_1'), 'pending');
      expect((store.data('facilities/f1')!['roles'] as Map).containsKey('newbie'), isFalse);

      // The next load tries again, and it all lands in one commit.
      store.refuseWrite = null;
      expect(await fulfil('newbie', 'new@example.com'), isTrue);
      expect(statusOf('f1', 'inv_1'), 'accepted');
      expect(store.data('facilities/f1/invites/inv_1')!['acceptedBy'], 'newbie');
      expect((store.data('facilities/f1')!['roles'] as Map)['newbie'], 'employee');
      expect(store.data('facilities/f1')!['acceptingInviteId'], 'inv_1');
      expect(roleRowsOf('newbie').map((r) => (r['isActive'], r['inviteId'])), [(true, 'inv_1')]);
      expect(store.commits, hasLength(1));
      expect(
        store.commits.single.map((w) => w.split(' ').last).toSet(),
        {...store.idsIn('user_roles').map((id) => 'user_roles/$id'), 'facilities/f1',
          'facilities/f1/invites/inv_1'},
      );
    });

    test('an acceptance that stopped part-way before this is finished on the next load', () async {
      // What the old two-write acceptance left behind in production: the
      // role row, and nothing else. It is not a role, so they are still new.
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner'},
      });
      invite('f1', 'inv_1', 'new@example.com');
      store.put('user_roles/half', {
        'userId': 'newbie',
        'facilityId': 'f1',
        'roleType': 'employee',
        'assignedBy': 'owner',
        'assignedAt': _daysAgo(1),
        'isActive': true,
        'inviteId': 'inv_1',
      });

      expect(await fulfil('newbie', 'new@example.com'), isTrue);
      expect(statusOf('f1', 'inv_1'), 'accepted');
      expect((store.data('facilities/f1')!['roles'] as Map)['newbie'], 'employee');
      expect(store.idsIn('user_roles'), ['half'], reason: 'the half-written row is reused');
      expect(store.data('user_roles/half')!['isActive'], isTrue);
    });

    test('but one promoted since keeps their role: the old invite is only marked accepted',
        () async {
      // The half-written row makes them look new, and the owner has since
      // made them a manager. The next load accepted the old employee invite
      // again, writing its role over the row and the roles map.
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner', 'newbie': 'manager'},
      });
      invite('f1', 'inv_1', 'new@example.com');
      store.put('user_roles/half', {
        'userId': 'newbie',
        'facilityId': 'f1',
        'roleType': 'manager',
        'assignedBy': 'owner',
        'assignedAt': _daysAgo(1),
        'isActive': true,
        'inviteId': 'inv_1',
      });

      expect(await fulfil('newbie', 'new@example.com'), isTrue);
      expect((store.data('facilities/f1')!['roles'] as Map)['newbie'], 'manager');
      expect(store.data('user_roles/half')!['roleType'], 'manager');
      expect(statusOf('f1', 'inv_1'), 'accepted');
      expect(store.data('facilities/f1/invites/inv_1')!['acceptedBy'], 'newbie');
      expect(store.writes, ['update facilities/f1/invites/inv_1']);
    });

    test('but a row for any other invite, or an inactive one, is a history: link only', () async {
      final rows = <String, Map<String, dynamic>>{
        'an accepted invite elsewhere': {'isActive': true, 'inviteId': 'inv_elsewhere'},
        'this invite, since removed': {'isActive': false, 'inviteId': 'inv_1'},
        'no invite at all': {'isActive': true},
      };
      for (final entry in rows.entries) {
        store = FakeStore();
        serve();
        invite('f1', 'inv_1', 'new@example.com');
        store.put('user_roles/r1', {
          'userId': 'newbie',
          'facilityId': 'f1',
          'roleType': 'employee',
          ...entry.value,
        });
        expect(await fulfil('newbie', 'new@example.com'), isTrue, reason: entry.key);
        expect(statusOf('f1', 'inv_1'), 'pending', reason: entry.key);
        expect(store.writes, isEmpty, reason: entry.key);
      }
    });

    test('reads a bounded number of role rows, not just the first', () async {
      // One row read (limit 1) could be the half-written one while a later
      // row is a real role elsewhere.
      invite('f1', 'inv_1', 'new@example.com');
      store.put('user_roles/a_half', {
        'userId': 'newbie',
        'facilityId': 'f1',
        'isActive': true,
        'inviteId': 'inv_1',
      });
      store.put('user_roles/b_real', {
        'userId': 'newbie',
        'facilityId': 'f9',
        'isActive': true,
        'inviteId': 'inv_old',
      });
      expect(await fulfil('newbie', 'new@example.com'), isTrue);
      expect(statusOf('f1', 'inv_1'), 'pending');
      expect(store.queries, contains('user_roles userId=newbie limit=20'));
    });
  });

  group('fulfillSpecificInvite (the invite link)', () {
    setUp(() => signedIn = MockUser(uid: 'newbie', email: 'new@example.com'));

    Future<bool> accept(String inviteId) => PermissionService.fulfillSpecificInvite(
        facilityId: 'f1', inviteId: inviteId, userId: 'newbie', email: 'new@example.com');

    test('accepts an invite too old to be accepted without it', () async {
      // Only the automatic acceptance has a window; the link has none.
      store.put('facilities/f1', {'ownerUid': 'owner', 'roles': {'owner': 'owner'}});
      invite('f1', 'stale', 'new@example.com', invitedAt: _daysAgo(90));
      expect(await accept('stale'), isTrue);
      expect(statusOf('f1', 'stale'), 'accepted');
      expect((store.data('facilities/f1')!['roles'] as Map)['newbie'], 'employee');
    });

    test('writes nothing when the invite cannot be marked accepted', () async {
      store.put('facilities/f1', {'ownerUid': 'owner', 'roles': {'owner': 'owner'}});
      invite('f1', 'inv_1', 'new@example.com');
      store.refuseWrite = (path) => path == 'facilities/f1/invites/inv_1';
      expect(await accept('inv_1'), isFalse);
      expect(roleRowsOf('newbie'), isEmpty);
      expect((store.data('facilities/f1')!['roles'] as Map).containsKey('newbie'), isFalse);
    });

    test('refuses an invite that is no longer pending', () async {
      store.put('facilities/f1', {'ownerUid': 'owner', 'roles': {'owner': 'owner'}});
      invite('f1', 'gone', 'new@example.com', status: 'cancelled');
      expect(await accept('gone'), isFalse);
      expect(store.writes, isEmpty);
    });

    test('someone on the team already keeps their role, however they joined; the invite is spent',
        () async {
      // An invite left over from before they joined: opening it made a
      // manager whatever the invite said.
      for (final facility in <Map<String, dynamic>>[
        {'ownerUid': 'owner', 'roles': {'owner': 'owner', 'newbie': 'manager'}},
        {'ownerUid': 'owner', 'roles': {'owner': 'owner'}, 'managers': {'newbie': true}},
        {'ownerUid': 'newbie'},
      ]) {
        store = FakeStore();
        serve();
        store.put('facilities/f1', facility);
        invite('f1', 'leftover', 'new@example.com');

        expect(await accept('leftover'), isTrue, reason: '$facility');
        expect(store.data('facilities/f1'), facility, reason: '$facility');
        expect(roleRowsOf('newbie'), isEmpty, reason: '$facility');
        expect(statusOf('f1', 'leftover'), 'accepted', reason: '$facility');
        expect(store.writes, ['update facilities/f1/invites/leftover'], reason: '$facility');
      }
    });
  });

  group("pendingInvitesFor (the dashboard's invitation links)", () {
    test('lists every pending invite to a verified address, saying which the guard accepts',
        () async {
      invite('f1', 'fresh', 'new@example.com', invitedAt: _daysAgo(3));
      invite('f2', 'stale', 'new@example.com', invitedAt: _daysAgo(45));
      invite('f3', 'done', 'new@example.com', status: 'accepted', acceptedBy: 'newbie');
      invite('f4', 'theirs', 'someone@example.com');
      store.put('facilities/f2/invites/stale', {
        ...store.data('facilities/f2/invites/stale')!,
        'facilityName': 'Birch Storage',
      });

      final invites = await PermissionService.pendingInvitesFor(
          MockUser(uid: 'newbie', email: 'New@Example.com', isEmailVerified: true));
      expect(
        invites.map((i) => (i.facilityId, i.id, i.autoAcceptable, i.facilityName)),
        unorderedEquals([
          ('f1', 'fresh', true, null),
          ('f2', 'stale', false, 'Birch Storage'),
        ]),
      );
    });

    test('leaves out invites to a facility they are on already', () async {
      // Left over from before they joined: "Join f1 as Employee" to f1's
      // manager.
      store.put('facilities/f1', {'ownerUid': 'owner', 'roles': {'newbie': 'manager'}});
      store.put('facilities/f2', {'ownerUid': 'owner2', 'roles': {'owner2': 'owner'}});
      invite('f1', 'leftover', 'new@example.com');
      invite('f2', 'fresh', 'new@example.com');

      final invites = await PermissionService.pendingInvitesFor(
          MockUser(uid: 'newbie', email: 'new@example.com', isEmailVerified: true));
      expect(invites.map((i) => i.id), ['fresh']);
    });

    test('an unverified address is not looked up at all (the rules refuse it)', () async {
      invite('f1', 'fresh', 'new@example.com');
      final invites = await PermissionService.pendingInvitesFor(
          MockUser(uid: 'newbie', email: 'new@example.com', isEmailVerified: false));
      expect(invites, isEmpty);
      expect(store.queries, isEmpty);
    });
  });

  group('holdsRoleAt', () {
    test('the owner, the roles map and the legacy managers map; nothing else', () async {
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner', 'u1': 'employee'},
        'managers': {'legacy': true, 'former': false},
      });
      for (final (uid, holds) in [
        ('owner', true),
        ('u1', true),
        ('legacy', true),
        ('former', false),
        ('stranger', false),
      ]) {
        expect(await PermissionService.holdsRoleAt(facilityId: 'f1', userId: uid), holds,
            reason: uid);
      }
      expect(await PermissionService.holdsRoleAt(facilityId: 'missing', userId: 'owner'), isFalse);
    });
  });

  group("assignRole (changing someone's role)", () {
    setUp(() => signedIn = MockUser(uid: 'owner', email: 'owner@example.com'));

    void row(String id, {String facilityId = 'f1', bool isActive = true}) =>
        store.put('user_roles/$id', {
          'userId': 'u1',
          'facilityId': facilityId,
          'roleType': 'manager',
          'assignedBy': 'owner',
          'assignedAt': _daysAgo(10),
          'isActive': isActive,
        });

    test('reaches every active row they have there, not just the first', () async {
      // The callables that charge cards take any active row as access (one
      // read, in no set order). An invitee's acceptance may write two manager
      // rows; demoted to viewer, only the first changed, and the other kept
      // them a manager there.
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner', 'u1': 'manager'},
      });
      row('r1');
      row('r2');
      row('r_old', isActive: false);
      row('r_elsewhere', facilityId: 'f2');

      final result = await PermissionService.assignRole(
        userId: 'u1',
        facilityId: 'f1',
        roleType: RoleType.viewer,
        assignedBy: 'owner',
      );

      expect(result.success, isTrue);
      expect(store.data('user_roles/r1')!['roleType'], 'viewer');
      expect(store.data('user_roles/r2')!['roleType'], 'viewer');
      expect(store.data('user_roles/r2')!['assignedBy'], 'owner');
      expect(store.data('user_roles/r_old')!['roleType'], 'manager',
          reason: 'an inactive row gives no access, and stays as it was');
      expect(store.data('user_roles/r_elsewhere')!['roleType'], 'manager');
      expect((store.data('facilities/f1')!['roles'] as Map)['u1'], 'viewer');
      expect(store.commits, hasLength(1));
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
      // Only pending ones: the accepted invite is what ties the address to
      // u1 here, for the next removal and for createFacilityInvite.
      expect(statusOf('f1', 'inv_old'), 'accepted');
      expect(store.data('facilities/f1/invites/inv_old')!['acceptedBy'], 'u1');
    });

    test('finds the invite a role row was written for when nothing else gives the address',
        () async {
      // Before the rules made an acceptance spend its invite, an invitee
      // could write their row with no address and leave the invite pending.
      // Nothing else tied that invite to them, so it survived the removal
      // and its link let them straight back in.
      store.put('user_roles/r1', {
        'userId': 'u1',
        'facilityId': 'f1',
        'roleType': 'employee',
        'isActive': true,
        'assignedAt': _daysAgo(10),
        'inviteId': 'inv_new',
      });
      // And another pending invite to that address, which would let them
      // back in just the same.
      invite('f1', 'inv_again', 'staff@example.com');
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(statusOf('f1', 'inv_new'), 'cancelled');
      expect(statusOf('f1', 'inv_again'), 'cancelled');
      expect(statusOf('f1', 'inv_someone'), 'pending');
      expect(store.data('user_roles/r1')!['isActive'], isFalse);
      expect(
        await PermissionService.fulfillSpecificInvite(
            facilityId: 'f1', inviteId: 'inv_new', userId: 'u1', email: 'staff@example.com'),
        isFalse,
      );
    });

    test('a row naming an invite since cancelled does not block the removal', () async {
      // Cancel Invite deletes the invite, and the rules refuse a get of one
      // that is not there, even to the owner. Read by id, that one refused
      // read failed the whole removal: an acceptance that stopped part-way
      // (the row written, the invite left pending) and whose invite the owner
      // then cancelled made its user unremovable. (The fake refuses it as
      // unavailable, not permission-denied; any failed read failed it.)
      store.refuseRead =
          (path) => path.startsWith('facilities/f1/invites/') && store.data(path) == null;
      store.put('user_roles/r1', {
        'userId': 'u1',
        'facilityId': 'f1',
        'roleType': 'employee',
        'isActive': true,
        'assignedAt': _daysAgo(10),
        'userEmail': 'staff@example.com',
        'inviteId': 'inv_cancelled',
      });
      // Their address from the invite they accepted: the row's own is theirs
      // to write, so it is not taken.
      acceptedInvite();
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(store.data('user_roles/r1')!['isActive'], isFalse);
      expect((store.data('facilities/f1')!['roles'] as Map).containsKey('u1'), isFalse);
      expect(statusOf('f1', 'inv_new'), 'cancelled');
      expect(statusOf('f1', 'inv_someone'), 'pending');
    });

    test('names this facility again on an invite pointed at another one', () async {
      // An invitee could point their invite at a facility of their own. The
      // rules now take an owner's edit of it only when it names this
      // facility after the write, so the cancel puts it back; without it the
      // whole removal was refused and they stayed on the team.
      roleRow();
      store.put('facilities/f1/invites/inv_new', {
        ...store.data('facilities/f1/invites/inv_new')!,
        'facilityId': 'theirs',
      });
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(statusOf('f1', 'inv_new'), 'cancelled');
      expect(store.data('facilities/f1/invites/inv_new')!['facilityId'], 'f1');
      expect((store.data('facilities/f1')!['roles'] as Map).containsKey('u1'), isFalse);
    });

    test('an accepted invite at the same address is left accepted', () async {
      roleRow();
      acceptedInvite();
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(statusOf('f1', 'inv_new'), 'cancelled');
      expect(statusOf('f1', 'inv_old'), 'accepted');
      expect(store.data('facilities/f1/invites/inv_old')!.containsKey('cancelledAt'), isFalse);
    });

    test('takes them out of the legacy managers map too, which the rules still read', () async {
      // A legacy manager "removed" only from roles kept their access through
      // managers.<uid>, which isFacilityOwnerOrManager accepts.
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner', 'u1': 'manager'},
        'managers': {'u1': true, 'other': true},
      });
      roleRow();
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      final facility = store.data('facilities/f1')!;
      expect(facility['managers'], {'other': true});
      expect((facility['roles'] as Map).containsKey('u1'), isFalse);
      expect(await PermissionService.holdsRoleAt(facilityId: 'f1', userId: 'u1'), isFalse);
    });

    test('is one commit, so a refused facility write removes nothing either', () async {
      // Row by row, a failure after the role rows left the user in the roles
      // map the rules read, still with access, while the team screen no
      // longer listed them.
      roleRow();
      store.refuseWrite = (path) => path == 'facilities/f1';
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isFalse);
      expect(store.data('user_roles/r1')!['isActive'], isTrue);
      expect(statusOf('f1', 'inv_new'), 'pending');
      expect((store.data('facilities/f1')!['roles'] as Map)['u1'], 'employee');
      expect(store.idsIn('facilities/f1/auditLogs'), isEmpty,
          reason: 'a removal that did not happen is not logged');

      store.refuseWrite = null;
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(store.commits, hasLength(1));
      final logId = store.idsIn('facilities/f1/auditLogs').single;
      expect(store.commits.single, [
        'update facilities/f1/invites/inv_new',
        'set user_roles/r1',
        'set facilities/f1',
        'set facilities/f1/auditLogs/$logId',
      ]);
    });

    test('does not take the address a member wrote on their own row', () async {
      // An invitee writes their row's userEmail themselves. With someone
      // else's address there, that person's pending invites were cancelled
      // along with the member's own removal.
      acceptedInvite();
      store.put('user_roles/r1', {
        'userId': 'u1',
        'facilityId': 'f1',
        'roleType': 'employee',
        'isActive': true,
        'assignedAt': _daysAgo(10),
        'assignedBy': 'owner',
        'userEmail': 'victim@example.com',
        'inviteId': 'inv_old',
      });
      // Nor one they assigned themselves (a legacy manager could).
      store.put('user_roles/r2', {
        'userId': 'u1',
        'facilityId': 'f1',
        'roleType': 'employee',
        'isActive': true,
        'assignedAt': _daysAgo(10),
        'assignedBy': 'u1',
        'userEmail': 'other-victim@example.com',
      });
      invite('f1', 'inv_victim', 'victim@example.com');
      invite('f1', 'inv_other', 'other-victim@example.com');
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(statusOf('f1', 'inv_victim'), 'pending');
      expect(statusOf('f1', 'inv_other'), 'pending');
      // Their own, known from the invite they accepted, still goes.
      expect(statusOf('f1', 'inv_new'), 'cancelled');
      expect(store.data('user_roles/r1')!['isActive'], isFalse);
      expect(store.data('user_roles/r2')!['isActive'], isFalse);
    });

    test('takes their own verified address when they remove themselves', () async {
      // A support session ending: the super admin removes their own role.
      signedIn = MockUser(uid: 'u1', email: 'Staff@Example.com');
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner', 'u1': 'manager'},
      });
      roleRow(userEmail: null);
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(statusOf('f1', 'inv_new'), 'cancelled');

      // Unverified, the address could be anyone's.
      invite('f1', 'inv_new', 'staff@example.com');
      roleRow(userEmail: null);
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner', 'u1': 'manager'},
      });
      signedIn = MockUser(uid: 'u1', email: 'staff@example.com', isEmailVerified: false);
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(statusOf('f1', 'inv_new'), 'pending');
    });

    test('cancels the pending invites they sent, so a login of their own cannot bring them back',
        () async {
      // A manager could invite a second login of theirs as manager; once
      // removed, that login accepted and they were back.
      roleRow();
      invite('f1', 'inv_sent', 'second-login@example.com', invitedBy: 'u1');
      invite('f1', 'inv_sent_done', 'hired@example.com', invitedBy: 'u1', status: 'accepted');
      invite('f2', 'inv_sent_elsewhere', 'second-login@example.com', invitedBy: 'u1');
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
      expect(statusOf('f1', 'inv_sent'), 'cancelled');
      expect(store.data('facilities/f1/invites/inv_sent')!['cancelledReason'], 'access_removed');
      expect(statusOf('f1', 'inv_sent_done'), 'accepted');
      expect(statusOf('f2', 'inv_sent_elsewhere'), 'pending');
      expect(statusOf('f1', 'inv_someone'), 'pending', reason: "the owner's, to someone else");

      signedIn = MockUser(uid: 'u2', email: 'second-login@example.com');
      expect(
        await PermissionService.fulfillSpecificInvite(
            facilityId: 'f1', inviteId: 'inv_sent', userId: 'u2', email: 'second-login@example.com'),
        isFalse,
      );
      expect((store.data('facilities/f1')!['roles'] as Map).containsKey('u2'), isFalse);
    });

    group('logs the removal in the facility audit log', () {
      Map<String, dynamic> onlyLog() =>
          store.data('facilities/f1/auditLogs/${store.idsIn('facilities/f1/auditLogs').single}')!;

      test('in the removal batch: who removed whom, as the audit log and rules read it', () async {
        roleRow();
        acceptedInvite();
        expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
        expect(store.commits, hasLength(1));
        expect(store.commits.single.last, startsWith('set facilities/f1/auditLogs/'));
        final log = onlyLog();
        // What functions-shared's writeAuditLog writes, and the screen reads.
        expect(log['eventType'], 'team.memberRemoved');
        expect(log['eventType'], PermissionService.removedMemberEventType);
        expect(log['timestamp'], isA<Timestamp>());
        expect(log['actorUid'], 'owner');
        expect(log['actorEmail'], 'owner@example.com');
        expect(log['actorRole'], 'owner');
        expect(log['targetType'], 'user');
        expect(log['targetId'], 'u1');
        expect(log['facilityId'], 'f1');
        expect(log['metadata'], containsPair('removedRole', 'employee'));
        expect(log['metadata'], containsPair('removedEmail', 'staff@example.com'));
        expect(log['metadata'], containsPair('invitesCancelled', 1));
        // What the auditLogs rule requires of a client entry.
        expect(log['userId'], 'owner');
        expect(log['action'], 'team.memberRemoved');
        expect(log['entityType'], 'user');
        expect(log['entityId'], 'u1');
        expect(log.keys, containsAll(['userEmail', 'changes', 'metadata']));
      });

      test("a manager's removal names the manager", () async {
        signedIn = MockUser(uid: 'm1', email: 'manager@example.com');
        store.put('facilities/f1', {
          'ownerUid': 'owner',
          'roles': {'owner': 'owner', 'm1': 'manager', 'u1': 'employee'},
        });
        roleRow();
        expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
        expect(onlyLog()['actorUid'], 'm1');
        expect(onlyLog()['actorRole'], 'manager');
        expect(onlyLog()['userId'], 'm1');
      });

      test('a legacy manager counts as staff, as the rules have it', () async {
        signedIn = MockUser(uid: 'm1', email: 'manager@example.com');
        store.put('facilities/f1', {
          'ownerUid': 'owner',
          'roles': {'owner': 'owner', 'u1': 'employee', 'm1': 'viewer'},
          'managers': {'m1': true},
        });
        roleRow();
        expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
        expect(onlyLog()['actorRole'], 'manager');
      });

      test('a super admin with no role there removes without one, which the rules would refuse',
          () async {
        signedIn = MockUser(uid: 'admin', email: SuperAdminService.superAdminEmails.first);
        roleRow();
        expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isTrue);
        expect(store.idsIn('facilities/f1/auditLogs'), isEmpty);
        expect((store.data('facilities/f1')!['roles'] as Map).containsKey('u1'), isFalse);
      });
    });

    test('removes nothing when the invites cannot be cancelled, so it can be tried again',
        () async {
      roleRow();
      acceptedInvite();
      store.refuseWrite = (path) => path.startsWith('facilities/f1/invites/');
      expect(await PermissionService.removeRole(userId: 'u1', facilityId: 'f1'), isFalse);
      expect(store.data('user_roles/r1')!['isActive'], isTrue);
      expect((store.data('facilities/f1')!['roles'] as Map)['u1'], 'employee');
      expect(statusOf('f1', 'inv_old'), 'accepted');
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

    test("a super admin inviting the owner's address is refused too", () async {
      // Addresses were tied to users only through accepted invites, and the
      // owner never accepts one: the invite sat pending for ever, since
      // assignRole keeps the owner role whatever it says.
      signedIn = MockUser(uid: 'admin', email: SuperAdminService.superAdminEmails.first);
      store.put('users/owner', {'email': 'Boss@Example.com', 'emailLower': 'boss@example.com'});
      final result = await inviteTo('boss@example.com');
      expect(result.inviteSaved, isFalse);
      expect(result.errorMessage, contains('already has access'));
      expect(store.idsIn('facilities/f1/invites'), ['inv_old']);
    });

    test("or through an owner's users doc that has only its email", () async {
      signedIn = MockUser(uid: 'admin', email: SuperAdminService.superAdminEmails.first);
      store.put('users/owner', {'email': 'Boss@Example.com'});
      expect((await inviteTo('boss@example.com')).inviteSaved, isFalse);
      expect(store.idsIn('facilities/f1/invites'), ['inv_old']);
    });

    test("saves who sent it only as the signed-in user's own verified address", () async {
      // The invitee is shown it ("Invited by ..."), and the rules refuse any
      // other: anyone can create a facility and invite any address.
      Future<Object?> savedSender(String? invitedByEmail, String to) async {
        await PermissionService.createFacilityInvite(
          facilityId: 'f1',
          email: to,
          roleType: RoleType.employee,
          invitedBy: 'owner',
          invitedByEmail: invitedByEmail,
        );
        final id = store
            .idsIn('facilities/f1/invites')
            .singleWhere((id) => store.data('facilities/f1/invites/$id')!['emailLower'] == to);
        return store.data('facilities/f1/invites/$id')!['invitedByEmail'];
      }

      expect(await savedSender('owner@example.com', 'a@example.com'), 'owner@example.com');
      expect(await savedSender('support@storagefacilitycreator.com', 'b@example.com'), isNull);
      signedIn = MockUser(uid: 'owner', email: 'owner@example.com', isEmailVerified: false);
      expect(await savedSender('owner@example.com', 'c@example.com'), isNull);
    });

    test("and so is the owner's address found through its account", () async {
      // Whoever cannot read the owner's users doc: the lookup callable. An
      // older facility's roles map need not list its owner at all.
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'name': 'Maple Storage',
        'roles': {'u1': 'employee'},
      });
      accounts['boss@example.com'] = 'owner';
      expect((await inviteTo('Boss@Example.com')).inviteSaved, isFalse);
      expect(store.idsIn('facilities/f1/invites'), ['inv_old']);
    });

    test('as is anyone on the team who did not join by invite', () async {
      store.put('facilities/f1', {
        'ownerUid': 'owner',
        'roles': {'owner': 'owner', 'support': 'manager'},
        'managers': {'legacy': true},
      });
      accounts['support@example.com'] = 'support';
      accounts['legacy@example.com'] = 'legacy';
      expect((await inviteTo('support@example.com')).inviteSaved, isFalse);
      expect((await inviteTo('legacy@example.com')).inviteSaved, isFalse);
      expect(store.idsIn('facilities/f1/invites'), ['inv_old']);
    });

    test('but an account with no role here, or no account, is invited as before', () async {
      accounts['elsewhere@example.com'] = 'someone-else';
      expect((await inviteTo('elsewhere@example.com')).inviteSaved, isTrue);
      expect((await inviteTo('nobody@example.com')).inviteSaved, isTrue);
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
