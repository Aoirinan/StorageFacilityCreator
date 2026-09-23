import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/feature_flag_provider.dart';
import 'package:sfcapp/providers/two_factor_provider.dart';
import 'package:sfcapp/router/route_guards.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';

/// Hands the test a Riverpod [Ref], which is what the router passes the guard.
final _refProvider = Provider<Ref>((ref) => ref);

class _ReloadCounter {
  int count = 0;
}

// MockUser's own fields are mutable; the counter here is not.
// ignore: must_be_immutable
class _CountingUser extends MockUser {
  _CountingUser({required super.uid, super.isEmailVerified, this.reloadResult})
      : super(email: '$uid@example.com');

  final _ReloadCounter _reloads = _ReloadCounter();
  int get reloads => _reloads.count;

  /// What reload() returns instead of MockUser's instant success, e.g. a
  /// future that never settles, or an error such as Auth's USER_DISABLED.
  final Future<void> Function()? reloadResult;

  @override
  Future<void> reload() {
    _reloads.count += 1;
    return reloadResult?.call() ?? super.reload();
  }
}

FacilityCreatorAccountModel _account(
  String uid, {
  required SubscriptionStatus status,
  DateTime? trialEnd,
  bool billingExempt = false,
}) {
  final now = DateTime.now();
  return FacilityCreatorAccountModel(
    accountId: 'acct_$uid',
    ownerUid: uid,
    ownerEmail: '$uid@example.com',
    ownerName: 'Owner',
    subscriptionStatus: status,
    subscriptionTrialEnd: trialEnd,
    billingExempt: billingExempt,
    createdAt: now,
    updatedAt: now,
  );
}

/// One simulated browser tab: the 2FA-verified flag lives in [container] and
/// starts false, exactly as after a hard reload.
class _Tab {
  _Tab({this.maintenance = false})
      : container = ProviderContainer(overrides: [
          maintenanceModeProvider.overrideWithValue(maintenance),
        ]);

  final bool maintenance;
  final ProviderContainer container;
  int accessChecks = 0;

  Future<String?> go(
    String location, {
    required User? user,
    FacilityCreatorAccountModel? account,
    List<FacilityModel> facilities = const [],
    bool superAdmin = false,
    bool twoFactorEnabled = false,
    Object? accessError,
    Object? accountReadError,
    DateTime? at,
  }) {
    final uri = Uri.parse(location);
    return evaluateRouteGuard(
      matchedLocation: uri.path,
      uri: uri,
      ref: container.read(_refProvider),
      currentUser: () => user,
      isSuperAdmin: (_) => superAdmin,
      isTwoFactorEnabled: () async => twoFactorEnabled,
      clock: at == null ? null : () => at,
      // The real access rules, with their existing injected seams.
      checkAccess: (path) {
        accessChecks += 1;
        if (accessError != null) return Future.error(accessError);
        return SubscriptionGuardService.checkAccess(
          currentRoute: path,
          allowSubscriptionRoutes: true,
          userOverride: user,
          authOverride: MockFirebaseAuth(mockUser: user as MockUser?),
          superAdminResolver: () => superAdmin,
          accountProvider: (_) async {
            if (accountReadError != null) throw accountReadError;
            return account;
          },
          facilitiesProvider: () async => facilities,
        );
      },
    );
  }

  bool get twoFactorVerified => container.read(twoFactorVerifiedProvider);

