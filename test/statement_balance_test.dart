import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/services/statement_service.dart';

// Fake data only: this repo is public.
LedgerEntry _entry(
  String id,
  LedgerEntryType type,
  double amount,
  DateTime at, {
  LedgerEntryStatus status = LedgerEntryStatus.posted,
}) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: type,
      amount: amount,
      entryDate: at,
      status: status,
      createdAt: at,
      createdBy: 'owner',
    );

void main() {
  // Stored as every writer stores them: payments negative, refunds positive.
  final paid = _entry('p', LedgerEntryType.payment, -50, DateTime(2026, 9, 2));
  final refunded =
      _entry('r', LedgerEntryType.refund, 50, DateTime(2026, 9, 5));

  group('a payment refunded in full', () {
    test('runs the balance back to zero, like the ledger header', () {
      // Passed newest first, as the ledger stream delivers them.
      final rows = StatementService.statementRows([refunded, paid]);
      expect(rows.map((r) => r.balance), [-50.0, 0.0]);
    });

    test('carries zero forward into a later statement', () {
      expect(
        StatementService.balanceForward(
            [paid, refunded], DateTime(2026, 10, 1)),
        0.0,
      );
    });

    test('sits under Payments, then under Charges', () {
      final rows = StatementService.statementRows([paid, refunded]);
      expect(rows[0].payments, 50.0);
      expect(rows[0].charges, 0.0);
      expect(rows[1].charges, 50.0);
      expect(rows[1].payments, 0.0);
    });
  });

  test('columns follow the sign of the amount, not the type', () {
    final rows = StatementService.statementRows([
      _entry('c', LedgerEntryType.rentCharge, 85, DateTime(2026, 9, 1)),
      _entry('k', LedgerEntryType.credit, -10, DateTime(2026, 9, 3)),
      // An adjustment can go either way.
      _entry('a', LedgerEntryType.adjustment, 5, DateTime(2026, 9, 4)),
    ]);
    expect(rows.map((r) => r.charges), [85.0, 0.0, 5.0]);
    expect(rows.map((r) => r.payments), [0.0, 10.0, 0.0]);
    expect(rows.map((r) => r.balance), [85.0, 75.0, 80.0]);
  });

  test('the balance forward feeds the first row and voided rows are skipped',
      () {
    final rows = StatementService.statementRows(
      [
        _entry('v', LedgerEntryType.lateFee, 20, DateTime(2026, 9, 1),
            status: LedgerEntryStatus.voided),
        _entry('c', LedgerEntryType.rentCharge, 85, DateTime(2026, 9, 1)),
      ],
      balanceForward: -30,
    );
    expect(rows, hasLength(1));
    expect(rows.single.balance, 55.0);
  });

  test('balance forward counts only entries dated before the start', () {
    final start = DateTime(2026, 9, 1);
    expect(
      StatementService.balanceForward([
        _entry('old', LedgerEntryType.rentCharge, 85, DateTime(2026, 8, 1)),
        _entry('oldPay', LedgerEntryType.payment, -85, DateTime(2026, 8, 3)),
        _entry('oldCredit', LedgerEntryType.credit, -10, DateTime(2026, 8, 20)),
        _entry('void', LedgerEntryType.lateFee, 20, DateTime(2026, 8, 25),
            status: LedgerEntryStatus.voided),
        _entry('new', LedgerEntryType.rentCharge, 85, start),
      ], start),
      -10.0,
    );
  });
}
