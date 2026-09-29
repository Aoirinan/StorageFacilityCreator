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
