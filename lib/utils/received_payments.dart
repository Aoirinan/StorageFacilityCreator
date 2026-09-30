import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';

/// One payment the tenant made, as the Payment History block lists it.
class ReceivedPayment {
  final String ledgerEntryId;

  /// The ledger row's date: the day the money was received for entries made
  /// with Enter past history, the day it was recorded otherwise.
  final DateTime receivedOn;

  /// Only the month is known (Enter past history's "month only"): the row is
  /// dated the 1st, which nobody recorded, so only the month is shown.
  final bool monthOnly;

  /// What was paid, positive.
  final double amount;

  /// "Check", "Cash", "Stripe"; null when the row does not say.
  final String? method;

  /// The check or reference number, when one was entered.
  final String? reference;

  const ReceivedPayment({
    required this.ledgerEntryId,
    required this.receivedOn,
    required this.monthOnly,
    required this.amount,
    required this.method,
    required this.reference,
  });

  /// "Check #1042", "Cash", "Payment".
  String get label {
    final ref = reference == null ? '' : ' #$reference';
    return '${method ?? 'Payment'}$ref';
  }
}

/// The payments on [entries], newest first: posted `payment` rows.
///
/// Read from the ledger only. The paths that take money (Record payment,
/// Enter past history, Stripe, autopay, move-in) each post a ledger row for
/// it, and most also write a `payments` doc that the row points at
/// (`metadata.paymentId` / `referenceId`). Reading both and merging them
/// would list those payments twice; the ledger rows alone are the same set
/// the balance, View Ledger and the statement are built from. Pending rows
/// are money still owed and voided rows were taken back, so neither is
/// listed.
List<ReceivedPayment> receivedPayments(List<LedgerEntry> entries) {
  final rows = [
    for (final e in entries)
      if (e.type == LedgerEntryType.payment && e.status == LedgerEntryStatus.posted) e,
  ]..sort(_newestFirst);
  return [
    for (final e in rows)
      ReceivedPayment(
        ledgerEntryId: e.id,
        receivedOn: e.entryDate,
        monthOnly: e.metadata?['dateIsMonthOnly'] == true,
        amount: e.amount.abs(),
        method: _methodOf(e.metadata),
        reference: _trimmed(e.metadata?['reference']),
      ),
  ];
}

/// Newest date first; on the same instant (two "month only" history
/// payments are both the 1st at 12:00 UTC) the one recorded last first,
/// then by id, so the order, and which rows make the Payment History
/// block's cut, is the same on every load.
int _newestFirst(LedgerEntry a, LedgerEntry b) {
  final byDate = b.entryDate.compareTo(a.entryDate);
  if (byDate != 0) return byDate;
  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;
  return a.id.compareTo(b.id);
}

String? _methodOf(Map<String, dynamic>? metadata) {
  final stored = _trimmed(metadata?['paymentMethod']);
  // The move-in wizard stores 'ach', which [PaymentMethod] has no name for
  // and so reads as Other.
  if (stored == 'ach') return 'Bank transfer (ACH)';
  if (stored != null) return paymentMethodFromStored(stored).displayName;
  // The Stripe webhook's row has no method, only the payment intent.
  if (_trimmed(metadata?['paymentIntentId']) != null) return PaymentMethod.stripe.displayName;
  return null;
}

String? _trimmed(Object? value) {
  if (value is! String) return null;
  final s = value.trim();
  return s.isEmpty ? null : s;
}
