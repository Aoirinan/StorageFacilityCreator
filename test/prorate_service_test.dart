import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/prorate_service.dart';

/// Proration is the first money the platform ever charges a tenant, and it
/// reaches the ledger directly. These tests pin the arithmetic itself; they
/// deliberately avoid Firestore so they can run in CI with no emulator.
void main() {
  group('calculateProratedRent', () {
    test('a whole calendar month bills exactly the monthly rate', () {
      // The invariant that matters: renting for every day of a month costs a
      // month. It must hold in every month of the year, because local-time day
      // arithmetic goes wrong across a daylight-saving boundary — a span that
      // is 30 days minus one hour truncates to 29. Whichever month carries the
      // transition in the runner's timezone, one of these will catch it.
      for (var year = 2026; year <= 2027; year++) {
        for (var month = 1; month <= 12; month++) {
          final first = DateTime(year, month, 1);
          final last = DateTime(year, month + 1, 0);
          final amount = ProrateService.calculateProratedRent(
            monthlyRate: 200,
            moveInDate: first,
            endDate: last,
          );
          expect(
            amount,
            200,
            reason: 'full month $year-$month should bill the full rate',
          );
        }
      }
    });

    test('the time of day a move-in is recorded does not change the bill', () {
      // Move-ins are stamped with DateTime.now(), so the same calendar day
      // arrives with any time attached. It must not move the money.
      final atMidnight = ProrateService.calculateProratedRent(
        monthlyRate: 200,
        moveInDate: DateTime(2026, 1, 15),
      );
      final lateAfternoon = ProrateService.calculateProratedRent(
        monthlyRate: 200,
        moveInDate: DateTime(2026, 1, 15, 14, 30),
      );
      final justBeforeMidnight = ProrateService.calculateProratedRent(
        monthlyRate: 200,
        moveInDate: DateTime(2026, 1, 15, 23, 59, 59),
      );

      expect(lateAfternoon, atMidnight);
      expect(justBeforeMidnight, atMidnight);
      // Jan 15-31 inclusive is 17 of 31 days: 200 / 31 * 17.
      expect(atMidnight, closeTo(109.68, 0.005));
    });

    test('moving in on the last day of the month bills one day', () {
      final amount = ProrateService.calculateProratedRent(
        monthlyRate: 310,
        moveInDate: DateTime(2026, 1, 31),
      );
      expect(amount, closeTo(10.00, 0.005));
    });

    test('February is billed on its own length, leap year included', () {
      final leap = ProrateService.calculateProratedRent(
        monthlyRate: 290,
        moveInDate: DateTime(2028, 2, 1),
      );
      expect(leap, 290, reason: '2028 is a leap year: 29 days');

      final common = ProrateService.calculateProratedRent(
        monthlyRate: 280,
        moveInDate: DateTime(2026, 2, 1),
      );
      expect(common, 280, reason: '2026 February has 28 days');
    });

    test('the result is rounded to whole cents', () {
      // A raw float reaching the ledger leaves residue that stops a balance
      // settling to exactly zero.
      final amount = ProrateService.calculateProratedRent(
        monthlyRate: 100,
        moveInDate: DateTime(2026, 1, 15),
      );
      expect(amount, double.parse(amount.toStringAsFixed(2)));
      expect(amount, closeTo(54.84, 0.005));
    });

    test('an end date before the start does not invent a negative charge', () {
      final amount = ProrateService.calculateProratedRent(
        monthlyRate: 200,
        moveInDate: DateTime(2026, 1, 20),
        endDate: DateTime(2026, 1, 10),
      );
      expect(amount, greaterThanOrEqualTo(0),
          reason: 'a backwards range must not produce a credit');
    });
  });

  group('calculateDaysRemainingInMonth', () {
    test('agrees with the number of days actually billed', () {
      // move_in_service puts this count in the ledger description while
      // charging the amount from calculateProratedRent. If the two disagree,
      // the invoice line says one thing and takes another.
      for (final moveIn in [
        DateTime(2026, 1, 15),
        DateTime(2026, 1, 15, 14, 30),
        DateTime(2026, 3, 9, 8, 5),
        DateTime(2026, 3, 1),
        DateTime(2026, 11, 2, 16, 45),
        DateTime(2026, 2, 28, 23, 30),
      ]) {
        final days = ProrateService.calculateDaysRemainingInMonth(moveIn);
        final daysInMonth = DateTime(moveIn.year, moveIn.month + 1, 0).day;
        final amount = ProrateService.calculateProratedRent(
          monthlyRate: 310,
          moveInDate: moveIn,
        );
        final impliedByLabel =
            double.parse((310 / daysInMonth * days).toStringAsFixed(2));
        expect(amount, impliedByLabel,
            reason: 'label says $days days for move-in $moveIn');
      }
    });

    test('counts the move-in day itself', () {
      expect(
        ProrateService.calculateDaysRemainingInMonth(DateTime(2026, 1, 31)),
        1,
      );
      expect(
        ProrateService.calculateDaysRemainingInMonth(DateTime(2026, 1, 1)),
        31,
      );
    });
  });

  group('calculateDaysInRange', () {
    test('is inclusive of both endpoints and ignores time of day', () {
      expect(
        ProrateService.calculateDaysInRange(
          startDate: DateTime(2026, 1, 1),
          endDate: DateTime(2026, 1, 1),
        ),
        1,
      );
      expect(
        ProrateService.calculateDaysInRange(
          startDate: DateTime(2026, 1, 1, 9, 15),
          endDate: DateTime(2026, 1, 31, 2, 0),
        ),
        31,
      );
    });

    test('spans a daylight-saving transition without losing a day', () {
      for (var month = 1; month <= 12; month++) {
        final first = DateTime(2026, month, 1);
        final last = DateTime(2026, month + 1, 0);
        expect(
          ProrateService.calculateDaysInRange(startDate: first, endDate: last),
          last.day,
          reason: 'month $month should span exactly ${last.day} days',
        );
      }
    });
  });

  group('month boundary helpers', () {
    test('getFirstDayOfNextMonth rolls the year over in December', () {
      expect(
        ProrateService.getFirstDayOfNextMonth(DateTime(2026, 12, 15)),
        DateTime(2027, 1, 1),
      );
      expect(
        ProrateService.getFirstDayOfNextMonth(DateTime(2026, 1, 15)),
        DateTime(2026, 2, 1),
      );
    });

    test('getLastDayOfMonth handles February and December', () {
      expect(ProrateService.getLastDayOfMonth(DateTime(2028, 2, 10)).day, 29);
      expect(ProrateService.getLastDayOfMonth(DateTime(2026, 2, 10)).day, 28);
      expect(ProrateService.getLastDayOfMonth(DateTime(2026, 12, 10)).day, 31);
    });
  });
}
