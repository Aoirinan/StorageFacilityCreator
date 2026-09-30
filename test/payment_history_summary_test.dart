import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/payment_month_status.dart';
import 'package:sfcapp/widgets/payment_history_summary.dart';

// Fake data only: this repo is public.
TenantModel _tenant({
  DateTime? moveInDate,
  DateTime? paidThrough,
  Map<String, String> overrides = const {},
}) =>
    TenantModel(
      id: 'tenant-1',
      facilityId: 'facility-1',
      name: 'Test Tenant',
      email: 'tenant@example.com',
      phone: '555-0100',
      unitNumber: 'A1',
      monthlyRate: 50,
      moveInDate: moveInDate,
      createdAt: DateTime(2026, 9, 20),
      paidThrough: paidThrough,
      monthStatusOverrides: overrides,
    );

LedgerEntry _entry(String id, LedgerEntryType type, double amount) => LedgerEntry(
      id: id,
      tenantId: 'tenant-1',
      facilityId: 'facility-1',
      type: type,
      amount: amount,
      entryDate: DateTime(2026, 8, 17),
      status: LedgerEntryStatus.posted,
      createdAt: DateTime(2026, 8, 17),
      createdBy: 'owner',
    );

/// A payment as Enter past history posts it: dated the day it came in, the
/// check number in metadata.reference, linked to its payments doc.
LedgerEntry _historyPayment(
  String id,
  DateTime received,
  double amount, {
  String method = 'check',
  String? reference,
  bool monthOnly = false,
  LedgerEntryStatus status = LedgerEntryStatus.posted,
}) =>
    LedgerEntry(
      id: id,
      tenantId: 'tenant-1',
      facilityId: 'facility-1',
      type: LedgerEntryType.payment,
      amount: -amount,
      referenceId: 'pay-$id',
      entryDate: received,
      status: status,
      metadata: {
        'paymentMethod': method,
        'paymentId': 'pay-$id',
        if (reference != null) 'reference': reference,
        if (monthOnly) 'dateIsMonthOnly': true,
        'source': 'past_history',
      },
      createdAt: DateTime(2026, 9, 25),
      createdBy: 'owner',
    );

Color? _monthColor(WidgetTester tester, String key) {
  final text = tester.widget<Text>(
    find.descendant(of: find.byKey(ValueKey('payment-month-$key')), matching: find.byType(Text)),
  );
  return text.style?.color;
}

