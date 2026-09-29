import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/constants/email_monthly_limits.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/owner_account_standing.dart';
import 'package:sfcapp/models/paid_subscription.dart';
import 'package:sfcapp/services/dnr_terms_service.dart';
import 'package:sfcapp/services/email_usage_service.dart';
import 'package:sfcapp/services/facility_creation_policy.dart';
import 'package:sfcapp/services/subscription_guard_service.dart';
import 'package:sfcapp/services/subscription_trial_notice.dart';
import 'package:sfcapp/services/super_admin_data_service.dart';

// Invented fixtures only. "Now" is real time: the models read DateTime.now().
final _past = DateTime.now().subtract(const Duration(days: 3));
final _future = DateTime.now().add(const Duration(days: 20));
final _soon = DateTime.now().add(const Duration(days: 2, hours: 12));

const _accountId = 'acct_test_owner';
const _ownerUid = 'uid_test_owner';

FacilityCreatorAccountModel _account({
  required SubscriptionStatus status,
  String? stripeSubscriptionId,
  DateTime? trialEnd,
  DateTime? periodEnd,
  bool suspended = false,
}) {
  final created = DateTime(2026, 9, 1);
  return FacilityCreatorAccountModel(
    accountId: _accountId,
    ownerUid: _ownerUid,
    ownerEmail: 'owner@example.test',
    ownerName: 'Test Owner',
    subscriptionStatus: status,
    stripeSubscriptionId: stripeSubscriptionId,
    subscriptionTrialEnd: trialEnd,
    subscriptionCurrentPeriodEnd: periodEnd,
    suspended: suspended,
    createdAt: created,
    updatedAt: created,
  );
}

FacilityModel _facility({
  String id = 'fac_test_1',
  String name = 'Harborview Test Storage',
  String ownerUid = _ownerUid,
  String? accountId = _accountId,
  String? status,
  String? subscriptionId,
  DateTime? trialEnd,
  OwnerAccountStanding? standing,
}) {
  return FacilityModel(
    id: id,
    name: name,
    ownerUid: ownerUid,
    createdAt: DateTime(2026, 9, 1),
    facilityCreatorAccountId: accountId,
    platformSubscriptionStatus: status,
    stripePlatformSubscriptionId: subscriptionId,
    platformSubscriptionTrialEnd: trialEnd,
    ownerAccountStanding: standing,
  );
}

/// An owner who subscribed with a card on the account: its free month runs on.
FacilityCreatorAccountModel _accountCardTrial({DateTime? trialEnd}) => _account(
      status: SubscriptionStatus.trialing,
      stripeSubscriptionId: 'sub_test_account',
      trialEnd: trialEnd ?? _future,
      periodEnd: trialEnd ?? _future,
    );

/// The unpaid app trial (startTrial / admin grant): no Stripe subscription.
FacilityCreatorAccountModel _appTrial({DateTime? trialEnd}) => _account(
      status: SubscriptionStatus.trialing,
      trialEnd: trialEnd ?? _future,
      periodEnd: trialEnd ?? _future,
    );

/// Per-facility billing in the facility's free month: the account rolls the
/// facility up as `trialing` and keeps the app trial's (passed) end date.
FacilityCreatorAccountModel _rolledUpAccount() => _appTrial(trialEnd: _past);
FacilityModel _cardTrialFacility({DateTime? trialEnd, String? accountId = _accountId}) => _facility(
      status: 'trialing',
      subscriptionId: 'sub_test_facility',
      trialEnd: trialEnd ?? _future,
      accountId: accountId,
    );

