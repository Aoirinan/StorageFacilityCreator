// The fake below implements cloud_firestore's @sealed query classes so the
// service's own queries run in tests; nothing outside tests sees it.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/permission_service.dart';
import 'package:sfcapp/utils/verified_email_token.dart';

import 'support/fake_facility_collection.dart';
import 'support/fake_firestore_store.dart';

/// A collection whose reads fail the way an offline Firestore does, and
/// which records any attempt to write a doc.
class _UnreadableCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  /// One entry per attempted doc write.
  final List<String?> docCalls = [];

  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) =>
      this;

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async =>
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    docCalls.add(path);
    throw StateError('no account may be written after a failed read');
  }
}

/// What a user's ID token says, and how often it was force-refreshed.
class _TokenState {
  _TokenState(this.claimVerified);

  bool claimVerified;
  int forcedRefreshes = 0;
  void Function()? onForcedRefresh;
}

class _FakeTokenResult extends Fake implements IdTokenResult {
  _FakeTokenResult(this.claims);

  @override
  final Map<String, dynamic>? claims;
}

/// A user whose ID token was minted before (claimVerified false) or after
/// they verified their email. A forced refresh brings it up to date.
// MockUser's own fields are mutable; the state here is not.
// ignore: must_be_immutable
class _TokenUser extends MockUser {
  _TokenUser({required bool verified, required bool claimVerified})
      : _state = _TokenState(claimVerified),
        super(uid: 'token-user', email: 'token@example.com', isEmailVerified: verified);

  final _TokenState _state;
  int get forcedRefreshes => _state.forcedRefreshes;
  set onForcedRefresh(void Function() callback) => _state.onForcedRefresh = callback;

  @override
  Future<IdTokenResult> getIdTokenResult([bool forceRefresh = false]) async =>
      _FakeTokenResult({'email_verified': _state.claimVerified});

  @override
  Future<String> getIdToken([bool forceRefresh = false]) async {
    if (forceRefresh) {
      _state.forcedRefreshes += 1;
      _state.claimVerified = emailVerified;
      _state.onForcedRefresh?.call();
    }
    return 'token';
  }
}

