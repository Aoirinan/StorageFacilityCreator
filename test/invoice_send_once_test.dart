import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/providers/invoice_provider.dart';
import 'package:sfcapp/screens/invoice_detail_screen.dart';

final _invoice = InvoiceModel(
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
  // Set, so the page does not offer to make one.
  pdfUrl: 'https://example.com/i1.pdf',
  createdAt: DateTime(2026, 9, 1),
  createdBy: 'owner',
);

/// Each call emails the invoice to the tenant.
class _FakeOperations extends InvoiceOperationsNotifier {
  _FakeOperations(this.result);

  final Future<void> Function() result;
  int sends = 0;

  @override
  Future<void> sendInvoice({
    required String facilityId,
    required String invoiceId,
  }) {
    sends++;
    return result();
  }
}

void main() {
  // The send buttons stayed live while a send ran, so a second tap emailed
  // the tenant the same invoice twice.
  testWidgets('Send to tenant is off while a send is running',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sending = Completer<void>();
    final operations = _FakeOperations(() => sending.future);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          invoiceOperationsProvider.overrideWith((ref) => operations),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: InvoiceDetailScreen(invoice: _invoice, facilityId: 'f1'),
          ),
        ),
      ),
    );
    await tester.pump();

    final send = find.widgetWithText(ElevatedButton, 'Send to tenant');
    await tester.tap(send);
    await tester.pump();
    expect(operations.sends, 1);
    expect(tester.widget<ElevatedButton>(send).onPressed, isNull);

    await tester.tap(send, warnIfMissed: false);
    await tester.pump();
    expect(operations.sends, 1);

    sending.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    // Live again afterwards: resending is a deliberate choice.
    expect(tester.widget<ElevatedButton>(send).onPressed, isNotNull);
  });

  // The real InvoiceOperationsNotifier and InvoiceService: with no Firebase
  // app in tests the send fails, as it does offline. The notifier swallowed
  // that, so the page said "Invoice sent successfully".
  testWidgets('a failed send is not reported as sent', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: InvoiceDetailScreen(invoice: _invoice, facilityId: 'f1'),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send to tenant'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.text('Invoice sent successfully'), findsNothing);
    expect(find.textContaining('Error sending invoice'), findsOneWidget);
  });
}
