// The fake below implements cloud_firestore's @sealed query classes so the
// service's own queries run in tests; nothing outside tests sees it.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';

import 'support/fake_facility_collection.dart';

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

  group('ensureAccountFor', () {
    final User owner = MockUser(uid: 'owner', email: 'owner@example.com');
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
          isInvitedStaffOnly: (_) async => false,
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
        isInvitedStaffOnly: (_) async => fail('not asked when an account exists'),
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
        isInvitedStaffOnly: (_) async => true,
        create: create,
      );
      expect(account, isNull);
      expect(creates, 0);
    });

    test('unless they are creating a facility of their own', () async {
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        owner,
        createForInvitedStaff: true,
        readAccount: (_) async => null,
        isInvitedStaffOnly: (_) async => true,
        create: create,
      );
      expect(account?.accountId, 'acct_new');
      expect(creates, 1);
    });

    test('a failed staff check never creates an account either', () async {
      // The production check (no Firebase app in tests, so it fails).
      await expectLater(
        FacilityCreatorAccountService.ensureAccountFor(
          owner,
          readAccount: (_) async => null,
          create: create,
        ),
        throwsA(anything),
      );
      expect(creates, 0);
    });

    test('a new owner with no account and no roles gets one', () async {
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: (_) async => null,
        isInvitedStaffOnly: (_) async => false,
        create: create,
      );
      expect(account?.accountId, 'acct_new');
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
        isInvitedStaffOnly: (_) async => false,
        create: slowCreate,
      );
      final second = FacilityCreatorAccountService.ensureAccountFor(
        owner,
        readAccount: (_) async => null,
        isInvitedStaffOnly: (_) async => false,
        create: slowCreate,
      );
      await pumpEventQueue();
      release.complete();
      final results = await Future.wait([first, second]);
      expect(results.map((a) => a?.accountId), ['acct_new', 'acct_new']);
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
    final User user = MockUser(uid: 'owner', email: 'owner@example.com');
    late int creates;

    Future<FacilityCreatorAccountModel> create(User user) async {
      creates += 1;
      return _account('acct_new',
          status: SubscriptionStatus.pendingApproval, createdAt: DateTime(2026, 9, 23));
    }

    setUp(() => creates = 0);
    tearDown(() => FacilityCreatorAccountService.overrideForTesting());

    void serve({required bool activeRole, required bool ownsFacility}) {
      FacilityCreatorAccountService.overrideForTesting(
        collection: (name) => switch (name) {
          'user_roles' => FakeCollection([
              if (activeRole)
                FakeDoc('role_1', {'userId': 'owner', 'isActive': true, 'facilityId': 'f1'}),
              FakeDoc('role_old', {'userId': 'owner', 'isActive': false, 'facilityId': 'f0'}),
            ]),
          'facilities' => FakeCollection([
              if (ownsFacility) FakeDoc('f1', {'ownerUid': 'owner', 'name': 'Mine'}),
              FakeDoc('f9', {'ownerUid': 'someone-else', 'name': 'Theirs'}),
            ]),
          _ => throw StateError('unexpected collection $name'),
        },
      );
    }

    test('an owner with an owner role row is not taken for staff', () async {
      // Owners have a role row per facility too; without the owned check they
      // were never given an account.
      serve(activeRole: true, ownsFacility: true);
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        user,
        readAccount: (_) async => null,
        create: create,
      );
      expect(account?.accountId, 'acct_new');
      expect(creates, 1);
    });

    test('an invited team member (an active role, no facility of their own) is', () async {
      serve(activeRole: true, ownsFacility: false);
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        user,
        readAccount: (_) async => null,
        create: create,
      );
      expect(account, isNull);
      expect(creates, 0);
    });

    test('a new signup (no active role, nothing owned) gets an account', () async {
      serve(activeRole: false, ownsFacility: false);
      final account = await FacilityCreatorAccountService.ensureAccountFor(
        user,
        readAccount: (_) async => null,
        create: create,
      );
      expect(account?.accountId, 'acct_new');
      expect(creates, 1);
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

    test('a failure never throws, and the next call tries again', () async {
      var calls = 0;
      Future<FacilityCreatorAccountModel?> failing(User u) async {
        calls += 1;
        throw StateError('offline');
      }

      expect(await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: failing), isFalse);
      expect(await FacilityCreatorAccountService.ensureAccountOnce(user, ensure: failing), isFalse);
      expect(calls, 2);
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
