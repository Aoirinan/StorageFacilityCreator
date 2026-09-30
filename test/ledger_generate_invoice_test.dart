import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/invoice_provider.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/detail_routes.dart';
import 'package:sfcapp/services/invoice_service.dart';
import 'package:sfcapp/widgets/ledger_entry_card.dart';

final _tenant = TenantModel(
  id: 't1',
  facilityId: 'f1',
  name: 'Pat Example',
  email: 'pat@example.com',
  phone: '',
  unitNumber: '12',
  monthlyRate: 130,
  createdAt: DateTime(2026, 1, 1),
);

const _ledgerParams = LedgerParams(tenantId: 't1', facilityId: 'f1');
const _invoiceParams = InvoiceParams(tenantId: 't1', facilityId: 'f1');

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
];

LedgerEntry _entry(
  String id, {
  required double amount,
  required DateTime on,
  DateTime? due,
  LedgerEntryType? type,
  String? description,
}) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: type ??
          (amount < 0 ? LedgerEntryType.payment : LedgerEntryType.rentCharge),
      amount: amount,
      description: description,
      entryDate: on,
      dueDate: due,
      status: LedgerEntryStatus.posted,
      createdAt: on,
      createdBy: 'owner',
    );

/// A fictional tenant's year so far: $130 rent on the first of each month
/// from January to September, and $737 paid by check. They owe $433. The
/// rent carries a due date, as move-in and monthly rent charges do.
final _nineMonths = [
  for (var m = 1; m <= 9; m++)
    _entry(
      'rent-2026-${m.toString().padLeft(2, '0')}',
      amount: 130,
      on: DateTime(2026, m, 1),
      due: DateTime(2026, m, 1),
      description: 'Rent - ${_months[m - 1]} 2026',
    ),
  for (var m = 1; m <= 5; m++)
    _entry('check-$m', amount: -130, on: DateTime(2026, m, 10)),
  _entry('check-6', amount: -87, on: DateTime(2026, 6, 10)),
];

/// The tenant paid ahead: one charge, two payments.
final _inCredit = [
  _entry('rent-2026-09', amount: 130, on: DateTime(2026, 9, 1)),
  _entry('check-1', amount: -130, on: DateTime(2026, 9, 3)),
  _entry('check-2', amount: -130, on: DateTime(2026, 9, 20)),
];

final _generated = InvoiceModel(
  id: 'inv-1',
  tenantId: 't1',
  facilityId: 'f1',
  invoiceNumber: 'INV-2026-001',
  status: InvoiceStatus.draft,
  issueDate: DateTime(2026, 9, 28),
  dueDate: DateTime(2026, 10, 28),
  subtotal: 433,
  total: 433,
  balance: 433,
  lineItems: const [],
  ledgerEntryIds: const [],
  paymentIds: const [],
  createdAt: DateTime(2026, 9, 28),
  createdBy: 'owner',
);

/// Records what the ledger asked to invoice and hands back [_generated].
class _FakeOperations extends InvoiceOperationsNotifier {
  final requested = <List<String>?>[];

  @override
  Future<InvoiceModel> generateInvoice({
    required String tenantId,
    required String facilityId,
    List<String>? ledgerEntryIds,
    DateTime? issueDate,
    DateTime? dueDate,
    double? taxRate,
  }) async {
    requested.add(ledgerEntryIds);
    return _generated;
  }
}

GoRouter _router() {
  return GoRouter(
    initialLocation: _ledgerLocation,
    initialExtra: _tenant,
    routes: [
      ShellRoute(
        // The app's shell has a Scaffold, which the snackbars need.
        builder: (context, state, child) => Scaffold(body: child),
        routes: [
          // The app's ledger route, with the real ledger page.
          tenantLedgerRoute(),
          // The app's invoice page route reads the same extra; a stand-in
          // shows what it was given (the real page needs Firebase).
          GoRoute(
            path: AppRoute.invoiceDetail,
            builder: (context, state) {
              final extra = state.extra;
              if (extra is Map<String, dynamic>) {
                final invoice = extra['invoice'];
                final facilityId = extra['facilityId'];
                if (invoice is InvoiceModel && facilityId is String) {
                  return Text('INVOICE ${invoice.invoiceNumber} $facilityId');
                }
              }
              return const Text('NOT FOUND');
            },
          ),
          // Somewhere else to go, so a test can leave the ledger and return
          // to it, as an owner does by way of the invoice page and the
          // Invoices tab.
          GoRoute(
            path: _elsewhere,
            builder: (context, state) => const Text('ELSEWHERE'),
          ),
        ],
      ),
    ],
  );
}

