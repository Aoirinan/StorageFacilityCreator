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

/// What the page does when finishing a paid move-in from the saved form fails.
enum PaidMoveInFailure {
  /// The server cannot finish it from a saved form: none was saved, or the
  /// server is older than this page and wants the form in the request. The
  /// renter fills it in here, as before.
  fillInForm,

  /// The move-in was refused. The renter has paid, must not pay again, and
  /// is told to contact the facility.
  refused,

  /// A failure that may pass (a timeout, the server or Stripe unavailable).
  /// The server finishes a paid move-in on its own when Stripe reports the
  /// payment, so the renter is asked to check again, not told it failed.
  tryAgain,
}

/// How the page treats a failed attempt to finish a paid move-in, from the
/// callable's error [code] and [details].
PaidMoveInFailure paidMoveInFailure({required String code, Object? details}) {
  if (isMoveInFormNotSaved(code: code, details: details) ||
      code == 'invalid-argument') {
    return PaidMoveInFailure.fillInForm;
  }
  if (code == 'failed-precondition' ||
      code == 'permission-denied' ||
      code == 'not-found') {
    return PaidMoveInFailure.refused;
  }
  return PaidMoveInFailure.tryAgain;
}
