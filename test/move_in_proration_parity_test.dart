import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/prorate_service.dart';

void main() {
  // The same file functions-public-website/src/test/moveInCharges.test.ts runs
  // through the server's calculateProratedRent. The online move-in page sends
  // the total it priced, and createPublicMoveInCheckout refuses a total that
  // is a cent off its own, so the two have to agree on the day and on the
  // rounding. They disagreed on both: the server billed a day short whenever
  // the move-in had a time of day (and nothing on a month's last day), and the
  // page priced a no-date move-in from the browser's local date, a day behind
  // the server's UTC date every evening in the Americas.
  final fixture = jsonDecode(
    File('test/fixtures/move_in_proration.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = fixture['cases']! as List<Object?>;

  test('the fixture has the cases the two sides share', () {
    expect(cases.length, greaterThanOrEqualTo(15));
  });

  for (final raw in cases) {
    final c = raw! as Map<String, Object?>;
    final name = c['name']! as String;
    final monthlyRate = (c['monthlyRate']! as num).toDouble();
    final at = DateTime.parse(c['at']! as String);
    final days = c['days']! as int;
    final daysInMonth = c['daysInMonth']! as int;
    final amount = (c['amount']! as num).toDouble();

    test('a chosen move-in date prices as the server does: $name', () {
      // getPublicReservationByToken sends a chosen date as an ISO instant,
      // which the page parses as it is parsed here.
      expect(at.isUtc, isTrue);
      expect(
        ProrateService.calculateProratedRent(
          monthlyRate: monthlyRate,
          moveInDate: at,
        ),
        amount,
      );
      expect(ProrateService.calculateDaysRemainingInMonth(at), days);
      expect(ProrateService.getLastDayOfMonth(at).day, daysInMonth);
    });

    test(
        'a move-in with no date, priced at that moment, prices as the server '
        'does: $name', () {
      // The browser's clock reads local time. Whatever this machine's zone,
      // the page must price the UTC date, as checkout will.
      final pricedFrom = ProrateService.onlineMoveInPricingDate(
        null,
        now: at.toLocal(),
      );
      expect(pricedFrom.isUtc, isTrue);
      expect(pricedFrom, at);
      expect(
        ProrateService.calculateProratedRent(
          monthlyRate: monthlyRate,
          moveInDate: pricedFrom,
        ),
        amount,
      );
      expect(ProrateService.calculateDaysRemainingInMonth(pricedFrom), days);
    });
  }

  test('a chosen move-in date is priced as given, not moved to another zone',
      () {
    final chosen = DateTime.utc(2026, 9, 25);
    expect(
      ProrateService.onlineMoveInPricingDate(
        chosen,
        now: DateTime.utc(2026, 9, 1, 12),
      ),
      same(chosen),
    );
  });

  test('a local evening that is already tomorrow in UTC prices tomorrow', () {
    // Built from a UTC instant so it holds on any runner: 01:00 UTC on
    // 16 Sep, which is the evening of the 15th anywhere in the Americas.
    final evening = DateTime.utc(2026, 9, 16, 1).toLocal();
    final pricedFrom =
        ProrateService.onlineMoveInPricingDate(null, now: evening);
    expect(
      [pricedFrom.year, pricedFrom.month, pricedFrom.day],
      [2026, 9, 16],
    );
    expect(ProrateService.calculateDaysRemainingInMonth(pricedFrom), 15);
  });
}