  void dispose() => container.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SubscriptionGuardService.routeGuardCache.clear();
    verifiedUserRecheck.reset();
  });

  test('needsVerificationReload only for accounts that are not verified yet', () {
    expect(needsVerificationReload(MockUser(isEmailVerified: true)), isFalse);
    expect(needsVerificationReload(MockUser(isEmailVerified: false)), isTrue);
  });

  group('verified users are re-checked with Auth in the background, once a minute', () {
    // The reload is what ends a session a super admin disabled or whose
    // password changed: Auth refuses it and the SDK signs the user out. On
    // every navigation it cost a round trip per click; never at all left a
    // disabled user in the app until their ID token expired (up to an hour).
    final account = _account('owner', status: SubscriptionStatus.active);
    final t0 = DateTime(2026, 9, 23, 12);

    test('the first navigation re-checks, later ones within 60 s do not', () async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      final user = _CountingUser(uid: 'owner');

      await tab.go('/dashboard', user: user, account: account, at: t0);
      expect(user.reloads, 1);
      await tab.go('/tenants', user: user, account: account,
          at: t0.add(const Duration(seconds: 30)));
      await tab.go('/units', user: user, account: account,
          at: t0.add(const Duration(seconds: 59)));
      expect(user.reloads, 1);
    });

    test('the next navigation after 60 s re-checks again', () async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      final user = _CountingUser(uid: 'owner');

      await tab.go('/dashboard', user: user, account: account, at: t0);
      await tab.go('/tenants', user: user, account: account,
          at: t0.add(const Duration(seconds: 61)));
      expect(user.reloads, 2);
      await tab.go('/units', user: user, account: account,
          at: t0.add(const Duration(seconds: 90)));
      expect(user.reloads, 2);
    });

    test('another account on the same tab is re-checked straight away', () async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      final first = _CountingUser(uid: 'owner');
      final second = _CountingUser(uid: 'other');

      await tab.go('/dashboard', user: first, account: account, at: t0);
      await tab.go('/dashboard', user: second,
          account: _account('other', status: SubscriptionStatus.active),
          at: t0.add(const Duration(seconds: 5)));
      expect(second.reloads, 1);
    });

    test('the navigation does not wait for it', () async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      final never = Completer<void>();
      final user = _CountingUser(uid: 'owner', reloadResult: () => never.future);

      expect(await tab.go('/dashboard', user: user, account: account, at: t0), isNull);
      expect(user.reloads, 1);
    });

    test('a refused re-check does not break the navigation', () async {
      // Auth's answer for a disabled account. The SDK signs the user out on
      // it; the guard itself must not throw.
      final tab = _Tab();
      addTearDown(tab.dispose);
      final user = _CountingUser(
        uid: 'owner',
        reloadResult: () => Future.error(FirebaseAuthException(code: 'user-disabled')),
      );

      expect(await tab.go('/dashboard', user: user, account: account, at: t0), isNull);
      await pumpEventQueue();
      expect(user.reloads, 1);
    });
  });

  test('an unverified user is still reloaded and sent to verify their email', () async {
    final tab = _Tab();
    addTearDown(tab.dispose);
    final user = _CountingUser(uid: 'new', isEmailVerified: false);

    final target = await tab.go('/dashboard', user: user);
    expect(user.reloads, 1);
    expect(target, startsWith('/verify-email'));
  });

  group('the first navigation after a reload gets the same answer as the second', () {
    // The first guarded navigation after every reload marked 2FA verified and
    // returned straight away, skipping the maintenance, super-admin and
    // subscription checks. Each scenario below checks that the reload now
    // lands where any later navigation lands, and nowhere stricter.
    final scenarios = <String, ({
      FacilityCreatorAccountModel? account,
      bool superAdmin,
      String path,
      String? expected,
    })>{
      'expired trial is sent to subscribe': (
        account: _account(
          'owner',
          status: SubscriptionStatus.trialing,
          trialEnd: DateTime.now().subtract(const Duration(days: 2)),
        ),
        superAdmin: false,
        path: '/dashboard',
        expected: '/subscription?trialExpired=1',
      ),
      'pending approval goes to the pending screen': (
        account: _account('owner', status: SubscriptionStatus.pendingApproval),
        superAdmin: false,
        path: '/facilities/edit?facilityId=f1',
        expected: '/pending-approval',
      ),
      'trialing account keeps access': (
        account: _account(
          'owner',
          status: SubscriptionStatus.trialing,
          trialEnd: DateTime.now().add(const Duration(days: 10)),
        ),
        superAdmin: false,
        path: '/tenants',
        expected: null,
      ),
      'billing-exempt account keeps access': (
        account: _account(
          'owner',
          status: SubscriptionStatus.cancelled,
          billingExempt: true,
        ),
        superAdmin: false,
        path: '/dashboard',
        expected: null,
      ),
      'active account keeps access': (
        account: _account('owner', status: SubscriptionStatus.active),
        superAdmin: false,
        path: '/dashboard',
        expected: null,
      ),
      'super admin keeps access even with a lapsed account': (
        account: _account(
          'owner',
          status: SubscriptionStatus.trialing,
          trialEnd: DateTime.now().subtract(const Duration(days: 2)),
        ),
        superAdmin: true,
        path: '/dashboard',
        expected: null,
      ),
      'super admin may open the super-admin console': (
        account: null,
        superAdmin: true,
        path: '/super-admin',
        expected: null,
      ),
      'anyone else is kept out of the super-admin console': (
        account: _account('owner', status: SubscriptionStatus.active),
        superAdmin: false,
        path: '/super-admin',
        expected: '/dashboard',
      ),
    };

    scenarios.forEach((name, s) {
      test(name, () async {
        final tab = _Tab();
        addTearDown(tab.dispose);
        final user = MockUser(uid: 'owner', email: 'owner@example.com');

        final first = await tab.go(
          s.path,
          user: user,
          account: s.account,
          superAdmin: s.superAdmin,
        );
        expect(tab.twoFactorVerified, isTrue);

        SubscriptionGuardService.routeGuardCache.clear();
        final second = await tab.go(
          s.path,
          user: user,
          account: s.account,
          superAdmin: s.superAdmin,
        );

        expect(first, s.expected);
        expect(first, second);
      });
    });

    test('maintenance mode is enforced on the first navigation too', () async {
      final tab = _Tab(maintenance: true);
      addTearDown(tab.dispose);
      final user = MockUser(uid: 'owner', email: 'owner@example.com');
      final lapsed = _account(
        'owner',
        status: SubscriptionStatus.trialing,
        trialEnd: DateTime.now().subtract(const Duration(days: 2)),
      );

      expect(await tab.go('/dashboard', user: user, account: lapsed),
          '/subscription?maintenance=1');
    });

    test('a failed access check fails closed on the first navigation', () async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      final user = MockUser(uid: 'owner', email: 'owner@example.com');

      expect(
        await tab.go('/dashboard', user: user, accessError: StateError('offline')),
        '/subscription',
      );
    });

    test('2FA-enabled accounts are still sent to finish 2FA first', () async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      final user = MockUser(uid: 'owner', email: 'owner@example.com');

      expect(await tab.go('/dashboard', user: user, twoFactorEnabled: true), '/login');
      expect(tab.twoFactorVerified, isFalse);
      expect(tab.accessChecks, 0);
    });
  });

  group('public routes on the first navigation are left exactly as before', () {
    // The subscription and maintenance checks never apply to public routes,
    // so a fresh load of one must not start bouncing signed-in operators to
    // the dashboard (e.g. returning to the tenant portal from Stripe).
    for (final path in ['/tenant-portal', '/pending-approval', '/login', '/']) {
      test(path, () async {
        final tab = _Tab();
        addTearDown(tab.dispose);
        final user = MockUser(uid: 'owner', email: 'owner@example.com');
        final pending = _account('owner', status: SubscriptionStatus.pendingApproval);

        expect(await tab.go(path, user: user, account: pending), isNull);
        expect(tab.accessChecks, 0);
      });
    }
  });

  test('a cached access result is never reused for another account', () async {
    final tab = _Tab();
    addTearDown(tab.dispose);
    final paying = MockUser(uid: 'paying', email: 'paying@example.com');
    final lapsed = MockUser(uid: 'lapsed', email: 'lapsed@example.com');

    expect(
      await tab.go('/dashboard',
          user: paying,
          account: _account('paying', status: SubscriptionStatus.active)),
      isNull,
    );
    // Same tab, different account within the 2-minute cache window.
    expect(
      await tab.go('/dashboard',
          user: lapsed,
          account: _account(
            'lapsed',
            status: SubscriptionStatus.trialing,
            trialEnd: DateTime.now().subtract(const Duration(days: 1)),
          )),
      '/subscription?trialExpired=1',
    );
  });

  group('/pending-approval after the first navigation', () {
    // The subscription check sends a pending account to /pending-approval,
    // and the "signed in on a public route" rule used to send it straight on
    // to the dashboard. The shell's 1-minute checker hit the same bounce, so
    // pending users ended up on the dashboard.
    Future<_Tab> signedInTab() async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      tab.container.read(twoFactorVerifiedProvider.notifier).state = true;
      return tab;
    }

    final user = MockUser(uid: 'owner', email: 'owner@example.com');

    test('a pending account stays on it', () async {
      final tab = await signedInTab();
      final pending = _account('owner', status: SubscriptionStatus.pendingApproval);

      expect(await tab.go('/dashboard', user: user, account: pending), '/pending-approval');
      expect(await tab.go('/pending-approval', user: user, account: pending), isNull);
    });

    test('an approved account is still sent on to the dashboard', () async {
      final tab = await signedInTab();
      expect(
        await tab.go('/pending-approval',
            user: user, account: _account('owner', status: SubscriptionStatus.active)),
        '/dashboard',
      );
    });

    test('an owner with no account yet is still sent on to the dashboard', () async {
      final tab = await signedInTab();
      expect(await tab.go('/pending-approval', user: user, account: null), '/dashboard');
    });

    test('a super admin is sent on without a lookup', () async {
      final tab = await signedInTab();
      expect(await tab.go('/pending-approval', user: user, superAdmin: true), '/dashboard');
      expect(tab.accessChecks, 0);
    });

    test('a failed check falls back to the dashboard, as before', () async {
      final tab = await signedInTab();
      expect(
        await tab.go('/pending-approval', user: user, accessError: StateError('offline')),
        '/dashboard',
      );
    });
  });

  group('only a confirmed grant is cached', () {
    final user = MockUser(uid: 'owner', email: 'owner@example.com');
    final active = _account('owner', status: SubscriptionStatus.active);
    final lapsed = _account(
      'owner',
      status: SubscriptionStatus.cancelled,
      trialEnd: DateTime.now().subtract(const Duration(days: 40)),
    );

    test('a grant is reused for 2 minutes', () async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      await tab.go('/dashboard', user: user, account: active);
      await tab.go('/tenants', user: user, account: active);
      expect(tab.accessChecks, 1);
    });

    test('a denial is not: renewing is seen on the next navigation', () async {
      // A denial used to be cached for 2 minutes, so one transient failure
      // that looked like a lapse (a failed facilities read) locked a paying
      // owner out for the whole window.
      final tab = _Tab();
      addTearDown(tab.dispose);
      expect(await tab.go('/dashboard', user: user, account: lapsed),
          '/subscription?trialExpired=1');
      expect(await tab.go('/dashboard', user: user, account: active), isNull);
    });

    test('a failed account read fails closed and is not cached', () async {
      final tab = _Tab();
      addTearDown(tab.dispose);
      expect(
        await tab.go('/dashboard',
            user: user, account: active, accountReadError: StateError('unavailable')),
        '/subscription',
      );
      expect(await tab.go('/dashboard', user: user, account: active), isNull);
    });
  });

  test('a signed-out navigation drops the per-account caches', () async {
    final tab = _Tab();
    addTearDown(tab.dispose);
    var facilityReads = 0;
    Future<List<FacilityModel>> ownerFacilities() => FacilityService.loadUserFacilitiesFor(
          currentUid: () => 'owner',
          fetch: (uid, {required includeArchived}) async {
            facilityReads += 1;
            return [
              FacilityModel(id: 'f1', name: 'Keepsake', ownerUid: uid, createdAt: DateTime(2026)),
            ];
          },
        );
    await ownerFacilities();
    SubscriptionGuardService.routeGuardCache
        .store('owner', const SubscriptionAccessResult(canAccess: true));

    expect(await tab.go('/login', user: null), isNull);

    await ownerFacilities();
    expect(facilityReads, 2, reason: 'the cached list was dropped');
    expect(SubscriptionGuardService.routeGuardCache.freshFor('owner'), isNull);
  });
}
