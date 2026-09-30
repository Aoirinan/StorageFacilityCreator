import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/providers/invoice_provider.dart';
import 'package:sfcapp/screens/invoice_detail_screen.dart';

InvoiceModel _draft({String? pdfUrl}) => InvoiceModel(
      id: 'i1',
      tenantId: 't1',
      facilityId: 'f1',
      invoiceNumber: 'INV-1',
      status: InvoiceStatus.draft,
      issueDate: DateTime(2026, 9, 1),
      dueDate: DateTime(2026, 9, 15),
      subtotal: 100,
      total: 100,
      balance: 100,
      lineItems: const [],
      ledgerEntryIds: const [],
      paymentIds: const [],
      pdfUrl: pdfUrl,
      createdAt: DateTime(2026, 9, 1),
      createdBy: 'owner',
    );

// Set, so the page does not offer to make one.
final _invoice = _draft(pdfUrl: 'https://example.com/i1.pdf');

/// What a send comes back as: the invoice marked sent.
final _sent = _invoice.copyWith(
  status: InvoiceStatus.sent,
  sentAt: DateTime(2026, 9, 2, 10),
);

/// Each call emails the invoice to the tenant.
class _FakeOperations extends InvoiceOperationsNotifier {
  _FakeOperations(this.result, {this.pdfResult});

  final Future<InvoiceModel> Function() result;
  final Future<InvoiceModel> Function()? pdfResult;
  int sends = 0;
  int pdfs = 0;

  @override
  Future<InvoiceModel> sendInvoice({
    required String facilityId,
    required String invoiceId,
  }) {
    sends++;
    return result();
  }

  @override
  Future<InvoiceModel> generateAndUploadPDF({
    required InvoiceModel invoice,
    required String facilityId,
    required String invoiceId,
  }) {
    pdfs++;
    return pdfResult!();
  }
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required InvoiceModel invoice,
  InvoiceOperationsNotifier? operations,
}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (operations != null)
          invoiceOperationsProvider.overrideWith((ref) => operations),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: InvoiceDetailScreen(invoice: invoice, facilityId: 'f1'),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  // The send buttons stayed live while a send ran, so a second tap emailed
  // the tenant the same invoice twice.
  testWidgets('Send to tenant is off while a send is running',
      (tester) async {
    final sending = Completer<InvoiceModel>();
    final operations = _FakeOperations(() => sending.future);
    await _pumpPage(tester, invoice: _invoice, operations: operations);

    final send = find.widgetWithText(ElevatedButton, 'Send to tenant');
    await tester.tap(send);
    await tester.pump();
    expect(operations.sends, 1);
    expect(tester.widget<ElevatedButton>(send).onPressed, isNull);

    await tester.tap(send, warnIfMissed: false);
    await tester.pump();
    expect(operations.sends, 1);

    sending.complete(_sent);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    // Live again afterwards, as a resend: sending again is a deliberate
    // choice, and the button says so.
    expect(send, findsNothing);
    final resend = find.widgetWithText(ElevatedButton, 'Resend to tenant');
    expect(tester.widget<ElevatedButton>(resend).onPressed, isNotNull);
  });

  // The page showed a copy of the invoice taken when it opened, so after a
  // send it still said Draft and still offered "Send to tenant". An owner
  // who took that at its word emailed the tenant a second copy.
  testWidgets('after a send the page says Sent, and only Resend sends again',
      (tester) async {
    final operations = _FakeOperations(() async => _sent);
    await _pumpPage(tester, invoice: _invoice, operations: operations);
    expect(find.text('Draft'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send to tenant'));
    await tester.pumpAndSettle();
    expect(operations.sends, 1);
    expect(find.text('Invoice sent successfully'), findsOneWidget);

    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Draft'), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Send to tenant'), findsNothing);
    final resend = find.widgetWithText(ElevatedButton, 'Resend to tenant');
    expect(resend, findsOneWidget);

    await tester.tap(resend);
    await tester.pumpAndSettle();
    expect(operations.sends, 2);
    await tester.pump(const Duration(seconds: 5));
  });

  // Likewise "Attach PDF copy": the PDF was made and stored, but the page
  // never showed it and kept offering to attach one.
  testWidgets('after Attach PDF copy the PDF shows and the offer goes',
      (tester) async {
    final withPdf = _draft(pdfUrl: 'https://example.com/i1.pdf');
    final operations = _FakeOperations(
      () async => _sent,
      pdfResult: () async => withPdf,
    );
    await _pumpPage(tester, invoice: _draft(), operations: operations);
    expect(find.widgetWithText(ElevatedButton, 'Open in New Tab'),
        findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Attach PDF copy'));
    await tester.pumpAndSettle();
    expect(operations.pdfs, 1);

    expect(find.text('Attach PDF copy'), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Open in New Tab'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  // The real InvoiceOperationsNotifier and InvoiceService: with no Firebase
  // app in tests the send fails, as it does offline. The notifier swallowed
  // that, so the page said "Invoice sent successfully".
  testWidgets('a failed send is not reported as sent', (tester) async {
    await _pumpPage(tester, invoice: _invoice);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send to tenant'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.text('Invoice sent successfully'), findsNothing);
    expect(find.textContaining('Error sending invoice'), findsOneWidget);
    // Still a draft: nothing went.
    expect(find.text('Draft'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Send to tenant'), findsOneWidget);
  });

  // The page showed the error raw, e.g. "[cloud_firestore/permission-denied]
  // The caller does not have permission...".
  testWidgets('a refused send is explained, not shown raw', (tester) async {
    final operations = _FakeOperations(
      () async => throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
        message: 'The caller does not have permission.',
      ),
    );
    await _pumpPage(tester, invoice: _invoice, operations: operations);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Send to tenant'));
    await tester.pump();

    expect(find.textContaining('Error sending invoice: You don'), findsOneWidget);
    expect(find.textContaining('cloud_firestore'), findsNothing);
  });
}
