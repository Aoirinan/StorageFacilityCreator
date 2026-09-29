import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/screens/tenant_past_history_dialog.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/past_history_math.dart';

// All names are made up. The owner's case: moved in 2026-02-10 at $80 a
// month, paid $80 by Venmo on 2/10, 3/20, 4/19 and 5/31, then $160 on 6/1
// for June and July; owes August and September.

final _today = DateTime(2026, 9, 28);

LedgerEntry _rent(int year, int month, {double amount = 80, LedgerEntryStatus status = LedgerEntryStatus.posted}) {
  return LedgerEntry(
    id: 'rent-$year-$month',
    tenantId: 't1',
    facilityId: 'f1',
    type: LedgerEntryType.rentCharge,
    amount: amount,
    entryDate: DateTime.utc(year, month, 1, 12),
    status: status,
    metadata: {'recurringCharge': true, 'chargeType': 'monthlyRent', 'month': month, 'year': year},
    createdAt: DateTime.utc(year, month, 1, 12),
    createdBy: 'system',
  );
}

List<HistoryPaymentInput> _examplePayments() => [
      HistoryPaymentInput(date: DateTime(2026, 2, 10), amount: 80, method: PaymentMethod.venmo),
      HistoryPaymentInput(date: DateTime(2026, 3, 20), amount: 80, method: PaymentMethod.venmo),
      HistoryPaymentInput(date: DateTime(2026, 4, 19), amount: 80, method: PaymentMethod.venmo),
      HistoryPaymentInput(date: DateTime(2026, 5, 31), amount: 80, method: PaymentMethod.venmo),
      HistoryPaymentInput(date: DateTime(2026, 6, 1), amount: 160, method: PaymentMethod.venmo),
    ];

TenantModel _tenant() => TenantModel(
      id: 't1',
      facilityId: 'f1',
      name: 'Pat Example',
      email: '',
      phone: '',
      unitNumber: 'OUT-1',
      monthlyRate: 80,
      createdAt: DateTime(2026, 9, 27),
    );

