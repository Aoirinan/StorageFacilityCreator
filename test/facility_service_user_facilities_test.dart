import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/facility_service.dart';

FacilityModel _facility(String id, String name, {bool active = true}) {
  return FacilityModel(
    id: id,
    name: name,
    ownerUid: 'owner-1',
    createdAt: DateTime(2026),
    active: active,
  );
}

void main() {
  group('facilityBackfillUpdates (same rules as the old separate backfill query)', () {
    const uid = 'owner-1';

    test('fills a missing active flag and the owner role on owned facilities', () {
      final updates = FacilityService.facilityBackfillUpdates(uid, {
        'needs-both': {'ownerUid': uid, 'name': 'A'},
        'already-fine': {
          'ownerUid': uid,
          'active': true,
          'roles': {uid: 'owner'},
        },
        'wrong-role': {
          'ownerUid': uid,
          'active': false,
          'roles': {uid: 'manager', 'someone-else': 'staff'},
        },
      });

      expect(updates, {
        'needs-both': {'active': true, 'roles.$uid': 'owner'},
        'wrong-role': {'roles.$uid': 'owner'},
      });
    });

    test('never writes to a facility the user does not own', () {
      final updates = FacilityService.facilityBackfillUpdates(uid, {
        'other-owner': {'ownerUid': 'someone-else'},
        'no-owner': {'active': null},
      });
      expect(updates, isEmpty);
    });

    test('treats an archived facility as owned too (the query has no active filter)', () {
      final updates = FacilityService.facilityBackfillUpdates(uid, {
        'archived': {'ownerUid': uid, 'active': false},
      });
      expect(updates, {
        'archived': {'roles.$uid': 'owner'},
      });
    });
  });

  group('mergeUserFacilities', () {
    final owned = [
      _facility('z', 'Zeta Storage'),
      _facility('a', 'Alpha Storage', active: false),
      _facility('m', 'Mid Storage'),
    ];
    final fromRoles = [
      _facility('b', 'Beta Storage'),
      _facility('m', 'Mid Storage'), // also owned: ownership wins
      _facility('g', 'Gamma Storage', active: false),
    ];

    test('drops archived facilities in memory and sorts by name', () {
      // The owner query no longer filters active == true or orders by
      // (active, name) (an index firestore.indexes.json never declared), so
      // both jobs happen here.
      final list = FacilityService.mergeUserFacilities(
        owned: owned,
        fromRoles: fromRoles,
        includeArchived: false,
      );
      expect(list.map((f) => f.name), ['Beta Storage', 'Mid Storage', 'Zeta Storage']);
      expect(
        {for (final f in list) f.id: f.currentUserOwnsFacility},
        {'b': false, 'm': true, 'z': true},
      );
    });

    test('keeps archived facilities when asked', () {
      final list = FacilityService.mergeUserFacilities(
        owned: owned,
        fromRoles: fromRoles,
        includeArchived: true,
      );
      expect(list.map((f) => f.id), ['a', 'b', 'g', 'm', 'z']);
    });

    test('a facility with no active field counts as active, as the backfill makes it', () {
      // FacilityModel reads a missing `active` as true.
      final list = FacilityService.mergeUserFacilities(
        owned: [_facility('n', 'No Flag')],
        fromRoles: const [],
        includeArchived: false,
      );
      expect(list.map((f) => f.id), ['n']);
    });
  });

  group('getUserFacilities cache and shared load (production path, fake read)', () {
    // loadUserFacilitiesFor is what getUserFacilities runs, with the signed-in
    // uid and the Firestore read passed in; everything else is production.
    late Map<String, int> fetches;
    late Map<String, List<Completer<List<FacilityModel>>>> pending;

    setUp(() {
      FacilityService.clearFacilitiesCache();
      fetches = {};
      pending = {};
    });
    tearDown(FacilityService.clearFacilitiesCache);

    /// A read that answers straight away with one facility named after [uid].
    Future<List<FacilityModel>> instant(String uid, {required bool includeArchived}) async {
      fetches[uid] = (fetches[uid] ?? 0) + 1;
      return [_facility('f-$uid', '$uid Storage')];
    }

    /// A read that waits until the test completes it.
    Future<List<FacilityModel>> gated(String uid, {required bool includeArchived}) {
      fetches[uid] = (fetches[uid] ?? 0) + 1;
      final gate = Completer<List<FacilityModel>>();
      (pending[uid] ??= []).add(gate);
      return gate.future;
    }

    Future<List<FacilityModel>> load(
      String uid, {
      required Future<List<FacilityModel>> Function(String uid, {required bool includeArchived})
          fetch,
      bool forceRefresh = false,
      bool throwOnError = false,
    }) {
      return FacilityService.loadUserFacilitiesFor(
        currentUid: () => uid,
        fetch: fetch,
        forceRefresh: forceRefresh,
        throwOnError: throwOnError,
      );
    }

    List<String> names(List<FacilityModel> list) => list.map((f) => f.name).toList();

    test('a cached list is served to its own account without another read', () async {
      await load('uid-A', fetch: instant);
      expect(names(await load('uid-A', fetch: instant)), ['uid-A Storage']);
      expect(fetches['uid-A'], 1);
    });

    test('a cached list is never handed to a different account', () async {
      // The bug: one unkeyed static list, so the next account to sign in on
      // the tab was shown the previous account's facilities for 2 minutes.
      await load('uid-A', fetch: instant);
      expect(names(await load('uid-B', fetch: instant)), ['uid-B Storage']);
      expect(fetches['uid-B'], 1);
    });

    test('a load in flight for one account is never shared with another', () async {
      final a = load('uid-A', fetch: gated);
      final b = load('uid-B', fetch: gated);
      await pumpEventQueue();
      pending['uid-B']!.single.complete([_facility('fb', 'B Storage')]);
      pending['uid-A']!.single.complete([_facility('fa', 'A Storage')]);
      expect(names(await a), ['A Storage']);
      expect(names(await b), ['B Storage']);
    });

    test('concurrent callers for one account share one read', () async {
      final a = load('uid-A', fetch: gated);
      final b = load('uid-A', fetch: gated);
      await pumpEventQueue();
      expect(fetches['uid-A'], 1);
      pending['uid-A']!.single.complete([_facility('fa', 'A Storage')]);
      expect(names(await a), ['A Storage']);
      expect(names(await b), ['A Storage']);
    });

    test('a forced refresh does not join a load already running', () async {
      final old = load('uid-A', fetch: gated);
      await pumpEventQueue();
      final forced = load('uid-A', fetch: gated, forceRefresh: true);
      await pumpEventQueue();
      expect(fetches['uid-A'], 2);
      pending['uid-A']![1].complete([_facility('f2', 'After write')]);
      pending['uid-A']![0].complete([_facility('f1', 'Before write')]);
      expect(names(await forced), ['After write']);
      expect(names(await old), ['Before write']);
    });

    test('a load that started before a forced refresh never overwrites its newer list', () async {
      // The old load finishes last. It used to write its list over the forced
      // one with a fresh 2-minute timestamp.
      final old = load('uid-A', fetch: gated);
      await pumpEventQueue();
      final forced = load('uid-A', fetch: gated, forceRefresh: true);
      await pumpEventQueue();
      pending['uid-A']![1].complete([_facility('f2', 'After write')]);
      await forced;
      pending['uid-A']![0].complete([_facility('f1', 'Before write')]);
      await old;

      expect(names(await load('uid-A', fetch: instant)), ['After write']);
      expect(fetches['uid-A'], 2, reason: 'served from the forced load\'s cache');
    });

    test('a load that started before clearFacilitiesCache is not cached', () async {
      // e.g. accepting an invite clears the cache; a load already under way
      // read the facilities before the new role existed.
      final old = load('uid-A', fetch: gated);
      await pumpEventQueue();
      FacilityService.clearFacilitiesCache();
      pending['uid-A']!.single.complete([_facility('f1', 'Before invite')]);
      await old;

      expect(names(await load('uid-A', fetch: instant)), ['uid-A Storage']);
      expect(fetches['uid-A'], 2);
    });

    testWidgets('a hung read releases its waiters after the timeout', (tester) async {
      // Callers share one load, so a read that never settled used to hold
      // every later caller, the route guard's access check included.
      expect(FacilityService.facilityLoadTimeout, const Duration(seconds: 15));
      List<FacilityModel>? first;
      unawaited(load('uid-A', fetch: gated).then((l) => first = l));
      await tester.pump(FacilityService.facilityLoadTimeout - const Duration(seconds: 1));
      List<FacilityModel>? joined;
      unawaited(load('uid-A', fetch: gated).then((l) => joined = l));
      await tester.pump();
      expect(fetches['uid-A'], 1, reason: 'inside the timeout it joins the hung read');
      expect(first, isNull);

      await tester.pump(const Duration(seconds: 2));
      expect(first, isEmpty);
      expect(joined, isEmpty);

      // The slot is free again, so the next caller reads afresh.
      List<FacilityModel>? retry;
      unawaited(load('uid-A', fetch: gated).then((l) => retry = l));
      await tester.pump();
      expect(fetches['uid-A'], 2);
      pending['uid-A']![1].complete([_facility('f1', 'Keepsake')]);
      await tester.pump();
      expect(names(retry!), ['Keepsake']);
    });

    test('a failed read is [] by default and an error when asked', () async {
      Future<List<FacilityModel>> failing(String uid, {required bool includeArchived}) =>
          Future.error(StateError('offline'));

      expect(await load('uid-A', fetch: failing), isEmpty);
      await expectLater(load('uid-A', fetch: failing, throwOnError: true), throwsStateError);
    });

    test('signed out is [] by default and an error when asked', () async {
      Future<List<FacilityModel>> run({bool throwOnError = false}) =>
          FacilityService.loadUserFacilitiesFor(
            currentUid: () => null,
            fetch: instant,
            throwOnError: throwOnError,
          );
      expect(await run(), isEmpty);
      await expectLater(run(throwOnError: true), throwsException);
      expect(fetches, isEmpty);
    });
  });
}
