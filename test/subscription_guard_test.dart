import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/facility_creator_account_service.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';

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

