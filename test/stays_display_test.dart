import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/utils/local_date.dart';

void main() {
  group('dates from YYYY-MM-DD strings', () {
    test('short and weekday labels', () {
      expect(shortDateLabel(LocalDate(2026, 10, 3)), 'Oct 3');
      expect(weekdayDateLabel(LocalDate(2026, 10, 3)), 'Sat, Oct 3');
      expect(monthTitle(LocalDate(2026, 12, 31)), 'December 2026');
      expect(ymdLabel('2026-01-09'), 'Jan 9');
      expect(ymdLabel('not a date'), 'not a date');
    });

    test('a stay counts nights up to the departure day', () {
      expect(stayDatesLabel('2026-10-03', '2026-10-06'), 'Oct 3 – Oct 6 · 3 nights');
      expect(stayDatesLabel('2026-10-31', '2026-11-01'), 'Oct 31 – Nov 1 · 1 night');
    });

    test('nights collapse into runs, across months too', () {
      expect(describeNights(['2026-10-05', '2026-10-03', '2026-10-04', '2026-10-09']), 'Oct 3–5, Oct 9');
      expect(describeNights(['2026-10-31', '2026-11-01']), 'Oct 31 – Nov 1');
      expect(describeNights(['2026-10-03', '2026-10-03']), 'Oct 3');
      expect(describeNights(['bad']), '');
    });
  });

  test('ago labels', () {
    final now = DateTime.utc(2026, 10, 3, 12);
    expect(agoLabel(null, now), 'never');
    expect(agoLabel(now.subtract(const Duration(seconds: 20)), now), 'just now');
    expect(agoLabel(now.subtract(const Duration(minutes: 6)), now), '6 min ago');
    expect(agoLabel(now.subtract(const Duration(hours: 2)), now), '2 h ago');
    expect(agoLabel(now.subtract(const Duration(days: 3)), now), '3 days ago');
  });

  group('money typed in dollars', () {
    test('parses whole and decimal amounts to cents', () {
      expect(parseDollarsToCents('125'), 12500);
      expect(parseDollarsToCents(' 125.5 '), 12550);
      expect(parseDollarsToCents(r'$1,250.05'), 125005);
      expect(parseDollarsToCents(''), isNull);
    });

    test('refuses what it cannot read rather than guessing', () {
      expect(() => parseDollarsToCents('12.345'), throwsFormatException);
      expect(() => parseDollarsToCents('-5'), throwsFormatException);
      expect(() => parseDollarsToCents('ten'), throwsFormatException);
    });

    test('labels cents', () {
      expect(centsLabel(12500), r'$125');
      expect(centsLabel(12505), r'$125.05');
    });
  });

  group('suggestShortCode', () {
    test('initials, short words and numbers', () {
      expect(suggestShortCode('Cabin 2', const []), 'C2');
      expect(suggestShortCode('RV 3', const []), 'RV3');
      expect(suggestShortCode('Blue House', const []), 'BH');
      expect(suggestShortCode('Loft', const []), 'LOF');
    });

    test('never repeats a code in use (any case), and stays within 8 characters', () {
      expect(suggestShortCode('Blue House', const ['bh']), 'BH2');
      expect(suggestShortCode('Blue House', const ['BH', 'BH2']), 'BH3');
      final long = suggestShortCode('A B C D E F G H I J', const ['ABCDEFGH']);
      expect(long.length, lessThanOrEqualTo(8));
      expect(long, isNot('ABCDEFGH'));
    });
  });

  test('every setup kind and channel has a label', () {
    for (final k in setupListingKinds) {
      expect(listingKindLabel(k), isNotEmpty);
    }
    for (final p in importProviders) {
      expect(channelProviderLabel(p), isNot('Calendar'));
      expect(exportTargetFor(p), isNot(ExportTargetProvider.unknown));
    }
  });
}
