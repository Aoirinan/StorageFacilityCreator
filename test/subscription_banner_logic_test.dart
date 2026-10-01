import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_creator_account_model.dart';
import 'package:sfcapp/services/subscription_banner_logic.dart';
import 'package:sfcapp/widgets/subscription_warning_banner.dart';

void main() {
  final now = DateTime(2026, 9, 14);

  test('an expired account trial is ignored when the facility has its own live trial', () {
    // Pinewood on 2026-09-14: account trial ended Aug 18, facility trial runs to Sep 17.
    final decision = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'trialing', trialEnd: DateTime(2026, 8, 18)),
      facilities: [
        FacilitySubscriptionState(
          name: 'Pinewood Self Storage',
          perFacility: true,
          status: 'trialing',
          trialEnd: DateTime(2026, 9, 17),
        ),
      ],
      now: now,
    );
    expect(decision.show, isFalse);
  });

  test('an unhealthy facility is called out by name', () {
    final decision = decideSubscriptionBanner(
      account: const AccountSubscriptionState(status: 'active'),
      facilities: const [
        FacilitySubscriptionState(name: 'North Lot', perFacility: true, status: 'past_due'),
        FacilitySubscriptionState(name: 'South Lot', perFacility: true, status: 'active'),
      ],
      now: now,
    );
    expect(decision.show, isTrue);
    expect(decision.critical, isTrue);
    expect(
      decision.message,
      'The subscription payment for North Lot is past due. Update payment to keep access.',
    );
  });

  test('a per-facility subscription trialing just past its trial end is paid for, like active', () {
    // A per-facility subscription always has a card behind it (Checkout), and
    // the first free month is Stripe trial time: trialing is the free month
    // before the first charge. A day past the trial end the webhook that
    // moves it to active may simply be late (3-day grace).
    final decision = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'trialing', trialEnd: DateTime(2026, 8, 18)),
      facilities: [
        FacilitySubscriptionState(
          name: 'North Lot',
          perFacility: true,
          status: 'trialing',
          trialEnd: DateTime(2026, 9, 13),
        ),
      ],
      now: now,
    );
    expect(decision.show, isFalse);
  });

  test('a per-facility subscription still trialing long past its trial end is stale and warns', () {
    // Stripe has charged or ended it by now; the app never heard.
    for (final trialEnd in [DateTime(2026, 9, 1), null]) {
      final decision = decideSubscriptionBanner(
        account: AccountSubscriptionState(status: 'trialing', trialEnd: DateTime(2026, 8, 18)),
        facilities: [
          FacilitySubscriptionState(
            name: 'North Lot',
            perFacility: true,
            status: 'trialing',
            trialEnd: trialEnd,
          ),
        ],
        now: now,
      );
      expect(decision.show, isTrue);
      expect(decision.critical, isTrue);
      expect(decision.message, 'The trial for North Lot has ended. Subscribe to keep using it.');
    }
  });

  test('an account in the card-backed free month is not told its trial expired', () {
    // Account-level subscription: trialing with a Stripe subscription. Even in
    // the minutes between the Stripe trial end and the webhook, no banner.
    final cardTrial = decideSubscriptionBanner(
      account: AccountSubscriptionState(
        status: 'trialing',
        trialEnd: DateTime(2026, 9, 1),
        cardBackedTrial: true,
      ),
      facilities: const [],
      now: now,
    );
    expect(cardTrial.show, isFalse);

    // The unpaid app trial with the same dates still expires.
    final appTrial = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'trialing', trialEnd: DateTime(2026, 9, 1)),
      facilities: const [],
      now: now,
    );
    expect(appTrial.message, 'Your trial has expired. Please subscribe to continue using the app.');
  });

  test('several unhealthy facilities are summarised', () {
    final decision = decideSubscriptionBanner(
      account: const AccountSubscriptionState(status: 'active'),
      facilities: const [
        FacilitySubscriptionState(name: 'A', perFacility: true, status: 'past_due'),
        FacilitySubscriptionState(name: 'B', perFacility: true, status: 'cancelled'),
        FacilitySubscriptionState(name: 'C', perFacility: true, status: 'unpaid'),
      ],
      now: now,
    );
    expect(decision.message, contains('A and 2 other facilities'));
    expect(decision.message, contains('past due'));
  });

  test('legacy accounts with no per-facility subscription keep the account rules', () {
    final expired = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'trialing', trialEnd: DateTime(2026, 8, 18)),
      facilities: const [FacilitySubscriptionState(name: 'Legacy Lot', perFacility: false)],
      now: now,
    );
    expect(expired.message, 'Your trial has expired. Please subscribe to continue using the app.');
    expect(expired.critical, isTrue);

    final cancelledWithAccess = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'cancelled', currentPeriodEnd: DateTime(2026, 10, 1)),
      facilities: const [],
      now: now,
    );
    expect(cancelledWithAccess.show, isTrue);
    expect(cancelledWithAccess.critical, isFalse);

    final fine = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'trialing', trialEnd: DateTime(2026, 12, 1)),
      facilities: const [],
      now: now,
    );
    expect(fine.show, isFalse);
  });

  test('no account means no banner', () {
    expect(decideSubscriptionBanner(account: null, facilities: const [], now: now).show, isFalse);
  });

  test('an expired trial still explains itself after the sweep cancels it', () {
    // The nightly sweep moves a lapsed local trial from 'trialing' to
    // 'cancelled'. The banner must keep naming the trial as the reason,
    // otherwise the operator loses access with no explanation.
    final decision = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'cancelled', trialEnd: DateTime(2026, 8, 18)),
      facilities: const [],
      now: now,
    );
    expect(decision.show, isTrue);
    expect(decision.critical, isTrue);
    expect(decision.message, 'Your trial has expired. Please subscribe to continue using the app.');
  });

  test('a past-due subscription outranks a long-finished trial', () {
    final decision = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'pastDue', trialEnd: DateTime(2026, 1, 1)),
      facilities: const [],
      now: now,
    );
    expect(
      decision.message,
      'Your subscription payment is past due. Please renew your subscription to continue.',
    );
  });
