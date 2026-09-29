/// Which ledger charges are still available to put on an invoice, and how
/// much of each an invoice may bill.
///
/// Three ways the same rent could be billed twice, all found by driving the
/// app rather than reading it:
///
/// 1. Marking an invoice paid updated the invoice and nothing else, so the
///    charge behind it stayed unallocated and was offered again the next time
///    an invoice was generated. The operator sees only "2 unpaid charges" and
///    has no reason to doubt it.
/// 2. A charge already sitting on a live invoice could be put on a second one,
///    because selection never asked whether an invoice already covered it.
/// 3. A charge counted as unpaid unless `metadata['allocatedAmount']` said it
///    was settled, and only the move-in and migration flows write that. A
///    payment recorded on the ledger by hand, entered as past history or
///    posted by a Stripe webhook never does. So a tenant with nine months of
///    rent charges and payments covering most of them was offered an invoice
///    for all nine months, several times what the ledger said they owed.
///
/// [openChargesForInvoice] settles the third from the ledger balance, which
/// every payment moves whatever wrote it. [selectableChargeIds] is the
/// exclusion rule behind it.
///
/// A charge on a voided invoice is deliberately available again — voiding is
/// how an operator corrects a mistaken invoice, and the charge still needs
/// billing.
library;

import '../models/ledger_entry_model.dart';

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

  /// When the charge was posted. Newer charges are billed before older ones,
  /// see [openChargesForInvoice].
  final DateTime entryDate;

  /// What the invoice line says for this charge.
  final String description;

  const SelectableCharge({
    required this.id,
    required this.isCharge,
    required this.isActive,
    required this.amount,
    this.allocatedAmount,
    required this.entryDate,
    required this.description,
  });

  /// The ledger's Generate Invoice dialog and the service build from this,
  /// so they cannot disagree on what counts as a charge. They used to: the
  /// dialog left out positive credit and refund rows that the service then
  /// billed, so the saved invoice was not the one previewed.
  factory SelectableCharge.fromLedgerEntry(LedgerEntry entry) {
    return SelectableCharge(
      id: entry.id,
      isCharge: entry.isCharge,
      isActive: entry.isActive,
      amount: entry.amount,
      allocatedAmount:
          (entry.metadata?['allocatedAmount'] as num?)?.toDouble(),
      entryDate: entry.entryDate,
      description: entry.description ?? entry.typeDisplayName,
    );
  }
}

/// One line of the invoice to generate: which charge, and how much of it.
class OpenCharge {
  final String id;

  /// How much of the charge to bill. Less than the charge itself when the
  /// tenant's payments have covered the rest of it.
  final double amount;

  /// The charge's description, with "(balance)" added when [amount] is only
  /// part of it.
  final String description;

  final bool isPartial;

  const OpenCharge({
    required this.id,
    required this.amount,
    required this.description,
    required this.isPartial,
  });
}

bool _isSelectable(
  SelectableCharge c, {
  required Set<String> idsOnLiveInvoices,
  required Set<String>? restrictTo,
}) {
  if (restrictTo != null && !restrictTo.contains(c.id)) return false;
  if (!c.isCharge || !c.isActive) return false;
  if (idsOnLiveInvoices.contains(c.id)) return false;
  final allocated = c.allocatedAmount;
  if (allocated != null && allocated >= c.amount) return false;
  return true;
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
      .where((c) => _isSelectable(
            c,
            idsOnLiveInvoices: idsOnLiveInvoices,
            restrictTo: restrictTo,
          ))
      .map((c) => c.id)
      .toList();
}

/// The lines of an invoice for what the tenant still owes.
///
/// What the tenant owes is [ledgerBalance]. What has already been asked of
/// them is [liveInvoiceBalance], the balance of their invoices that are
/// neither voided nor paid. The difference is all a new invoice may bill: if
/// it is nothing, or the tenant is in credit, the result is empty.
///
/// The selectable charges (see [selectableChargeIds]) are then walked newest
/// first and taken whole until that amount is covered. The oldest one taken
/// may be billed in part, and its description says "(balance)". This is what
/// the tenant's payments come to when each pays off the oldest charge first,
/// whichever charge it was written against, and it needs nothing stored on
/// the entries: `allocatedAmount` only ever reflects the move-in and
/// migration flows, so deciding from it billed rent that had been paid for
/// months.
///
/// Ties on the same day are broken by id, so the preview and the saved
/// invoice pick the same charge whatever order the entries arrived in.
List<OpenCharge> openChargesForInvoice({
  required Iterable<SelectableCharge> charges,
  required Set<String> idsOnLiveInvoices,
  required double ledgerBalance,
  required double liveInvoiceBalance,
  Iterable<String>? onlyThese,
}) {
  var remaining = _cents(ledgerBalance - liveInvoiceBalance);
  if (remaining <= 0) return const [];

  final restrictTo = onlyThese?.toSet();
  final open = charges
      .where((c) => _isSelectable(
            c,
            idsOnLiveInvoices: idsOnLiveInvoices,
            restrictTo: restrictTo,
          ))
      .toList()
    ..sort((a, b) {
      final byDate = b.entryDate.compareTo(a.entryDate);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });

  final lines = <OpenCharge>[];
  for (final charge in open) {
    if (remaining <= 0) break;
    final billable = _cents(charge.amount - (charge.allocatedAmount ?? 0));
    if (billable <= 0) continue;
    final partial = billable > remaining;
    final amount = partial ? remaining : billable;
    lines.add(OpenCharge(
      id: charge.id,
      amount: amount,
      description:
          partial ? '${charge.description} (balance)' : charge.description,
      isPartial: partial,
    ));
    remaining = _cents(remaining - amount);
  }
  return lines;
}

/// What the operator is told when [openChargesForInvoice] comes back empty.
///
/// The ledger's Generate Invoice snackbar and the service's exception both
/// say this, so the two cannot drift apart. "No balance due" is true only
/// when the tenant owes nothing. Every other empty result was worded the
/// same, so a tenant owing $433 whose old draft still asked for $1,170 got
/// "No balance due" directly under a header reading $433.00, with no hint
/// that the draft had to be voided first. The same words met an owner who
/// had recorded a check on the ledger but not marked the invoice paid.
String nothingToInvoiceMessage({
  required double ledgerBalance,
  required double liveInvoiceBalance,
}) {
  if (_cents(ledgerBalance) <= 0) {
    return 'No balance due — nothing to invoice';
  }
  if (_cents(liveInvoiceBalance) > 0) {
    return "This tenant's balance is already on an invoice: open invoices "
        'ask for ${_money(liveInvoiceBalance)} and the ledger balance is '
        '${_money(ledgerBalance)}. Void it or mark it paid under '
        'Rent & payments › Invoices before generating another.';
  }
  // Owed, nothing live asking for it, and still no charge to bill: every
  // charge is on a paid invoice or recorded as settled, so the balance is
  // made of entries an invoice cannot carry.
  return 'This tenant owes ${_money(ledgerBalance)}, but every charge on '
      'the ledger is already on an invoice or recorded as settled, so there '
      'is nothing to put on a new one. Check Rent & payments › Invoices.';
}

String _money(double value) => '\$${_cents(value).toStringAsFixed(2)}';

/// Money to the cent, the same way the ledger balance is rounded: summing
/// doubles drifts, and a drift of a fraction of a cent must not leave a
/// charge "partly" billed.
double _cents(double value) => double.parse(value.toStringAsFixed(2));

/// Whether a charge counts as settled.
bool chargeIsSettled({required double amount, double? allocatedAmount}) {
  if (allocatedAmount == null) return false;
  return allocatedAmount >= amount;
}
