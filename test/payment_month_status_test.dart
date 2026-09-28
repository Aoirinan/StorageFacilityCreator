import 'package:flutter_test/flutter_test.dart';
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
