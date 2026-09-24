import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/email_service.dart';
import 'package:sfcapp/services/invoice_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

// An invoice from the ledger's Generate Invoice: no PDF yet.
final _invoice = InvoiceModel(
  id: 'i1',
  tenantId: 't1',
  facilityId: 'f1',
  invoiceNumber: 'INV-2026-001',
  status: InvoiceStatus.draft,
  issueDate: DateTime(2026, 9, 1),
  dueDate: DateTime(2026, 9, 15),
  subtotal: 100,
  total: 100,
  balance: 100,
  lineItems: const [],
  ledgerEntryIds: const [],
  paymentIds: const [],
  createdAt: DateTime(2026, 9, 1),
  createdBy: 'owner',
);

TenantModel _tenant({String email = 'pat@example.com'}) => TenantModel(
      id: 't1',
      facilityId: 'f1',
      name: 'Pat Renter',
      email: email,
      phone: '',
      unitNumber: 'A1',
      monthlyRate: 100,
      createdAt: DateTime(2026, 1, 1),
    );

final _facility = FacilityModel(
  id: 'f1',
  name: 'Oak Storage',
  ownerUid: 'owner-1',
  createdAt: DateTime(2026, 1, 1),
);

/// What a send did, in order.
class _Steps {
  final log = <String>[];
  final emails = <({String to, String subject, String html, String text})>[];
  bool emailFails = false;
  bool attachFails = false;
  bool markFails = false;

  Future<void> send(InvoiceModel invoice, {TenantModel? tenant}) =>
      InvoiceService.deliverInvoice(
        invoice: invoice,
        tenant: tenant ?? _tenant(),
        facility: _facility,
        attachPdf: () async {
          log.add('attach');
          if (attachFails) throw Exception('storage/unauthorized');
          return 'https://example.com/new.pdf';
        },
        sendEmail: (email) async {
          log.add('email');
          emails.add(email);
          return emailFails
              ? const EmailResult(
                  success: false,
                  errorCode: 'recipient-unsubscribed',
                )
              : const EmailResult(success: true, messageId: 'm1');
        },
        markSent: () async {
          log.add('mark sent');
          if (markFails) throw Exception('permission-denied');
        },
      );
}

Future<String> _refusal(Future<void> send) async {
  try {
    await send;
  } catch (e) {
    return ErrorMessageHelper.getUserFriendlyMessage(e);
  }
  fail('the send went through');
}

void main() {
  // Send marked the invoice Sent first and emailed only when it had a PDF,
  // so Send on a new invoice said "Invoice sent successfully" and marked it
  // Sent with nothing emailed.
  test('an invoice with no PDF gets one, is emailed, then marked sent',
      () async {
    final steps = _Steps();
    await steps.send(_invoice);
    expect(steps.log, ['attach', 'email', 'mark sent']);
    expect(steps.emails.single.to, 'pat@example.com');
    expect(steps.emails.single.html, contains('https://example.com/new.pdf'));
    expect(steps.emails.single.text, contains('https://example.com/new.pdf'));
  });

  test('an invoice with a PDF is not given another', () async {
    final steps = _Steps();
    await steps.send(_invoice.copyWith(pdfUrl: 'https://example.com/i1.pdf'));
    expect(steps.log, ['email', 'mark sent']);
    expect(steps.emails.single.html, contains('https://example.com/i1.pdf'));
  });

  test('a tenant with no email address: nothing done, and it says so',
      () async {
    final steps = _Steps();
    expect(
      await _refusal(steps.send(_invoice, tenant: _tenant(email: '  '))),
      'Pat Renter has no email address, so the invoice was not sent. '
      'Add one to their profile, then send it again.',
    );
    expect(steps.log, isEmpty);
  });

  test('a failed email leaves the invoice unsent and says why', () async {
    final steps = _Steps()..emailFails = true;
    expect(
      await _refusal(steps.send(_invoice)),
      startsWith('The invoice email was not sent: This tenant has '
          'unsubscribed'),
    );
    expect(steps.log, ['attach', 'email']);
  });

  test('a PDF that cannot be attached: nothing emailed or marked', () async {
    final steps = _Steps()..attachFails = true;
    expect(
      await _refusal(steps.send(_invoice)),
      startsWith('The invoice PDF could not be attached, so nothing was sent'),
    );
    expect(steps.log, ['attach']);
  });

  // Reported as a failure, it invited a second send: a second email.
  test('emailed but not marked sent says not to send it again', () async {
    final steps = _Steps()..markFails = true;
    final message = await _refusal(steps.send(_invoice));
    expect(message, contains('emailed to pat@example.com'));
    expect(message, contains('Do not send it again.'));
    expect(steps.emails, hasLength(1));
  });

  // A page opened before the invoice was paid or voided still offered Send,
  // and the write put a paid invoice back to Sent.
  for (final status in [InvoiceStatus.paid, InvoiceStatus.voided]) {
    test('a ${status.name} invoice is not sent', () async {
      final steps = _Steps();
      expect(
        await _refusal(steps.send(_invoice.copyWith(status: status))),
        'This invoice is ${status.name}, so it was not sent.',
      );
      expect(steps.log, isEmpty);
    });
  }

  test('overdue and already-sent invoices can be sent again', () async {
    for (final status in [InvoiceStatus.sent, InvoiceStatus.overdue]) {
      final steps = _Steps();
      await steps.send(_invoice.copyWith(status: status));
      expect(steps.log, ['attach', 'email', 'mark sent'], reason: status.name);
    }
  });

  // sendInvoice needs Firebase for its reads, so how it hands its writes to
  // deliverInvoice is checked in its source: the status write must be the
  // markSent step, not a write before the email.
  test('sendInvoice writes status sent only through markSent', () {
    final source =
        File('lib/services/invoice_service.dart').readAsStringSync();
    final start = source.indexOf('static Future<void> sendInvoice(');
    final end = source.indexOf('static Future<void> deliverInvoice(');
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final sendInvoice = source.substring(start, end);
    expect(sendInvoice, contains('await deliverInvoice('));
    final statusWrites =
        RegExp(r"'status': InvoiceStatus\.sent\.name").allMatches(sendInvoice);
    expect(statusWrites, hasLength(1));
    expect(
      statusWrites.single.start,
      greaterThan(sendInvoice.indexOf('markSent: () =>')),
    );
  });
}