const _ledgerLocation = '/tenants/t1/ledger?facilityId=f1';
const _elsewhere = '/elsewhere';

/// Pumps the real ledger page. [coverageNow] is what the tenant's live
/// invoices cover at the moment the ledger reads it; [coverage] is the
/// shorthand for a value that never changes.
Future<_FakeOperations> _pumpLedger(
  WidgetTester tester, {
  required List<LedgerEntry> entries,
  LiveInvoiceCoverage coverage =
      const LiveInvoiceCoverage(ledgerEntryIds: {}, balance: 0),
  LiveInvoiceCoverage Function()? coverageNow,
  Size size = const Size(1200, 2400),
  GoRouter? router,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final operations = _FakeOperations();
  final theRouter = router ?? _router();
  addTearDown(theRouter.dispose);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ledgerStreamProvider(_ledgerParams)
          .overrideWith((ref) => Stream.value(entries)),
      facilityTenantsProvider('f1')
          .overrideWith((ref) => Stream.value([_tenant])),
      liveInvoiceCoverageProvider(_invoiceParams)
          .overrideWith((ref) async => (coverageNow ?? () => coverage)()),
      invoiceOperationsProvider.overrideWith((ref) => operations),
    ],
    child: MaterialApp.router(routerConfig: theRouter),
  ));
  await tester.pumpAndSettle();
  return operations;
}

final _headerButton = find.widgetWithText(FilledButton, 'Generate Invoice');
final _dialogButton = find.widgetWithText(ElevatedButton, 'Generate Invoice');

