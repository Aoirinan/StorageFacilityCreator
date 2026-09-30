import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/move_out_service.dart';

/// What the move-out screen sends processMoveOut and reads back from it.
void main() {
  group('moveOutDay', () {
    test('is the calendar day the owner picked, with no time or zone', () {
      // toIso8601String() sent local midnight with no offset, which the
      // server read as UTC: the 23rd became the evening of the 22nd in the US.
      expect(MoveOutService.moveOutDay(DateTime(2026, 9, 23)), '2026-09-23');
      expect(MoveOutService.moveOutDay(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
      expect(MoveOutService.moveOutDay(DateTime(2028, 2, 29, 8, 30)), '2028-02-29');
    });
  });

  group("processMoveOut's refund, for the move-out screen", () {
    final calculation = MoveOutCalculation(
      lineItems: const [],
      currentBalance: -50,
      newCharges: 0,
      finalBalance: -50,
      refundAmount: 50,
    );

    test('is shown when the server posted it', () {
      final result = MoveOutService.moveOutResultFromServer(
        {'success': true, 'refundPosted': true},
        calculation,
      );
      expect(result.refund, 50);
      expect(result.charges, 0);
    });

    test('is not shown when Process Refund was off: the credit stayed on the ledger', () {
      final result = MoveOutService.moveOutResultFromServer(
        {'success': true, 'refundPosted': false},
        calculation,
      );
      expect(result.success, isTrue);
      expect(result.refund, isNull);
    });

    test('is not shown on a retry of a finished move-out either', () {
      final result = MoveOutService.moveOutResultFromServer(
        {'success': true, 'alreadyCompleted': true, 'refundPosted': false},
        calculation,
      );
      expect(result.refund, isNull);
      expect(result.charges, isNull);
    });
  });
}
