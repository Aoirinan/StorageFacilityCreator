import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/late_logic_service.dart';

/// The app displays a late fee; `processDelinquencyAutomation` charges one.
/// These mirror `functions-automation/src/test/lateFee.test.ts` case for case,
/// so the two engines cannot drift without a test going red on one side.
void main() {
  const legacy = LateFeeRules(
    gracePeriodDays: 3,
    baseLateFee: 25,
    dailyLateFee: 5,
  );

  group('resolveLateFee', () {
    test('a configured flat fee is used instead of the hardcoded default', () {
      final fee = LateLogicService.resolveLateFee(
        rules: const LateFeeRules(
          gracePeriodDays: 3,
          baseLateFee: 25,
          dailyLateFee: 5,
          lateFeeType: 'flat',
          lateFeeAmount: 15,
        ),
        daysLate: 40,
        balance: 150,
      );
      expect(fee, 15);
    });

    test('a configured percentage fee is taken from the balance', () {
      final fee = LateLogicService.resolveLateFee(
        rules: const LateFeeRules(
          gracePeriodDays: 3,
          baseLateFee: 25,
          dailyLateFee: 5,
          lateFeeType: 'percentage',
          lateFeeAmount: 10,
        ),
        daysLate: 10,
        balance: 150,
      );
      expect(fee, 15);
    });

    test('the legacy accrual still applies when nothing is configured', () {
      // 25 + (10 - 3) * 5 = 60, under the balance so uncapped.
      final fee = LateLogicService.resolveLateFee(
        rules: legacy,
        daysLate: 10,
        balance: 150,
      );
      expect(fee, 60);
    });

    test('the legacy accrual can no longer exceed the debt', () {
      // Sixty days overdue used to produce $310 on a $150 unit.
      final fee = LateLogicService.resolveLateFee(
        rules: legacy,
        daysLate: 60,
        balance: 150,
      );
      expect(fee, 150);
    });

    test('an explicit maxLateFee wins over the balance', () {
      final fee = LateLogicService.resolveLateFee(
        rules: const LateFeeRules(
          gracePeriodDays: 3,
          baseLateFee: 25,
          dailyLateFee: 5,
          maxLateFee: 20,
        ),
        daysLate: 60,
        balance: 150,
      );
      expect(fee, 20);
    });

    test('a percentage fee is capped too', () {
      final fee = LateLogicService.resolveLateFee(
        rules: const LateFeeRules(
          gracePeriodDays: 3,
          baseLateFee: 25,
          dailyLateFee: 5,
          lateFeeType: 'percentage',
          lateFeeAmount: 200,
          maxLateFee: 50,
        ),
        daysLate: 5,
        balance: 150,
      );
      expect(fee, 50);
    });

    test('a fee is never negative and never fractional cents', () {
      final withinGrace = LateLogicService.resolveLateFee(
        rules: legacy,
        daysLate: 0,
        balance: 150,
      );
      expect(withinGrace, greaterThanOrEqualTo(0));

      final third = LateLogicService.resolveLateFee(
        rules: const LateFeeRules(
          gracePeriodDays: 3,
          baseLateFee: 25,
          dailyLateFee: 5,
          lateFeeType: 'percentage',
          lateFeeAmount: 10,
        ),
        daysLate: 10,
        balance: 33.33,
      );
      expect(third, double.parse(third.toStringAsFixed(2)));
    });

    test('a zero balance yields no fee rather than an unbounded one', () {
      final fee = LateLogicService.resolveLateFee(
        rules: legacy,
        daysLate: 90,
        balance: 0,
      );
      expect(fee, 0);
    });
  });

  group('LateFeeRules.fromBillingSettings', () {
    test('falls back to platform defaults when unset', () {
      final rules = LateFeeRules.fromBillingSettings(null);
      expect(rules.gracePeriodDays, LateLogicService.defaultGracePeriodDays);
      expect(rules.baseLateFee, LateLogicService.defaultBaseLateFee);
      expect(rules.dailyLateFee, LateLogicService.defaultDailyLateFee);
      expect(rules.lateFeeType, isNull);
      expect(rules.lateFeeAmount, isNull);
      expect(rules.maxLateFee, isNull);
    });

    test('coerces the shapes Firestore actually returns', () {
      // These fields have been written as int, double and String over time.
      final rules = LateFeeRules.fromBillingSettings({
        'gracePeriodDays': '7',
        'baseLateFee': 30,
        'dailyLateFee': 2.5,
        'lateFeeType': 'flat',
        'lateFeeAmount': '12.50',
        'maxLateFee': 40,
      });
      expect(rules.gracePeriodDays, 7);
      expect(rules.baseLateFee, 30);
      expect(rules.dailyLateFee, 2.5);
      expect(rules.lateFeeType, 'flat');
      expect(rules.lateFeeAmount, 12.5);
      expect(rules.maxLateFee, 40);
    });

    test('an empty lateFeeType is treated as unconfigured', () {
      final rules = LateFeeRules.fromBillingSettings({'lateFeeType': ''});
      expect(rules.lateFeeType, isNull);
    });

    test('a configured flat fee survives the round trip into a charge', () {
      final rules = LateFeeRules.fromBillingSettings({
        'gracePeriodDays': 5,
        'lateFeeType': 'flat',
        'lateFeeAmount': 15,
      });
      final fee = LateLogicService.resolveLateFee(
        rules: rules,
        daysLate: 45,
        balance: 200,
      );
      expect(fee, 15, reason: 'the operator set \$15, so \$15 is charged');
    });
  });
}