test("a billing-exempt facility never nags, whatever Stripe says", () {
    // The operator does not bill their own facility. A past-due Stripe record
    // on it is not a thing anyone needs to act on.
    final decision = decideSubscriptionBanner(
      account: const AccountSubscriptionState(status: "pastDue"),
      facilities: const [
        FacilitySubscriptionState(
          name: "Pinewood Self Storage",
          perFacility: true,
          status: "pastDue",
          billingExempt: true,
        ),
      ],
      now: now,
    );
    expect(decision.show, isFalse);
  });

  test("one exempt facility does not silence a real problem on another", () {
    final decision = decideSubscriptionBanner(
      account: const AccountSubscriptionState(status: "active"),
      facilities: const [
        FacilitySubscriptionState(
          name: "Pinewood Self Storage",
          perFacility: true,
          status: "pastDue",
          billingExempt: true,
        ),
        FacilitySubscriptionState(
          name: "Paying Facility",
          perFacility: true,
          status: "pastDue",
        ),
      ],
      now: now,
    );
    expect(decision.show, isTrue);
    expect(decision.message, contains("Paying Facility"));
    expect(decision.message, isNot(contains("Pinewood")));
  });

  test("an exempt account is never asked to subscribe", () {
    final decision = decideSubscriptionBanner(
      account: const AccountSubscriptionState(status: "cancelled", billingExempt: true),
      facilities: const [],
      now: now,
    );
    expect(decision.show, isFalse);
  });

  test("a support session hides the supporter own billing banner", () {
    // Standing inside someone else facility, this banner would name an
    // unrelated business and its payment status on a possibly shared screen.
    final decision = decideSubscriptionBanner(
      account: const AccountSubscriptionState(status: "pastDue"),
      facilities: const [],
      now: now,
      supportSession: true,
    );
    expect(decision.show, isFalse);
  });

  test('a suspended account gets no Subscribe banner, whatever its status says', () {
    // Suspending also cancels the account, which read as "Your subscription
    // has been cancelled" beside Subscribe Now, a checkout the server now
    // refuses and one that never lifted a suspension.
    for (final status in ['cancelled', 'active', 'pastDue']) {
      final decision = decideSubscriptionBanner(
        account: AccountSubscriptionState(
          status: status,
          currentPeriodEnd: now.add(const Duration(days: 5)),
          suspended: true,
        ),
        facilities: const [],
        now: now,
      );
      expect(decision.show, isFalse, reason: status);
    }
    // Per-facility subscriptions do not bring it back either.
    expect(
      decideSubscriptionBanner(
        account: const AccountSubscriptionState(status: 'cancelled', suspended: true),
        facilities: const [
          FacilitySubscriptionState(name: 'North Lot', perFacility: true, status: 'past_due'),
        ],
        now: now,
      ).show,
      isFalse,
    );
    // Not suspended, the same cancelled account is still warned.
    expect(
      decideSubscriptionBanner(
        account: AccountSubscriptionState(
            status: 'cancelled', currentPeriodEnd: now.add(const Duration(days: 5))),
        facilities: const [],
        now: now,
      ).show,
      isTrue,
    );
  });

  test("the banner decides on the account's suspension too", () {
    // The decision was tested, but not what the banner hands it: without the
    // suspension a suspended owner saw Subscribe Now again.
    FacilityCreatorAccountModel account({required bool suspended}) => FacilityCreatorAccountModel(
          accountId: 'acct-1',
          ownerUid: 'owner',
          ownerEmail: 'owner@example.com',
          ownerName: 'Owner',
          subscriptionStatus: SubscriptionStatus.cancelled,
          subscriptionCurrentPeriodEnd: now.add(const Duration(days: 5)),
          suspended: suspended,
          createdAt: now,
          updatedAt: now,
        );
    bool shown({required bool suspended}) => decideSubscriptionBanner(
          account: SubscriptionWarningBanner.accountStateOf(account(suspended: suspended)),
          facilities: const [],
          now: now,
        ).show;

    expect(shown(suspended: true), isFalse);
    expect(shown(suspended: false), isTrue);
  });
}
