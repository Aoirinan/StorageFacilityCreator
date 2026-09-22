import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/sms_consent_import.dart';

void main() {
  group('parseSmsConsent', () {
    test('reads the yes shapes operators actually type', () {
      for (final value in ['Yes', 'y', 'TRUE', '1', 'x', 'opted in', 'signed', 'Checked']) {
        expect(parseSmsConsent(consentValue: value).optedIn, isTrue, reason: value);
      }
    });

    test('reads the no shapes', () {
      for (final value in ['No', 'n', 'FALSE', '0', 'opted out', 'declined', 'n/a', '-']) {
        expect(parseSmsConsent(consentValue: value).optedIn, isFalse, reason: value);
      }
    });

    test('a blank cell is not consent', () {
      expect(parseSmsConsent(consentValue: '').optedIn, isFalse);
      expect(parseSmsConsent(consentValue: null).optedIn, isFalse);
      expect(parseSmsConsent().optedIn, isFalse);
    });

    test('anything ambiguous is treated as no, because guessing wrong texts a stranger', () {
      expect(parseSmsConsent(consentValue: 'maybe').optedIn, isFalse);
      expect(parseSmsConsent(consentValue: 'call first').optedIn, isFalse);
    });

    test('a consent date on its own counts as consent', () {
      final parsed = parseSmsConsent(consentDateValue: '2026-03-14');
      expect(parsed.optedIn, isTrue);
      expect(parsed.consentedAt, DateTime(2026, 3, 14));
    });

    test('accepts the US date shape a spreadsheet exports', () {
      final parsed = parseSmsConsent(consentValue: 'yes', consentDateValue: '3/14/2026');
      expect(parsed.optedIn, isTrue);
      expect(parsed.consentedAt, DateTime(2026, 3, 14));

      final twoDigitYear = parseSmsConsent(consentDateValue: '3/14/26');
      expect(twoDigitYear.consentedAt, DateTime(2026, 3, 14));
    });

    test('a date typed into the consent column itself still counts', () {
      final parsed = parseSmsConsent(consentValue: '2026-01-05');
      expect(parsed.optedIn, isTrue);
      expect(parsed.consentedAt, DateTime(2026, 1, 5));
    });

    test('yes with no date falls back to the import date', () {
      final importedAt = DateTime(2026, 9, 22, 10, 30);
      final parsed = parseSmsConsent(consentValue: 'yes', importedAt: importedAt);
      expect(parsed.consentedAt, importedAt);
    });

    test('a no wins even when a date is present', () {
      final parsed = parseSmsConsent(consentValue: 'no', consentDateValue: '2026-03-14');
      expect(parsed.optedIn, isFalse);
    });

    test('a nonsense date is ignored rather than accepted', () {
      expect(parseSmsConsent(consentDateValue: '13/45/2026').optedIn, isFalse);
      expect(parseSmsConsent(consentDateValue: 'sometime').optedIn, isFalse);
    });
  });

  group('consentIsUsable', () {
    test('consent without a usable mobile number cannot be texted', () {
      expect(consentIsUsable(optedIn: true, phone: null), isFalse);
      expect(consentIsUsable(optedIn: true, phone: ''), isFalse);
      expect(consentIsUsable(optedIn: true, phone: '555-1234'), isFalse);
    });

    test('consent plus a ten digit number is usable', () {
      expect(consentIsUsable(optedIn: true, phone: '406-989-1696'), isTrue);
      expect(consentIsUsable(optedIn: true, phone: '(406) 9891696'), isTrue);
    });

    test('no consent is never usable, however good the number', () {
      expect(consentIsUsable(optedIn: false, phone: '406-989-1696'), isFalse);
    });
  });
}
