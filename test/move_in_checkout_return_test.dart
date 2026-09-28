import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/move_in_checkout_return.dart';

/// A renter who paid and closed Stripe's tab, or came back on the move-in
/// link, has no session_id: the page confirmed nothing, and checkout refused
/// a second payment as already paid, so they could not finish.
void main() {
  const reservationId = 'res-1';

  MoveInCheckoutReturn fromQuery(Map<String, String> query) =>
      MoveInCheckoutReturn.fromQuery(query, reservationId: reservationId);

  test('Stripe\'s success redirect confirms the session it names', () {
    final r = fromQuery({
      'reservationId': reservationId,
      'checkout': 'success',
      'session_id': ' cs_paid ',
    });
    expect(r.check, MoveInPaymentCheck.confirmSession);
    expect(r.sessionId, 'cs_paid');
  });

  test('a link with no session named asks about the session checkout recorded',
      () {
    // Before: nothing was checked, so a renter who had paid was asked to pay again.
    for (final query in <Map<String, String>>[
      {},
      {'token': 'tok'},
      {'reservationId': reservationId},
      {'reservationId': reservationId, 'checkout': 'success'},
      {'reservationId': reservationId, 'checkout': 'success', 'session_id': ' '},
    ]) {
      final r = fromQuery(query);
      expect(r.check, MoveInPaymentCheck.askRecorded, reason: '$query');
      expect(r.sessionId, isNull);
    }
  });

  test('Stripe\'s cancel redirect asks nothing', () {
    expect(
      fromQuery({'reservationId': reservationId, 'checkout': 'cancel'}).check,
      MoveInPaymentCheck.cancelled,
    );
  });

  test('a redirect for another reservation is left alone', () {
    expect(
      fromQuery({
        'reservationId': 'res-other',
        'checkout': 'success',
        'session_id': 'cs_other',
      }).check,
      MoveInPaymentCheck.none,
    );
  });

  group('paidPaymentIntentId', () {
    test('is the PaymentIntent of a paid session', () {
      expect(
        paidPaymentIntentId(
            {'success': true, 'paid': true, 'paymentIntentId': 'pi_1'}),
        'pi_1',
      );
      // As a server from before `paid` answers a redirect's confirmation.
      expect(
          paidPaymentIntentId({'success': true, 'paymentIntentId': 'pi_1'}),
          'pi_1');
    });

    test('is null when nothing was paid', () {
      expect(paidPaymentIntentId({'success': false, 'paid': false}), isNull);
      expect(
        paidPaymentIntentId({'paid': false, 'paymentIntentId': 'pi_1'}),
        isNull,
      );
      expect(paidPaymentIntentId({'success': true, 'paymentIntentId': ' '}),
          isNull);
    });
  });
}
