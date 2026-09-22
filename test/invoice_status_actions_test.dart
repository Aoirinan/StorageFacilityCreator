import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/invoice_status_actions.dart';

/// An invoice is a demand for money. What may be done to it decides whether a
/// tenant can be chased, settled, or left holding a bill nobody can withdraw.
void main() {
  test('an open invoice can be sent, settled or withdrawn', () {
    for (final status in [
      InvoiceStatus.draft,
      InvoiceStatus.sent,
      InvoiceStatus.overdue,
    ]) {
      final actions = availableInvoiceActions(status);
      expect(actions, contains(InvoiceAction.send), reason: '$status');
      expect(actions, contains(InvoiceAction.markPaid), reason: '$status');
      expect(actions, contains(InvoiceAction.voidInvoice), reason: '$status');
    }
  });

  test('an overdue invoice can still be resent', () {
    // Overdue is an open invoice past its date, not a separate end state. If
    // it dropped send, the one invoice most worth chasing could not be.
    expect(
      availableInvoiceActions(InvoiceStatus.overdue),
      contains(InvoiceAction.send),
    );
  });

  test('a closed invoice offers nothing', () {
    expect(availableInvoiceActions(InvoiceStatus.paid), isEmpty);
    expect(availableInvoiceActions(InvoiceStatus.voided), isEmpty);
  });

  test('a paid invoice cannot be voided from a button', () {
    // Voiding a paid invoice changes what the tenant owes with no record of
    // why. That is a correction with a paper trail, not a tap.
    expect(
      availableInvoiceActions(InvoiceStatus.paid),
      isNot(contains(InvoiceAction.voidInvoice)),
    );
  });

  test('a voided invoice cannot be sent to the tenant', () {
    expect(
      availableInvoiceActions(InvoiceStatus.voided),
      isNot(contains(InvoiceAction.send)),
    );
  });

  test('invoiceIsOpen agrees with what the status allows', () {
    expect(invoiceIsOpen(InvoiceStatus.draft), isTrue);
    expect(invoiceIsOpen(InvoiceStatus.sent), isTrue);
    expect(invoiceIsOpen(InvoiceStatus.overdue), isTrue);
    expect(invoiceIsOpen(InvoiceStatus.paid), isFalse);
    expect(invoiceIsOpen(InvoiceStatus.voided), isFalse);
  });

  test('every status is covered, so a new one cannot be forgotten', () {
    for (final status in InvoiceStatus.values) {
      expect(() => availableInvoiceActions(status), returnsNormally);
    }
  });

  test('only voiding is styled as destructive', () {
    expect(InvoiceAction.voidInvoice.isDestructive, isTrue);
    expect(InvoiceAction.send.isDestructive, isFalse);
    expect(InvoiceAction.markPaid.isDestructive, isFalse);
  });

  test('every action has a label a person can read', () {
    for (final action in InvoiceAction.values) {
      expect(action.label.trim(), isNotEmpty, reason: '$action');
    }
  });
}
