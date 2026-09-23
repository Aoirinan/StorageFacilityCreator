import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/utils/facility_create_recovery.dart';

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
        create: () async => throw Exception('deadline-exceeded'),
        reloadFacilities: () async => [
          _facility('zeta', 'Zeta Storage', age: const Duration(days: 9)),
          _facility('made', 'Oak Storage', age: const Duration(seconds: 5)),
        ],
        now: () => _now,
      );
      expect(id, 'made');
    });

    test('rethrows the create error when nothing it made is found', () async {
      final error = Exception('unavailable');
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
      final error = Exception('unavailable');
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
  });
}
