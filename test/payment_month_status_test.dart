import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/utils/payment_month_status.dart';

// Fake data only: this repo is public.
TenantModel _tenant({
  DateTime? moveInDate,
  DateTime? createdAt,
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
      createdAt: createdAt ?? DateTime(2026, 9, 1),
      paidThrough: paidThrough,
      monthStatusOverrides: overrides,
    );

/// A posted payment row; [source] 'past_history' is how Enter past history
/// marks its rows.
LedgerEntry _payment(
  String id,
  DateTime on, {
  String? source,
  LedgerEntryStatus status = LedgerEntryStatus.posted,
  Map<String, dynamic> extra = const {},
}) =>
    LedgerEntry(
      id: id,
      tenantId: 'tenant-1',
      facilityId: 'facility-1',
      type: LedgerEntryType.payment,
      amount: -50,
      entryDate: on,
      status: status,
      metadata: {
        ...extra,
        if (source != null) 'source': source,
      },
      createdAt: DateTime(2026, 9, 25),
      createdBy: 'owner',
    );

void main() {
  final today = DateTime(2026, 9, 28);

  List<PaymentMonthStatus> grid(TenantModel t, {double balance = 0}) => [
        for (final m in paymentHistoryMonths(today))
          tenantPaymentMonthStatus(t, m, balance: balance, today: today),
      ];

  test('the 12 months end with the current month', () {
    final months = paymentHistoryMonths(today);
    expect(months.first, DateTime(2025, 10, 1));
    expect(months.last, DateTime(2026, 9, 1));
    expect(months, hasLength(12));
  });

  test('moved in mid-August, paid through September, \$0 balance: no late months', () {
    final statuses = grid(_tenant(
      moveInDate: DateTime.utc(2026, 8, 17, 12),
      paidThrough: DateTime(2026, 9, 30),
    ));
    expect(statuses.take(10), everyElement(PaymentMonthStatus.beforeMoveIn));
    expect(statuses.skip(10), [PaymentMonthStatus.paid, PaymentMonthStatus.paid]);
    expect(statuses, isNot(contains(PaymentMonthStatus.late)));
  });

  test('without a move-in date the grid starts at createdAt', () {
    final statuses = grid(_tenant(
      createdAt: DateTime(2026, 6, 3),
      paidThrough: DateTime(2026, 9, 30),
    ));
    expect(statuses.take(8), everyElement(PaymentMonthStatus.beforeMoveIn));
    expect(statuses.skip(8), everyElement(PaymentMonthStatus.paid));
  });

  List<PaymentMonthStatus> gridFrom(TenantModel t, List<LedgerEntry> entries, {double balance = 0}) => [
        for (final m in paymentHistoryMonths(today))
          tenantPaymentMonthStatus(t, m,
              balance: balance,
              today: today,
              firstPastHistoryPayment: firstPastHistoryPaymentDate(entries)),
      ];

  test('a past-history payment received before the saved move-in date starts the grid there', () {
    // Enter past history kept the move-in date the tenant was typed in with,
    // so the checks entered for March to July sat in "Before move-in".
    final t = _tenant(
      moveInDate: DateTime(2026, 9, 20),
      paidThrough: DateTime(2026, 7, 31),
    );
    expect(grid(t).take(11), everyElement(PaymentMonthStatus.beforeMoveIn));

    final entries = [
      _payment('h1', DateTime.utc(2026, 3, 4, 12), source: 'past_history'),
      _payment('h2', DateTime.utc(2026, 5, 6, 12), source: 'past_history'),
    ];
    expect(firstPastHistoryPaymentDate(entries), DateTime.utc(2026, 3, 4, 12));
    final statuses = gridFrom(t, entries);
    expect(statuses.take(5), everyElement(PaymentMonthStatus.beforeMoveIn)); // Oct 25 - Feb 26
    expect(statuses.sublist(5, 10), everyElement(PaymentMonthStatus.paid)); // Mar - Jul 26
    expect(statuses.skip(10), everyElement(PaymentMonthStatus.notRecorded));
  });

  test('a move-in payment made the month before move-in leaves that month before move-in', () {
    // Paid online on Aug 28 for a Sep 3 move-in: August was not theirs.
    final t = _tenant(moveInDate: DateTime(2026, 9, 3));
    final entries = [
      _payment('m1', DateTime(2026, 8, 28, 15, 30),
          extra: {'paymentIntentId': 'pi_test_1', 'moveInPayment': true}),
    ];
    expect(firstPastHistoryPaymentDate(entries), isNull);

    // Still owing: August would have been red "Late".
    final owing = gridFrom(t, entries, balance: 40);
    expect(owing[10], PaymentMonthStatus.beforeMoveIn); // Aug 2026
    expect(owing[11], PaymentMonthStatus.late); // Sep 2026

    // Paid through September: August would have been green "Paid".
    final paid = gridFrom(
        _tenant(moveInDate: DateTime(2026, 9, 3), paidThrough: DateTime(2026, 9, 30)), entries);
    expect(paid[10], PaymentMonthStatus.beforeMoveIn);
    expect(paid[11], PaymentMonthStatus.paid);
  });

  test('a pending or voided past-history payment does not move the start', () {
    final t = _tenant(moveInDate: DateTime(2026, 9, 20), paidThrough: DateTime(2026, 9, 30));
    final entries = [
      _payment('owed', DateTime.utc(2026, 3, 4, 12),
          source: 'past_history', status: LedgerEntryStatus.pending),
      _payment('undone', DateTime.utc(2026, 4, 2, 12),
          source: 'past_history', status: LedgerEntryStatus.voided),
      // A charge Enter past history posted is not money received.
      LedgerEntry(
        id: 'rent',
        tenantId: 'tenant-1',
        facilityId: 'facility-1',
        type: LedgerEntryType.rentCharge,
        amount: 50,
        entryDate: DateTime.utc(2026, 2, 1, 12),
        status: LedgerEntryStatus.posted,
        metadata: const {'source': 'past_history'},
        createdAt: DateTime(2026, 9, 25),
        createdBy: 'owner',
      ),
    ];
    expect(firstPastHistoryPaymentDate(entries), isNull);
    expect(gridFrom(t, entries).take(11), everyElement(PaymentMonthStatus.beforeMoveIn));
  });

  test('a payment after move-in does not move the start', () {
    final t = _tenant(moveInDate: DateTime(2026, 5, 10), paidThrough: DateTime(2026, 9, 30));
    expect(tenancyStart(t, firstPastHistoryPayment: DateTime(2026, 6, 1)), DateTime(2026, 5, 10));
    expect(tenancyStart(t), DateTime(2026, 5, 10));
  });

  test('imported from a paper ledger with no paidThrough and \$0 balance is not late', () {
    final statuses = grid(_tenant(
      moveInDate: DateTime(2025, 1, 1),
      createdAt: DateTime(2026, 9, 20),
    ));
    expect(statuses, everyElement(PaymentMonthStatus.notRecorded));
  });

  test('months after paidThrough are late only while the balance is positive', () {
    final t = _tenant(
      moveInDate: DateTime(2025, 1, 1),
      paidThrough: DateTime(2026, 6, 30),
    );
    final owing = grid(t, balance: 150);
    expect(owing.sublist(0, 9), everyElement(PaymentMonthStatus.paid));
    expect(owing.sublist(9), everyElement(PaymentMonthStatus.late));

    final settled = grid(t, balance: 0);
    expect(settled.sublist(9), everyElement(PaymentMonthStatus.notRecorded));

    final inCredit = grid(t, balance: -25);
    expect(inCredit, isNot(contains(PaymentMonthStatus.late)));
  });

  test('a month is not late before it falls due', () {
    final t = _tenant(moveInDate: DateTime(2026, 1, 1), paidThrough: DateTime(2026, 8, 31));
    PaymentMonthStatus sept(DateTime day) => tenantPaymentMonthStatus(
        t, DateTime(2026, 9, 1), balance: 50, today: day);
    expect(sept(DateTime(2026, 9, 1)), PaymentMonthStatus.notRecorded);
    expect(sept(DateTime(2026, 9, 2)), PaymentMonthStatus.late);
    expect(
      tenantPaymentMonthStatus(t, DateTime(2026, 10, 1), balance: 50, today: today),
      PaymentMonthStatus.notRecorded,
    );
  });

  test('a stored status wins, before move-in and after paidThrough alike', () {
    final t = _tenant(
      moveInDate: DateTime(2026, 8, 17),
      paidThrough: DateTime(2026, 9, 30),
      overrides: {'2026-03': 'late', '2026-09': 'moved_out', '2026-08': 'paid'},
    );
    final statuses = grid(t);
    expect(statuses[5], PaymentMonthStatus.late); // Mar 2026
    expect(statuses[10], PaymentMonthStatus.paid); // Aug 2026
    expect(statuses[11], PaymentMonthStatus.movedOut); // Sep 2026
  });

  test('blank or unknown stored values count as no override', () {
    final t = _tenant(
      moveInDate: DateTime(2026, 8, 17),
      paidThrough: DateTime(2026, 9, 30),
      overrides: {'2026-09': '', '2026-08': 'something-else'},
    );
    final statuses = grid(t, balance: 100);
    expect(statuses.skip(10), everyElement(PaymentMonthStatus.paid));
  });

  test('stored values round-trip', () {
    for (final s in [PaymentMonthStatus.paid, PaymentMonthStatus.late, PaymentMonthStatus.movedOut]) {
      expect(PaymentMonthStatus.fromStored(s.storedValue), s);
    }
    expect(PaymentMonthStatus.beforeMoveIn.storedValue, isNull);
    expect(PaymentMonthStatus.notRecorded.storedValue, isNull);
    expect(paymentMonthKey(DateTime(2026, 3, 15)), '2026-03');
  });
}
