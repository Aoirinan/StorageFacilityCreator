import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/screens/ledger_screen.dart';

final _tenant = TenantModel(
  id: 't1',
  facilityId: 'f1',
  name: 'Pat Example',
  email: '',
  phone: '',
  unitNumber: 'B-14',
  monthlyRate: 50,
  createdAt: DateTime(2026, 1, 1),
);

LedgerEntry _entry(String id, LedgerEntryType type, double amount,
        DateTime at, String description) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: type,
      amount: amount,
      description: description,
      entryDate: at,
      status: LedgerEntryStatus.posted,
      createdAt: at,
      createdBy: 'owner',
    );

/// Rent on the 1st, a check on the 15th, a late fee on the 31st, all in a
/// month that is over, so the date picker (which stops at today) accepts
/// every date typed here.
final _entries = [
  _entry('r', LedgerEntryType.rentCharge, 50, DateTime(2026, 1, 1, 12), 'January rent'),
  _entry('p', LedgerEntryType.payment, -50, DateTime(2026, 1, 15, 12), 'Check #1001'),
  _entry('l', LedgerEntryType.lateFee, 10, DateTime(2026, 1, 31, 12), 'Late fee'),
];

Future<void> _pumpLedger(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    overrides: [
      ledgerStreamProvider(
        LedgerParams(tenantId: _tenant.id, facilityId: _tenant.facilityId),
      ).overrideWith((ref) => Stream.value(_entries)),
      facilityTenantsProvider('f1')
          .overrideWith((ref) => Stream.value([_tenant])),
    ],
    child: MaterialApp(
      home: Scaffold(body: LedgerScreen(tenant: _tenant)),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openFilter(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Filter'));
  await tester.pumpAndSettle();
  expect(find.text('Filter Ledger'), findsOneWidget);
}

/// The date the dialog shows for a picked date (the ledger cards behind it
/// print their entry dates the same way).
Finder _dialogDate(String mmddyyyy) => find.descendant(
    of: find.byType(AlertDialog), matching: find.text(mmddyyyy));

/// Picks [mmddyyyy] in the date picker behind [tooltip], typing it: the
/// calendar opens on this month, and the test's dates are not in it.
Future<void> _pickDate(
    WidgetTester tester, String tooltip, String mmddyyyy) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Switch to input'));
  await tester.pumpAndSettle();
  await tester.enterText(
      find.descendant(
          of: find.byType(DatePickerDialog), matching: find.byType(TextField)),
      mmddyyyy);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Cancel leaves the ledger as it was, whatever was picked',
      (tester) async {
    await _pumpLedger(tester);
    await _openFilter(tester);
    await _pickDate(tester, 'Pick end date', '01/15/2026');
    // The dialog shows the pick...
    expect(_dialogDate('01/15/2026'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // ...and the screen never took it. It used to: the dialog wrote the
    // screen's fields as each date was picked.
    expect(find.textContaining('To: 01/15/2026'), findsNothing);
    expect(find.text('January rent'), findsOneWidget);
    expect(find.text('Check #1001'), findsOneWidget);
    expect(find.text('Late fee'), findsOneWidget);

    // The screen only showed the old bug at its next rebuild, and nothing
    // above forced one, so look where the pick would have landed: the dialog
    // opens on the screen's dates, and End Date must still be None.
    await _openFilter(tester);
    expect(
        find.descendant(
            of: find.widgetWithText(ListTile, 'End Date'),
            matching: find.text('None')),
        findsOneWidget);
    expect(_dialogDate('01/15/2026'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Opening and closing the dialog rebuilt the screen behind it; the
    // filter bar still shows no end date and every entry is still there.
    expect(find.textContaining('To:'), findsNothing);
    expect(find.text('January rent'), findsOneWidget);
    expect(find.text('Check #1001'), findsOneWidget);
    expect(find.text('Late fee'), findsOneWidget);
  });

  testWidgets('Apply keeps entries on the end day; Clear puts every date back',
      (tester) async {
    await _pumpLedger(tester);
    await _openFilter(tester);
    await _pickDate(tester, 'Pick end date', '01/15/2026');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.textContaining('To: 01/15/2026'), findsOneWidget);
    expect(find.text('January rent'), findsOneWidget);
    // Dated noon on the end day: it prints on the statement for this period,
    // and the screen used to hide it, comparing against the day's midnight.
    expect(find.text('Check #1001'), findsOneWidget);
    expect(find.text('Late fee'), findsNothing);

    await _openFilter(tester);
    expect(_dialogDate('01/15/2026'), findsOneWidget);
    // The dialog's Clear, not the filter bar's behind it.
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Clear')));
    await tester.pumpAndSettle();

    expect(find.textContaining('To:'), findsNothing);
    expect(find.text('Late fee'), findsOneWidget);
  });

  testWidgets('a start date hides what came before it', (tester) async {
    await _pumpLedger(tester);
    await _openFilter(tester);
    await _pickDate(tester, 'Pick start date', '01/15/2026');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(find.textContaining('From: 01/15/2026'), findsOneWidget);
    expect(find.text('January rent'), findsNothing);
    expect(find.text('Check #1001'), findsOneWidget);
    expect(find.text('Late fee'), findsOneWidget);
  });
}
