import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/utils/invoice_edit_rules.dart';

void main() {
  group('canEditDueDateAndNotes', () {
    test('allows editing on a draft, a sent invoice and an overdue one', () {
      expect(canEditDueDateAndNotes(InvoiceStatus.draft), isTrue);
      expect(canEditDueDateAndNotes(InvoiceStatus.sent), isTrue);
      expect(canEditDueDateAndNotes(InvoiceStatus.overdue), isTrue);
    });

    test('allows editing a paid invoice, because notes are written after the fact', () {
      expect(canEditDueDateAndNotes(InvoiceStatus.paid), isTrue);
    });

    test('refuses a voided invoice', () {
      expect(canEditDueDateAndNotes(InvoiceStatus.voided), isFalse);
    });
  });

  group('canEditInvoiceNumber', () {
    test('only a draft can be renumbered', () {
      expect(canEditInvoiceNumber(InvoiceStatus.draft), isTrue);
      expect(canEditInvoiceNumber(InvoiceStatus.sent), isFalse);
      expect(canEditInvoiceNumber(InvoiceStatus.overdue), isFalse);
      expect(canEditInvoiceNumber(InvoiceStatus.paid), isFalse);
      expect(canEditInvoiceNumber(InvoiceStatus.voided), isFalse);
    });

    test('a locked number explains itself in the operator\'s terms', () {
      expect(invoiceNumberLockReason(InvoiceStatus.draft), isEmpty);
      expect(invoiceNumberLockReason(InvoiceStatus.sent), contains('tenant already has'));
      expect(invoiceNumberLockReason(InvoiceStatus.paid), contains('paid'));
    });
  });

  group('validateInvoiceNumber', () {
    test('accepts an operator\'s own numbering, not just ours', () {
      expect(validateInvoiceNumber('2026-0041', existingNumbers: const []), isNull);
      expect(validateInvoiceNumber('Caprock 118', existingNumbers: const []), isNull);
      expect(validateInvoiceNumber('INV-2026-001', existingNumbers: const []), isNull);
    });

    test('requires something', () {
      expect(validateInvoiceNumber('', existingNumbers: const []), isNotNull);
      expect(validateInvoiceNumber('   ', existingNumbers: const []), isNotNull);
      expect(validateInvoiceNumber(null, existingNumbers: const []), isNotNull);
    });

    test('refuses a number another invoice already uses, ignoring case and spacing', () {
      const existing = ['INV-2026-001', 'INV-2026-002'];
      expect(validateInvoiceNumber('INV-2026-001', existingNumbers: existing), isNotNull);
      expect(validateInvoiceNumber('  inv-2026-002 ', existingNumbers: existing), isNotNull);
      expect(validateInvoiceNumber('INV-2026-003', existingNumbers: existing), isNull);
    });

    test('keeps the number short enough to print on a line', () {
      expect(
        validateInvoiceNumber('X' * 41, existingNumbers: const []),
        contains('40 characters'),
      );
      expect(validateInvoiceNumber('X' * 40, existingNumbers: const []), isNull);
    });
  });
}
