import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/owner_account_standing.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';

import 'support/fake_facility_collection.dart';

FacilityCreatorAccountModel _account({
  required SubscriptionStatus status,
  DateTime? periodEnd,
  DateTime? trialEnd,
  bool billingExempt = false,
  bool suspended = false,
}) {
  final now = DateTime.now();
  return FacilityCreatorAccountModel(
    accountId: 'acct_123',
    ownerUid: 'user_1',
    ownerEmail: 'user@example.com',
    ownerName: 'Test User',
    subscriptionStatus: status,
    billingExempt: billingExempt,
    suspended: suspended,
    createdAt: now,
    updatedAt: now,
    subscriptionTrialEnd: trialEnd,
    subscriptionCurrentPeriodEnd: periodEnd,
    subscriptionCurrentPeriodStart: now.subtract(const Duration(days: 30)),
  );
}

FacilityModel _facility({
  String? accountId = 'acct_123',
  String? platformStatus,
  bool billingExempt = false,
}) {
  return FacilityModel(
    id: 'fac_1',
    name: 'Keepsake Storage',
    ownerUid: 'user_1',
    createdAt: DateTime(2026),
    facilityCreatorAccountId: accountId,
    platformSubscriptionStatus: platformStatus,
    billingExempt: billingExempt,
  );
}

