import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/reservation_model.dart';
import 'package:sfcapp/services/public_move_in_flow.dart';

void main() {
  const id = 'res-1';

  PublicMoveInStart start(ReservationStatus status, Map<String, String> query) =>
      publicMoveInStart(status: status, reservationId: id, query: query);

  group('publicMoveInStart', () {
    test('a completed reservation shows the move-in as done, even on the return from Stripe', () {
      // The server completed it while the renter was away; they must not see
      // the form, or be asked to pay again.
      expect(start(ReservationStatus.completed, {}), PublicMoveInStart.completed);
      expect(
        start(ReservationStatus.completed,
            {'checkout': 'success', 'session_id': 'cs_1', 'reservationId': id}),
        PublicMoveInStart.completed,
      );
    });

    test('a paid return from Stripe finishes the move-in from the saved form', () {
      expect(
        start(ReservationStatus.pending,
            {'checkout': 'success', 'session_id': 'cs_1', 'reservationId': id}),
        PublicMoveInStart.finishAfterPayment,
      );
    });

    test('a return with no session, or for another reservation, shows the form', () {
      expect(start(ReservationStatus.pending, {'checkout': 'success'}), PublicMoveInStart.form);
      expect(
        start(ReservationStatus.pending, {'checkout': 'success', 'session_id': ' '}),
        PublicMoveInStart.form,
      );
      expect(
        start(ReservationStatus.pending,
            {'checkout': 'success', 'session_id': 'cs_1', 'reservationId': 'res-other'}),
        PublicMoveInStart.form,
      );
    });

    test('a cancelled checkout, and a first visit, show the form', () {
      expect(start(ReservationStatus.pending, {'checkout': 'cancel'}),
          PublicMoveInStart.checkoutCancelled);
      expect(start(ReservationStatus.pending, {}), PublicMoveInStart.form);
      expect(start(ReservationStatus.confirmed, {}), PublicMoveInStart.form);
    });
  });

  group('isMoveInFormNotSaved', () {
    test('recognises the refusal to finish from a form that was never saved', () {
      expect(
        isMoveInFormNotSaved(
            code: 'failed-precondition', details: {'reason': 'moveInFormNotSaved'}),
        isTrue,
      );
    });

    test('does not mistake other refusals for it', () {
      expect(isMoveInFormNotSaved(code: 'failed-precondition'), isFalse);
      expect(
        isMoveInFormNotSaved(code: 'failed-precondition', details: {'reason': 'other'}),
        isFalse,
      );
      expect(
        isMoveInFormNotSaved(code: 'internal', details: {'reason': 'moveInFormNotSaved'}),
        isFalse,
      );
    });
  });
}
