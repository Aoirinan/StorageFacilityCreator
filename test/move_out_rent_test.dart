import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/move_out_rent.dart';
import 'package:sfcapp/services/move_out_service.dart';

/// The move-out rent line, by the table processMoveOut runs too. It charged
/// "Prorated Rent (24 days) $0.80" to a tenant whose tenancy starts 1 Oct,
/// moved out on 24 Sep, while October, paid at move-in, stayed charged.
void main() {
  final fixture = jsonDecode(File(
          'functions-tenant-lifecycle/src/test/fixtures/moveOutRent.json')
      .readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  /// A ledger document's data as Firestore returns it: entryDate a Timestamp.
  Map<String, dynamic> asRead(Map<String, dynamic> row) => {
        ...row,
        if (row['entryDate'] != null)
          'entryDate':
              Timestamp.fromDate(DateTime.parse(row['entryDate'] as String)),
      };

  test('MoveOutRent.line matches the shared table, as processMoveOut does', () {
    expect(cases.length, greaterThan(10));
    for (final c in cases) {
      final name = c['name'] as String;
      final unitMoveIn = c['unitMoveInDate'] as String?;
      final line = MoveOutRent.line(
        monthlyRate: (c['monthlyRate'] as num).toDouble(),
        moveOutDay: MoveOutRent.wallDayOf(c['moveOutDate'] as String)!,
        contractId: 'c1',
        rows: (c['rows'] as List).cast<Map<String, dynamic>>().map(asRead),
        unitMoveInDate:
            unitMoveIn == null ? null : Timestamp.fromDate(DateTime.parse(unitMoveIn)),
      );
      expect(line.chargeDays, c['chargeDays'], reason: name);
      expect(line.chargeAmount, (c['chargeAmount'] as num).toDouble(), reason: name);
      expect(line.creditDays, c['creditDays'], reason: name);
      expect(line.creditAmount, (c['creditAmount'] as num).toDouble(), reason: name);
      expect(line.moveInDate, c['moveInDate'], reason: name);
    }
  });

  test('wall dates are read as processMoveOut reads the one the app sends', () {
    for (final row in (fixture['wallDates'] as List).cast<List>()) {
      final day = MoveOutRent.wallDayOf(row[0] as String);
      expect(day == null ? null : MoveOutRent.isoDay(day), row[1], reason: row[0] as String);
    }
    // What the screen sends: its picked date's toIso8601String().
    final picked = DateTime(2026, 9, 24);
    expect(MoveOutRent.wallDayOf(picked.toIso8601String()), MoveOutRent.wallDay(picked));
  });

  test('a month stored as a double still names its month', () {
    final found = MoveOutRent.coverage([
      {
        'status': 'posted',
        'metadata': {'chargeType': 'monthlyRent', 'month': 6.0, 'year': 2026.0},
      },
    ], 'c1');
    expect(found.periods, hasLength(1));
    expect(MoveOutRent.isoDay(found.periods.single.start), '2026-06-01');
    expect(MoveOutRent.isoDay(found.periods.single.end), '2026-06-30');
  });

  group('the three cases a test move-out raised', () {
    Map<String, dynamic> find(String fragment) =>
        cases.firstWhere((c) => (c['name'] as String).contains(fragment));

    test('before a future move-in date: nothing charged, the prepaid month back', () {
      final c = find('before a tenancy starting 1 Oct, October prorated and paid online');
      expect(c['chargeAmount'], 0);
      expect(c['creditAmount'], 1);
    });

    test('mid-month move-in then out the same month: not charged from the 1st', () {
      expect(find('mid-month move-in on 10 Sep, moved out on 20 Sep')['chargeAmount'], 0);
    });

    test("after the month's rent posted: not charged again", () {
      final c = find("after June's rent posted");
      expect(c['chargeAmount'], 0);
      expect(c['creditAmount'], 100);
    });
  });

  group('the move-out lines built from the rent line', () {
    final day = DateTime(2026, 9, 24);

    test('out before a tenancy starting 1 Oct: no charge, the prepaid October a credit, refundable', () {
      final c = MoveOutService.buildCalculation(
        currentBalance: 0,
        moveOutDate: day,
        rent: const MoveOutRentLine(
          chargeDays: 0,
          chargeAmount: 0,
          creditDays: 31,
          creditAmount: 1,
          moveInDate: '2026-10-01',
        ),
      );
      expect(c.lineItems.map((i) => (i.description, i.amount)),
          [('Prorated Rent Credit (31 unused days)', -1.0)]);
      expect(c.newCharges, -1);
      expect(c.finalBalance, -1);
      expect(c.refundAmount, 1);
      expect(c.prorateRent, isTrue);
      expect(c.fees, 0);
    });

    test('rent for days used, and fees, as processMoveOut posts them', () {
      final c = MoveOutService.buildCalculation(
        currentBalance: 10,
        moveOutDate: day,
        rent: const MoveOutRentLine(
          chargeDays: 4,
          chargeAmount: 13.33,
          creditDays: 31,
          creditAmount: 1,
          moveInDate: null,
        ),
        cleaningFee: 25,
        damageFee: 0,
        otherFees: double.nan,
      );
      expect(c.lineItems.map((i) => (i.description, i.amount)), [
        ('Prorated Rent (4 days)', 13.33),
        ('Prorated Rent Credit (31 unused days)', -1.0),
        ('Cleaning Fee', 25.0),
      ]);
      // moveOutLines' net for the same line and fees (moveOutRent.test.ts).
      expect(c.newCharges, 37.33);
      expect(c.fees, 25);
      expect(c.finalBalance, 47.33);
      expect(c.refundAmount, 0);
    });

    test('not prorating: no rent line, and the callable is told so', () {
      final c = MoveOutService.buildCalculation(
        currentBalance: -5,
        moveOutDate: day,
        otherFees: 2.5,
      );
      expect(c.prorateRent, isFalse);
      expect(c.newCharges, 2.5);
      expect(c.refundAmount, 2.5);
    });
  });
}