void main() {
  final mockUser = MockUser(uid: 'user_1', email: 'user@example.com');
  final mockAuth = MockFirebaseAuth(mockUser: mockUser);

  test('Superadmin bypasses subscription checks', () async {
    final result = await SubscriptionGuardService.checkAccess(
      authOverride: mockAuth,
      userOverride: mockUser,
      superAdminResolver: () => true,
      currentRoute: '/dashboard',
    );

    expect(result.canAccess, isTrue);
    expect(result.redirectRoute, isNull);
  });

  test('Active subscription grants access', () async {
    final result = await SubscriptionGuardService.checkAccess(
      authOverride: mockAuth,
      userOverride: mockUser,
      currentRoute: '/dashboard',
      superAdminResolver: () => false,
      accountProvider: (_) async => _account(status: SubscriptionStatus.active),
      facilitiesProvider: () async => [],
      activeSubscriptionChecker: (_, __) async => true,
    );

    expect(result.canAccess, isTrue);
    expect(result.redirectRoute, isNull);
  });

  test('Expired past-due subscription is denied with redirect', () async {
    final expiredPeriodEnd = DateTime.now().subtract(const Duration(days: 10));
    final result = await SubscriptionGuardService.checkAccess(
      authOverride: mockAuth,
      userOverride: mockUser,
      currentRoute: '/dashboard',
      superAdminResolver: () => false,
      accountProvider: (_) async => _account(
        status: SubscriptionStatus.pastDue,
        periodEnd: expiredPeriodEnd,
      ),
      facilitiesProvider: () async => [],
      activeSubscriptionChecker: (_, __) async => false,
    );

    expect(result.canAccess, isFalse);
    expect(result.redirectRoute, '/subscription?pastDue=1');
  });

  group('checkAccess without an injected checker (production path)', () {
    // Each case counts lookups. The default path used to call
    // hasActiveSubscription, which fetched the account a second time, and it
    // always fetched the facilities even when the account alone decided.
    late int accountFetches;
    late int facilityFetches;

    Future<SubscriptionAccessResult> check(
      FacilityCreatorAccountModel? account, {
      List<FacilityModel> facilities = const [],
      bool superAdmin = false,
    }) {
      accountFetches = 0;
      facilityFetches = 0;
      return SubscriptionGuardService.checkAccess(
        authOverride: mockAuth,
        userOverride: mockUser,
        currentRoute: '/dashboard',
        superAdminResolver: () => superAdmin,
        accountProvider: (_) async {
          accountFetches += 1;
          return account;
        },
        facilitiesProvider: () async {
          facilityFetches += 1;
          return facilities;
        },
      );
    }

    test('account-level access is decided from the account already fetched', () async {
      final result = await check(_account(status: SubscriptionStatus.active));
      expect(result.canAccess, isTrue);
      expect(accountFetches, 1);
      expect(facilityFetches, 0);
    });

    test('a trialing account keeps access and is looked up once', () async {
      final result = await check(_account(
        status: SubscriptionStatus.trialing,
        trialEnd: DateTime.now().add(const Duration(days: 5)),
      ));
      expect(result.canAccess, isTrue);
      expect(result.subscriptionStatus, SubscriptionStatus.trialing);
      expect(accountFetches, 1);
    });

    test('a linked facility with an active platform subscription still grants access', () async {
      // Per-facility billing: the account-level status is a legacy leftover.
      final result = await check(
        _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().subtract(const Duration(days: 40)),
        ),
        facilities: [_facility(platformStatus: 'active')],
      );
      expect(result.canAccess, isTrue);
      expect(accountFetches, 1);
      expect(facilityFetches, 1);
    });

    test('a facility linked to a different account does not', () async {
      final result = await check(
        _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().subtract(const Duration(days: 40)),
        ),
        facilities: [_facility(accountId: 'acct_other', platformStatus: 'active')],
      );
      expect(result.canAccess, isFalse);
      expect(result.redirectRoute, '/subscription');
    });

    test('an expired trial is sent to subscribe', () async {
      final result = await check(_account(
        status: SubscriptionStatus.trialing,
        trialEnd: DateTime.now().subtract(const Duration(days: 1)),
      ));
      expect(result.canAccess, isFalse);
      expect(result.redirectRoute, '/subscription?trialExpired=1');
    });

    test('a pending-approval account goes to the pending screen', () async {
      final result = await check(_account(status: SubscriptionStatus.pendingApproval));
      expect(result.canAccess, isFalse);
      expect(result.redirectRoute, '/pending-approval');
      expect(result.subscriptionStatus, SubscriptionStatus.pendingApproval);
    });

    test('a billing-exempt account is let through without any facility lookup', () async {
      final result = await check(_account(
        status: SubscriptionStatus.cancelled,
        billingExempt: true,
      ));
      expect(result.canAccess, isTrue);
      expect(facilityFetches, 0);
    });

    test('a billing-exempt facility linked to the account grants access', () async {
      // The guard used to honour only the account-level flag, so an owner
      // whose facility a super admin had exempted was still locked out.
      final result = await check(
        _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().subtract(const Duration(days: 40)),
        ),
        facilities: [_facility(billingExempt: true)],
      );
      expect(result.canAccess, isTrue);
      expect(facilityFetches, 1);
    });

    test('a billing-exempt facility linked to a different account does not', () async {
      final result = await check(
        _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().subtract(const Duration(days: 40)),
        ),
        facilities: [_facility(accountId: 'acct_other', billingExempt: true)],
      );
      expect(result.canAccess, isFalse);
    });

    test('a failed account read is refused as unverified, not let through as "no account"', () async {
      final result = await SubscriptionGuardService.checkAccess(
        authOverride: mockAuth,
        userOverride: mockUser,
        currentRoute: '/dashboard',
        superAdminResolver: () => false,
        accountProvider: (_) async => throw StateError('unavailable'),
        facilitiesProvider: () async => const [],
      );
      expect(result.canAccess, isFalse);
      expect(result.verified, isFalse);
      expect(result.redirectRoute, '/subscription');
    });

    test('a failed facilities read is refused as unverified, not as a lapse', () async {
      final result = await SubscriptionGuardService.checkAccess(
        authOverride: mockAuth,
        userOverride: mockUser,
        currentRoute: '/dashboard',
        superAdminResolver: () => false,
        accountProvider: (_) async => _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().subtract(const Duration(days: 40)),
        ),
        facilitiesProvider: () async => throw StateError('unavailable'),
      );
      expect(result.canAccess, isFalse);
      expect(result.verified, isFalse);
    });

    test('a real denial is verified', () async {
      final result = await check(_account(
        status: SubscriptionStatus.trialing,
        trialEnd: DateTime.now().subtract(const Duration(days: 1)),
      ));
      expect(result.canAccess, isFalse);
      expect(result.verified, isTrue);
    });

    test('no account at all is still let through (created with the first facility)', () async {
      final result = await check(null);
      expect(result.canAccess, isTrue);
      expect(result.verified, isTrue);
    });

    test('a suspended account is refused even while active', () async {
      final result = await check(_account(
        status: SubscriptionStatus.active,
        suspended: true,
      ));
      expect(result.canAccess, isFalse);
    });

    test('super admins bypass before any lookup', () async {
      final result = await check(null, superAdmin: true);
      expect(result.canAccess, isTrue);
      expect(accountFetches, 0);
    });
  });

  group('accountGrantsPlatformAccess (route guard, sidebar lock and lock overlay)', () {
    final lapsed = _account(
      status: SubscriptionStatus.cancelled,
      periodEnd: DateTime.now().subtract(const Duration(days: 40)),
    );

    test('account-level access', () {
      expect(
        FacilityCreatorAccountService.accountGrantsPlatformAccess(
            _account(status: SubscriptionStatus.active)),
        isTrue,
      );
      expect(FacilityCreatorAccountService.accountGrantsPlatformAccess(lapsed), isFalse);
    });

    test('a billing-exempt account, whatever its status', () {
      // The guard already let these through; the sidebar lock and the lock
      // overlay (which used this rule) locked them.
      expect(
        FacilityCreatorAccountService.accountGrantsPlatformAccess(_account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().subtract(const Duration(days: 40)),
          billingExempt: true,
        )),
        isTrue,
      );
    });

    test('a linked facility that is billing-exempt or has an active platform subscription', () {
      bool grants(FacilityModel f) =>
          FacilityCreatorAccountService.accountGrantsPlatformAccess(lapsed, facilities: [f]);

      expect(grants(_facility(billingExempt: true)), isTrue);
      expect(grants(_facility(platformStatus: 'active')), isTrue);
      expect(grants(_facility(platformStatus: 'cancelled')), isFalse);
      expect(grants(_facility(accountId: 'acct_other', billingExempt: true)), isFalse);
      expect(grants(_facility(accountId: 'acct_other', platformStatus: 'active')), isFalse);
    });
  });

  group("checkAccess's own reads (production defaults)", () {
    // No Firebase app is initialised in tests, so the real Firestore and Auth
    // lookups fail: exactly the failed read the defaults must not turn into
    // "no account, allow" or "no facilities, lapsed".
    test('a failed account read is refused as unverified', () async {
      final result = await SubscriptionGuardService.checkAccess(
        authOverride: mockAuth,
        userOverride: mockUser,
        currentRoute: '/dashboard',
        superAdminResolver: () => false,
        facilitiesProvider: () async => const [],
      );
      expect(result.canAccess, isFalse);
      expect(result.verified, isFalse);
    });

    test('a failed facilities read is refused as unverified, not as a lapse', () async {
      final result = await SubscriptionGuardService.checkAccess(
        authOverride: mockAuth,
        userOverride: mockUser,
        currentRoute: '/dashboard',
        superAdminResolver: () => false,
        accountProvider: (_) async => _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().subtract(const Duration(days: 40)),
        ),
      );
      expect(result.canAccess, isFalse);
      expect(result.verified, isFalse);
    });
  });

  group('a suspended account gets nothing from its facilities', () {
    // Suspension is a super admin's decision about the account. A linked
    // facility's own subscription, or its exemption, used to let it back in.
    final suspended = _account(status: SubscriptionStatus.active, suspended: true);

    test('accountGrantsPlatformAccess', () {
      bool grants(FacilityCreatorAccountModel a, FacilityModel f) =>
          FacilityCreatorAccountService.accountGrantsPlatformAccess(a, facilities: [f]);

      expect(grants(suspended, _facility(platformStatus: 'active')), isFalse);
      expect(grants(suspended, _facility(billingExempt: true)), isFalse);
      // Only an exempt account, also a super admin's decision, overrides it.
      expect(
        grants(
          _account(status: SubscriptionStatus.active, suspended: true, billingExempt: true),
          _facility(),
        ),
        isTrue,
      );
    });

    for (final (name, facility) in [
      ('an active platform subscription', _facility(platformStatus: 'active')),
      ('a billing exemption', _facility(billingExempt: true)),
    ]) {
      test('checkAccess, with a linked facility that has $name', () async {
        final result = await SubscriptionGuardService.checkAccess(
          authOverride: mockAuth,
          userOverride: mockUser,
          currentRoute: '/dashboard',
          superAdminResolver: () => false,
          accountProvider: (_) async => suspended,
          facilitiesProvider: () async => [facility],
        );
        expect(result.canAccess, isFalse);
        expect(result.verified, isTrue);
      });
    }
  });

  group("the shell's 1-minute re-check (backgroundRecheckRedirect)", () {
    test('an unverified denial leaves the page alone', () {
      // A read failed; that is not a lapse. It used to be able to pull a
      // working page to /subscription.
      expect(
        SubscriptionGuardService.backgroundRecheckRedirect(const SubscriptionAccessResult(
          canAccess: false,
          redirectRoute: '/subscription',
          verified: false,
        )),
        isNull,
      );
    });

    test('a verified denial sends the user where checkAccess says', () {
      expect(
        SubscriptionGuardService.backgroundRecheckRedirect(const SubscriptionAccessResult(
          canAccess: false,
          redirectRoute: '/subscription?trialExpired=1',
        )),
        '/subscription?trialExpired=1',
      );
      expect(
        SubscriptionGuardService.backgroundRecheckRedirect(
            const SubscriptionAccessResult(canAccess: true)),
        isNull,
      );
    });
  });

  group('shellLock (sidebar lock and lock overlay)', () {
    Future<bool?> locked(
      FacilityCreatorAccountModel? account, {
      List<FacilityModel> facilities = const [],
    }) async {
      final lock = await SubscriptionGuardService.shellLock(
        'user_1',
        accountProvider: (_) async => account,
        facilitiesProvider: () async => facilities,
      );
      return lock.locked;
    }

    test('invited staff (no account of their own) are not locked out', () async {
      // checkAccess lets them in; the lock widgets locked everyone without an
      // account, so staff reached pages they could not use.
      expect(await locked(null), isFalse);
    });

    test('a cancelled account inside its paid period is not locked', () async {
      expect(
        await locked(_account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().add(const Duration(days: 5)),
        )),
        isFalse,
      );
    });

    test('pending approval is left to its own page', () async {
      expect(await locked(_account(status: SubscriptionStatus.pendingApproval)), isFalse);
    });

    test('a lapsed account, and a suspended one with a paying facility, are locked', () async {
      expect(
        await locked(_account(
          status: SubscriptionStatus.trialing,
          trialEnd: DateTime.now().subtract(const Duration(days: 1)),
        )),
        isTrue,
      );
      expect(
        await locked(
          _account(status: SubscriptionStatus.active, suspended: true),
          facilities: [_facility(platformStatus: 'active')],
        ),
        isTrue,
      );
    });

    test('a failed read is "unknown", not "locked"', () async {
      // The widgets keep what they show; the route guard fails closed.
      final accountFails = await SubscriptionGuardService.shellLock(
        'user_1',
        accountProvider: (_) async => throw StateError('offline'),
        facilitiesProvider: () async => const [],
      );
      expect(accountFails.locked, isNull);

      // The production facilities read (no Firebase app here, so it fails).
      // The non-throwing read returned [], which locked per-facility owners.
      final facilitiesFail = await SubscriptionGuardService.shellLock(
        'user_1',
        accountProvider: (_) async => _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().subtract(const Duration(days: 40)),
        ),
      );
      expect(facilitiesFail.locked, isNull);

      // And the production account read.
      final defaults = await SubscriptionGuardService.shellLock(
        'user_1',
        facilitiesProvider: () async => const [],
      );
      expect(defaults.locked, isNull);
    });

    test('shellLockFor: an unverified answer never changes the lock', () {
      // e.g. checkAccess's fail-closed guess after a failed read.
      expect(
        SubscriptionGuardService.shellLockFor(const SubscriptionAccessResult(
          canAccess: false,
          redirectRoute: '/subscription',
          verified: false,
        )),
        isNull,
      );
    });

    test('locks exactly when checkAccess denies (pending approval aside)', () async {
      final now = DateTime.now();
      final cases = <(FacilityCreatorAccountModel?, List<FacilityModel>)>[
        (null, const []),
        (_account(status: SubscriptionStatus.active), const []),
        (
          _account(status: SubscriptionStatus.trialing, trialEnd: now.add(const Duration(days: 3))),
          const [],
        ),
        (
          _account(status: SubscriptionStatus.trialing, trialEnd: now.subtract(const Duration(days: 3))),
          const [],
        ),
        (
          _account(status: SubscriptionStatus.pastDue, periodEnd: now.subtract(const Duration(days: 2))),
          const [],
        ),
        (
          _account(status: SubscriptionStatus.pastDue, periodEnd: now.subtract(const Duration(days: 20))),
          const [],
        ),
        (
          _account(status: SubscriptionStatus.cancelled, periodEnd: now.add(const Duration(days: 2))),
          const [],
        ),
        (
          _account(status: SubscriptionStatus.cancelled, periodEnd: now.subtract(const Duration(days: 40))),
          const [],
        ),
        (
          _account(status: SubscriptionStatus.cancelled, periodEnd: now.subtract(const Duration(days: 40))),
          [_facility(platformStatus: 'active')],
        ),
        (_account(status: SubscriptionStatus.unpaid), [_facility(billingExempt: true)]),
        (_account(status: SubscriptionStatus.unpaid, billingExempt: true), const []),
        (_account(status: SubscriptionStatus.active, suspended: true), const []),
      ];
      for (final (account, facilities) in cases) {
        final access = await SubscriptionGuardService.checkAccess(
          authOverride: mockAuth,
          userOverride: mockUser,
          currentRoute: '/dashboard',
          superAdminResolver: () => false,
          accountProvider: (_) async => account,
          facilitiesProvider: () async => facilities,
        );
        expect(
          await locked(account, facilities: facilities),
          !access.canAccess,
          reason: '${account?.subscriptionStatus} suspended=${account?.suspended} '
              'exempt=${account?.billingExempt} facilities=${facilities.length}',
        );
      }
    });
  });

  group("a suspended account's paid period does not override the suspension", () {
    // Suspending cancels the account, and the cancelled branch let a
    // cancelled account whose paid period was still running straight back in:
    // the shell stayed unlocked and the guard let every page through.
    final suspendedInPaidPeriod = _account(
      status: SubscriptionStatus.cancelled,
      periodEnd: DateTime.now().add(const Duration(days: 10)),
      suspended: true,
    );

    test('checkAccess refuses it, and says why', () async {
      final result = await SubscriptionGuardService.checkAccess(
        authOverride: mockAuth,
        userOverride: mockUser,
        currentRoute: '/dashboard',
        superAdminResolver: () => false,
        accountProvider: (_) async => suspendedInPaidPeriod,
        facilitiesProvider: () async => const [],
      );
      expect(result.canAccess, isFalse);
      expect(result.verified, isTrue);
      expect(result.redirectRoute, '/subscription');
      expect(result.message, contains('suspended'));
    });

    test('shellLock locks it', () async {
      final lock = await SubscriptionGuardService.shellLock(
        'user_1',
        accountProvider: (_) async => suspendedInPaidPeriod,
        facilitiesProvider: () async => const [],
      );
      expect(lock.locked, isTrue);
    });

    test('an unsuspended cancelled account still keeps its paid period', () async {
      final result = await SubscriptionGuardService.checkAccess(
        authOverride: mockAuth,
        userOverride: mockUser,
        currentRoute: '/dashboard',
        superAdminResolver: () => false,
        accountProvider: (_) async => _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().add(const Duration(days: 10)),
        ),
        facilitiesProvider: () async => const [],
      );
      expect(result.canAccess, isTrue);
    });

    test('only an exempt account overrides a suspension', () async {
      final lock = await SubscriptionGuardService.shellLock(
        'user_1',
        accountProvider: (_) async => _account(
          status: SubscriptionStatus.cancelled,
          periodEnd: DateTime.now().add(const Duration(days: 10)),
          suspended: true,
          billingExempt: true,
        ),
        facilitiesProvider: () async => const [],
      );
      expect(lock.locked, isFalse);
    });
  });

  group('an invited team member (no account of their own)', () {
    // Staff are let in only through a facility whose billing is in good
    // standing. They used to be let in whatever the owner's standing, so an
    // invited login kept every facility after the owner lapsed or was
    // suspended. The owner's account is read from the copy the backend keeps
    // on each facility (staff cannot read the account itself).
    final now = DateTime.now();
    OwnerAccountStanding owner(
      SubscriptionStatus status, {
      DateTime? trialEnd,
      DateTime? periodEnd,
      bool suspended = false,
      bool billingExempt = false,
    }) =>
        OwnerAccountStanding(
          accountId: 'acct_owner',
          subscriptionStatus: status,
          subscriptionTrialEnd: trialEnd,
          subscriptionCurrentPeriodEnd: periodEnd,
          suspended: suspended,
          billingExempt: billingExempt,
        );

    FacilityModel teamFacility({
      String id = 'fac_team',
      OwnerAccountStanding? standing,
      String? platformStatus,
      DateTime? platformTrialEnd,
      bool billingExempt = false,
    }) =>
        FacilityModel(
          id: id,
          name: 'Owner Storage',
          ownerUid: 'owner_1',
          createdAt: DateTime(2026),
          facilityCreatorAccountId: 'acct_owner',
          platformSubscriptionStatus: platformStatus,
          platformSubscriptionTrialEnd: platformTrialEnd,
          billingExempt: billingExempt,
          ownerAccountStanding: standing,
          currentUserOwnsFacility: false,
        );

    final lapsedOwner = owner(SubscriptionStatus.cancelled,
        periodEnd: now.subtract(const Duration(days: 40)));

    final cases = <(String, List<FacilityModel>, bool)>[
      (
        'a paid owner (active facility subscription)',
        [teamFacility(standing: owner(SubscriptionStatus.active), platformStatus: 'active')],
        true,
      ),
      (
        'a paid owner whose account pays for the facility',
        [teamFacility(standing: owner(SubscriptionStatus.active))],
        true,
      ),
      (
        'a trialing facility',
        [
          teamFacility(
            standing: lapsedOwner,
            platformStatus: 'trialing',
            platformTrialEnd: now.add(const Duration(days: 5)),
          ),
        ],
        true,
      ),
      (
        "an owner on the account's own trial",
        [teamFacility(standing: owner(SubscriptionStatus.trialing, trialEnd: now.add(const Duration(days: 5))))],
        true,
      ),
      ('an exempt facility', [teamFacility(standing: lapsedOwner, billingExempt: true)], true),
      (
        'an exempt owner account',
        [teamFacility(standing: owner(SubscriptionStatus.cancelled, suspended: true, billingExempt: true))],
        true,
      ),
      (
        'a cancelled owner inside the paid period',
        [teamFacility(standing: owner(SubscriptionStatus.cancelled, periodEnd: now.add(const Duration(days: 3))))],
        true,
      ),
      ('a lapsed owner', [teamFacility(standing: lapsedOwner)], false),
      (
        'an owner whose trial ended',
        [teamFacility(standing: owner(SubscriptionStatus.trialing, trialEnd: now.subtract(const Duration(days: 1))))],
        false,
      ),
      (
        'a lapsed facility trial',
        [
          teamFacility(
            standing: lapsedOwner,
            platformStatus: 'trialing',
            platformTrialEnd: now.subtract(const Duration(days: 1)),
          ),
        ],
        false,
      ),
      ('an owner still pending approval', [teamFacility(standing: owner(SubscriptionStatus.pendingApproval))], false),
      (
        'a suspended owner, even with a paying facility',
        [teamFacility(standing: owner(SubscriptionStatus.active, suspended: true), platformStatus: 'active')],
        false,
      ),
      (
        'a suspended owner, even with an exempt facility',
        [teamFacility(standing: owner(SubscriptionStatus.cancelled, suspended: true), billingExempt: true)],
        false,
      ),
      (
        'a suspended owner inside a paid period',
        [
          teamFacility(
            standing: owner(SubscriptionStatus.cancelled,
                periodEnd: now.add(const Duration(days: 10)), suspended: true),
          ),
        ],
        false,
      ),
      (
        'one facility in good standing among lapsed ones',
        [
          teamFacility(id: 'a', standing: lapsedOwner),
          teamFacility(id: 'b', standing: owner(SubscriptionStatus.active), platformStatus: 'active'),
        ],
        true,
      ),
      (
        'a facility the backend has no copy for yet (the owner has no account)',
        [teamFacility()],
        true,
      ),
      ('a new signup with no facilities at all', const [], true),
      (
        'an owner with no account (a facility of their own) who is also staff elsewhere',
        [
          teamFacility(standing: lapsedOwner),
          FacilityModel(
            id: 'mine',
            name: 'Mine',
            ownerUid: 'user_1',
            createdAt: DateTime(2026),
            currentUserOwnsFacility: true,
          ),
        ],
        true,
      ),
    ];

    for (final (name, facilities, allowed) in cases) {
      test('${allowed ? 'let in' : 'kept out'}: $name (checkAccess and shellLock)', () async {
        final access = await SubscriptionGuardService.checkAccess(
          authOverride: mockAuth,
          userOverride: mockUser,
          currentRoute: '/dashboard',
          superAdminResolver: () => false,
          accountProvider: (_) async => null,
          facilitiesProvider: () async => facilities,
        );
        expect(access.canAccess, allowed);
        expect(access.verified, isTrue);
        if (!allowed) {
          expect(access.redirectRoute, '/subscription');
          expect(access.message, contains('owner'));
        }

        final lock = await SubscriptionGuardService.shellLock(
          'user_1',
          accountProvider: (_) async => null,
          facilitiesProvider: () async => facilities,
        );
        expect(lock.locked, !allowed);
        if (!allowed) expect(lock.message, contains('owner'));
      });
    }

    test('a failed facilities read is unverified, never a lapse', () async {
      final access = await SubscriptionGuardService.checkAccess(
        authOverride: mockAuth,
        userOverride: mockUser,
        currentRoute: '/dashboard',
        superAdminResolver: () => false,
        accountProvider: (_) async => null,
        facilitiesProvider: () async => throw StateError('offline'),
      );
      expect(access.canAccess, isFalse);
      expect(access.verified, isFalse);
      final lock = await SubscriptionGuardService.shellLock(
        'user_1',
        accountProvider: (_) async => null,
        facilitiesProvider: () async => throw StateError('offline'),
      );
      expect(lock.locked, isNull);
    });

    test("the facility doc's copy reaches the rule through the facility list", () async {
      // What production runs: the facility doc is parsed, and the facility
      // list marks each entry owned or not with copyWith. copyWith used to
      // drop billingExempt, so an exempt facility never let anyone in.
      FakeDoc doc(String id, Map<String, dynamic> extra) => FakeDoc(id, {
            'name': 'Owner Storage',
            'ownerUid': 'owner_1',
            'active': true,
            ...extra,
          });
      final suspendedCopy = <String, dynamic>{
        'accountId': 'acct_owner',
        'subscriptionStatus': 'active',
        'suspended': true,
        'billingExempt': false,
      };
      final paidCopy = <String, dynamic>{
        'accountId': 'acct_owner',
        'subscriptionStatus': 'cancelled',
        'subscriptionCurrentPeriodEnd':
            Timestamp.fromDate(now.add(const Duration(days: 3))),
      };
      List<FacilityModel> listed(FakeDoc d) => FacilityService.mergeUserFacilities(
            owned: const [],
            fromRoles: [FacilityModel.fromFirestore(d)],
            includeArchived: false,
          );

      expect(
        SubscriptionGuardService.accessWithoutAccount(
            listed(doc('f1', {'ownerAccountStanding': suspendedCopy, 'platformSubscriptionStatus': 'active'}))).canAccess,
        isFalse,
      );
      expect(
        SubscriptionGuardService.accessWithoutAccount(listed(doc('f2', {'ownerAccountStanding': paidCopy}))).canAccess,
        isTrue,
      );
      expect(
        SubscriptionGuardService.accessWithoutAccount(listed(doc('f3', {
          'ownerAccountStanding': {'accountId': 'acct_owner', 'subscriptionStatus': 'cancelled'},
          'billingExempt': true,
        }))).canAccess,
        isTrue,
      );
      expect(
        SubscriptionGuardService.accessWithoutAccount(listed(doc('f4', {
          'ownerAccountStanding': {'accountId': 'acct_owner', 'subscriptionStatus': 'cancelled'},
        }))).canAccess,
        isFalse,
      );
    });
  });

  group('SubscriptionAccessCache', () {
    const allowed = SubscriptionAccessResult(canAccess: true);

    test('only returns a result to the account it was stored for', () {
      // It used to be one unkeyed global, reused by whoever signed in next.
      final cache = SubscriptionAccessCache();
      cache.store('uid-A', allowed);
      expect(cache.freshFor('uid-A'), same(allowed));
      expect(cache.freshFor('uid-B'), isNull);
    });

    test('expires after the ttl and can be cleared', () {
      final cache = SubscriptionAccessCache(ttl: const Duration(minutes: 2));
      final t0 = DateTime(2026, 9, 23, 12);
      cache.store('uid-A', allowed, now: t0);
      expect(
        cache.freshFor('uid-A', now: t0.add(const Duration(seconds: 119))),
        same(allowed),
      );
      expect(cache.freshFor('uid-A', now: t0.add(const Duration(minutes: 2))), isNull);

      cache.store('uid-A', allowed, now: t0);
      cache.clear();
      expect(cache.freshFor('uid-A', now: t0), isNull);
    });
  });
}

