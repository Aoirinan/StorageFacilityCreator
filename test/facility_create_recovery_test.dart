import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/utils/facility_create_recovery.dart';

FirebaseException _firestoreError(String code) =>
    FirebaseException(plugin: 'cloud_firestore', code: code);

// What FacilityService.createFacility throws before writing anything.
final _subscriptionRequired = Exception(
  'Active subscription required to create additional facilities. '
  'Please subscribe to continue.',
);
final _badUnitCount = Exception('Total units must be between 1 and 5000.');

final _now = DateTime(2026, 9, 23, 12);

FacilityModel _facility(
  String id,
  String name, {
  Duration age = Duration.zero,
  bool owned = true,
}) =>
    FacilityModel(
      id: id,
      name: name,
      ownerUid: owned ? 'me' : 'someone-else',
      currentUserOwnsFacility: owned,
      createdAt: _now.subtract(age),
    );

void main() {
  group('findJustCreatedFacility', () {
    test('finds the facility this attempt made', () {
      final found = findJustCreatedFacility(
        [
          _facility('old', 'Main St', age: const Duration(days: 30)),
          _facility('new', 'Oak Storage', age: const Duration(seconds: 20)),
        ],
        name: 'Oak Storage',
        now: _now,
      );
      expect(found?.id, 'new');
    });

    // getUserFacilities sorts by name. The wizard took facilities.last, so a
    // failed create carried on as whichever facility sorted last, one the
    // owner already had.
    test('is not the last facility in the list', () {
      final found = findJustCreatedFacility(
        [
          _facility('new', 'Acme Storage', age: const Duration(seconds: 20)),
          _facility('zeta', 'Zeta Storage', age: const Duration(days: 300)),
        ],
        name: 'Acme Storage',
        now: _now,
      );
      expect(found?.id, 'new');
    });

    test('is nothing when no facility of that name was just made', () {
      expect(
        findJustCreatedFacility(
          [
            _facility('a', 'Zeta Storage', age: const Duration(seconds: 20)),
            _facility('b', 'Oak Storage', age: const Duration(hours: 2)),
          ],
          name: 'Oak Storage',
          now: _now,
        ),
        isNull,
      );
      expect(findJustCreatedFacility([], name: 'Oak', now: _now), isNull);
    });

    test('ignores facilities the user only has a role at', () {
      expect(
        findJustCreatedFacility(
          [_facility('staff', 'Oak Storage', owned: false)],
          name: 'Oak Storage',
          now: _now,
        ),
        isNull,
      );
    });

    test('takes the newest of several, and ignores surrounding spaces', () {
      final found = findJustCreatedFacility(
        [
          _facility('first', 'Oak Storage', age: const Duration(minutes: 3)),
          _facility('second', 'Oak Storage ', age: const Duration(minutes: 1)),
        ],
        name: ' Oak Storage',
        now: _now,
      );
      expect(found?.id, 'second');
    });
  });

  group('createFacilityOrRecover', () {
    test('returns the new id and does not re-read on success', () async {
      var reloads = 0;
      final id = await createFacilityOrRecover(
        name: 'Oak Storage',
        create: () async => 'created',
        reloadFacilities: () async {
          reloads++;
          return [];
        },
        now: () => _now,
      );
      expect(id, 'created');
      expect(reloads, 0);
    });

    test('carries on with the facility a timed-out create made', () async {
      final id = await createFacilityOrRecover(
        name: 'Oak Storage',
        create: () async => throw _firestoreError('deadline-exceeded'),
        reloadFacilities: () async => [
          _facility('zeta', 'Zeta Storage', age: const Duration(days: 9)),
          _facility('made', 'Oak Storage', age: const Duration(seconds: 5)),
        ],
        now: () => _now,
      );
      expect(id, 'made');
    });

    test('rethrows the create error when nothing it made is found', () async {
      final error = _firestoreError('unavailable');
      await expectLater(
        createFacilityOrRecover(
          name: 'Oak Storage',
          create: () async => throw error,
          // The old fallback went on as this one.
          reloadFacilities: () async => [_facility('zeta', 'Zeta Storage')],
          now: () => _now,
        ),
        throwsA(same(error)),
      );
    });

    test('rethrows the create error when the re-check fails too', () async {
      final error = _firestoreError('unavailable');
      await expectLater(
        createFacilityOrRecover(
          name: 'Oak Storage',
          create: () async => throw error,
          reloadFacilities: () async => throw Exception('offline'),
          now: () => _now,
        ),
        throwsA(same(error)),
      );
    });

    // Every error was treated as "maybe created". A refusal, with a
    // same-name facility made minutes earlier (the owner's first try), was
    // swallowed: the wizard set that facility up again and said "created".
    for (final (label, refusal) in [
      ('subscription required', _subscriptionRequired),
      ('unit count out of range', _badUnitCount),
      ('permission denied', _firestoreError('permission-denied')),
    ]) {
      test('passes a refusal on without looking: $label', () async {
        var reloads = 0;
        await expectLater(
          createFacilityOrRecover(
            name: 'Oak Storage',
            create: () async => throw refusal,
            reloadFacilities: () async {
              reloads++;
              return [
                _facility('first-oak', 'Oak Storage',
                    age: const Duration(minutes: 2)),
              ];
            },
            now: () => _now,
          ),
          throwsA(same(refusal)),
        );
        expect(reloads, 0);
      });
    }

    // Offline, the Firestore write waits for a connection, so the create
    // never finished and the wizard spun until the page was closed.
    testWidgets('stops waiting for a create that never finishes, then looks',
        (tester) async {
      String? id;
      Object? error;
      unawaited(
        createFacilityOrRecover(
          name: 'Oak Storage',
          create: () => Completer<String>().future,
          reloadFacilities: () async => [
            _facility('made', 'Oak Storage', age: const Duration(seconds: 5)),
          ],
          now: () => _now,
        ).then((v) => id = v, onError: (Object e) => error = e),
      );

      await tester.pump(facilityCreateTimeout - const Duration(seconds: 1));
      expect(id, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(error, isNull);
      expect(id, 'made');
    });

    testWidgets('a create that timed out and made nothing reports the timeout',
        (tester) async {
      Object? error;
      unawaited(
        createFacilityOrRecover(
          name: 'Oak Storage',
          create: () => Completer<String>().future,
          reloadFacilities: () async => [],
          now: () => _now,
        ).then((_) {}, onError: (Object e) => error = e),
      );

      await tester.pump(facilityCreateTimeout + const Duration(seconds: 1));
      expect(error, isA<TimeoutException>());
      expect(facilityCreateMayHaveLanded(error!), isTrue);
    });
  });

  // A timeout did not cancel the create: offline, Firestore sends the
  // queued write on reconnect. The wizard turned Create back on, and a
  // second Create made a second facility when both writes landed.
  group('a create kept after a timeout', () {
    late int starts;
    late Completer<String> firstCreate;
    late List<(String?, Object?)> settled;
    late FacilityCreateInFlight inFlight;

    // Called in each test body, not setUp: in the test's zone, so pump
    // sees the create complete.
    void start() {
      starts = 0;
      firstCreate = Completer<String>();
      settled = [];
      inFlight = FacilityCreateInFlight(
        onSettled: (id, error) => settled.add((id, error)),
      );
    }

    /// Create as the wizard does it: through [inFlight].
    Future<String> create(
      String name, {
      Future<String> Function()? start,
      List<FacilityModel> found = const [],
    }) =>
        createFacilityOrRecover(
          name: name,
          create: () {
            starts++;
            return start == null ? firstCreate.future : start();
          },
          reloadFacilities: () async => found,
          inFlight: inFlight,
          now: () => _now,
        );

    /// Starts a create that times out with nothing found, as offline.
    Future<Object?> timeOut(WidgetTester tester, [String name = 'Oak Storage']) async {
      Object? error;
      unawaited(create(name).then((_) {}, onError: (Object e) => error = e));
      await tester.pump(facilityCreateTimeout + const Duration(seconds: 1));
      return error;
    }

    testWidgets('is still running, and a second Create waits for it',
        (tester) async {
      start();
      expect(await timeOut(tester), isA<TimeoutException>());
      expect(inFlight.isRunning, isTrue);

      String? id;
      unawaited(create('Oak Storage').then((v) => id = v));
      await tester.pump();
      expect(starts, 1);

      firstCreate.complete('made');
      await tester.pump();
      expect(id, 'made');
      expect(starts, 1);
      expect(inFlight.isRunning, isFalse);
      expect(settled, [('made', null)]);
    });

    testWidgets('finished late: the next Create takes its facility',
        (tester) async {
      start();
      await timeOut(tester);
      firstCreate.complete('made-late');
      await tester.pump();
      expect(inFlight.isRunning, isFalse);
      expect(inFlight.createdId, 'made-late');
      expect(settled, [('made-late', null)]);

      String? id;
      unawaited(create('Oak Storage').then((v) => id = v));
      await tester.pump();
      expect(id, 'made-late');
      expect(starts, 1);
    });

    testWidgets('failed late: dropped, and the next Create starts afresh',
        (tester) async {
      start();
      await timeOut(tester);
      final refusal = _firestoreError('permission-denied');
      firstCreate.completeError(refusal);
      await tester.pump();
      expect(inFlight.isRunning, isFalse);
      expect(inFlight.createdId, isNull);
      expect(settled, [(null, refusal)]);

      String? id;
      unawaited(
        create('Oak Storage', start: () async => 'second').then((v) => id = v),
      );
      await tester.pump();
      expect(id, 'second');
      expect(starts, 2);
    });

    // The owner may have changed the name before trying again.
    testWidgets('is looked for by the name it was started with',
        (tester) async {
      start();
      await timeOut(tester, 'Oak Storage');
      String? id;
      unawaited(
        create(
          'Oak Storage Renamed',
          found: [
            _facility('made', 'Oak Storage', age: const Duration(seconds: 5)),
          ],
        ).then((v) => id = v),
      );
      await tester.pump(facilityCreateTimeout + const Duration(seconds: 1));
      expect(id, 'made');
      expect(starts, 1);
    });
  });

  group('facilityCreateMayHaveLanded', () {
    test('a timeout or lost connection may have written the facility', () {
      expect(facilityCreateMayHaveLanded(TimeoutException('slow')), isTrue);
      for (final code in [
        'unavailable',
        'deadline-exceeded',
        'network-request-failed',
      ]) {
        expect(
          facilityCreateMayHaveLanded(_firestoreError(code)),
          isTrue,
          reason: code,
        );
      }
    });

    // The wizard adds "Check Facilities before retrying: the facility may
    // have been created" only for these.
    test('a refusal wrote nothing', () {
      expect(facilityCreateMayHaveLanded(_subscriptionRequired), isFalse);
      expect(facilityCreateMayHaveLanded(_badUnitCount), isFalse);
      expect(
        facilityCreateMayHaveLanded(_firestoreError('permission-denied')),
        isFalse,
      );
      expect(facilityCreateMayHaveLanded(Exception('Not signed in')), isFalse);
    });
  });

  // FacilityCreationWizard needs Firebase to reach Create, so how it calls
  // these is checked in its source.
  test('the wizard re-reads from the server and hints only when it may exist',
      () {
    final wizard =
        File('lib/screens/facility_creation_wizard.dart').readAsStringSync();
    // A plain read could join a load started before the create.
    expect(wizard, contains('getUserFacilities(forceRefresh: true)'));
    expect(wizard, contains('createUnconfirmed = facilityCreateMayHaveLanded(e);'));
    expect(wizard, isNot(contains('createUnconfirmed = true;')));
  });

  // FacilityCreationWizard needs Firebase to reach Create, so its use of
  // FacilityCreateInFlight is checked in its source.
  test('the wizard keeps its create, and Create is off while it runs', () {
    final wizard =
        File('lib/screens/facility_creation_wizard.dart').readAsStringSync();
    expect(wizard, contains('inFlight: _inFlightCreate,'));
    expect(
      RegExp(r'onPressed: _isLoading \|\|\s+_createdFacilityId != null \|\|'
              r'\s+_inFlightCreate\.isRunning\s+\? null')
          .hasMatch(wizard),
      isTrue,
    );
    expect(
      RegExp(r'_inFlightCreate\.isRunning\)\s*\{\s*return;').hasMatch(wizard),
      isTrue,
    );
  });
}
