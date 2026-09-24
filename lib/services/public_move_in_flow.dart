import 'package:sfcapp/models/reservation_model.dart';

/// What the online move-in page does once its reservation has loaded.
enum PublicMoveInStart {
  /// The move-in is done: submitted on this page before, or completed by the
  /// server after the renter paid and left (functions-public-website
  /// paidCheckoutCompletion.ts).
  completed,

  /// Back from Stripe having paid: finish the move-in from the form saved
  /// when checkout was created. The renter filled it in before paying.
  finishAfterPayment,

  /// Back from Stripe without paying.
  checkoutCancelled,

  /// Fill in the form.
  form,
}

/// Where the page starts, from the reservation's [status] and the URL's
/// query parameters [query] (Stripe's return adds `checkout`, `session_id`
/// and `reservationId`).
PublicMoveInStart publicMoveInStart({
  required ReservationStatus status,
  required String reservationId,
  required Map<String, String> query,
}) {
  if (status == ReservationStatus.completed) return PublicMoveInStart.completed;
  final returnedFor = query['reservationId'];
  if (returnedFor != null && returnedFor.isNotEmpty && returnedFor != reservationId) {
    return PublicMoveInStart.form;
  }
  final checkout = query['checkout'];
  if (checkout == 'cancel') return PublicMoveInStart.checkoutCancelled;
  final sessionId = query['session_id']?.trim() ?? '';
  if (checkout == 'success' && sessionId.isNotEmpty) {
    return PublicMoveInStart.finishAfterPayment;
  }
  return PublicMoveInStart.form;
}

/// Whether completePublicMoveIn refused to finish from a saved form because
/// none was saved: checkout was created before the form was saved with it.
/// The renter then fills the form in on the page, as before.
bool isMoveInFormNotSaved({required String code, Object? details}) {
  return code == 'failed-precondition' &&
      details is Map &&
      details['reason'] == 'moveInFormNotSaved';
}
