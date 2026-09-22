/// What may be changed on an invoice after it has been generated, and why.
///
/// The amounts are deliberately not editable: they are derived from posted
/// ledger entries, and letting someone retype a total would put the invoice and
/// the ledger into disagreement with no record of which one is right. To change
/// what is owed, void the invoice and generate a new one from the corrected
/// charges. Everything here is presentation: when it is due, what it says, and
/// what it is called.
library;

import 'package:sfcapp/models/invoice_model.dart';

/// The due date and notes can be changed on anything except a voided invoice.
///
/// A paid invoice is included on purpose: notes are where an operator records
/// how it was settled, and that is most often written after the fact.
bool canEditDueDateAndNotes(InvoiceStatus status) {
  return status != InvoiceStatus.voided;
}

/// The invoice number can be changed only while the invoice is a draft.
///
/// Once it has been sent, the tenant is holding a document with that number on
/// it, and renumbering it in the operator's system means the two no longer
/// refer to the same thing when someone calls about it.
bool canEditInvoiceNumber(InvoiceStatus status) {
  return status == InvoiceStatus.draft;
}

/// Why the number cannot be edited, phrased for the operator.
String invoiceNumberLockReason(InvoiceStatus status) {
  switch (status) {
    case InvoiceStatus.draft:
      return '';
    case InvoiceStatus.sent:
    case InvoiceStatus.overdue:
      return 'The tenant already has this invoice with this number on it, so '
          'the number is fixed. Void it and generate a new one to renumber.';
    case InvoiceStatus.paid:
      return 'This invoice has been paid, so its number stays as a record of '
          'that payment.';
    case InvoiceStatus.voided:
      return 'This invoice is voided.';
  }
}

/// Checks an operator-supplied invoice number.
///
/// [existingNumbers] is every other invoice number already used at this
/// facility. Returns an error message, or null when the number is usable.
/// Anything printable is allowed, because operators migrating off a paper book
/// or a spreadsheet want to keep their own sequence rather than adopt ours.
String? validateInvoiceNumber(String? value, {required Iterable<String> existingNumbers}) {
  final number = value?.trim() ?? '';
  if (number.isEmpty) {
    return 'Give the invoice a number';
  }
  if (number.length > 40) {
    return 'Keep it to 40 characters or fewer';
  }
  final taken = existingNumbers.any(
    (other) => other.trim().toLowerCase() == number.toLowerCase(),
  );
  if (taken) {
    return 'Another invoice at this facility already uses that number';
  }
  return null;
}
