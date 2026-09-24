import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/utils/callable_failure.dart';
import 'package:sfcapp/widgets/facility_delete_gate.dart';

import 'support/fake_facility_collection.dart';

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
      final e = await failure(_CallableError('unknown', 'UNKNOWN'));
      expect(e.message, contains('Something went wrong on our side'));
    });

    test('a bare internal error, in any case, may be a dropped connection: refresh to check', () async {
      // The web SDK reports a lost connection (HTTP status 0) as code
      // 'internal', message 'internal'. The case-sensitive check showed
      // "Error deleting facility: internal" for a delete that may have run.
      for (final message in ['internal', 'INTERNAL', '']) {
        final e = await failure(_CallableError('internal', message));
        expect(e.message, contains('the delete may not have finished'), reason: message);
        expect(e.message, contains('Refresh the list'), reason: message);
      }
      // The server's own internal message is still shown as written.
      final own = await failure(_CallableError('internal',
          "The facility couldn't be fully deleted. Refresh the list to see what changed, then try again."));
      expect(own.message, startsWith("The facility couldn't be fully deleted."));
    });

    test('codes are matched whatever their case or spelling', () async {
      expect((await failure(_CallableError('PERMISSION_DENIED', 'PERMISSION_DENIED'))).message,
          "Only the facility's owner can delete it. Nothing was deleted.");
      expect((await failure(_CallableError('Not-Found', 'not found'))).message,
          contains('it may already be deleted'));
      expect((await failure(_CallableError('functions/unavailable', 'x'))).message,
          contains('the delete may not have finished'));
    });
  });

  group('an owner is refused while the facility has active tenants', () {
    tearDown(() => FacilitySubcollections.overrideForTesting(null));

    void tenants(List<FakeDoc> docs) => FacilitySubcollections.overrideForTesting(
        (facilityId, name) => FakeCollection(name == 'tenants' ? docs : const []));

    test('active is exactly true: archived and flagless tenants do not block', () async {
      tenants([
        FakeDoc('archived', {'name': 'Bo', 'isActive': false}),
        FakeDoc('legacy', {'name': 'No flag'}),
      ]);
      expect(await FacilityService.facilityDeleteBlocker('fac-1', superAdmin: false), isNull);
    });

    test('counts the active tenants, in the words the server refuses with', () async {
      tenants([
        FakeDoc('a', {'name': 'Ada', 'isActive': true}),
        FakeDoc('b', {'name': 'Bo', 'isActive': true}),
        FakeDoc('c', {'name': 'Cy', 'isActive': false}),
      ]);
      expect(
        await FacilityService.facilityDeleteBlocker('fac-1', superAdmin: false),
        'Nothing was deleted: this facility still has 2 active tenants. '
        'Move them out or archive them first, then delete the facility.',
      );
    });

    test('a super admin is not refused', () async {
      tenants([FakeDoc('a', {'name': 'Ada', 'isActive': true})]);
      expect(await FacilityService.facilityDeleteBlocker('fac-1', superAdmin: true), isNull);
    });

    final facility = FacilityModel(
      id: 'fac-1',
      name: 'Acme Storage',
      ownerUid: 'owner-1',
      createdAt: DateTime(2026, 1, 1),
    );

    // Pumps a Delete button that runs the gate; returns a reader for its answer.
    Future<bool? Function()> press(
        WidgetTester tester, Future<String?> Function(String) blocker) async {
      bool? allowed;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                allowed = await facilityDeleteAllowed(context, facility, blocker: blocker),
            child: const Text('Delete Permanently'),
          ),
        ),
      ));
      await tester.tap(find.text('Delete Permanently'));
      await tester.pumpAndSettle();
      return () => allowed;
    }

    testWidgets('the Delete menu stops before the confirmation, and says why', (tester) async {
      final allowed = await press(tester,
          (_) async => 'Nothing was deleted: this facility still has 1 active tenant.');
      expect(find.text("Can't delete Acme Storage yet"), findsOneWidget);
      expect(find.textContaining('still has 1 active tenant'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(allowed(), isFalse);
    });

    testWidgets('nothing active, or a check that fails: the delete goes on', (tester) async {
      expect((await press(tester, (_) async => null))(), isTrue);
      expect((await press(tester, (_) async => throw StateError('offline')))(), isTrue);
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
