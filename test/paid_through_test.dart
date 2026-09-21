import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/payment_service.dart';

/// paidThrough is what isTenantLate reads, which decides whether a tenant is
/// chased, charged a late fee, sent notices and eventually locked out. Setting
/// it too far forward silently writes off real debt; too far back invents it.
void main() {
  // A fixed "today" so month boundaries are stable.
  final now = DateTime(2026, 6, 15);

  group('a payment that covers whole months', () {
    test('one month paid advances one month', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 150,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 5, 31),
        now: now,
      );
      expect(result, DateTime(2026, 6, 30));
    });

    test('paying six months forward advances six months', () {
      // The mirror of the arrears bug: this used to advance only to the end of
      // the current month, losing five months the tenant had paid for.
      final result = PaymentService.advancePaidThrough(
        amountPaid: 900,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 5, 31),
        now: now,
      );
      expect(result, DateTime(2026, 11, 30));
    });

    test('catching up on arrears moves one month per month paid', () {
      // Three months behind, pays one month. They must still be late, not
      // marked current: paidThrough advances from where they stood.
      final result = PaymentService.advancePaidThrough(
        amountPaid: 150,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 3, 31),
        now: now,
      );
      expect(result, DateTime(2026, 4, 30),
          reason: 'still two months behind, so still collectable');
    });

    test('a tenant who has never paid starts from the end of last month', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 150,
        monthlyRate: 150,
        existingPaidThrough: null,
        now: now,
      );
      expect(result, DateTime(2026, 6, 30));
    });

    test('an overpayment that is not a whole extra month rounds down', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 220,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 5, 31),
        now: now,
      );
      expect(result, DateTime(2026, 6, 30),
          reason: '\$220 buys one month, not one and a half');
    });
  });

  group('a payment that buys no month', () {
    test('a part payment leaves paidThrough untouched', () {
      // $25 against $150 rent. This is the case that wrote off the debt: the
      // tenant was marked paid through today and collection stopped.
      final result = PaymentService.advancePaidThrough(
        amountPaid: 25,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 3, 31),
        now: now,
      );
      expect(result, isNull);
    });

    test('a zero payment leaves paidThrough untouched', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 0,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 3, 31),
        now: now,
      );
      expect(result, isNull);
    });
  });

  group('paidThrough never moves backwards', () {
    test('a prepaid tenant paying again is not knocked back', () {
      // Paid through December, pays another month in June: they must end up
      // at January, not June. Setting it to the end of the current month made
      // a prepaid tenant late the following month.
      final result = PaymentService.advancePaidThrough(
        amountPaid: 150,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 12, 31),
        now: now,
      );
      expect(result, DateTime(2027, 1, 31));
    });

    test('a prepaid tenant making a part payment is left alone', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 10,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 12, 31),
        now: now,
      );
      expect(result, isNull);
    });

    test('with no rate on file a prepaid tenant is still not walked back', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 150,
        monthlyRate: 0,
        existingPaidThrough: DateTime(2026, 12, 31),
        now: now,
      );
      expect(result, isNull);
    });

    test('with no rate on file and no history it falls to this month end', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 150,
        monthlyRate: 0,
        existingPaidThrough: null,
        now: now,
      );
      expect(result, DateTime(2026, 6, 30));
    });
  });

  group('month arithmetic', () {
    test('advancing across a year boundary rolls the year', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 300,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2026, 12, 31),
        now: DateTime(2026, 12, 5),
      );
      expect(result, DateTime(2027, 2, 28));
    });

    test('always lands on the last day of a month, February included', () {
      final result = PaymentService.advancePaidThrough(
        amountPaid: 150,
        monthlyRate: 150,
        existingPaidThrough: DateTime(2028, 1, 31),
        now: DateTime(2028, 1, 10),
      );
      expect(result, DateTime(2028, 2, 29), reason: '2028 is a leap year');
    });
  });
}
