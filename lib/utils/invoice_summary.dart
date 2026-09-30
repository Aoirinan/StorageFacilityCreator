/// The Invoices tab's headline figures, counted from invoices and nothing else.
///
/// Each figure matches a filter chip under the cards, so tapping the chip lists
/// exactly the invoices the card counted:
///
/// - Invoices: every invoice except voided ones (the "All" chip).
/// - Paid: status paid (the "Paid" chip).
/// - Overdue: [InvoiceModel.isOverdueAt]: sent, a balance still owed, due on a
///   day before today (the "Overdue" chip). Drafts never count: they were
///   never sent.
/// - Unpaid: the balances still owed on open invoices (draft, sent or
///   overdue). Drafts are included: an invoice is generated from charges
///   already on the tenant's ledger, so the money is owed whether or not the
///   invoice has gone out, and "Mark paid" works on a draft. [unpaidDrafts]
///   says how many drafts are in the sum so the card can label it.
///
/// Tenants late on rent are not invoices and are not counted here; they are on
/// the Past due tab.
library;

import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/invoice_status_actions.dart';

class InvoiceSummary {
  const InvoiceSummary({
    required this.count,
    required this.paid,
    required this.overdue,
    required this.unpaidAmount,
    required this.unpaidDrafts,
  });

  /// Every invoice except voided ones.
  final int count;

  /// Invoices with status paid.
  final int paid;

  /// Invoices overdue today (see [InvoiceModel.isOverdueAt]).
  final int overdue;

  /// Sum of the balances on open invoices, drafts included, in dollars
  /// rounded to the cent.
  final double unpaidAmount;

  /// How many drafts have a balance in [unpaidAmount].
  final int unpaidDrafts;

  static const empty = InvoiceSummary(
    count: 0,
    paid: 0,
    overdue: 0,
    unpaidAmount: 0,
    unpaidDrafts: 0,
  );

  factory InvoiceSummary.of(
    Iterable<InvoiceModel> invoices, {
    required DateTime now,
  }) {
    var count = 0;
    var paid = 0;
    var overdue = 0;
    var unpaidCents = 0;
    var unpaidDrafts = 0;
    for (final invoice in invoices) {
      if (invoice.status == InvoiceStatus.voided) continue;
      count++;
      if (invoice.status == InvoiceStatus.paid) paid++;
      if (invoice.isOverdueAt(now)) overdue++;
      if (invoiceIsUnpaid(invoice)) {
        unpaidCents += (invoice.balance * 100).round();
        if (invoice.status == InvoiceStatus.draft) unpaidDrafts++;
      }
    }
    return InvoiceSummary(
      count: count,
      paid: paid,
      overdue: overdue,
      unpaidAmount: unpaidCents / 100,
      unpaidDrafts: unpaidDrafts,
    );
  }
}

/// Whether [invoice] still has money owed on it: open (draft, sent or
/// overdue, so not paid or voided) with a balance above zero.
bool invoiceIsUnpaid(InvoiceModel invoice) =>
    invoiceIsOpen(invoice.status) && invoice.balance > 0;

/// Whether [invoice] belongs under the status chip [filter] (null is "All").
///
/// "All" leaves voided invoices out, as the Invoices count does; they have a
/// chip of their own. "Overdue" is worked out from the due date and balance
/// rather than read from the stored status, which nothing sets to overdue, so
/// the chip lists what the Overdue card counts.
bool invoiceMatchesStatusFilter(
  InvoiceModel invoice,
  InvoiceStatus? filter, {
  required DateTime now,
}) {
  switch (filter) {
    case null:
      return invoice.status != InvoiceStatus.voided;
    case InvoiceStatus.overdue:
      return invoice.isOverdueAt(now);
    case InvoiceStatus.draft:
    case InvoiceStatus.sent:
    case InvoiceStatus.paid:
    case InvoiceStatus.voided:
      return invoice.status == filter;
  }
}
