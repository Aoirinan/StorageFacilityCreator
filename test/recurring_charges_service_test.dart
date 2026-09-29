import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/recurring_charges_service.dart';
import 'package:sfcapp/utils/callable_failure.dart';

/// A callable error as the plugin raises it.
class _CallableError extends FirebaseFunctionsException {
  _CallableError(String code, String message)
      : super(code: code, message: message);
}

/// The Recurring Charges screen used to post monthly rent from the browser.
/// Its check for an existing charge did not know about rent a move-in had
/// already charged, so it could bill the month twice. It now asks the
/// generateMonthlyRentCharges callable, which decides like the scheduled job.
void main() {
  group('RecurringChargesService.generateMonthlyRentCharges', () {
    test('asks the server, once, and posts nothing itself', () async {
      // No Firebase app exists here: a client-side ledger read or write
      // would fail before reaching the callable.
      final sent = <Map<String, Object?>>[];
      await RecurringChargesService.generateMonthlyRentCharges(
        facilityId: 'fac-1',
        forDate: DateTime(2026, 10, 1),
        callable: (payload) async {
          sent.add(payload);
          return {'success': true, 'successCount': 0, 'skippedCount': 0};
        },
      );
      expect(sent, [
        {
          'facilityId': 'fac-1',
          'forDate': '2026-10-01T00:00:00.000',
          'dryRun': false,
        },
      ]);
    });

    test('a preview is sent as a dry run', () async {
      final sent = <Map<String, Object?>>[];
      await RecurringChargesService.generateMonthlyRentCharges(
        facilityId: 'fac-1',
        forDate: DateTime(2026, 10, 1),
        dryRun: true,
        callable: (payload) async {
          sent.add(payload);
          return {'success': true, 'dryRun': true};
        },
      );
      expect(sent.single['dryRun'], isTrue);
    });

    test("the month sent is the one picked on the operator's calendar", () {
      // Late on the last day of September in the US is already October in
      // UTC. The picked month goes with no offset, which the callable reads
      // as written (see rentChargeMonthFromInput's tests in
      // functions-automation, which use this exact form).
      Object? month(DateTime d) =>
          RecurringChargesService.monthlyRentChargesPayload(
            facilityId: 'f',
            forDate: d,
            dryRun: false,
          )['forDate'];
      expect(month(DateTime(2026, 9, 30, 23, 30)), '2026-09-01T00:00:00.000');
      expect(month(DateTime(2026, 10, 1)), '2026-10-01T00:00:00.000');
      expect(month(DateTime(2027, 1, 15)), '2027-01-01T00:00:00.000');
    });

    test("reads the server's counts and the tenants it lists to check",
        () async {
      final result = await RecurringChargesService.generateMonthlyRentCharges(
        facilityId: 'fac-1',
        forDate: DateTime(2026, 10, 1),
        callable: (_) async => {
          'success': true,
          'totalTenants': 5,
          'successCount': 2,
          'skippedCount': 3,
          'errorCount': 0,
          'errors': [
            'Tenant Ann Lee: not charged, check by hand. Rent charged at '
                r'move-in ($150.00) is at least the monthly rate ($150.00) '
                'though the tenant rents 2 units.',
          ],
          'dryRun': false,
        },
      );
      expect(result.totalTenants, 5);
      expect(result.successCount, 2);
      expect(result.skippedCount, 3);
      expect(result.errorCount, 0);
      expect(result.errors, hasLength(1));
      expect(result.errors.single, contains('check by hand'));
    });

    test('counts the server leaves out read as zero', () async {
      final result = await RecurringChargesService.generateMonthlyRentCharges(
        facilityId: 'fac-1',
        forDate: DateTime(2026, 10, 1),
        callable: (_) async => {'success': true},
      );
      expect(result.successCount, 0);
      expect(result.skippedCount, 0);
      expect(result.errorCount, 0);
      expect(result.errors, isEmpty);
    });

    Future<CallableFailureException> failure(
      FirebaseFunctionsException e, {
      bool dryRun = false,
    }) async {
      try {
        await RecurringChargesService.generateMonthlyRentCharges(
          facilityId: 'fac-1',
          forDate: DateTime(2026, 10, 1),
          dryRun: dryRun,
          callable: (_) async => throw e,
        );
      } on CallableFailureException catch (f) {
        return f;
      }
      fail('expected a CallableFailureException');
    }

    test('a refusal says who can run it and that nothing was charged',
        () async {
      final e = await failure(_CallableError('permission-denied',
          'User does not have permission to generate charges for this facility'));
      expect(e.message, contains('owner or a manager'));
      expect(e.message, contains('Nothing was charged'));
      expect('$e', isNot(contains('firebase_functions')));
    });

    test('a lost connection on a real run says a re-run is safe', () async {
      // The run may have finished on the server. The callable skips a
      // tenant already charged for the month, so running it again cannot
      // bill anyone twice.
      final e = await failure(_CallableError('internal', 'internal'));
      expect(e.message, contains('may have posted'));
      expect(e.message, contains('Running it again is safe'));
    });

    test('a lost connection on a preview says nothing was charged', () async {
      final e = await failure(
        _CallableError('deadline-exceeded', 'deadline-exceeded'),
        dryRun: true,
      );
      expect(e.message, contains('Nothing was charged'));
      expect(e.message, isNot(contains('may have posted')));
    });

    test("the server's own words for an error it explains", () async {
      final e = await failure(
          _CallableError('invalid-argument', 'forDate is not a valid date'));
      expect(e.message, 'forDate is not a valid date');
      expect(e.code, 'invalid-argument');
    });
  });
}