void main() {
  final today = DateTime(2026, 9, 28);

  Future<void> pump(
    WidgetTester tester,
    TenantModel tenant,
    List<LedgerEntry> entries, {
    void Function(DateTime, PaymentMonthStatus)? onTap,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PaymentHistorySummary(
              tenant: tenant,
              entries: entries,
              today: today,
              onMonthTap: onTap,
            ),
          ),
        ),
      ));

  testWidgets('August move-in paid through September with a \$0 balance shows no late months',
      (tester) async {
    await pump(
      tester,
      _tenant(moveInDate: DateTime.utc(2026, 8, 17, 12), paidThrough: DateTime(2026, 9, 30)),
      [
        _entry('c1', LedgerEntryType.rentCharge, 100),
        _entry('p1', LedgerEntryType.payment, -100),
      ],
    );

    expect(find.text('Late: '), findsOneWidget);
    final late = tester.widget<Text>(find.descendant(
      of: find.ancestor(of: find.text('Late: '), matching: find.byType(Row)).first,
      matching: find.text('0'),
    ));
    expect(late.data, '0');
    expect(find.text('Oct 25'), findsOneWidget);
    expect(_monthColor(tester, '2025-10'), AppTheme.textTertiary);
    expect(_monthColor(tester, '2026-07'), AppTheme.textTertiary);
    expect(_monthColor(tester, '2026-08'), AppTheme.success);
    expect(_monthColor(tester, '2026-09'), AppTheme.success);
    expect(find.textContaining('not counted as late'), findsOneWidget);
  });

  testWidgets('unpaid months with a positive balance are late', (tester) async {
    await pump(
      tester,
      _tenant(moveInDate: DateTime(2026, 5, 1), paidThrough: DateTime(2026, 7, 31)),
      [_entry('c1', LedgerEntryType.rentCharge, 100)],
    );
    expect(_monthColor(tester, '2026-04'), AppTheme.textTertiary);
    expect(_monthColor(tester, '2026-07'), AppTheme.success);
    expect(_monthColor(tester, '2026-08'), AppTheme.error);
    expect(_monthColor(tester, '2026-09'), AppTheme.error);
  });

  testWidgets('past history payments are listed with their dates and check numbers', (tester) async {
    // Typed in on Sep 20 with that day as move-in; Enter past history then
    // posted March to July and left the move-in date alone.
    await pump(
      tester,
      _tenant(moveInDate: DateTime(2026, 9, 20), paidThrough: DateTime(2026, 7, 31)),
      [
        for (var m = 3; m <= 7; m++) _entry('c$m', LedgerEntryType.rentCharge, 65),
        _historyPayment('p3', DateTime(2026, 3, 4), 65, reference: '301'),
        _historyPayment('p4', DateTime(2026, 4, 2), 65, reference: '302'),
        _historyPayment('p5', DateTime(2026, 5, 6), 65, reference: '303'),
        _historyPayment('p6', DateTime(2026, 6, 3), 65, reference: '304'),
        _historyPayment('p7', DateTime(2026, 7, 1), 65, method: 'cash', monthOnly: true),
        // Taken back by Undo: not a payment received.
        _historyPayment('p0', DateTime(2026, 2, 5), 65, reference: '300', status: LedgerEntryStatus.voided),
      ],
    );

    expect(find.text('Payments received'), findsOneWidget);
    expect(find.text('Mar 4, 2026'), findsOneWidget);
    expect(find.text('Check #301'), findsOneWidget);
    expect(find.text('Jun 3, 2026'), findsOneWidget);
    expect(find.text('Check #304'), findsOneWidget);
    // Known only by its month: the day is not made up.
    expect(find.text('Jul 2026'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('Check #300'), findsNothing);

    // Each payment once, newest first.
    final rows = tester
        .widgetList<Padding>(find.byWidgetPredicate(
            (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('received-payment-')))
        .map((w) => (w.key! as ValueKey<String>).value)
        .toList();
    expect(rows, [
      'received-payment-p7',
      'received-payment-p6',
      'received-payment-p5',
      'received-payment-p4',
      'received-payment-p3',
    ]);
    expect(find.text('\$65.00'), findsNWidgets(5));

    // The months those checks paid are no longer "Before move-in".
    expect(_monthColor(tester, '2026-02'), AppTheme.textTertiary);
    expect(_monthColor(tester, '2026-03'), AppTheme.success);
    expect(_monthColor(tester, '2026-07'), AppTheme.success);
  });

  testWidgets('a tenant with no payments says so', (tester) async {
    await pump(
      tester,
      _tenant(moveInDate: DateTime(2026, 8, 17)),
      [_entry('c1', LedgerEntryType.rentCharge, 100)],
    );
    expect(find.text('No payments on the ledger yet.'), findsOneWidget);
  });

  testWidgets('the list stops at the limit and points to the ledger', (tester) async {
    await pump(
      tester,
      _tenant(moveInDate: DateTime(2025, 1, 1), paidThrough: DateTime(2026, 9, 30)),
      [
        for (var i = 0; i < PaymentHistorySummary.receivedListLimit + 2; i++)
          _historyPayment('p$i', DateTime(2025, 1 + i, 5), 65, reference: '${700 + i}'),
      ],
    );
    expect(find.text('Check #713'), findsOneWidget); // newest
    expect(find.text('Check #702'), findsOneWidget);
    expect(find.text('Check #701'), findsNothing);
    expect(find.text('Check #700'), findsNothing);
    expect(find.text('2 earlier payments on the ledger (View Ledger).'), findsOneWidget);
  });

  testWidgets('a stored status is shown and clicking a month reports it', (tester) async {
    DateTime? tappedMonth;
    PaymentMonthStatus? tappedStatus;
    await pump(
      tester,
      _tenant(
        moveInDate: DateTime(2026, 8, 17),
        paidThrough: DateTime(2026, 9, 30),
        overrides: {'2026-02': 'late'},
      ),
      const [],
      onTap: (m, s) {
        tappedMonth = m;
        tappedStatus = s;
      },
    );
    expect(_monthColor(tester, '2026-02'), AppTheme.error);

    await tester.tap(find.text('Feb 26'));
    expect(tappedMonth, DateTime(2026, 2, 1));
    expect(tappedStatus, PaymentMonthStatus.late);

    // Months before move-in can still be set by hand.
    await tester.tap(find.text('Jan 26'));
    expect(tappedMonth, DateTime(2026, 1, 1));
    expect(tappedStatus, PaymentMonthStatus.beforeMoveIn);
  });

  testWidgets('months cannot be clicked while a change is saving', (tester) async {
    await pump(tester, _tenant(paidThrough: DateTime(2026, 9, 30)), const []);
    final inkWells = tester.widgetList<InkWell>(find.byType(InkWell));
    expect(inkWells, hasLength(12));
    expect(inkWells.every((w) => w.onTap == null), isTrue);
  });

  testWidgets('a refund is not a payment made', (tester) async {
    await pump(
      tester,
      _tenant(moveInDate: DateTime(2026, 8, 17), paidThrough: DateTime(2026, 9, 30)),
      [
        _entry('p1', LedgerEntryType.payment, -50),
        _entry('r1', LedgerEntryType.refund, 50),
      ],
    );
    final made = tester.widget<Text>(find.descendant(
      of: find.ancestor(of: find.text('Payments made: '), matching: find.byType(Row)).first,
      matching: find.text('1'),
    ));
    expect(made.data, '1');
  });
}
