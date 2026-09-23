import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';

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
  });
}
