/// What the online move-in page checks about payment when it opens.
///
/// Stripe's success redirect names the paid Checkout Session (`session_id`),
/// which the page confirms. A renter who paid and closed Stripe's tab before
/// the redirect ran, or who came back on the move-in link, has none. The page
/// then did nothing: it offered to take the payment again, checkout refused
/// that as already paid, and the renter could not finish. So with no session
/// named, it asks about the session checkout recorded for the reservation
/// (confirmPublicMoveInCheckout with no sessionId).
library;

enum MoveInPaymentCheck {
  /// Stripe's success redirect: confirm the session it names.
  confirmSession,

  /// No session named: ask about the one checkout recorded, if any.
  askRecorded,

  /// Stripe's cancel redirect: nothing was paid on that page.
  cancelled,

  /// A redirect for another reservation: nothing to do here.
  none,
}

class MoveInCheckoutReturn {
  const MoveInCheckoutReturn._(this.check, [this.sessionId]);

  final MoveInPaymentCheck check;

  /// The session to confirm, for [MoveInPaymentCheck.confirmSession].
  final String? sessionId;

  /// From the move-in link's [query] (its own and its fragment's), for the
  /// reservation [reservationId] the page opened.
  factory MoveInCheckoutReturn.fromQuery(
    Map<String, String> query, {
    required String reservationId,
  }) {
    final named = query['reservationId'];
    if (named != null && named.isNotEmpty && named != reservationId) {
      return const MoveInCheckoutReturn._(MoveInPaymentCheck.none);
    }
    final state = query['checkout'];
    if (state == 'cancel') {
      return const MoveInCheckoutReturn._(MoveInPaymentCheck.cancelled);
    }
    final sessionId = query['session_id']?.trim() ?? '';
    if (state == 'success' && sessionId.isNotEmpty) {
      return MoveInCheckoutReturn._(MoveInPaymentCheck.confirmSession, sessionId);
    }
    return const MoveInCheckoutReturn._(MoveInPaymentCheck.askRecorded);
  }
}

/// The PaymentIntent a confirmPublicMoveInCheckout [result] says was paid, or
/// null when it found nothing paid (`paid: false`, as it answers when no
/// session was named and none recorded was paid).
String? paidPaymentIntentId(Map<String, dynamic> result) {
  if (result['paid'] == false || result['success'] == false) return null;
  final id = result['paymentIntentId']?.toString().trim() ?? '';
  return id.isEmpty ? null : id;
}
