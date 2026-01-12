import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';

FacilityCreatorAccountModel _account({
  required SubscriptionStatus status,
  DateTime? periodEnd,
}) {
  final now = DateTime.now();
  return FacilityCreatorAccountModel(
    accountId: 'acct_123',
    ownerUid: 'user_1',
    ownerEmail: 'user@example.com',
    ownerName: 'Test User',
    subscriptionStatus: status,
    createdAt: now,
    updatedAt: now,
    subscriptionCurrentPeriodEnd: periodEnd,
    subscriptionCurrentPeriodStart: now.subtract(const Duration(days: 30)),
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
    );

    expect(result.canAccess, isFalse);
    expect(result.redirectRoute, '/subscription');
  });
}

