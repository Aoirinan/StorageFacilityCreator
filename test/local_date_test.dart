import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/facility_clock.dart';
import 'package:sfcapp/utils/local_date.dart';
import 'package:sfcapp/utils/request_id.dart';

void main() {
  group('LocalDate', () {
    test('parses YYYY-MM-DD strictly and refuses dates that do not exist', () {
      expect(LocalDate.parse('2026-10-03'), LocalDate(2026, 10, 3));
      expect(LocalDate.tryParse('2026-02-29'), isNull);
      expect(LocalDate.tryParse('2028-02-29'), LocalDate(2028, 2, 29));
      expect(LocalDate.tryParse('2026-13-01'), isNull);
      expect(LocalDate.tryParse('2026-1-5'), isNull);
      expect(LocalDate.tryParse('2026-10-03T00:00:00Z'), isNull);
      expect(LocalDate.tryParse(''), isNull);
      expect(LocalDate.tryParse(null), isNull);
      expect(() => LocalDate.parse('Oct 3'), throwsFormatException);
      expect(() => LocalDate(2026, 2, 30), throwsArgumentError);
      expect(LocalDate.isValidYmd('2026-10-03'), isTrue);
    });

    test('formats with zero padding and round-trips', () {
      final d = LocalDate(2026, 3, 7);
      expect(d.toYmd(), '2026-03-07');
      expect(d.toString(), '2026-03-07');
      expect(d.monthKey, '2026-03');
      expect(LocalDate.parse(d.toYmd()), d);
    });

    test('adds days across months, years and leap days', () {
      expect(LocalDate(2026, 10, 31).addDays(1), LocalDate(2026, 11, 1));
      expect(LocalDate(2026, 12, 31).addDays(1), LocalDate(2027, 1, 1));
      expect(LocalDate(2028, 2, 28).addDays(1), LocalDate(2028, 2, 29));
      expect(LocalDate(2026, 3, 1).addDays(-1), LocalDate(2026, 2, 28));
      expect(LocalDate(2026, 10, 3).addDays(0), LocalDate(2026, 10, 3));
    });

    test('counts days between dates, whatever the DST change in between', () {
      // US DST ends 2026-11-01 and starts 2027-03-14: no 23- or 25-hour day here.
      expect(LocalDate(2026, 10, 31).daysUntil(LocalDate(2026, 11, 2)), 2);
      expect(LocalDate(2027, 3, 13).daysUntil(LocalDate(2027, 3, 15)), 2);
      expect(LocalDate(2026, 10, 3).daysUntil(LocalDate(2026, 10, 1)), -2);
    });

    test('nights leave out the exclusive checkout', () {
      final nights = LocalDate.nights(LocalDate(2026, 10, 30), LocalDate(2026, 11, 2));
      expect(nights.map((n) => n.toYmd()), ['2026-10-30', '2026-10-31', '2026-11-01']);
      expect(LocalDate.nights(LocalDate(2026, 10, 3), LocalDate(2026, 10, 3)), isEmpty);
    });

    test('months spanned are the months of the nights, not the checkout day', () {
      expect(LocalDate.monthsSpanned(LocalDate(2026, 10, 30), LocalDate(2026, 11, 1)), ['2026-10']);
      expect(LocalDate.monthsSpanned(LocalDate(2026, 12, 30), LocalDate(2027, 2, 2)), ['2026-12', '2027-01', '2027-02']);
      expect(LocalDate.monthsSpanned(LocalDate(2026, 10, 3), LocalDate(2026, 10, 3)), isEmpty);
    });

    test('weekday comes from the date alone', () {
      expect(LocalDate(2026, 10, 3).weekday, DateTime.saturday);
      expect(LocalDate(2026, 10, 2).isFridayOrSaturday, isTrue);
      expect(LocalDate(2026, 10, 4).isFridayOrSaturday, isFalse);
    });

    test('compares and orders by date', () {
      final a = LocalDate(2026, 9, 30);
      final b = LocalDate(2026, 10, 1);
      expect(a.isBefore(b), isTrue);
      expect(b.isAfter(a), isTrue);
      expect([b, a]..sort(), [a, b]);
      expect(LocalDate.tryParseMonth('2026-10'), LocalDate(2026, 10, 1));
      expect(LocalDate.tryParseMonth('2026-13'), isNull);
      expect(LocalDate(2026, 12, 15).firstOfNextMonth, LocalDate(2027, 1, 1));
    });
  });

  group('facility clock', () {
    test('Intl parts become a facility-local date and time, midnight as 00', () {
      expect(
        localDateTimeFromParts({'year': '2026', 'month': '11', 'day': '01', 'hour': '24', 'minute': '05'}),
        '2026-11-01 00:05',
      );
      expect(localDateTimeFromParts({'year': '2026', 'month': '11'}), isNull);
      expect(localDateTimeFromParts(null), isNull);
    });

    test('off the web only UTC is answered; any other zone throws instead of guessing', () {
      final clock = IntlFacilityClock(now: () => DateTime.utc(2026, 11, 1, 6, 30));
      expect(clock.todayYmd('UTC'), '2026-11-01');
      expect(clock.nowLocalHm('UTC'), '06:30');
      expect(clock.isValidZone('UTC'), isTrue);
      // In a VM test there is no zone database, so Denver is not usable and
      // the clock refuses rather than falling back to the machine's zone.
      expect(clock.isValidZone('America/Denver'), isFalse);
      expect(() => clock.todayYmd('America/Denver'), throwsA(isA<FacilityTimeZoneException>()));
      expect(clock.isValidZone(null), isFalse);
      expect(clock.isValidZone(''), isFalse);
    });

    test('zones compare in the canonical spelling, and an unknown one has none', () {
      final clock = IntlFacilityClock(now: () => DateTime.utc(2026, 11, 1));
      expect(clock.canonicalZone('Etc/UTC'), 'UTC');
      expect(clock.canonicalZone('UTC'), 'UTC');
      // No zone database in a VM test: the browser build asks Intl instead.
      expect(clock.canonicalZone('America/Denver'), isNull);
      expect(clock.canonicalZone(null), isNull);
      expect(clock.canonicalZone(''), isNull);
      // A fixed clock takes zones as written.
      expect(FixedFacilityClock(todayValue: LocalDate(2026, 11, 1)).canonicalZone('America/Denver'), 'America/Denver');
    });

    test('a fixed clock gives the same facility day whatever the machine zone', () {
      final clock = FixedFacilityClock(
        todayValue: LocalDate(2026, 11, 1),
        nowHm: '01:30',
        utcOffset: const Duration(hours: -7),
      );
      expect(clock.today('America/Denver'), LocalDate(2026, 11, 1));
      expect(clock.nowLocalHm('America/Denver'), '01:30');
      expect(clock.formatInstant(DateTime.utc(2026, 11, 1, 8, 15), 'America/Denver'), '2026-11-01 01:15');
    });
  });

  group('request ids', () {
    test('are 32 lowercase hex characters and differ each time', () {
      final a = newRequestId();
      final b = newRequestId();
      expect(isValidRequestId(a), isTrue);
      expect(a, isNot(b));
      expect(newRequestId(Random(1)), newRequestId(Random(1)));
    });

    test('anything else is refused', () {
      expect(isValidRequestId(null), isFalse);
      expect(isValidRequestId('ABCDEF0123456789ABCDEF0123456789'), isFalse);
      expect(isValidRequestId('abc'), isFalse);
      expect(isValidRequestId('${'a' * 32}/'), isFalse);
    });
  });
}