/// Text in the Generate Invoice dialog; the ledger's cards behind it show
/// the same descriptions and amounts.
Finder _inDialog(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

void main() {
  // On a live facility Generate Invoice offered nine months of rent, $1,170,
  // to a tenant whose ledger balance was $433, because it took every charge
  // without allocatedAmount as unpaid and nothing but move-in writes that.
  // The saved invoice then vanished from view: a four-second "Invoice
  // generated successfully" and nothing on the ledger, so the owner asked
  // where it went.
  testWidgets('previews the balance, saves it, says where it went and opens it',
      (tester) async {
    final operations = await _pumpLedger(tester, entries: _nineMonths);
    expect(find.text('\$433.00'), findsOneWidget); // Current Balance

    await tester.tap(_headerButton);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      _inDialog('This will create an invoice for 4 charge(s) to invoice:'),
      findsOneWidget,
    );
    expect(_inDialog('Rent - September 2026'), findsOneWidget);
    expect(_inDialog('Rent - August 2026'), findsOneWidget);
    expect(_inDialog('Rent - July 2026'), findsOneWidget);
    expect(_inDialog('Rent - June 2026 (balance)'), findsOneWidget);
    expect(_inDialog('\$43.00'), findsOneWidget);
    // Paid months are not on it.
    expect(_inDialog('Rent - May 2026'), findsNothing);
    // The dialog's total is the balance.
    expect(_inDialog('\$433.00'), findsOneWidget);

    await tester.tap(_dialogButton);
    await tester.pumpAndSettle();

    expect(operations.requested, [
      ['rent-2026-09', 'rent-2026-08', 'rent-2026-07', 'rent-2026-06'],
    ]);
    expect(
      find.text('Invoice INV-2026-001 saved as a draft. You can find it later '
          'under Rent & payments › Invoices.'),
      findsOneWidget,
    );
    // On the invoice's page, built from the same extra the Invoices tab
    // passes.
    expect(find.text('INVOICE INV-2026-001 f1'), findsOneWidget);

    // Let the snackbar go.
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
  });

  testWidgets('a tenant in credit is told there is nothing to invoice',
      (tester) async {
    final operations = await _pumpLedger(tester, entries: _inCredit);

    await tester.tap(_headerButton);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('No balance due — nothing to invoice'), findsOneWidget);
    expect(operations.requested, isEmpty);

    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
  });

  // The state the owner's question came from: the ledger says $433 and an
  // earlier draft asks for every month, $1,170. "No balance due" under a
  // header reading $433.00 was false, and gave no hint that the draft had to
  // be voided before another could be made.
  testWidgets('a tenant whose balance a live invoice already asks for is sent '
      'to that invoice', (tester) async {
    final operations = await _pumpLedger(
      tester,
      entries: _nineMonths,
      coverage: LiveInvoiceCoverage(
        ledgerEntryIds: {for (var m = 1; m <= 9; m++) 'rent-2026-0$m'},
        balance: 1170,
      ),
    );
    expect(find.text('\$433.00'), findsOneWidget); // Current Balance

    await tester.tap(_headerButton);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('No balance due — nothing to invoice'), findsNothing);
    expect(
      find.text("This tenant's balance is already on an invoice: open invoices "
          'ask for \$1170.00 and the ledger balance is \$433.00. Void it or '
          'mark it paid under Rent & payments › Invoices before generating '
          'another.'),
      findsOneWidget,
    );
    expect(operations.requested, isEmpty);

    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
  });

  testWidgets('a live invoice already asking for part of the balance leaves '
      'only the rest', (tester) async {
    // September is on a draft invoice for $130.
    final operations = await _pumpLedger(
      tester,
      entries: _nineMonths,
      coverage: const LiveInvoiceCoverage(
        ledgerEntryIds: {'rent-2026-09'},
        balance: 130,
      ),
    );

    await tester.tap(_headerButton);
    await tester.pumpAndSettle();

    expect(
      _inDialog('This will create an invoice for 3 charge(s) to invoice:'),
      findsOneWidget,
    );
    expect(_inDialog('Rent - September 2026'), findsNothing);
    expect(_inDialog('\$303.00'), findsOneWidget);

    await tester.tap(_dialogButton);
    await tester.pumpAndSettle();
    expect(operations.requested, [
      ['rent-2026-08', 'rent-2026-07', 'rent-2026-06'],
    ]);

    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
  });

  // Nothing on the ledger showed which charges an invoice covered.
  testWidgets('charges on a live invoice are marked "On invoice"',
      (tester) async {
    await _pumpLedger(
      tester,
      entries: _nineMonths,
      coverage: const LiveInvoiceCoverage(
        ledgerEntryIds: {'rent-2026-09', 'rent-2026-08'},
        balance: 260,
      ),
    );

    expect(find.text('On invoice'), findsNWidgets(2));
    for (final month in ['September', 'August']) {
      final card = find.ancestor(
        of: find.text('Rent - $month 2026'),
        matching: find.byType(LedgerEntryCard),
      );
      expect(
        find.descendant(of: card, matching: find.text('On invoice')),
        findsOneWidget,
        reason: month,
      );
    }
  });

  // The owner voids the invoice from its page and comes back to the ledger
  // by way of the Invoices tab. The coverage was cached for the session, so
  // the voided invoice's charges still read "On invoice" until she generated
  // again or reloaded the app.
  testWidgets('the "On invoice" marks are read afresh on each visit to the '
      'ledger', (tester) async {
    var coverage = const LiveInvoiceCoverage(
      ledgerEntryIds: {'rent-2026-09', 'rent-2026-08'},
      balance: 260,
    );
    final router = _router();
    await _pumpLedger(
      tester,
      entries: _nineMonths,
      coverageNow: () => coverage,
      router: router,
    );
    expect(find.text('On invoice'), findsNWidgets(2));

    // Away from the ledger the invoice is voided.
    router.go(_elsewhere);
    await tester.pumpAndSettle();
    expect(find.text('ELSEWHERE'), findsOneWidget);
    expect(find.byType(LedgerEntryCard), findsNothing);
    coverage = const LiveInvoiceCoverage(ledgerEntryIds: {}, balance: 0);

    router.go(_ledgerLocation, extra: _tenant);
    await tester.pumpAndSettle();
    expect(find.byType(LedgerEntryCard), findsNWidgets(15));
    expect(find.text('On invoice'), findsNothing);
  });

  // On a phone the chip sat in the date row, which overflowed and was
  // clipped; with a due date that row overflowed even without it.
  testWidgets('at phone width the marked cards lay out without overflowing',
      (tester) async {
    await _pumpLedger(
      tester,
      entries: _nineMonths,
      coverage: const LiveInvoiceCoverage(
        ledgerEntryIds: {'rent-2026-09', 'rent-2026-08'},
        balance: 260,
      ),
      size: const Size(390, 844),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('On invoice'), findsNWidgets(2));
    expect(find.text('Due: 09/01/2026'), findsOneWidget);
  });
}