void main() {
  group('hasPaidOrCardTrialSubscription', () {
    test('active, or trialing with a Stripe subscription', () {
      expect(hasPaidOrCardTrialSubscription(status: 'active', stripeSubscriptionId: null), isTrue);
      expect(hasPaidOrCardTrialSubscription(status: 'trialing', stripeSubscriptionId: 'sub_x'), isTrue);
      for (final id in [null, '', '   ']) {
        expect(hasPaidOrCardTrialSubscription(status: 'trialing', stripeSubscriptionId: id), isFalse,
            reason: 'unpaid app trial ($id)');
      }
      for (final status in ['pastDue', 'past_due', 'cancelled', 'unpaid', 'pendingApproval', null]) {
        expect(hasPaidOrCardTrialSubscription(status: status, stripeSubscriptionId: 'sub_x'), isFalse,
            reason: '$status');
      }
    });
  });

  group('FacilityCreatorAccountModel', () {
    test('a card-backed trial counts as a paid subscription, even past its trial end', () {
      for (final trialEnd in [_future, _past]) {
        final a = _accountCardTrial(trialEnd: trialEnd);
        expect(a.hasCardBackedTrial, isTrue);
        expect(a.hasActiveSubscription, isTrue);
        expect(a.hasPremiumAccess, isTrue);
        expect(a.hasTrial, isFalse);
        expect(a.isTrialExpired, isFalse);
        expect(a.isTrialExpiringSoon, isFalse);
        expect(a.canAccessPlatform, isTrue);
        expect(a.allowsPermanentTenantDeletion, isTrue);
      }
    });

    test('the unpaid app trial keeps its limits and expires at the trial end', () {
      final running = _appTrial();
      expect(running.hasCardBackedTrial, isFalse);
      expect(running.hasTrial, isTrue);
      expect(running.hasActiveSubscription, isFalse);
      expect(running.hasPremiumAccess, isFalse);
      expect(running.canAccessPlatform, isTrue);

      final ended = _appTrial(trialEnd: _past);
      expect(ended.isTrialExpired, isTrue);
      expect(ended.canAccessPlatform, isFalse);
      expect(ended.allowsPermanentTenantDeletion, isFalse);

      expect(_appTrial(trialEnd: _soon).isTrialExpiringSoon, isTrue);
    });

    test('active is unchanged, and a subscription id does not make other statuses paid', () {
      expect(_account(status: SubscriptionStatus.active).hasActiveSubscription, isTrue);
      expect(_account(status: SubscriptionStatus.active).hasPremiumAccess, isTrue);
      final pastDue = _account(status: SubscriptionStatus.pastDue, stripeSubscriptionId: 'sub_x');
      expect(pastDue.hasActiveSubscription, isFalse);
      expect(pastDue.hasCardBackedTrial, isFalse);
    });
  });

  group('FacilityModel', () {
    test('a card-backed facility trial is paid for, even past its trial end', () {
      final f = _cardTrialFacility(trialEnd: _past);
      expect(f.hasPaidOrCardTrialPlatformSubscription, isTrue);
      expect(f.hasActivePlatformSubscription, isTrue);
    });

    test('a trialing facility without a subscription still needs a future end', () {
      expect(_facility(status: 'trialing', trialEnd: _future).hasActivePlatformSubscription, isTrue);
      expect(_facility(status: 'trialing', trialEnd: _past).hasActivePlatformSubscription, isFalse);
      expect(_facility(status: 'trialing', trialEnd: _future).hasPaidOrCardTrialPlatformSubscription, isFalse);
      expect(_facility(status: 'past_due', subscriptionId: 'sub_x').hasActivePlatformSubscription, isFalse);
    });
  });

  group('owner-level predicates', () {
    test('a card on the account or on a linked facility subscribes the owner', () {
      expect(ownerHasPaidOrCardTrialSubscription(_accountCardTrial(), const []), isTrue);
      expect(ownerHasPaidOrCardTrialSubscription(_rolledUpAccount(), [_cardTrialFacility()]), isTrue);
      expect(ownerHasPaidOrCardTrialSubscription(_rolledUpAccount(), const []), isFalse);
      expect(ownerHasPaidOrCardTrialSubscription(null, [_cardTrialFacility()]), isFalse);
    });

    test("another account's facility does not count", () {
      final elsewhere = _cardTrialFacility(accountId: 'acct_someone_else');
      expect(ownerHasPaidOrCardTrialSubscription(_rolledUpAccount(), [elsewhere]), isFalse);
      expect(ownerOnUnpaidAppTrial(_rolledUpAccount(), [elsewhere]), isTrue);
    });

    test('ownerOnUnpaidAppTrial is the unpaid app trial only', () {
      expect(ownerOnUnpaidAppTrial(_appTrial(), const []), isTrue);
      expect(ownerOnUnpaidAppTrial(_accountCardTrial(), const []), isFalse);
      expect(ownerOnUnpaidAppTrial(_rolledUpAccount(), [_cardTrialFacility()]), isFalse);
      expect(ownerOnUnpaidAppTrial(_account(status: SubscriptionStatus.active), const []), isFalse);
      expect(ownerOnUnpaidAppTrial(_account(status: SubscriptionStatus.cancelled), const []), isFalse);
      expect(ownerOnUnpaidAppTrial(null, const []), isFalse);
    });
  });

  group('subscription screen (SubscriptionTrialNotice)', () {
    test('account-level free month: shown as active with the first charge date, no trial notices', () {
      final account = _accountCardTrial();
      final notice = SubscriptionTrialNotice.of(account, const []);
      expect(notice.ownerSubscribed, isTrue);
      expect(notice.displayStatus, SubscriptionStatus.active);
      expect(notice.firstCharge, account.subscriptionTrialEnd);
      expect(notice.showAccountPeriod, isTrue);
      expect(notice.showTrialDaysLeft, isFalse);
      expect(notice.showTrialExpired, isFalse);
      expect(notice.showTrialEndingSoon, isFalse);
      expect(notice.showTrialExpiredDialog(redirectedForExpiredTrial: true), isFalse);

      // Even a first charge two days out is not "Trial ends in 2 days".
      expect(SubscriptionTrialNotice.of(_accountCardTrial(trialEnd: _soon), const []).showTrialEndingSoon, isFalse);
    });

    test('facility free month after the app trial end: no "Trial expired", no dialog, no app trial dates', () {
      final facility = _cardTrialFacility();
      final notice = SubscriptionTrialNotice.of(_rolledUpAccount(), [facility]);
      expect(notice.ownerSubscribed, isTrue);
      expect(notice.displayStatus, SubscriptionStatus.active);
      expect(notice.showTrialExpired, isFalse);
      expect(notice.showTrialExpiredDialog(redirectedForExpiredTrial: false), isFalse);
      expect(notice.showTrialExpiredDialog(redirectedForExpiredTrial: true), isFalse);
      // The account's period end is the app trial's: not shown as "Until <date>".
      expect(notice.showAccountPeriod, isFalse);
      expect(notice.firstCharge, isNull);
      expect(SubscriptionTrialNotice.facilityFirstCharge(facility), facility.platformSubscriptionTrialEnd);
    });

    test('facility free month during the app trial: no app trial countdown', () {
      final notice = SubscriptionTrialNotice.of(_appTrial(trialEnd: _soon), [_cardTrialFacility()]);
      expect(notice.showTrialDaysLeft, isFalse);
      expect(notice.showTrialEndingSoon, isFalse);
    });

    test('the unpaid app trial keeps every notice', () {
      final expired = SubscriptionTrialNotice.of(_appTrial(trialEnd: _past), const []);
      expect(expired.ownerSubscribed, isFalse);
      expect(expired.displayStatus, SubscriptionStatus.trialing);
      expect(expired.showTrialExpired, isTrue);
      expect(expired.showTrialExpiredDialog(redirectedForExpiredTrial: false), isTrue);
      expect(expired.showAccountPeriod, isTrue);

      final ending = SubscriptionTrialNotice.of(_appTrial(trialEnd: _soon), const []);
      expect(ending.showTrialDaysLeft, isTrue);
      expect(ending.showTrialEndingSoon, isTrue);
      expect(ending.showTrialExpired, isFalse);
    });

    test('a facility plan line names a first charge only for a card-backed trial', () {
      expect(SubscriptionTrialNotice.facilityFirstCharge(_facility(status: 'active', subscriptionId: 'sub_x')), isNull);
      expect(SubscriptionTrialNotice.facilityFirstCharge(_facility(status: 'trialing', trialEnd: _future)), isNull);
    });
  });

  group('adding a facility (wizardAddFacilityCheck)', () {
    test('the trial limit is for the unpaid app trial only', () {
      expect(wizardAddFacilityCheck(_appTrial(), const []), WizardAddFacilityCheck.trialLimit);
      expect(wizardAddFacilityCheck(_accountCardTrial(), const []), WizardAddFacilityCheck.confirmAddedCharge);
      expect(
        wizardAddFacilityCheck(_rolledUpAccount(), [_cardTrialFacility()]),
        WizardAddFacilityCheck.confirmAddedCharge,
      );
      expect(wizardAddFacilityCheck(_account(status: SubscriptionStatus.active), const []),
          WizardAddFacilityCheck.confirmAddedCharge);
      expect(wizardAddFacilityCheck(_account(status: SubscriptionStatus.cancelled), const []),
          WizardAddFacilityCheck.subscriptionRequired);
    });
  });

  group('DNR', () {
    test('premium: a paid or card-backed subscription on the account or a linked facility', () {
      expect(DnrTermsService.hasPremiumAccess(_accountCardTrial(), const []), isTrue);
      expect(DnrTermsService.hasPremiumAccess(_rolledUpAccount(), [_cardTrialFacility()]), isTrue);
      expect(DnrTermsService.hasPremiumAccess(_appTrial(), const []), isFalse);
      expect(DnrTermsService.hasPremiumAccess(_appTrial(), [_facility(status: 'trialing', trialEnd: _future)]), isFalse);
    });

    test('acceptance names the owned, linked, card-backed facility for the rules', () {
      final other = _facility(id: 'fac_test_other', accountId: 'acct_someone_else', status: 'active');
      final staffOnly = _facility(id: 'fac_test_staff', ownerUid: 'uid_someone_else', status: 'active');
      final unpaid = _facility(id: 'fac_test_unpaid', status: 'cancelled');
      final paid = _cardTrialFacility();
      expect(
        DnrTermsService.premiumFacilityIdForAcceptance(_rolledUpAccount(), [other, staffOnly, unpaid, paid], _ownerUid),
        paid.id,
      );
      expect(DnrTermsService.premiumFacilityIdForAcceptance(_appTrial(), [other, unpaid], _ownerUid), isNull);
    });
  });

  group('email cap (EmailUsageService.defaultLimitFor)', () {
    test('the trial cap is for the unpaid app trial only', () {
      expect(EmailUsageService.defaultLimitFor(facility: const {}, account: _appTrial()), kEmailMonthlyLimitTrialing);
      expect(EmailUsageService.defaultLimitFor(facility: const {}, account: _accountCardTrial()), kEmailMonthlyLimitPaid);
      expect(
        EmailUsageService.defaultLimitFor(
          facility: const {},
          account: _rolledUpAccount(),
          facilities: [_cardTrialFacility()],
        ),
        kEmailMonthlyLimitPaid,
      );
      // A facility with its own (card-backed) subscription is judged by it.
      expect(
        EmailUsageService.defaultLimitFor(
          facility: const {'stripePlatformSubscriptionId': 'sub_x', 'platformSubscriptionStatus': 'trialing'},
          account: _appTrial(),
        ),
        kEmailMonthlyLimitPaid,
      );
      expect(EmailUsageService.defaultLimitFor(facility: const {}, account: null), kEmailMonthlyLimitPaid);
    });
  });

  group('access guard', () {
    test('a facility free month keeps the owner in after the app trial end', () async {
      final result = await SubscriptionGuardService.decideAccess(
        _rolledUpAccount(),
        currentRoute: '/dashboard',
        facilities: () async => [_cardTrialFacility(trialEnd: _past)],
      );
      expect(result.canAccess, isTrue);
    });

    test('an account free month past its trial end is not locked out', () async {
      final result = await SubscriptionGuardService.decideAccess(
        _accountCardTrial(trialEnd: _past),
        currentRoute: '/dashboard',
        facilities: () async => const [],
      );
      expect(result.canAccess, isTrue);
    });

    test('the unpaid app trial is still locked out at its end', () async {
      final result = await SubscriptionGuardService.decideAccess(
        _appTrial(trialEnd: _past),
        currentRoute: '/dashboard',
        facilities: () async => const [],
      );
      expect(result.canAccess, isFalse);
      expect(result.redirectRoute, '/subscription?trialExpired=1');
    });

    test("team members are covered by a facility's card-backed free month", () {
      final standing = OwnerAccountStanding(
        accountId: _accountId,
        subscriptionStatus: SubscriptionStatus.trialing,
        subscriptionTrialEnd: _past,
      );
      final cardTrial = _facility(
        status: 'trialing',
        subscriptionId: 'sub_test_facility',
        trialEnd: _past,
        standing: standing,
      );
      expect(SubscriptionGuardService.facilityCoversTeamMember(cardTrial), isTrue);
      expect(SubscriptionGuardService.facilityCoversTeamMember(_facility(standing: standing)), isFalse);
    });
  });

  group('website add-on base plan (WebsiteAdminRow)', () {
    test('the card-backed free month counts as the base plan', () {
      WebsiteAdminRow row(FacilityCreatorAccountModel account, FacilityModel facility) => WebsiteAdminRow(
            facility: facility,
            ownerEmail: 'owner@example.test',
            account: account,
            publicWebsiteConfigured: false,
            publicWebsiteEnabled: false,
          );
      expect(row(_accountCardTrial(trialEnd: _past), _facility()).hasActiveBaseSubscription, isTrue);
      expect(row(_rolledUpAccount(), _cardTrialFacility(trialEnd: _past)).hasActiveBaseSubscription, isTrue);
      expect(row(_appTrial(trialEnd: _past), _facility()).hasActiveBaseSubscription, isFalse);
    });
  });
}

