import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/subscription_banner_logic.dart';

void main() {
  final now = DateTime(2026, 9, 14);

  test('an expired account trial is ignored when the facility has its own live trial', () {
    // Keepsake on 2026-09-14: account trial ended Aug 18, facility trial runs to Sep 17.
    final decision = decideSubscriptionBanner(
      account: AccountSubscriptionState(status: 'trialing', trialEnd: DateTime(2026, 8, 18)),
      facilities: [
        FacilitySubscriptionState(
          name: 'Keepsake Self Storage',
          perFacility: true,
          status: 'trialing',
          trialEnd: DateTime(2026, 9, 17),
        ),
      ],
      now: now,
    );
    expect(decision.show, isFalse);
  });

  test('a facility whose own trial ended is called out by name', () {
    final decision = decideSubscriptionBanner(
      account: const AccountSubscriptionState(status: 'active'),
      facilities: [
        FacilitySubscriptionState(
          name: 'North Lot',
          perFacility: true,
          status: 'trialing',
          trialEnd: DateTime(2026, 9, 1),
        ),
        const FacilitySubscriptionState(name: 'South Lot', perFacility: true, status: 'active'),
      ],
      now: now,
    );
    expect(decision.show, isTrue);
    expect(decision.critical, isTrue);
    expect(decision.message, 'The trial for North Lot has ended. Subscribe to keep using it.');
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
}