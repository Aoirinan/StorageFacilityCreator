import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';

FacilityModel facility({
  String? stripeWebsiteSubscriptionId,
  String? websiteSubscriptionStatus,
  DateTime? websiteAdminTrialEndsAt,
}) {
  return FacilityModel(
    id: 'facility-1',
    name: 'Test Facility',
    ownerUid: 'owner-1',
    createdAt: DateTime(2026),
    stripeWebsiteSubscriptionId: stripeWebsiteSubscriptionId,
    websiteSubscriptionStatus: websiteSubscriptionStatus,
    websiteAdminTrialEndsAt: websiteAdminTrialEndsAt,
  );
}

FacilityCreatorAccountModel account({
  SubscriptionStatus status = SubscriptionStatus.active,
  bool suspended = false,
  DateTime? trialEnd,
}) {
  return FacilityCreatorAccountModel(
    accountId: 'account-1',
    ownerUid: 'owner-1',
    ownerEmail: 'owner@example.com',
    ownerName: 'Owner',
    subscriptionStatus: status,
    subscriptionTrialEnd: trialEnd,
    suspended: suspended,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

void main() {
  test('active Stripe website subscription grants access', () {
    expect(
      facility(
        stripeWebsiteSubscriptionId: 'sub_website',
        websiteSubscriptionStatus: 'active',
      ).hasActiveWebsiteSubscription,
      isTrue,
    );
  });

  test('unexpired superadmin website trial grants access without Stripe', () {
    expect(
      facility(
        websiteAdminTrialEndsAt: DateTime.now().add(const Duration(days: 1)),
      ).hasActiveWebsiteSubscription,
      isTrue,
    );
  });

  test('expired superadmin website trial does not grant access', () {
    expect(
      facility(
        websiteAdminTrialEndsAt:
            DateTime.now().subtract(const Duration(seconds: 1)),
      ).hasActiveWebsiteSubscription,
      isFalse,
    );
  });

  test('website admin base eligibility rejects suspended accounts', () {
    final row = WebsiteAdminRow(
      facility: facility(),
      ownerEmail: 'owner@example.com',
      account: account(suspended: true),
      publicWebsiteConfigured: false,
      publicWebsiteEnabled: false,
    );
    expect(row.hasActiveBaseSubscription, isFalse);
  });

  test('website admin base eligibility requires an unexpired account trial',
      () {
    final expired = WebsiteAdminRow(
      facility: facility(),
      ownerEmail: 'owner@example.com',
      account: account(
        status: SubscriptionStatus.trialing,
        trialEnd: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
      publicWebsiteConfigured: false,
      publicWebsiteEnabled: false,
    );
    final active = WebsiteAdminRow(
      facility: facility(),
      ownerEmail: 'owner@example.com',
      account: account(
        status: SubscriptionStatus.trialing,
        trialEnd: DateTime.now().add(const Duration(days: 1)),
      ),
      publicWebsiteConfigured: false,
      publicWebsiteEnabled: false,
    );
    expect(expired.hasActiveBaseSubscription, isFalse);
    expect(active.hasActiveBaseSubscription, isTrue);
  });
}
