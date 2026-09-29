import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/platform_trial_markers.dart';

void main() {
  const stamp = 'STAMP';

  test('revoking a trial granted before the marker existed records the marker', () {
    final fields = revokeTrialFields({
      'subscriptionStatus': 'trialing',
      'subscriptionTrialEnd': DateTime.utc(2026, 10, 21),
    }, stamp: stamp);
    expect(fields['subscriptionStatus'], 'cancelled');
    expect(fields.containsKey('subscriptionTrialEnd'), isTrue);
    expect(fields['subscriptionTrialEnd'], isNull);
    expect(fields['platformTrialUsedAt'], stamp);
  });

  test('revoking keeps an existing marker untouched', () {
    final fields = revokeTrialFields({
      'subscriptionStatus': 'trialing',
      'platformTrialUsedAt': DateTime.utc(2026, 9, 1),
    }, stamp: stamp);
    expect(fields.containsKey('platformTrialUsedAt'), isFalse);
    expect(fields['subscriptionStatus'], 'cancelled');
  });

  test('a missing account document still gets the marker', () {
    expect(revokeTrialFields(null, stamp: stamp)['platformTrialUsedAt'], stamp);
  });

  group('suspension (accountSuspensionFields)', () {
    const deleteValue = 'DELETE';
    Map<String, dynamic> suspend(Map<String, dynamic>? current) => accountSuspensionFields(
          current,
          suspended: true,
          reason: 'abuse',
          actorUid: 'uid_test_admin',
          actorEmail: 'admin@example.test',
          stamp: stamp,
          deleteValue: deleteValue,
        );

    test('suspending a legacy app-trial account records the trial it deletes', () {
      final fields = suspend({
        'subscriptionStatus': 'trialing',
        'subscriptionTrialEnd': DateTime.utc(2026, 10, 21),
      });
      expect(fields['subscriptionStatus'], 'cancelled');
      expect(fields['subscriptionTrialEnd'], deleteValue);
      expect(fields['subscriptionCurrentPeriodEnd'], deleteValue);
      expect(fields['platformTrialUsedAt'], stamp);
      expect(fields['suspended'], isTrue);
      expect(fields['suspendedAt'], stamp);
      expect(fields['suspendedByUid'], 'uid_test_admin');
      expect(fields['suspendedByEmail'], 'admin@example.test');
      expect(fields['suspensionReason'], 'abuse');
    });

    test('an expired trial swept to cancelled still counts', () {
      expect(
        suspend({'subscriptionStatus': 'cancelled', 'subscriptionTrialEnd': DateTime.utc(2026, 8, 1)})['platformTrialUsedAt'],
        stamp,
      );
    });

    test('an existing marker is kept; an account that never had a trial gets none', () {
      expect(
        suspend({
          'subscriptionStatus': 'trialing',
          'subscriptionTrialEnd': DateTime.utc(2026, 10, 21),
          'platformTrialUsedAt': DateTime.utc(2026, 9, 1),
        }).containsKey('platformTrialUsedAt'),
        isFalse,
      );
      expect(suspend({'subscriptionStatus': 'pendingApproval'}).containsKey('platformTrialUsedAt'), isFalse);
      expect(suspend(null).containsKey('platformTrialUsedAt'), isFalse);
    });

    test('unsuspending clears the suspension and touches nothing else', () {
      final fields = accountSuspensionFields(
        {'subscriptionStatus': 'cancelled', 'suspended': true},
        suspended: false,
        reason: 'abuse',
        actorUid: 'uid_test_admin',
        actorEmail: 'admin@example.test',
        stamp: stamp,
        deleteValue: deleteValue,
      );
      expect(fields, {
        'suspended': false,
        'updatedAt': stamp,
        'suspendedByUid': null,
        'suspendedByEmail': null,
        'suspendedAt': null,
        'suspensionReason': null,
      });
    });
  });

  group('admin app trial on a Stripe-billed account', () {
    test('grant, approve and extend are refused when the account has a Stripe subscription id', () {
      for (final data in [
        {'subscriptionStatus': 'trialing', 'stripeSubscriptionId': 'sub_test_card_trial'},
        {'subscriptionStatus': 'pendingApproval', 'stripeSubscriptionId': 'sub_test_card_at_signup'},
        {'subscriptionStatus': 'cancelled', 'stripeSubscriptionId': 'sub_test_stale'},
        {'subscriptionStatus': 'active', 'stripeSubscriptionId': 'sub_test_paid'},
      ]) {
        expect(adminAppTrialRefusal(data), adminAppTrialStripeSubscriptionMessage, reason: '$data');
      }
      expect(adminAppTrialStripeSubscriptionMessage, contains('Stripe subscription'));
      expect(const AdminAppTrialRefused('nope').toString(), 'nope');
    });

    test('allowed without one', () {
      expect(adminAppTrialRefusal(null), isNull);
      expect(adminAppTrialRefusal({'subscriptionStatus': 'pendingApproval'}), isNull);
      expect(adminAppTrialRefusal({'subscriptionStatus': 'trialing', 'stripeSubscriptionId': null}), isNull);
      expect(adminAppTrialRefusal({'subscriptionStatus': 'cancelled', 'stripeSubscriptionId': '  '}), isNull);
    });

    test('the Accounts tab: extend only the unpaid app trial; revoke a stale card-backed trial too', () {
      // Unpaid app trial.
      var actions = AdminTrialActions.of(onTrial: true, pendingApproval: false, hasStripeSubscription: false);
      expect([actions.grant, actions.extend, actions.revoke], [false, true, true]);
      // Stale card-backed trial: revoke, never extend.
      actions = AdminTrialActions.of(onTrial: true, pendingApproval: false, hasStripeSubscription: true);
      expect([actions.grant, actions.extend, actions.revoke], [false, false, true]);
      // Card-backed trial still counting as paid, or active: no trial rewrite offered but grant
      // (which the service refuses with a message when there is a Stripe subscription).
      actions = AdminTrialActions.of(onTrial: false, pendingApproval: false, hasStripeSubscription: true);
      expect([actions.extend, actions.revoke], [false, false]);
      // Pending approval: approve/reject only.
      actions = AdminTrialActions.of(onTrial: false, pendingApproval: true, hasStripeSubscription: false);
      expect([actions.grant, actions.extend, actions.revoke], [false, false, false]);
    });
  });
}
