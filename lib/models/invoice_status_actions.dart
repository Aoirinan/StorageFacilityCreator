import 'invoice_model.dart';

/// One thing an operator can do to an invoice from where it stands.
enum InvoiceAction {
  send,
  markPaid,
  voidInvoice,
}

extension InvoiceActionLabels on InvoiceAction {
  String get label {
    switch (this) {
      case InvoiceAction.send:
        return 'Send to tenant';
      case InvoiceAction.markPaid:
        return 'Mark paid';
      case InvoiceAction.voidInvoice:
        return 'Void invoice';
    }
  }

  bool get isDestructive => this == InvoiceAction.voidInvoice;
}

/// What may be done to an invoice sitting at [status].
///
/// An invoice is a demand for money, so the two ends are what matter: it can be
/// sent once it exists, and it can be settled or withdrawn while it is open.
/// A paid or voided invoice is closed, and reopening one by tapping a button
/// would change what a tenant owes with no record of why.
///
/// An overdue invoice is an open one that has passed its date, so everything an
/// open invoice allows it allows too, resending included.
List<InvoiceAction> availableInvoiceActions(InvoiceStatus status) {
  switch (status) {
    case InvoiceStatus.draft:
      return const [
        InvoiceAction.send,
        InvoiceAction.markPaid,
        InvoiceAction.voidInvoice,
      ];
    case InvoiceStatus.sent:
    case InvoiceStatus.overdue:
      return const [
        InvoiceAction.send,
        InvoiceAction.markPaid,
        InvoiceAction.voidInvoice,
      ];
    case InvoiceStatus.paid:
    case InvoiceStatus.voided:
      return const [];
  }
}

/// Whether an invoice at [status] is still open, meaning money may yet arrive
/// against it.
bool invoiceIsOpen(InvoiceStatus status) =>
    availableInvoiceActions(status).isNotEmpty;
