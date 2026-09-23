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
  _CountingUser({required super.uid, super.isEmailVerified})
      : super(email: '$uid@example.com');

  final _ReloadCounter _reloads = _ReloadCounter();
  int get reloads => _reloads.count;

  @override
  Future<void> reload() {
    _reloads.count += 1;
    return super.reload();
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
  }) {
    final uri = Uri.parse(location);
    return evaluateRouteGuard(
      matchedLocation: uri.path,
      uri: uri,
      ref: container.read(_refProvider),
      currentUser: () => user,
      isSuperAdmin: (_) => superAdmin,
      isTwoFactorEnabled: () async => twoFactorEnabled,
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
          accountProvider: (_) async => account,
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

  setUp(SubscriptionGuardService.routeGuardCache.clear);

  test('needsVerificationReload only for accounts that are not verified yet', () {
    expect(needsVerificationReload(MockUser(isEmailVerified: true)), isFalse);
    expect(needsVerificationReload(MockUser(isEmailVerified: false)), isTrue);
  });

  test('a verified user is not reloaded on every navigation', () async {
    final tab = _Tab();
    addTearDown(tab.dispose);
    final user = _CountingUser(uid: 'owner');
    final account = _account('owner', status: SubscriptionStatus.active);

    await tab.go('/dashboard', user: user, account: account);
    await tab.go('/tenants', user: user, account: account);
    expect(user.reloads, 0);
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

  test('a signed-out navigation drops the per-account caches', () async {
    final tab = _Tab();
    addTearDown(tab.dispose);
    FacilityService.debugSeedFacilitiesCache('owner', [
      FacilityModel(id: 'f1', name: 'Keepsake', ownerUid: 'owner', createdAt: DateTime(2026)),
    ]);
    SubscriptionGuardService.routeGuardCache
        .store('owner', const SubscriptionAccessResult(canAccess: true));

    expect(await tab.go('/login', user: null), isNull);

    expect(FacilityService.cachedFacilitiesFor('owner'), isNull);
    expect(SubscriptionGuardService.routeGuardCache.freshFor('owner'), isNull);
  });
}
