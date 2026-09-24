import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/utils/callable_failure.dart';

/// A callable error as the plugin raises it.
class _CallableError extends FirebaseFunctionsException {
  _CallableError(String code, String message, [Object? details])
      : super(code: code, message: message, details: details);
}

/// The owner's Delete facility used to delete subcollection by subcollection
/// in the browser, skip any it couldn't (tenants, once only super admins
/// could delete them), and delete the facility doc anyway, leaving tenant
/// records behind. It now asks the deleteFacilityPermanently callable.
void main() {
  group('FacilityService.deleteFacility', () {
    test('asks the server to delete it, once, and deletes nothing itself', () async {
      // No Firebase app exists here: the old in-browser delete would have
      // failed on its first read instead of reaching the callable.
      final sent = <Map<String, Object?>>[];
      await FacilityService.deleteFacility('fac-1', callable: (payload) async {
        sent.add(payload);
        return {'success': true};
      });
      expect(sent, [
        {'facilityId': 'fac-1'}
      ]);
    });

    Future<CallableFailureException> failure(FirebaseFunctionsException e) async {
      try {
        await FacilityService.deleteFacility('fac-1', callable: (_) async => throw e);
      } on CallableFailureException catch (f) {
        return f;
      }
      fail('expected a CallableFailureException');
    }

    test("the server's own words for a refusal it explains", () async {
      final e = await failure(_CallableError(
        'failed-precondition',
        "Nothing was deleted: confirm it's you with the code we email you, then try again.",
        {'reason': 'two-factor-required'},
      ));
      expect(e.message, contains("confirm it's you"));
      expect(e.code, 'failed-precondition');
      expect('$e', isNot(contains('firebase_functions')));
    });

    test('permission, not found and no connection are worded for the owner', () async {
      expect((await failure(_CallableError('permission-denied', 'PERMISSION_DENIED'))).message,
          "Only the facility's owner can delete it. Nothing was deleted.");
      expect((await failure(_CallableError('not-found', 'NOT_FOUND'))).message,
          contains('it may already be deleted'));
      for (final code in ['unavailable', 'deadline-exceeded']) {
        expect((await failure(_CallableError(code, 'x'))).message,
            contains('the delete may not have finished'),
            reason: code);
      }
      expect((await failure(_CallableError('unauthenticated', 'x'))).message,
          contains('Sign in again'));
    });

    test('a bare error code is not shown as the message', () async {
      final e = await failure(_CallableError('internal', 'INTERNAL'));
      expect(e.message, contains('Something went wrong on our side'));
    });
  });

  test('the facility notifier passes a failed delete on to the screen', () async {
    // It used to record the error and return normally, so the screen said
    // "deleted permanently" whatever happened. With no Firebase app here the
    // real callable cannot be reached, which is the failure it must pass on.
    final notifier = FacilityOperationsNotifier();
    addTearDown(notifier.dispose);
    await expectLater(notifier.hardDeleteFacility('fac-1'), throwsA(anything));
    expect(notifier.state, isA<AsyncError<void>>());
  });
}