Future<void> _pumpDialog(WidgetTester tester, List<LedgerEntry> ledger) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ledgerStreamProvider(const LedgerParams(tenantId: 't1', facilityId: 'f1'))
          .overrideWith((ref) => Stream.value(ledger)),
    ],
    child: MaterialApp(home: Scaffold(body: TenantPastHistoryDialog(tenant: _tenant(), today: _today))),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the dialog asks for the move-in date and shows what is already entered', (tester) async {
    final typed = DateTime(2026, 9, 27, 21);
    await _pumpDialog(tester, [
      for (var i = 0; i < 8; i++)
        LedgerEntry(
          id: 'hand-c$i',
          tenantId: 't1',
          facilityId: 'f1',
          type: LedgerEntryType.rentCharge,
          amount: 80,
          entryDate: typed,
          status: LedgerEntryStatus.posted,
          createdAt: typed,
          createdBy: 'owner',
        ),
      for (var i = 0; i < 4; i++)
        LedgerEntry(
          id: 'hand-p$i',
          tenantId: 't1',
          facilityId: 'f1',
          type: LedgerEntryType.payment,
          amount: i == 0 ? -160 : -80,
          entryDate: typed,
          status: LedgerEntryStatus.posted,
          createdAt: typed,
          createdBy: 'owner',
        ),
    ]);
    // No move-in date is guessed.
    expect(find.text('Choose move-in date *'), findsOneWidget);
    expect(find.text('Choose the move-in date to list the months.'), findsOneWidget);
    expect(
      find.text('This tenant already has 8 charges (\$640.00) and 4 payments (\$400.00) entered.'),
      findsOneWidget,
    );
    // Nothing is ticked to void until the owner asks, and the balance counts them.
    expect(find.text('Choose entries to void (0 ticked)'), findsOneWidget);
    expect(find.text('\$240.00'), findsOneWidget);
    await tester.tap(find.text('Choose entries to void (0 ticked)'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(13)); // 12 entries + the confirm box
    await tester.tap(find.text('Tick all 12'));
    await tester.pumpAndSettle();
    expect(find.text('Existing entries voided by this save'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
  });

  group('charge proposal', () {
    test('move-in month dated the move-in day, then the 1st, through this month', () {
      final p = proposeHistoryCharges(
        moveIn: DateTime(2026, 2, 10),
        monthlyRate: 80,
        existing: const [],
        today: _today,
      );
      expect(p.charges.map((c) => c.label).toList(), [
        'February 2026',
        'March 2026',
        'April 2026',
        'May 2026',
        'June 2026',
        'July 2026',
        'August 2026',
        'September 2026',
      ]);
      expect(p.charges.first.day, 10);
      expect(p.charges.skip(1).every((c) => c.day == 1), isTrue);
      expect(p.charges.every((c) => c.amount == 80 && c.included), isTrue);
      expect(p.stoppedBefore, isNull);
      expect(p.charges.first.toPayload(), {'year': 2026, 'month': 2, 'day': 10, 'amount': 80.0});
    });

    test('stops before the first month that already has rent on the ledger', () {
      final p = proposeHistoryCharges(
        moveIn: DateTime(2026, 2, 10),
        monthlyRate: 80,
        existing: [_rent(2026, 9), _rent(2025, 12)],
        today: _today,
      );
      expect(p.charges.last.label, 'August 2026');
      expect(p.charges.length, 7);
      expect(p.stoppedBefore, (year: 2026, month: 9));
    });

    test('a voided rent charge does not stop it', () {
      final p = proposeHistoryCharges(
        moveIn: DateTime(2026, 2, 10),
        monthlyRate: 80,
        existing: [_rent(2026, 5, status: LedgerEntryStatus.voided)],
        today: _today,
      );
      expect(p.charges.length, 8);
    });

    test('move-in this month proposes just this month', () {
      final p = proposeHistoryCharges(moveIn: DateTime(2026, 9, 3), monthlyRate: 55, existing: const [], today: _today);
      expect(p.charges.single.label, 'September 2026');
      expect(p.charges.single.day, 3);
    });
  });

  group('preview', () {
    List<ProposedHistoryCharge> exampleCharges() => proposeHistoryCharges(
          moveIn: DateTime(2026, 2, 10),
          monthlyRate: 80,
          existing: const [],
          today: _today,
        ).charges;

    test('the owner example: 640 charged, 480 paid, 160 owed, paid through July 31', () {
      final preview = computeHistoryPreview(
        existing: const [],
        charges: exampleCharges(),
        payments: _examplePayments(),
        existingPaidThrough: null,
      );
      expect(preview.totalCharges, 640);
      expect(preview.totalPayments, 480);
      expect(preview.balance, 160);
      expect(preview.resultingPaidThrough, DateTime(2026, 7, 31));
      expect(preview.paidThroughChanges, isTrue);
      expect(preview.credit, 0);
      expect(preview.firstUnpaidMonth, (year: 2026, month: 8));
      expect(preview.paidThroughWarning, isNull);
    });

    test('an unticked month is free: not charged, paid through moves past it', () {
      final charges = exampleCharges();
      charges.firstWhere((c) => c.month == 3).included = false;
      final preview = computeHistoryPreview(
        existing: const [],
        charges: charges,
        payments: _examplePayments(),
        existingPaidThrough: null,
      );
      expect(preview.totalCharges, 560);
      expect(preview.balance, 80);
      expect(preview.resultingPaidThrough, DateTime(2026, 8, 31));
    });

    test('an edited amount counts', () {
      final charges = exampleCharges();
      charges.first.amount = 40; // half month
      final preview = computeHistoryPreview(existing: const [], charges: charges, payments: const [], existingPaidThrough: null);
      expect(preview.totalCharges, 600);
    });

    test('an overpayment shows as a credit on the account', () {
      final charges = exampleCharges().where((c) => c.month <= 4).toList();
      final preview = computeHistoryPreview(
        existing: const [],
        charges: charges,
        payments: [HistoryPaymentInput(date: DateTime(2026, 2, 10), amount: 300)],
        existingPaidThrough: null,
      );
      expect(preview.balance, -60);
      expect(preview.credit, 60);
      expect(preview.firstUnpaidMonth, isNull);
      expect(preview.resultingPaidThrough, DateTime(2026, 4, 30));
    });

    test('rent already on the ledger counts toward the balance', () {
      final charges = exampleCharges().where((c) => c.month <= 8).toList();
      final preview = computeHistoryPreview(
        existing: [_rent(2026, 9)],
        charges: charges,
        payments: _examplePayments(),
        existingPaidThrough: null,
      );
      expect(preview.totalCharges, 560);
      expect(preview.balance, 160);
      expect(preview.resultingPaidThrough, DateTime(2026, 7, 31));
    });

    test('a later paid-through date already set is kept, with a warning', () {
      final preview = computeHistoryPreview(
        existing: const [],
        charges: exampleCharges(),
        payments: _examplePayments(),
        existingPaidThrough: DateTime(2026, 12, 31),
      );
      expect(preview.resultingPaidThrough, DateTime(2026, 12, 31));
      expect(preview.paidThroughChanges, isFalse);
      expect(preview.paidThroughWarning, contains('12/31/2026'));
    });

    test('the same date already set changes nothing and warns of nothing', () {
      final preview = computeHistoryPreview(
        existing: const [],
        charges: exampleCharges(),
        payments: _examplePayments(),
        existingPaidThrough: DateTime(2026, 7, 31),
      );
      expect(preview.paidThroughChanges, isFalse);
      expect(preview.paidThroughWarning, isNull);
    });
  });

  group('history typed in by hand before', () {
    // Eight $80 charges and four payments typed in through Add entry,
    // all dated the day they were typed, on an invoice rather than the rent
    // job's metadata.
    List<LedgerEntry> handEntered() {
      final typed = DateTime(2026, 9, 27, 21);
      return [
        for (var i = 0; i < 8; i++)
          LedgerEntry(
            id: 'hand-c$i',
            tenantId: 't1',
            facilityId: 'f1',
            type: LedgerEntryType.rentCharge,
            amount: 80,
            entryDate: typed,
            status: LedgerEntryStatus.posted,
            metadata: const {'invoiceId': 'inv-1'},
            createdAt: typed,
            createdBy: 'owner',
          ),
        for (final (i, amount) in [-160.0, -80.0, -80.0, -80.0].indexed)
          LedgerEntry(
            id: 'hand-p$i',
            tenantId: 't1',
            facilityId: 'f1',
            type: LedgerEntryType.payment,
            amount: amount,
            entryDate: typed,
            status: LedgerEntryStatus.posted,
            createdAt: typed,
            createdBy: 'owner',
          ),
      ];
    }

    test('left alone they are counted, so the preview shows the doubled balance', () {
      final existing = handEntered();
      final proposal = proposeHistoryCharges(moveIn: DateTime(2026, 2, 10), monthlyRate: 80, existing: existing, today: _today);
      // Dated this month, so this month counts as charged.
      expect(proposal.charges.last.label, 'August 2026');
      final preview = computeHistoryPreview(
        existing: existing,
        charges: proposal.charges,
        payments: _examplePayments(),
        existingPaidThrough: null,
      );
      expect(preview.existingCharges, 8);
      expect(preview.existingChargeTotal, 640);
      expect(preview.existingPayments, 4);
      expect(preview.existingPaymentTotal, 400);
      expect(preview.balance, 320);
      expect(preview.voidedCount, 0);
    });

    test('ticked to void, they leave the balance and free up this month', () {
      final existing = handEntered();
      final voiding = existing.map((e) => e.id).toSet();
      final kept = existing.where((e) => !voiding.contains(e.id)).toList();
      final proposal = proposeHistoryCharges(moveIn: DateTime(2026, 2, 10), monthlyRate: 80, existing: kept, today: _today);
      expect(proposal.charges.length, 8);
      final preview = computeHistoryPreview(
        existing: existing,
        charges: proposal.charges,
        payments: _examplePayments(),
        existingPaidThrough: null,
        voiding: voiding,
      );
      expect(preview.voidedCount, 12);
      expect(preview.existingCharges, 0);
      expect(preview.balance, 160);
      expect(preview.resultingPaidThrough, DateTime(2026, 7, 31));
    });
  });

  group('paid through from the whole ledger (review round)', () {
    List<ProposedHistoryCharge> exampleCharges() =>
        proposeHistoryCharges(moveIn: DateTime(2026, 2, 10), monthlyRate: 80, existing: const [], today: _today).charges;

    // Four hand payments through Record payment pushed paidThrough to 1/31/2027.
    List<LedgerEntry> handPayments() => [
          for (final (i, amount) in [-160.0, -80.0, -80.0, -80.0].indexed)
            LedgerEntry(
              id: 'hand-p$i',
              tenantId: 't1',
              facilityId: 'f1',
              type: LedgerEntryType.payment,
              amount: amount,
              entryDate: DateTime(2026, 9, 27, 21),
              status: LedgerEntryStatus.posted,
              metadata: {'paymentId': 'pay-$i', 'invoiceId': 'inv-7'},
              createdAt: DateTime(2026, 9, 27, 21),
              createdBy: 'owner',
            ),
        ];

    test('voiding the hand payments recomputes paid through back to 7/31 by default', () {
      final existing = handPayments();
      final preview = computeHistoryPreview(
        existing: existing,
        charges: exampleCharges(),
        payments: _examplePayments(),
        existingPaidThrough: DateTime(2027, 1, 31),
        voiding: existing.map((e) => e.id).toSet(),
        monthlyRate: 80,
      );
      expect(preview.voidsPayment, isTrue);
      expect(preview.choice, PaidThroughChoice.computed);
      expect(preview.paidThroughNow, DateTime(2027, 1, 31));
      expect(preview.computedPaidThrough, DateTime(2026, 7, 31));
      expect(preview.resultingPaidThrough, DateTime(2026, 7, 31));
      expect(preview.recomputedIsEarlier, isTrue);
      expect(preview.balance, 160);
      expect(preview.invoiceIds, ['inv-7']);
    });

    test('the owner can keep the later date instead', () {
      final existing = handPayments();
      final preview = computeHistoryPreview(
        existing: existing,
        charges: exampleCharges(),
        payments: _examplePayments(),
        existingPaidThrough: DateTime(2027, 1, 31),
        voiding: existing.map((e) => e.id).toSet(),
        monthlyRate: 80,
        choice: PaidThroughChoice.keepLater,
      );
      expect(preview.resultingPaidThrough, DateTime(2027, 1, 31));
      expect(preview.paidThroughWarning, contains('1/31/2027'));
    });

    test('without voids the default keeps the later date', () {
      final preview = computeHistoryPreview(
        existing: const [],
        charges: exampleCharges(),
        payments: _examplePayments(),
        existingPaidThrough: DateTime(2027, 1, 31),
        monthlyRate: 80,
      );
      expect(preview.choice, PaidThroughChoice.keepLater);
      expect(preview.resultingPaidThrough, DateTime(2027, 1, 31));
    });

    test('a \$15 fee counts in the balance but does not hold paid through back', () {
      final fee = LedgerEntry(
        id: 'fee',
        tenantId: 't1',
        facilityId: 'f1',
        type: LedgerEntryType.lateFee,
        amount: 15,
        entryDate: DateTime(2026, 3, 6),
        status: LedgerEntryStatus.posted,
        createdAt: DateTime(2026, 3, 6),
        createdBy: 'system',
      );
      final preview = computeHistoryPreview(
        existing: [fee],
        charges: exampleCharges(),
        payments: _examplePayments(),
        existingPaidThrough: null,
        monthlyRate: 80,
      );
      expect(preview.balance, 175);
      expect(preview.resultingPaidThrough, DateTime(2026, 7, 31));
    });

    test('credit buys whole months; less than a month shows as credit', () {
      List<ProposedHistoryCharge> augSep() =>
          proposeHistoryCharges(moveIn: DateTime(2026, 8, 1), monthlyRate: 80, existing: const [], today: _today).charges;
      final p240 = computeHistoryPreview(
        existing: const [],
        charges: augSep(),
        payments: [HistoryPaymentInput(date: DateTime(2026, 8, 1), amount: 240)],
        existingPaidThrough: null,
        monthlyRate: 80,
      );
      expect(p240.resultingPaidThrough, DateTime(2026, 10, 31));
      expect(p240.prepaidMonths, 1);
      expect(p240.credit, 0);
      final p270 = computeHistoryPreview(
        existing: const [],
        charges: augSep(),
        payments: [HistoryPaymentInput(date: DateTime(2026, 8, 1), amount: 270)],
        existingPaidThrough: null,
        monthlyRate: 80,
      );
      expect(p270.resultingPaidThrough, DateTime(2026, 10, 31));
      expect(p270.credit, 30);
    });

    test('money that paid a deposit does not buy future rent', () {
      final deposit = LedgerEntry(
        id: 'dep',
        tenantId: 't1',
        facilityId: 'f1',
        type: LedgerEntryType.otherCharge,
        amount: 1000,
        description: 'Security deposit',
        entryDate: DateTime(2026, 8, 1),
        status: LedgerEntryStatus.posted,
        createdAt: DateTime(2026, 8, 1),
        createdBy: 'owner',
      );
      final charges =
          proposeHistoryCharges(moveIn: DateTime(2026, 8, 1), monthlyRate: 1000, existing: const [], today: _today).charges;
      final preview = computeHistoryPreview(
        existing: [deposit],
        charges: charges,
        payments: [
          HistoryPaymentInput(date: DateTime(2026, 8, 1), amount: 2000),
          HistoryPaymentInput(date: DateTime(2026, 9, 1), amount: 1000),
        ],
        existingPaidThrough: null,
        monthlyRate: 1000,
      );
      expect(preview.balance, 0);
      expect(preview.resultingPaidThrough, DateTime(2026, 9, 30));
      expect(preview.prepaidMonths, 0);
      expect(preview.credit, 0);
    });

    test('a genuine \$160 credit still buys two months', () {
      final preview = computeHistoryPreview(
        existing: const [],
        charges: exampleCharges(),
        payments: [
          ..._examplePayments(),
          HistoryPaymentInput(date: DateTime(2026, 6, 2), amount: 160),
          HistoryPaymentInput(date: DateTime(2026, 7, 1), amount: 160),
        ],
        existingPaidThrough: null,
        monthlyRate: 80,
      );
      expect(preview.balance, -160);
      expect(preview.prepaidMonths, 2);
      expect(preview.resultingPaidThrough, DateTime(2026, 11, 30));
    });

    test('a free trailing month right after paid months counts as paid', () {
      final charges =
          proposeHistoryCharges(moveIn: DateTime(2026, 7, 1), monthlyRate: 80, existing: const [], today: _today).charges;
      charges.last.included = false; // September free
      final preview = computeHistoryPreview(
        existing: const [],
        charges: charges,
        payments: [
          HistoryPaymentInput(date: DateTime(2026, 7, 1), amount: 80),
          HistoryPaymentInput(date: DateTime(2026, 8, 1), amount: 80),
        ],
        existingPaidThrough: null,
        monthlyRate: 80,
      );
      expect(preview.resultingPaidThrough, DateTime(2026, 9, 30));
    });
  });

  test('rent is proposed at the tenant rate, which covers all their units', () {
    // Four $20 outdoor spaces, one $80 rate on the tenant.
    final p = proposeHistoryCharges(moveIn: DateTime(2026, 6, 1), monthlyRate: 80, existing: const [], today: _today);
    expect(p.charges.every((c) => c.amount == 80), isTrue);
  });

  group('amounts typed off the rate', () {
    // A person renting two units, entered at their combined $110 on a record
    // whose rate is one unit's $55. Nothing said the months were double.
    List<ProposedHistoryCharge> months(List<double> amounts, {int day = 1}) => [
          for (final (i, a) in amounts.indexed)
            ProposedHistoryCharge(year: 2026, month: 3 + i, day: i == 0 ? day : 1, amount: a),
        ];

    test('every month at the rate: nothing to say', () {
      expect(historyAmountsOffRate(charges: months([55, 55, 55]), monthlyRate: 55), isEmpty);
    });

    test('the combined rent on every month is reported once', () {
      expect(historyAmountsOffRate(charges: months([110, 110, 110], day: 25), monthlyRate: 55), [110]);
      expect(historyAmountsOffRate(charges: months([110, 110, 165]), monthlyRate: 55), [110, 165]);
    });

    test('a prorated first month is expected; a lower month dated the 1st is not', () {
      expect(historyAmountsOffRate(charges: months([12.43, 55, 55], day: 25), monthlyRate: 55), isEmpty);
      expect(historyAmountsOffRate(charges: months([12.43, 55, 55]), monthlyRate: 55), [12.43]);
      expect(historyAmountsOffRate(charges: months([55, 40, 55]), monthlyRate: 55), [40]);
    });

    test('unticked months, blank amounts and a record with no rate are not compared', () {
      final c = months([110, 110]);
      c[0].included = false;
      expect(historyAmountsOffRate(charges: c, monthlyRate: 55), [110]);
      c[1].amount = 0;
      expect(historyAmountsOffRate(charges: c, monthlyRate: 55), isEmpty);
      expect(historyAmountsOffRate(charges: months([110]), monthlyRate: 0), isEmpty);
    });

    test('compared to the cent', () {
      expect(historyAmountsOffRate(charges: months([55.004, 55]), monthlyRate: 55), isEmpty);
      expect(historyAmountsOffRate(charges: months([55.01, 55]), monthlyRate: 55), [55.01]);
    });
  });

  testWidgets('a month typed above the rate warns that the rate may be one unit\'s, without blocking the save',
      (tester) async {
    await _pumpDialog(tester, const []);
    await tester.tap(find.text('Choose move-in date *'));
    await tester.pumpAndSettle();
    // The picker opens on today, 9/28/2026.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('September 2026 (from 9/28)'), findsOneWidget);
    expect(find.textContaining('is not this tenant\'s rate'), findsNothing);

    final amount = find.descendant(
      of: find.byKey(const ValueKey('history-charge-2026-9')),
      matching: find.byType(TextField),
    );
    await tester.enterText(amount, '160');
    await tester.pumpAndSettle();
    // The other unit is usually on a duplicate record, so the copy has to
    // name Unassign before Assign: Assign Tenant alone stops on "occupied".
    final warning = find.text('\$160.00 is not this tenant\'s rate of \$80.00. '
        'If they rent more than one unit, put every unit on this record first: on the other unit\'s page '
        '(Units › Unit List), Unassign Tenant if another record holds it, then Assign Tenant to this tenant. '
        'The rate then becomes the total.');
    expect(warning, findsOneWidget);
    expect(tester.widget<Text>(warning).style?.color, AppTheme.warning);
    // A warning only: ticking the confirm box still lets the owner save.
    await tester.tap(find.text('I checked these months, amounts and dates against my records'));
    await tester.pumpAndSettle();
    final save = tester.widget<FilledButton>(
        find.byWidgetPredicate((w) => w is FilledButton && find.descendant(of: find.byWidget(w), matching: find.text('Save history')).evaluate().isNotEmpty));
    expect(save.onPressed, isNotNull);

    // Below the rate on a mid-month move-in: a proration, nothing to say.
    await tester.enterText(amount, '8');
    await tester.pumpAndSettle();
    expect(find.textContaining('is not this tenant\'s rate'), findsNothing);
  });

  testWidgets('a month dated the 1st typed below the rate is named without the multi-unit warning', (tester) async {
    // Rent was lower before a raise, or a month was discounted: the helper
    // text invites the change, so it must not read as a two-unit mistake.
    await _pumpDialog(tester, const []);
    await tester.tap(find.text('Choose move-in date *'));
    await tester.pumpAndSettle();
    // The picker opens on September 2026; move in on the 1st.
    await tester.tap(find.text('1'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('September 2026'), findsOneWidget);

    final amount = find.descendant(
      of: find.byKey(const ValueKey('history-charge-2026-9')),
      matching: find.byType(TextField),
    );
    await tester.enterText(amount, '40');
    await tester.pumpAndSettle();
    final note = find.text('\$40.00 is not this tenant\'s rate of \$80.00. Fine if the rent was different then.');
    expect(note, findsOneWidget);
    expect(tester.widget<Text>(note).style?.color, AppTheme.textSecondary);
    expect(find.textContaining('If they rent more than one unit'), findsNothing);

    // Above the rate on the same month is still the two-unit case.
    await tester.enterText(amount, '160');
    await tester.pumpAndSettle();
    expect(find.textContaining('If they rent more than one unit'), findsOneWidget);
    expect(find.textContaining('Fine if the rent was different then'), findsNothing);
  });

  group('payment dates', () {
    test('a full date or just a month', () {
      expect(parseHistoryDateInput('8/17/2026'), (date: DateTime(2026, 8, 17), monthOnly: false));
      expect(parseHistoryDateInput('2026-08-17'), (date: DateTime(2026, 8, 17), monthOnly: false));
      expect(parseHistoryDateInput('9/2026'), (date: DateTime(2026, 9, 1), monthOnly: true));
      expect(parseHistoryDateInput('2026-09'), (date: DateTime(2026, 9, 1), monthOnly: true));
      expect(parseHistoryDateInput('September 2026'), (date: DateTime(2026, 9, 1), monthOnly: true));
      expect(parseHistoryDateInput('Sept 2026'), (date: DateTime(2026, 9, 1), monthOnly: true));
      expect(parseHistoryDateInput('2/30/2026'), isNull);
      expect(parseHistoryDateInput('13/2026'), isNull);
      expect(parseHistoryDateInput('soon'), isNull);
      expect(parseHistoryDateInput(''), isNull);
    });

    test('a month-only payment is sent as the 1st, flagged', () {
      final p = HistoryPaymentInput(date: DateTime(2026, 9, 1), monthOnly: true, amount: 1000, method: PaymentMethod.check);
      expect(p.toPayload(), {'date': '2026-09-01', 'monthOnly': true, 'amount': 1000.0, 'method': 'check'});
      expect(formatHistoryDateInput(DateTime(2026, 9, 1), monthOnly: true), '9/2026');
    });

    test('a house: prorated first month edited, month-only payment, paid through September', () {
      final charges = proposeHistoryCharges(moveIn: DateTime(2026, 8, 17), monthlyRate: 1000, existing: const [], today: _today).charges;
      expect(charges.first.day, 17);
      charges.first.amount = 475;
      final preview = computeHistoryPreview(
        existing: const [],
        charges: charges,
        payments: [
          HistoryPaymentInput(date: DateTime(2026, 8, 17), amount: 475, method: PaymentMethod.zelle),
          HistoryPaymentInput(date: DateTime(2026, 9, 1), monthOnly: true, amount: 1000, method: PaymentMethod.check),
        ],
        existingPaidThrough: null,
      );
      expect(preview.totalCharges, 1475);
      expect(preview.balance, 0);
      expect(preview.resultingPaidThrough, DateTime(2026, 9, 30));
    });
  });

  test('payment payload: date as a calendar day, method by name, blanks left out', () {
    final p = HistoryPaymentInput(
      date: DateTime(2026, 6, 1, 23, 30),
      amount: 160,
      method: PaymentMethod.zelle,
      reference: '  ',
      note: 'June and July',
    );
    expect(p.toPayload(), {'date': '2026-06-01', 'amount': 160.0, 'method': 'zelle', 'note': 'June and July'});
  });

  test('history batches on the ledger, for Undo this history entry', () {
    LedgerEntry e(String id, double amount, String req, {LedgerEntryStatus status = LedgerEntryStatus.posted}) => LedgerEntry(
          id: id,
          tenantId: 't1',
          facilityId: 'f1',
          type: amount > 0 ? LedgerEntryType.rentCharge : LedgerEntryType.payment,
          amount: amount,
          entryDate: DateTime(2026, 3, 1),
          status: status,
          metadata: {'source': 'past_history', 'historyRequestId': req},
          createdAt: DateTime(2026, 9, 28),
          createdBy: 'owner',
        );
    final batches = postedHistoryBatches([
      e('a', 80, 'hist-1'),
      e('b', 80, 'hist-1'),
      e('c', -80, 'hist-1'),
      e('d', 80, 'hist-2', status: LedgerEntryStatus.voided),
      _rent(2026, 9),
    ]);
    expect(batches.length, 1);
    expect(batches.single.requestId, 'hist-1');
    expect(batches.single.charges, 2);
    expect(batches.single.payments, 1);
    expect(batches.single.totalCharges, 160);
    expect(batches.single.totalPayments, 80);
  });

  group('payment methods', () {
    test('Venmo, Zelle and Other have names, and an unknown stored method reads as Other', () {
      expect(PaymentMethod.venmo.displayName, 'Venmo');
      expect(PaymentMethod.zelle.displayName, 'Zelle');
      expect(PaymentMethod.other.displayName, 'Other');
      expect(paymentMethodFromStored('venmo'), PaymentMethod.venmo);
      expect(paymentMethodFromStored('cashApp'), PaymentMethod.other);
      expect(paymentMethodFromStored(null), PaymentMethod.cash);
      expect(manualPaymentMethods, [
        PaymentMethod.cash,
        PaymentMethod.check,
        PaymentMethod.venmo,
        PaymentMethod.zelle,
        PaymentMethod.bankTransfer,
        PaymentMethod.other,
      ]);
    });

    test('the ledger line carries the check number', () {
      expect(receivedPaymentDescription(PaymentMethod.check, reference: '1234'), 'Payment - Check #1234');
      expect(receivedPaymentDescription(PaymentMethod.venmo, notes: 'June'), 'Payment - Venmo: June');
      expect(receivedPaymentDescription(PaymentMethod.cash, reference: ' ', notes: ''), 'Payment - Cash');
    });
  });

  testWidgets('the preview card shows what saving will do', (tester) async {
    final charges = proposeHistoryCharges(
      moveIn: DateTime(2026, 2, 10),
      monthlyRate: 80,
      existing: const [],
      today: _today,
    ).charges;
    final preview = computeHistoryPreview(
      existing: const [],
      charges: charges,
      payments: _examplePayments(),
      existingPaidThrough: null,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PastHistoryPreviewCard(preview: preview))));
    expect(find.text('\$640.00'), findsOneWidget);
    expect(find.text('\$480.00'), findsOneWidget);
    expect(find.text('\$160.00'), findsOneWidget);
    expect(find.text('7/31/2026'), findsOneWidget);
    expect(find.textContaining('Late fees are not added for past months'), findsOneWidget);
  });

  testWidgets('a partial payment shows as credit toward the next month', (tester) async {
    final charges = proposeHistoryCharges(
      moveIn: DateTime(2026, 2, 1),
      monthlyRate: 80,
      existing: const [],
      today: DateTime(2026, 3, 15),
    ).charges;
    final preview = computeHistoryPreview(
      existing: const [],
      charges: charges,
      payments: [HistoryPaymentInput(date: DateTime(2026, 2, 1), amount: 120)],
      existingPaidThrough: null,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PastHistoryPreviewCard(preview: preview))));
    expect(find.text('Credit toward March 2026'), findsOneWidget);
    expect(find.text('\$40.00'), findsWidgets);
    expect(find.text('2/28/2026'), findsOneWidget);
  });
}