FacilityCreatorAccountModel _account(
  String id, {
  required SubscriptionStatus status,
  required DateTime createdAt,
}) {
  return FacilityCreatorAccountModel(
    accountId: id,
    ownerUid: 'owner',
    ownerEmail: 'owner@example.com',
    ownerName: 'Owner',
    subscriptionStatus: status,
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

void main() {
  final original = _account(
    'acct_original',
    status: SubscriptionStatus.active,
    createdAt: DateTime(2026, 3, 1),
  );
  // What a failed read in getOrCreateAccountForCurrentUser used to create.
  final pendingDuplicate = _account(
    'acct_duplicate',
    status: SubscriptionStatus.pendingApproval,
    createdAt: DateTime(2026, 9, 20),
  );

  group('an owner with more than one account', () {
    test('the approved account wins over a pendingApproval duplicate, whatever the read order', () async {
      // The guard's lookup took whichever doc Firestore returned first, so a
      // paying owner could be sent to /pending-approval on the duplicate.
      for (final order in [
        [pendingDuplicate, original],
        [original, pendingDuplicate],
      ]) {
        final picked = await FacilityCreatorAccountService.getAccountByOwnerUidOrThrow(
          'owner',
          readOwnerAccounts: (_) async => order,
        );
        expect(picked?.accountId, 'acct_original');
      }
    });

    test('then the oldest, then the id, so the answer never depends on read order', () {
      final older = _account('acct_b',
          status: SubscriptionStatus.cancelled, createdAt: DateTime(2025, 1, 1));
      final newer = _account('acct_a',
          status: SubscriptionStatus.active, createdAt: DateTime(2026, 1, 1));
      final twin = _account('acct_c',
          status: SubscriptionStatus.cancelled, createdAt: DateTime(2025, 1, 1));

      expect(FacilityCreatorAccountService.preferredOwnerAccount([newer, older])?.accountId,
          'acct_b');
      expect(FacilityCreatorAccountService.preferredOwnerAccount([twin, older])?.accountId,
          'acct_b');
      expect(FacilityCreatorAccountService.preferredOwnerAccount(const []), isNull);
    });

    test('a failed read still throws', () async {
      await expectLater(
        FacilityCreatorAccountService.getAccountByOwnerUidOrThrow(
          'owner',
          readOwnerAccounts: (_) async => throw StateError('offline'),
        ),
        throwsStateError,
      );
    });
  });

  group('AccountTies', () {
    AccountTies ties({bool role = false, bool owns = false, bool invite = false}) =>
        AccountTies(activeRole: role, ownsFacility: owns, pendingInvite: invite);

    test('invited staff: a role or a pending invite, and no facility of their own', () {
      expect(ties(role: true).invitedStaffOnly, isTrue);
      expect(ties(invite: true).invitedStaffOnly, isTrue);
      expect(ties(role: true, owns: true).invitedStaffOnly, isFalse);
      expect(ties(invite: true, owns: true).invitedStaffOnly, isFalse);
      expect(ties().invitedStaffOnly, isFalse);
    });

    test('a new signup: no role, no facility and no invite', () {
      expect(ties().newSignup, isTrue);
      expect(ties(role: true).newSignup, isFalse);
      expect(ties(owns: true).newSignup, isFalse);
      expect(ties(invite: true).newSignup, isFalse);
    });
  });

  group('ensureAccountFor', () {
    final User owner = MockUser(uid: 'owner', email: 'owner@example.com');
    const nothing = AccountTies(activeRole: false, ownsFacility: false, pendingInvite: false);
    const staff = AccountTies(activeRole: true, ownsFacility: false, pendingInvite: false);
    const ownerOfFacilities =
        AccountTies(activeRole: true, ownsFacility: true, pendingInvite: false);
    late int creates;

    Future<FacilityCreatorAccountModel> create(User user) async {
      creates += 1;
      return _account('acct_new',
          status: SubscriptionStatus.pendingApproval, createdAt: DateTime(2026, 9, 23));
    }

    setUp(() => creates = 0);

    test('a failed account read never creates an account', () async {
      // The production read (no Firebase app in tests, so it fails). The old
      // lookup turned this into "no account" and wrote a second,
      // pendingApproval account for an owner who already had one.
      await expectLater(
        FacilityCreatorAccountService.ensureAccountFor(
          owner,
          readTies: (_) async => nothing,
          create: create,
        ),
        throwsA(anything),
      );
      expect(creates, 0);
    });

    test('an existing account is returned as is', () async {
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: (_) async => original,
        readTies: (_) async => fail('not asked when an account exists'),
        create: create,
      );
      expect(account?.accountId, 'acct_original');
      expect(creates, 0);
    });

    test('invited staff are not given an account', () async {
      // The first screen that called this gave staff a pendingApproval account,
      // and the route guard then held them on /pending-approval.
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: (_) async => null,
        readTies: (_) async => staff,
        create: create,
      );
      expect(account, isNull);
      expect(creates, 0);
    });

    test('unless they are creating a facility of their own (no staff check needed)', () async {
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        owner,
        createForInvitedStaff: true,
        readAccount: (_) async => null,
        readTies: (_) async => fail('creating a facility makes them an owner either way'),
        create: create,
      );
      expect(account?.accountId, 'acct_new');
      expect(creates, 1);
    });

    test('a failed staff check never creates an account either', () async {
      // The production check (no Firebase app in tests, so it fails).
      for (final newSignupsOnly in [false, true]) {
        await expectLater(
          FacilityCreatorAccountService.ensureAccountFor(
            owner,
            createOnlyForNewSignups: newSignupsOnly,
            readAccount: (_) async => null,
            create: create,
          ),
          throwsA(anything),
        );
      }
      expect(creates, 0);
    });

    test('a new owner with no account and no roles gets one', () async {
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: (_) async => null,
        readTies: (_) async => nothing,
        create: create,
      );
      expect(account?.accountId, 'acct_new');
      expect(creates, 1);
    });

    test('an owner with facilities but no account: the screens create one, the guard does not',
        () async {
      // The guard gave these owners a pendingApproval account with no
      // facilities linked, and then held them on /pending-approval. They are
      // left to the screens that create one, as before.
      final fromGuard = await FacilityCreatorAccountService.ensureAccountFor(
        owner,
        createOnlyForNewSignups: true,
        readAccount: (_) async => null,
        readTies: (_) async => ownerOfFacilities,
        create: create,
      );
      expect(fromGuard, isNull);
      expect(creates, 0);

      final fromScreen = await FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: (_) async => null,
        readTies: (_) async => ownerOfFacilities,
        create: create,
      );
      expect(fromScreen?.accountId, 'acct_new');
      expect(creates, 1);
    });

    test('two callers at once create one account between them', () async {
      // The route guard's first-load ensure and a screen's used to be able to
      // both read "no account" and both create one.
      final release = Completer<void>();
      Future<FacilityCreatorAccountModel> slowCreate(User user) async {
        await release.future;
        return create(user);
      }

      final first = FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: (_) async => null,
        readTies: (_) async => nothing,
        create: slowCreate,
      );
      final second = FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: (_) async => null,
        readTies: (_) async => nothing,
        create: slowCreate,
      );
      await pumpEventQueue();
      release.complete();
      final results = await Future.wait([first, second]);
      expect(results.map((a) => a?.accountId), ['acct_new', 'acct_new']);
      expect(creates, 1);
    });

    test("a screen that joins the guard's run still gets its own answer", () async {
      // Sharing the guard's run handed the screen the guard's "none" for an
      // owner the screen would have given an account.
      final release = Completer<void>();
      FacilityCreatorAccountModel? stored;
      Future<FacilityCreatorAccountModel?> read(String uid) async {
        await release.future;
        return stored;
      }

      Future<FacilityCreatorAccountModel> storingCreate(User user) async =>
          stored = await create(user);

      final fromGuard = FacilityCreatorAccountService.ensureAccountFor(
        owner,
        createOnlyForNewSignups: true,
        readAccount: read,
        readTies: (_) async => ownerOfFacilities,
        create: storingCreate,
      );
      final fromScreen = FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: read,
        readTies: (_) async => ownerOfFacilities,
        create: storingCreate,
      );
      release.complete();
      expect(await fromGuard, isNull);
      expect((await fromScreen)?.accountId, 'acct_new');
      expect(creates, 1);
    });
  });

  group("the owner lookup's own read", () {
    tearDown(() => FacilityCreatorAccountService.overrideForTesting());

    FakeDoc accountDoc(String id, Map<String, dynamic> extra) => FakeDoc(id, {
          'ownerUid': 'owner',
          'ownerEmail': 'owner@example.com',
          'ownerName': 'Owner',
          ...extra,
        });

    test('a malformed duplicate is skipped, not fatal to the whole read', () async {
      // One bad doc used to throw for the whole read, and the guard then sent
      // a paying owner to /subscription on every navigation.
      final log = FakeQueryLog();
      FacilityCreatorAccountService.overrideForTesting(
        collection: (name) {
          expect(name, 'facilityCreatorAccounts');
          return FakeCollection([
            accountDoc('acct_bad', {
              'subscriptionStatus': 'active',
              'createdAt': Timestamp.fromDate(DateTime(2025, 1, 1)),
              'subscriptionCurrentPeriodEnd': '2026-10-01',
            }),
            accountDoc('acct_good', {
              'subscriptionStatus': 'active',
              'createdAt': Timestamp.fromDate(DateTime(2026, 3, 1)),
            }),
          ], log: log);
        },
      );
      final account = await FacilityCreatorAccountService.getAccountByOwnerUidOrThrow('owner');
      expect(account?.accountId, 'acct_good');
      expect(log.equalityFilters, [('ownerUid', 'owner')]);
      expect(log.limits.single, greaterThan(1));
    });

    test('when none parse, the read fails rather than claiming "no account"', () async {
      FacilityCreatorAccountService.overrideForTesting(
        collection: (_) => FakeCollection([
          accountDoc('acct_bad', {'metadata': 'not a map'}),
        ]),
      );
      await expectLater(
        FacilityCreatorAccountService.getAccountByOwnerUidOrThrow('owner'),
        throwsA(anything),
      );
    });

    test('parseOwnerAccounts keeps every doc that parses', () {
      final parsed = FacilityCreatorAccountService.parseOwnerAccounts([
        accountDoc('a', {'subscriptionStatus': 'active'}),
        accountDoc('b', {'createdAt': 'yesterday'}),
        accountDoc('c', {'subscriptionStatus': 'trialing'}),
      ]);
      expect(parsed.map((a) => a.accountId), ['a', 'c']);
      expect(FacilityCreatorAccountService.parseOwnerAccounts(const []), isEmpty);
    });
  });

  group("ensureAccountFor's staff check (its own queries)", () {
    // A mixed-case address: the invite and the rules both use it lower-cased.
    final User user = MockUser(uid: 'owner', email: 'Owner@Example.com');
    late int creates;
    late FakeQueryLog invitesLog;
    late List<String> events;

    Future<FacilityCreatorAccountModel> create(User user) async {
      creates += 1;
      events.add('create');
      return _account('acct_new',
          status: SubscriptionStatus.pendingApproval, createdAt: DateTime(2026, 9, 23));
    }

    setUp(() {
      creates = 0;
      invitesLog = FakeQueryLog();
      events = [];
    });
    tearDown(() => FacilityCreatorAccountService.overrideForTesting());

    FakeDoc invite(String id, String emailLower, {String status = 'pending'}) => FakeDoc(id, {
          'facilityId': 'f7',
          'email': emailLower,
          'emailLower': emailLower,
          'roleType': 'employee',
          'status': status,
        });

    /// Serves the ties reads from fakes. [fulfil] replaces invite acceptance;
    /// by default it accepts every pending invite for the address the way
    /// PermissionService does: an active role row, and the invite accepted.
    void serve({
      required bool activeRole,
      required bool ownsFacility,
      bool pendingInvite = false,
      Future<bool> Function(User user, String emailLower)? fulfil,
    }) {
      final roles = [
        if (activeRole)
          FakeDoc('role_1', {'userId': 'owner', 'isActive': true, 'facilityId': 'f1'}),
        FakeDoc('role_old', {'userId': 'owner', 'isActive': false, 'facilityId': 'f0'}),
      ];
      final invites = [
        if (pendingInvite) invite('inv_1', 'owner@example.com'),
        invite('inv_old', 'owner@example.com', status: 'accepted'),
        invite('inv_other', 'someone@example.com'),
      ];
      FacilityCreatorAccountService.overrideForTesting(
        collection: (name) => switch (name) {
          'user_roles' => FakeCollection(roles),
          'facilities' => FakeCollection([
              if (ownsFacility) FakeDoc('f1', {'ownerUid': 'owner', 'name': 'Mine'}),
              FakeDoc('f9', {'ownerUid': 'someone-else', 'name': 'Theirs'}),
            ]),
          _ => throw StateError('unexpected collection $name'),
        },
        collectionGroup: (name) {
          expect(name, 'invites');
          events.add('invite check');
          return FakeCollection(invites, log: invitesLog);
        },
        fulfillPendingInvites: fulfil ??
            (u, emailLower) async {
              events.add('fulfil:$emailLower');
              for (final d in invites) {
                if (d.data()['emailLower'] != emailLower || d.data()['status'] != 'pending') {
                  continue;
                }
                d.data()['status'] = 'accepted';
                roles.add(FakeDoc('role_${d.id}',
                    {'userId': u.uid, 'isActive': true, 'facilityId': d.data()['facilityId']}));
              }
              return true;
            },
      );
    }

    Future<FacilityCreatorAccountModel?> ensure({bool newSignupsOnly = false}) =>
        FacilityCreatorAccountService.ensureAccountFor(
          user,
          createOnlyForNewSignups: newSignupsOnly,
          readAccount: (_) async => null,
          create: create,
        );

    test('an owner with an owner role row is not taken for staff (screens create one)', () async {
      // Owners have a role row per facility too; without the owned check they
      // were never given an account.
      serve(activeRole: true, ownsFacility: true);
      final account = await ensure();
      expect(account?.accountId, 'acct_new');
      expect(creates, 1);
    });

    test('an invited team member (an active role, no facility of their own) is', () async {
      serve(activeRole: true, ownsFacility: false);
      expect(await ensure(), isNull);
      expect(creates, 0);
    });

    test('so is a signup with only a pending invite, even on a screen', () async {
      // No role until the invite is accepted, so they were taken for a new
      // owner and given a pendingApproval account.
      serve(activeRole: false, ownsFacility: false, pendingInvite: true);
      expect(await ensure(), isNull);
      expect(creates, 0);
      expect(invitesLog.equalityFilters, [
        ('emailLower', 'owner@example.com'),
        ('status', 'pending'),
      ]);
    });

    test('an unverified user is not looked up by invite, so a screen still creates as before',
        () async {
      // The rules refuse the invite query to an unverified address. Sending
      // it anyway failed the whole ensure, so such a user got no account.
      serve(activeRole: false, ownsFacility: false, pendingInvite: true);
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        MockUser(uid: 'owner', email: 'owner@example.com', isEmailVerified: false),
        readAccount: (_) async => null,
        create: create,
      );
      expect(account?.accountId, 'acct_new');
      expect(events, isNot(contains('invite check')));
    });

    test('a new signup (no active role, nothing owned, no invite) gets an account', () async {
      serve(activeRole: false, ownsFacility: false);
      final account = await ensure();
      expect(account?.accountId, 'acct_new');
      expect(creates, 1);
    });

    group('from the route guard (createOnlyForNewSignups)', () {
      test("an invited signup's invites are accepted first, and they get no account", () async {
        serve(activeRole: false, ownsFacility: false, pendingInvite: true);
        expect(await ensure(newSignupsOnly: true), isNull);
        expect(creates, 0);
        expect(events, ['fulfil:owner@example.com', 'invite check']);
      });

      test('an invite that could not be accepted keeps them from an account, and is a failure',
          () async {
        // Settling on "no account" left the invitee with no role for the
        // rest of the session; failing lets ensureAccountOnce try again.
        for (final fulfil in <Future<bool> Function(User, String)>[
          (_, __) async => throw StateError('permission-denied'),
          (_, __) async => false,
        ]) {
          serve(activeRole: false, ownsFacility: false, pendingInvite: true, fulfil: fulfil);
          await expectLater(ensure(newSignupsOnly: true), throwsA(anything));
        }
        expect(creates, 0);
      });

      test('but not when they have a role after all, or it only skipped invites', () async {
        // One of several accepted: they are on a team now. Skipped (they
        // accept through the link): nothing failed.
        serve(
          activeRole: true,
          ownsFacility: false,
          pendingInvite: true,
          fulfil: (_, __) async => false,
        );
        expect(await ensure(newSignupsOnly: true), isNull);
        serve(
          activeRole: false,
          ownsFacility: false,
          pendingInvite: true,
          fulfil: (_, __) async => true,
        );
        expect(await ensure(newSignupsOnly: true), isNull);
        expect(creates, 0);
      });

      test('an owner with facilities but no account is not given one', () async {
        serve(activeRole: true, ownsFacility: true);
        expect(await ensure(newSignupsOnly: true), isNull);
        expect(creates, 0);
      });

      test('nor is a team member', () async {
        serve(activeRole: true, ownsFacility: false);
        expect(await ensure(newSignupsOnly: true), isNull);
        expect(creates, 0);
      });

      test('a genuinely new signup is, after the invite check', () async {
        serve(activeRole: false, ownsFacility: false);
        final account = await ensure(newSignupsOnly: true);
        expect(account?.accountId, 'acct_new');
        expect(events, ['fulfil:owner@example.com', 'invite check', 'create']);
      });
    });

    test('the invite query has the collection-group index it needs', () async {
      // Two equality filters on a collection group: Firestore refuses the
      // query without a declared index, and a refused ties read creates
      // nothing, so new signups would get no account.
      serve(activeRole: false, ownsFacility: false);
      await ensure();
      final fields = [for (final (field, _) in invitesLog.equalityFilters) field as String];
      final indexes = (jsonDecode(File('firestore.indexes.json').readAsStringSync())
          as Map<String, dynamic>)['indexes'] as List<dynamic>;
      final declared = indexes.cast<Map<String, dynamic>>().any((index) =>
          index['collectionGroup'] == 'invites' &&
          index['queryScope'] == 'COLLECTION_GROUP' &&
          listEquals(
            [for (final f in index['fields'] as List<dynamic>) (f as Map)['fieldPath'] as String],
            fields,
          ));
      expect(fields, ['emailLower', 'status']);
      expect(declared, isTrue, reason: 'firestore.indexes.json needs invites $fields (COLLECTION_GROUP)');
    });
  });

  group('refreshStaleEmailVerifiedClaim (before the invite reads)', () {
    test('refreshes a verified user whose token still says unverified, and only then', () async {
      final stale = _TokenUser(verified: true, claimVerified: false);
      await refreshStaleEmailVerifiedClaim(stale);
      expect(stale.forcedRefreshes, 1);

      final fresh = _TokenUser(verified: true, claimVerified: true);
      await refreshStaleEmailVerifiedClaim(fresh);
      expect(fresh.forcedRefreshes, 0);

      final unverified = _TokenUser(verified: false, claimVerified: false);
      await refreshStaleEmailVerifiedClaim(unverified);
      expect(unverified.forcedRefreshes, 0);
    });

    test("the account service's staff check runs it before its invite query", () async {
      final user = _TokenUser(verified: true, claimVerified: false);
      final order = <String>[];
      user.onForcedRefresh = () => order.add('refresh');
      FacilityCreatorAccountService.overrideForTesting(
        collection: (name) => FakeCollection([]),
        collectionGroup: (_) {
          order.add('invite query');
          return FakeCollection([]);
        },
        fulfillPendingInvites: (_, __) async {
          order.add('fulfil');
          return true;
        },
      );
      addTearDown(FacilityCreatorAccountService.overrideForTesting);
      await FacilityCreatorAccountService.ensureAccountFor(
        user,
        createOnlyForNewSignups: true,
        readAccount: (_) async => null,
        create: (_) async => _account('acct_new',
            status: SubscriptionStatus.pendingApproval, createdAt: DateTime(2026, 9, 23)),
      );
      expect(order.first, 'refresh');
      expect(order, containsAllInOrder(['refresh', 'fulfil', 'invite query']));
    });

    test('so do the screens, which accept no invites first', () async {
      // Nothing else refreshes on the screens' path: a stale token had the
      // rules refuse the invite query, and the whole ensure failed.
      final user = _TokenUser(verified: true, claimVerified: false);
      final order = <String>[];
      user.onForcedRefresh = () => order.add('refresh');
      FacilityCreatorAccountService.overrideForTesting(
        collection: (name) => FakeCollection([]),
        collectionGroup: (_) {
          order.add('invite query');
          return FakeCollection([]);
        },
        fulfillPendingInvites: (_, __) async => fail('the screens accept no invites'),
      );
      addTearDown(FacilityCreatorAccountService.overrideForTesting);
      await FacilityCreatorAccountService.ensureAccountFor(
        user,
        readAccount: (_) async => null,
        create: (_) async => _account('acct_new',
            status: SubscriptionStatus.pendingApproval, createdAt: DateTime(2026, 9, 23)),
      );
      expect(order, ['refresh', 'invite query']);
    });
  });

  group("the route guard's ensure with PermissionService's own acceptance", () {
    // Both services' reads and writes on one fake Firestore: the production
    // path from the guard's first-load ensure to the invite and role writes.
    late FakeStore store;
    final User user = MockUser(uid: 'u1', email: 'Staff@Example.com');

    setUp(() {
      FacilityCreatorAccountService.resetEnsuredForTesting();
      store = FakeStore();
      FacilityCreatorAccountService.overrideForTesting(
        collection: store.collection,
        collectionGroup: store.collectionGroup,
        currentUser: () => user,
      );
      PermissionService.overrideForTesting(
        collection: store.collection,
        collectionGroup: store.collectionGroup,
        currentUser: () => user,
      );
    });
    tearDown(() {
      FacilityCreatorAccountService.overrideForTesting();
      PermissionService.overrideForTesting();
    });

    void pendingInvite(String facilityId) =>
        store.put('facilities/$facilityId/invites/inv_$facilityId', {
          'facilityId': facilityId,
          'email': 'staff@example.com',
          'emailLower': 'staff@example.com',
          'roleType': 'employee',
          'status': 'pending',
          'invitedBy': '$facilityId-owner',
          'invitedAt': Timestamp.fromDate(DateTime.now().subtract(const Duration(days: 1))),
        });
    String? inviteStatus(String facilityId) =>
        store.data('facilities/$facilityId/invites/inv_$facilityId')?['status'] as String?;

    test('a genuinely new invitee lands on the team, with no account', () async {
      pendingInvite('keepsake');
      expect(
        await FacilityCreatorAccountService.ensureAccountOnce(user, createOnlyForNewSignups: true),
        isTrue,
      );
      expect(inviteStatus('keepsake'), 'accepted');
      expect(store.idsIn('facilityCreatorAccounts'), isEmpty);
    });

    test('existing staff and a removed team member are not put on a team without a click',
        () async {
      // Every verified user with no account had every pending invite
      // accepted on their next load, once per session.
      for (final isActive in [true, false]) {
        FacilityCreatorAccountService.resetEnsuredForTesting();
        store.put('user_roles/r1', {
          'userId': 'u1',
          'facilityId': 'caprock',
          'roleType': 'employee',
          'isActive': isActive,
        });
        pendingInvite('keepsake');
        await FacilityCreatorAccountService.ensureAccountOnce(user, createOnlyForNewSignups: true);
        expect(inviteStatus('keepsake'), 'pending', reason: 'isActive: $isActive');
        expect(store.idsIn('user_roles'), ['r1']);
        expect(store.idsIn('facilityCreatorAccounts'), isEmpty);
      }
    });
  });

  group('createAccount', () {
    tearDown(() => FacilityCreatorAccountService.overrideForTesting());

    test('a failed existing-account check writes nothing', () async {
      // The non-throwing read turned a failed read into "none" and wrote a
      // duplicate, pendingApproval account for an owner who already had one.
      final accounts = _UnreadableCollection();
      FacilityCreatorAccountService.overrideForTesting(
        collection: (name) {
          expect(name, 'facilityCreatorAccounts');
          return accounts;
        },
        currentUser: () => MockUser(uid: 'owner', email: 'owner@example.com'),
      );
      await expectLater(
        FacilityCreatorAccountService.createAccount(
          ownerUid: 'owner',
          ownerEmail: 'owner@example.com',
          ownerName: 'Owner',
        ),
        throwsA(isA<FirebaseException>()),
      );
      expect(accounts.docCalls, isEmpty);
    });
  });

  group('ensureAccountOnce (first authenticated load)', () {
    final User user = MockUser(uid: 'new-owner', email: 'new@example.com');
    setUp(FacilityCreatorAccountService.resetEnsuredForTesting);

    FacilityCreatorAccountModel created() => _account('acct_new',
        status: SubscriptionStatus.pendingApproval, createdAt: DateTime(2026, 9, 23));

    test('runs once per user per session, and says so the first time', () async {
      var calls = 0;
      Future<FacilityCreatorAccountModel?> ensure(User u) async {
        calls += 1;
        return created();
      }

      expect(await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: ensure), isTrue);
      expect(await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: ensure), isFalse);
      expect(calls, 1);
    });

    test('a team member confirmed as having none is not asked again either', () async {
      var calls = 0;
      Future<FacilityCreatorAccountModel?> ensure(User u) async {
        calls += 1;
        return null;
      }

      await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: ensure);
      await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: ensure);
      expect(calls, 1);
    });

    test('a failure never throws, and is tried again only after ensureRetryAfter', () async {
      // The route guard awaits this on every navigation until it succeeds, so
      // a failure that was retried at once paid the account read, the staff
      // queries and the failed write on every click.
      var calls = 0;
      Future<FacilityCreatorAccountModel?> failing(User u) async {
        calls += 1;
        throw StateError('offline');
      }

      final t0 = DateTime(2026, 9, 23, 12);
      Future<bool> at(Duration after) => FacilityCreatorAccountService.ensureAccountOnce(user,
          ensure: failing, clock: () => t0.add(after));

      expect(await at(Duration.zero), isFalse);
      expect(await at(const Duration(seconds: 30)), isFalse);
      expect(calls, 1);
      expect(await at(FacilityCreatorAccountService.ensureRetryAfter), isFalse);
      expect(calls, 2);
    });

    test('a success after a failure is kept for the session', () async {
      var fail = true;
      var calls = 0;
      Future<FacilityCreatorAccountModel?> flaky(User u) async {
        calls += 1;
        if (fail) throw StateError('offline');
        return created();
      }

      final t0 = DateTime(2026, 9, 23, 12);
      await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: flaky, clock: () => t0);
      fail = false;
      final later = t0.add(FacilityCreatorAccountService.ensureRetryAfter);
      expect(
        await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: flaky, clock: () => later),
        isTrue,
      );
      expect(
        await FacilityCreatorAccountService.ensureAccountOnce(user,
            ensure: flaky, clock: () => later.add(const Duration(hours: 1))),
        isFalse,
      );
      expect(calls, 2);
    });

    test("the route guard's \"none wanted\" leaves the screens their own ensure", () async {
      // An owner with facilities but no account: the guard creates nothing,
      // and the screens that create one still get to, as before.
      final asked = <String>[];
      expect(
        await FacilityCreatorAccountService.ensureAccountOnce(user,
            createOnlyForNewSignups: true, ensure: (_) async {
          asked.add('guard');
          return null;
        }),
        isTrue,
      );
      expect(
        await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: (_) async {
          asked.add('screen');
          return created();
        }),
        isTrue,
      );
      expect(asked, ['guard', 'screen']);
    });

    test('an account found or created settles both', () async {
      var calls = 0;
      Future<FacilityCreatorAccountModel?> ensure(User u) async {
        calls += 1;
        return created();
      }

      await FacilityCreatorAccountService.ensureAccountOnce(user,
          createOnlyForNewSignups: true, ensure: ensure);
      expect(await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: ensure), isFalse);
      expect(calls, 1);
    });

    test('the route guard mode runs the new-signups-only ensure by default', () async {
      // The production ensure on fakes: an owner with a facility and no
      // account is not given one from the guard, but is from a screen.
      final accounts = FakeQueryLog();
      final accountDocs = <FakeDoc>[];
      FacilityCreatorAccountService.overrideForTesting(
        collection: (name) => switch (name) {
          'facilityCreatorAccounts' => FakeCollection(accountDocs, log: accounts),
          'user_roles' => FakeCollection([]),
          'facilities' => FakeCollection([FakeDoc('f1', {'ownerUid': 'new-owner'})]),
          _ => throw StateError('unexpected collection $name'),
        },
        collectionGroup: (_) => FakeCollection([]),
        currentUser: () => user,
        fulfillPendingInvites: (_, __) async => true,
      );
      addTearDown(FacilityCreatorAccountService.overrideForTesting);

      expect(
        await FacilityCreatorAccountService.ensureAccountOnce(user, createOnlyForNewSignups: true),
        isTrue,
      );
      expect(accounts.writes, isEmpty);
      expect(await FacilityCreatorAccountService.ensureAccountOnce(user), isTrue);
      expect(accounts.writes.single.$3['subscriptionStatus'], 'pendingApproval');
    });

    test('a new invitee whose invites could not be accepted is retried, not settled', () async {
      // The production ensure on fakes. Settling left the invitee on an empty
      // dashboard with no role for the rest of the session.
      final invites = [
        FakeDoc('inv_1', {
          'facilityId': 'keepsake',
          'emailLower': 'new@example.com',
          'status': 'pending',
        }),
      ];
      final roles = <FakeDoc>[];
      var accepting = false;
      var attempts = 0;
      FacilityCreatorAccountService.overrideForTesting(
        collection: (name) => switch (name) {
          'facilityCreatorAccounts' => FakeCollection([]),
          'user_roles' => FakeCollection(roles),
          'facilities' => FakeCollection([]),
          _ => throw StateError('unexpected collection $name'),
        },
        collectionGroup: (_) => FakeCollection(invites),
        currentUser: () => user,
        fulfillPendingInvites: (u, emailLower) async {
          attempts += 1;
          if (!accepting) return false;
          invites.single.data()['status'] = 'accepted';
          roles.add(FakeDoc('role_1', {'userId': u.uid, 'isActive': true, 'facilityId': 'keepsake'}));
          return true;
        },
      );
      addTearDown(FacilityCreatorAccountService.overrideForTesting);

      final t0 = DateTime(2026, 9, 23, 12);
      Future<bool> at(Duration after) => FacilityCreatorAccountService.ensureAccountOnce(user,
          createOnlyForNewSignups: true, clock: () => t0.add(after));

      expect(await at(Duration.zero), isFalse);
      expect(await at(const Duration(seconds: 30)), isFalse);
      expect(attempts, 1);
      accepting = true;
      expect(await at(FacilityCreatorAccountService.ensureRetryAfter), isTrue);
      expect(attempts, 2);
      expect(roles.single.data()['facilityId'], 'keepsake');
    });

    test('by default it runs the real ensure (which fails here, with no Firebase) without throwing',
        () async {
      expect(await FacilityCreatorAccountService.ensureAccountOnce(user), isFalse);
    });
  });

  group('ensureAccountInBackground (list screens)', () {
    test('starts the once-per-session ensure for the signed-in user and returns', () {
      final started = <String>[];
      final never = Completer<bool>();
      FacilityCreatorAccountService.ensureAccountInBackground(
        currentUser: () => MockUser(uid: 'owner'),
        ensureOnce: (u) {
          started.add(u.uid);
          return never.future;
        },
      );
      expect(started, ['owner']);
    });

    test('never throws into the screen, whatever fails', () async {
      FacilityCreatorAccountService.ensureAccountInBackground(
        currentUser: () => throw StateError('no auth'),
      );
      FacilityCreatorAccountService.ensureAccountInBackground(
        currentUser: () => MockUser(uid: 'owner'),
        ensureOnce: (_) async => false,
      );
      // The production defaults (no Firebase app here, so they fail).
      FacilityCreatorAccountService.ensureAccountInBackground();
      await pumpEventQueue();
    });
  });
}
