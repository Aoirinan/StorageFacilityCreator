/// Which ledger charges are still available to put on an invoice.
///
/// Two ways the same rent could be billed twice, both found by driving the app
/// rather than reading it:
///
/// 1. Marking an invoice paid updated the invoice and nothing else, so the
///    charge behind it stayed unallocated and was offered again the next time
///    an invoice was generated. The operator sees only "2 unpaid charges" and
///    has no reason to doubt it.
/// 2. A charge already sitting on a live invoice could be put on a second one,
///    because selection never asked whether an invoice already covered it.
///
/// A charge on a voided invoice is deliberately available again — voiding is
/// how an operator corrects a mistaken invoice, and the charge still needs
/// billing.
library;

/// The parts of a ledger entry this decision needs.
class SelectableCharge {
  final String id;

  /// Charges only. A payment or credit is never invoiced.
  final bool isCharge;

  /// False once the entry has been voided.
  final bool isActive;

  final double amount;

  /// How much of this charge has already been settled, from
  /// `metadata['allocatedAmount']`.
  final double? allocatedAmount;

  const SelectableCharge({
    required this.id,
    required this.isCharge,
    required this.isActive,
    required this.amount,
    this.allocatedAmount,
  });
}

/// Returns the ids of charges that may go on a new invoice.
///
/// [idsOnLiveInvoices] is every ledger entry id already covered by an invoice
/// that has not been voided.
List<String> selectableChargeIds({
  required Iterable<SelectableCharge> charges,
  required Set<String> idsOnLiveInvoices,
  Iterable<String>? onlyThese,
}) {
  final restrictTo = onlyThese?.toSet();
  return charges
      .where((c) {
        if (restrictTo != null && !restrictTo.contains(c.id)) return false;
        if (!c.isCharge || !c.isActive) return false;
        if (idsOnLiveInvoices.contains(c.id)) return false;
        final allocated = c.allocatedAmount;
        if (allocated != null && allocated >= c.amount) return false;
        return true;
      })
      .map((c) => c.id)
      .toList();
}

/// Whether a charge counts as settled.
bool chargeIsSettled({required double amount, double? allocatedAmount}) {
  if (allocatedAmount == null) return false;
  return allocatedAmount >= amount;
}
