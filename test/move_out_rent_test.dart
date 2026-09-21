import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/move_out_service.dart';

/// Rent is billed in advance on the 1st, so a move-out mid-month is normally a
/// credit, not a charge. Getting the direction wrong bills the month twice.
void main() {
  group('moveOutRentAmount when the month was already charged', () {
    test('credits the unused days, not the used ones', () {
      // $150 over 30 days, leaving on the 10th: 20 unused days at $5.
      final rent = MoveOutService.moveOutRentAmount(
        monthlyRate: 150,
        moveOutDate: DateTime(2026, 6, 10),
        alreadyCharged: true,
      );
      expect(rent.amount, 100);
      expect(rent.days, 10);
      expect(rent.unusedDays, 20);
    });

    test('leaving on the last day of the month credits nothing', () {
      final rent = MoveOutService.moveOutRentAmount(
        monthlyRate: 150,
        moveOutDate: DateTime(2026, 6, 30),
        alreadyCharged: true,
      );
      expect(rent.amount, 0);
      expect(rent.unusedDays, 0);
    });

    test('leaving on the 1st credits all but that day', () {
      final rent = MoveOutService.moveOutRentAmount(
        monthlyRate: 310,
        moveOutDate: DateTime(2026, 1, 1),
        alreadyCharged: true,
      );
      expect(rent.unusedDays, 30);
      expect(rent.amount, 300);
    });
  });

  group('moveOutRentAmount when the month was never charged', () {
    test('charges the days used', () {
      // The double-billing case: this must be the ten days used, $50, and it
      // may only apply when the month was not already posted. A tenant on $150
      // leaving on the 10th was once billed $150 plus $50.
      final rent = MoveOutService.moveOutRentAmount(
        monthlyRate: 150,
        moveOutDate: DateTime(2026, 6, 10),
        alreadyCharged: false,
      );
      expect(rent.amount, 50);
      expect(rent.days, 10);
    });

    test('a full month used charges the full rate', () {
      final rent = MoveOutService.moveOutRentAmount(
        monthlyRate: 150,
        moveOutDate: DateTime(2026, 6, 30),
        alreadyCharged: false,
      );
      expect(rent.amount, 150);
    });
  });

  group('moveOutRentAmount arithmetic', () {
    test('the charge and the credit always sum to the month', () {
      // Whichever way a move-out falls, the two halves are one month's rent.
      for (final date in [
        DateTime(2026, 1, 1),
        DateTime(2026, 2, 14),
        DateTime(2028, 2, 29),
        DateTime(2026, 3, 9),
        DateTime(2026, 6, 10),
        DateTime(2026, 12, 31),
      ]) {
        final charge = MoveOutService.moveOutRentAmount(
          monthlyRate: 300,
          moveOutDate: date,
          alreadyCharged: false,
        );
        final credit = MoveOutService.moveOutRentAmount(
          monthlyRate: 300,
          moveOutDate: date,
          alreadyCharged: true,
        );
        expect(charge.amount + credit.amount, closeTo(300, 0.02),
            reason: 'used plus unused should be the month for $date');
        expect(charge.days + charge.unusedDays,
            DateTime(date.year, date.month + 1, 0).day);
      }
    });

    test('February is measured on its own length', () {
      final leap = MoveOutService.moveOutRentAmount(
        monthlyRate: 290,
        moveOutDate: DateTime(2028, 2, 29),
        alreadyCharged: false,
      );
      expect(leap.days, 29);
      expect(leap.amount, 290);

      final common = MoveOutService.moveOutRentAmount(
        monthlyRate: 280,
        moveOutDate: DateTime(2026, 2, 28),
        alreadyCharged: false,
      );
      expect(common.days, 28);
      expect(common.amount, 280);
    });

    test('amounts are whole cents', () {
      final rent = MoveOutService.moveOutRentAmount(
        monthlyRate: 100,
        moveOutDate: DateTime(2026, 1, 10),
        alreadyCharged: true,
      );
      expect(rent.amount, double.parse(rent.amount.toStringAsFixed(2)));
    });

    test('a zero rate produces no line either way', () {
      for (final already in [true, false]) {
        final rent = MoveOutService.moveOutRentAmount(
          monthlyRate: 0,
          moveOutDate: DateTime(2026, 6, 10),
          alreadyCharged: already,
        );
        expect(rent.amount, 0);
      }
    });
  });
}
