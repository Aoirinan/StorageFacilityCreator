import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/utils/statement_lines.dart';

LedgerEntry _entry(
  String id,
  LedgerEntryType type,
  double amount,
  DateTime at, {
  String? description,
  LedgerEntryStatus status = LedgerEntryStatus.posted,
  DateTime? createdAt,
}) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: type,
      amount: amount,
      description: description,
      entryDate: at,
      status: status,
      createdAt: createdAt ?? at,
      createdBy: 'owner',
    );

/// Rent and past-history payments are stored at 12:00 UTC on their day, as
/// the rent job and the past-history callable write them.
DateTime _noonUtc(int y, int m, int d) => DateTime.utc(y, m, d, 12);

void main() {
  group('buildStatementLines', () {
    test('posted entries only: pending and voided are left out everywhere',
        () {
      final lines = buildStatementLines([
        _entry('rent', LedgerEntryType.rentCharge, 65, _noonUtc(2026, 9, 1)),
        _entry('pay', LedgerEntryType.payment, -40, _noonUtc(2026, 9, 3)),
        _entry('pending', LedgerEntryType.payment, -25, _noonUtc(2026, 9, 4),
            status: LedgerEntryStatus.pending),
        _entry('voided', LedgerEntryType.lateFee, 30, _noonUtc(2026, 9, 5),
            status: LedgerEntryStatus.voided),
      ]);
      expect(lines.rows.map((r) => r.description),
          ['Rent', 'Payment']);
      expect(lines.balanceForward, 0);
      expect(lines.closingBalance, 25);
    });

    test('a refund, stored positive, raises the balance like the ledger', () {
      // The statement's own rule subtracted refunds, so a refunded tenant's
      // printed balance came out lower than the ledger by twice the refund.
      final lines = buildStatementLines([
        _entry('rent', LedgerEntryType.rentCharge, 100, _noonUtc(2026, 9, 1)),
        _entry('pay', LedgerEntryType.payment, -100, _noonUtc(2026, 9, 2)),
        _entry('refund', LedgerEntryType.refund, 25, _noonUtc(2026, 9, 10),
            description: 'Refund of overpayment'),
      ]);
      expect(lines.closingBalance, 25);
      final refund = lines.rows.last;
      expect(refund.charge, 25);
      expect(refund.payment, 0);
    });

    test('columns follow the sign: charges under Charges, payments under '
        'Payments as a positive figure', () {
      final lines = buildStatementLines([
        _entry('rent', LedgerEntryType.rentCharge, 85, _noonUtc(2026, 9, 1)),
        _entry('pay', LedgerEntryType.payment, -85, _noonUtc(2026, 9, 3)),
        // A credit is stored negative, like a payment, and prints where the
        // ledger counts it: under Payments.
        _entry('credit', LedgerEntryType.credit, -10, _noonUtc(2026, 9, 5)),
      ]);
      expect(lines.rows[0].charge, 85);
      expect(lines.rows[0].payment, 0);
      expect(lines.rows[1].charge, 0);
      expect(lines.rows[1].payment, 85);
      expect(lines.rows[2].payment, 10);
      expect(lines.rows.map((r) => r.runningBalance), [85, 0, -10]);
    });

    test('on one day the charge prints before the payment that paid it', () {
      // The Firestore stream orders ties by document id, so the payment
      // could print first and the Balance column read -$120 then $10.
      final lines = buildStatementLines([
        _entry('a-pay', LedgerEntryType.payment, -120, _noonUtc(2026, 1, 1),
            description: 'Payment - Check #1001',
            createdAt: DateTime.utc(2026, 9, 28, 18, 21)),
        _entry('b-rent', LedgerEntryType.rentCharge, 130, _noonUtc(2026, 1, 1),
            description: 'January rent',
            createdAt: DateTime.utc(2026, 9, 28, 18, 22)),
      ]);
      expect(lines.rows.map((r) => r.description),
          ['January rent', 'Payment - Check #1001']);
      expect(lines.rows.map((r) => r.runningBalance), [130, 10]);
    });

    test('on one local day the charge prints first even when the payment '
        'is earlier in the day', () {
      // A check logged at 09:00 and the rent posted at 12:00 the same day
      // used to print payment first, the Balance column reading -$120 then
      // $10. Local times, so the day is the same whatever zone runs this.
      final payAt = DateTime(2026, 9, 1, 9);
      final rentAt = DateTime(2026, 9, 1, 12);
      final lines = buildStatementLines([
        _entry('a-pay', LedgerEntryType.payment, -120, payAt,
            description: 'Payment - Check #1001'),
        _entry('b-rent', LedgerEntryType.rentCharge, 130, rentAt,
            description: 'September rent'),
      ]);
      expect(lines.rows.map((r) => r.description),
          ['September rent', 'Payment - Check #1001']);
      expect(lines.rows.map((r) => r.runningBalance), [130, 10]);
      expect(lines.rows.every((r) => r.runningBalance >= 0), isTrue);
      expect(lines.closingBalance, 10);
    });

    test('a payment the day before a charge still prints first', () {
      final lines = buildStatementLines([
        _entry('b-rent', LedgerEntryType.rentCharge, 130,
            DateTime(2026, 9, 2, 0, 5),
            description: 'September rent'),
        _entry('a-pay', LedgerEntryType.payment, -120,
            DateTime(2026, 9, 1, 23, 55),
            description: 'Payment - Check #1001'),
      ]);
      expect(lines.rows.map((r) => r.description),
          ['Payment - Check #1001', 'September rent']);
      expect(lines.rows.map((r) => r.runningBalance), [-120, 10]);
    });

    test('same day and same sign: earlier time first', () {
      final lines = buildStatementLines([
        _entry('late', LedgerEntryType.lateFee, 10, DateTime(2026, 3, 1, 8),
            description: 'late'),
        _entry('admin', LedgerEntryType.adminFee, 5, DateTime(2026, 3, 1, 7),
            description: 'admin'),
      ]);
      expect(lines.rows.map((r) => r.description), ['admin', 'late']);
    });

    test('same moment and same sign: creation order, then id', () {
      final lines = buildStatementLines([
        _entry('z', LedgerEntryType.lateFee, 10, _noonUtc(2026, 3, 1),
            description: 'late', createdAt: DateTime.utc(2026, 3, 1, 9)),
        // 'm' and 'a' were created at the same moment: 'a' first by id.
        _entry('m', LedgerEntryType.adminFee, 5, _noonUtc(2026, 3, 1),
            description: 'admin', createdAt: DateTime.utc(2026, 3, 1, 8)),
        _entry('a', LedgerEntryType.rentCharge, 50, _noonUtc(2026, 3, 1),
            description: 'rent', createdAt: DateTime.utc(2026, 3, 1, 8)),
      ]);
      expect(lines.rows.map((r) => r.description), ['rent', 'admin', 'late']);
    });

    test('a start date carries the earlier balance forward, credit included',
        () {
      // A credit carried forward used to be silent: the yellow box showed
      // only when the balance forward was above zero.
      final lines = buildStatementLines(
        [
          _entry('r1', LedgerEntryType.rentCharge, 40, _noonUtc(2026, 7, 1)),
          _entry('p1', LedgerEntryType.payment, -60, _noonUtc(2026, 7, 2)),
          _entry('r2', LedgerEntryType.rentCharge, 40, _noonUtc(2026, 8, 1)),
          _entry('r3', LedgerEntryType.rentCharge, 40, _noonUtc(2026, 9, 1)),
        ],
        startDate: DateTime(2026, 8, 1),
        endDate: DateTime(2026, 8, 31),
      );
      expect(lines.balanceForward, -20);
      expect(lines.rows.map((r) => r.date), [_noonUtc(2026, 8, 1)]);
      expect(lines.rows.single.runningBalance, 20);
      expect(lines.closingBalance, 20);
    });

    test('the end day counts, the day after does not', () {
      final lines = buildStatementLines(
        [
          _entry('on', LedgerEntryType.rentCharge, 10, DateTime(2026, 9, 15, 23, 59)),
          _entry('after', LedgerEntryType.rentCharge, 10, DateTime(2026, 9, 16)),
        ],
        endDate: DateTime(2026, 9, 15),
      );
      expect(lines.rows.map((r) => r.date), [DateTime(2026, 9, 15, 23, 59)]);
      expect(lines.closingBalance, 10);
    });

    test('entries already cut to the period give the same rows', () {
      final all = [
        _entry('r1', LedgerEntryType.rentCharge, 40, _noonUtc(2026, 7, 1)),
        _entry('r2', LedgerEntryType.rentCharge, 40, _noonUtc(2026, 8, 1)),
        _entry('r3', LedgerEntryType.rentCharge, 40, _noonUtc(2026, 9, 1)),
      ];
      final fromAll = buildStatementLines(all,
          startDate: DateTime(2026, 8, 1), endDate: DateTime(2026, 8, 31));
      final fromCut = buildStatementLines([all[1]],
          startDate: DateTime(2026, 8, 1), endDate: DateTime(2026, 8, 31));
      expect(fromCut.rows.length, fromAll.rows.length);
      expect(fromCut.rows.single.runningBalance, 40);
      // Only the balance forward needs the earlier entries.
      expect(fromAll.balanceForward, 40);
      expect(fromCut.balanceForward, 0);
    });

    test('all history closes on the ledger balance, to the cent', () {
      final entries = [
        _entry('a', LedgerEntryType.rentCharge, 65.10, _noonUtc(2026, 6, 1)),
        _entry('b', LedgerEntryType.payment, -65.10, _noonUtc(2026, 6, 4)),
        _entry('c', LedgerEntryType.rentCharge, 65.10, _noonUtc(2026, 7, 1)),
        _entry('d', LedgerEntryType.lateFee, 10.25, _noonUtc(2026, 7, 6)),
        _entry('e', LedgerEntryType.payment, -50.00, _noonUtc(2026, 7, 9)),
        _entry('f', LedgerEntryType.credit, -0.35, _noonUtc(2026, 7, 9)),
        _entry('g', LedgerEntryType.rentCharge, 65.10, _noonUtc(2026, 8, 1),
            status: LedgerEntryStatus.pending),
        _entry('h', LedgerEntryType.adjustment, 3.33, _noonUtc(2026, 8, 2),
            status: LedgerEntryStatus.voided),
      ];
      final lines = buildStatementLines(entries);
      expect(lines.closingBalance, sumPostedLedgerEntries(entries));
      // 65.10 - 65.10 + 65.10 + 10.25 - 50.00 - 0.35
      expect(lines.closingBalance, 25.00);
      expect(lines.rows.last.runningBalance, lines.closingBalance);
    });

    test('a row with no description is named by its type', () {
      final lines = buildStatementLines([
        _entry('a', LedgerEntryType.lockCutFee, 20, _noonUtc(2026, 9, 1)),
      ]);
      expect(lines.rows.single.description, 'Lock Cut Fee');
    });

    test('no entries: zero everywhere', () {
      final lines = buildStatementLines(const [], startDate: DateTime(2026, 9, 1));
      expect(lines.balanceForward, 0);
      expect(lines.rows, isEmpty);
      expect(lines.closingBalance, 0);
    });
  });

  group('inStatementPeriod', () {
    test('open on both sides with no dates', () {
      expect(inStatementPeriod(DateTime(1999, 1, 1)), isTrue);
    });

    test('start is inclusive, end runs to the end of its day', () {
      final start = DateTime(2026, 9, 1);
      final end = DateTime(2026, 9, 30);
      expect(inStatementPeriod(start, startDate: start, endDate: end), isTrue);
      expect(
          inStatementPeriod(DateTime(2026, 8, 31, 23, 59),
              startDate: start, endDate: end),
          isFalse);
      expect(
          inStatementPeriod(DateTime(2026, 9, 30, 23, 59, 59),
              startDate: start, endDate: end),
          isTrue);
      expect(inStatementPeriod(DateTime(2026, 10, 1), startDate: start, endDate: end),
          isFalse);
    });
  });
}
