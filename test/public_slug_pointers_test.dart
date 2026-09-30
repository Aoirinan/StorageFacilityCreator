// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_map_v2_models.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';

import 'support/fake_firestore_store.dart';

// A public map slug change used to leave the old publicFacilityMaps doc with
// its full unit list, never synced again, so old links served a frozen list;
// and getPublicSlugForFacility answered with whichever doc sorted first.

/// facilities/*: every read refused, as the rules refuse mapEngine/meta to
/// staff and signed-out visitors.
class _DeniedCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) => _DeniedDoc();
}

class _DeniedDoc extends Fake implements DocumentReference<Map<String, dynamic>> {
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      _DeniedCollection();

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future.error(
          FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'));
}

const _facility = 'kT4mZ8vLr2QpWx7NbY3d';
const _live = 'pinewoodonlinerentals';

Map<String, dynamic> _map(String slug,
        {String facilityId = _facility, int units = 3, Object? syncedAt}) =>
    {
      'facilityId': facilityId,
      'facilitySlug': slug,
      'publishedAt': Timestamp.fromDate(DateTime(2026, 9, 1)),
      if (syncedAt != null) 'inventorySyncedAt': syncedAt,
      'publicSettings': {'enabled': true, 'facilityName': 'Pinewood'},
      'units': [
        for (var i = 0; i < units; i++) {'unitId': 'u$i', 'isRentable': true},
      ],
      'rentalRouteTemplate': '/f/$slug/rent?unitId={unitId}',
    };

Map<String, dynamic> _pointer(String to, {String facilityId = _facility}) =>
    {'facilityId': facilityId, 'movedToSlug': to, 'movedAt': 'then'};

void main() {
  late FakeStore store;

  setUp(() {
    store = FakeStore();
    FacilityMapV2Service.overrideForTesting(
      collection: store.collection,
      batch: store.batch,
      currentUser: () => MockUser(uid: 'owner-1'),
    );
  });
  tearDown(FacilityMapV2Service.overrideForTesting);

  void meta(String slug) => store.put(
      'facilities/$_facility/mapEngine/meta', {'publicSlug': slug});

  String? metaSlug() =>
      store.data('facilities/$_facility/mapEngine/meta')?['publicSlug'] as String?;

  group('setPublicSlug', () {
    test('turns the old slug into a pointer and carries its map to the new one',
        () async {
      meta('storage');
      store.put('publicFacilityMaps/storage', _map('storage'));

      final slug = await FacilityMapV2Service.setPublicSlug(
          facilityId: _facility, slug: 'Pinewood Online Rentals');

      expect(slug, 'pinewood-online-rentals');
      expect(metaSlug(), 'pinewood-online-rentals');
      final pointer = store.data('publicFacilityMaps/storage')!;
      expect(pointer.keys, unorderedEquals(['facilityId', 'movedToSlug', 'movedAt']));
      expect(pointer['facilityId'], _facility);
      expect(pointer['movedToSlug'], 'pinewood-online-rentals');
      expect(pointer['movedAt'], FieldValue.serverTimestamp());

      final carried = store.data('publicFacilityMaps/pinewood-online-rentals')!;
      expect(carried['facilityId'], _facility);
      expect(carried['facilitySlug'], 'pinewood-online-rentals');
      expect(carried['rentalRouteTemplate'],
          '/f/pinewood-online-rentals/rent?unitId={unitId}');
      expect(carried['units'], hasLength(3));
      expect(carried.containsKey('movedToSlug'), isFalse);
    });

    test('old links serve the current map straight away', () async {
      meta('storage');
      store.put('publicFacilityMaps/storage', _map('storage'));
      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: _live);

      final served = await FacilityMapV2Service.resolvePublicMap('storage');
      expect(served?.slug, _live);
      expect(served?.snapshot.facilityId, _facility);
      expect(served?.snapshot.units, hasLength(3));
      expect(
          (await FacilityMapV2Service.getPublicSnapshotBySlug('storage'))
              ?.facilitySlug,
          _live);
    });

    test('an unchanged slug writes only the meta', () async {
      meta(_live);
      store.put('publicFacilityMaps/$_live', _map(_live));

      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: _live);

      expect(store.writes, ['set facilities/$_facility/mapEngine/meta']);
      expect(store.data('publicFacilityMaps/$_live')!['units'], hasLength(3));
    });

    test('with no old doc, or none of its own, only the meta changes', () async {
      meta('never-published');
      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: _live);
      expect(store.writes, ['set facilities/$_facility/mapEngine/meta']);

      store.writes.clear();
      store.put('publicFacilityMaps/theirs', _map('theirs', facilityId: 'other'));
      meta('theirs');
      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: 'mine');
      expect(store.writes, ['set facilities/$_facility/mapEngine/meta']);
      expect(store.data('publicFacilityMaps/theirs')!['units'], hasLength(3));
    });

    test("another facility's slug is refused, and nothing is written", () async {
      meta('storage');
      store.put('publicFacilityMaps/storage', _map('storage'));
      store.put('publicFacilityMaps/rival', _map('rival', facilityId: 'rival-facility'));

      await expectLater(
        FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: 'rival'),
        throwsA(isA<PublicSlugTakenException>()
            .having((e) => e.toString(), 'message', contains('"rival"'))),
      );
      expect(store.writes, isEmpty);
      expect(metaSlug(), 'storage');
      expect(store.data('publicFacilityMaps/storage')!['units'], hasLength(3));
      // Shown as it is, not as a generic error (facility edit screen).
      expect(ErrorMessageHelper.getUserFriendlyMessage(PublicSlugTakenException('rival')),
          contains('"rival" is already used by another facility'));
    });

    test('the meta, the carried map and the pointer land together or not at all',
        () async {
      meta('storage');
      store.put('publicFacilityMaps/storage', _map('storage'));
      store.refuseWrite = (path) => path == 'publicFacilityMaps/storage';

      await expectLater(
        FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: _live),
        throwsA(isA<FirebaseException>()),
      );
      expect(store.writes, isEmpty);
      expect(metaSlug(), 'storage');
      expect(store.data('publicFacilityMaps/$_live'), isNull);
    });

    test('returning to a slug it once left makes that slug the map again',
        () async {
      meta(_live);
      store.put('publicFacilityMaps/$_live', _map(_live, units: 4));
      store.put('publicFacilityMaps/storage', _pointer(_live));

      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: 'storage');

      final back = store.data('publicFacilityMaps/storage')!;
      expect(back.containsKey('movedToSlug'), isFalse);
      expect(back['units'], hasLength(4));
      expect(store.data('publicFacilityMaps/$_live')!['movedToSlug'], 'storage');
      expect((await FacilityMapV2Service.resolvePublicMap(_live))?.slug, 'storage');
    });

    test('a second change repoints the first one\'s pointers, so none is two hops',
        () async {
      meta('storage');
      store.put('publicFacilityMaps/storage', _map('storage'));
      store.put('publicFacilityMaps/theirs', _pointer('storage', facilityId: 'other'));
      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: 'second');
      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: _live);

      for (final slug in ['storage', 'second']) {
        expect(store.data('publicFacilityMaps/$slug')!['movedToSlug'], _live,
            reason: slug);
        expect((await FacilityMapV2Service.resolvePublicMap(slug))?.slug, _live,
            reason: slug);
      }
      // Another facility's doc is never rewritten.
      expect(store.data('publicFacilityMaps/theirs')!['movedToSlug'], 'storage');

      // And a third, back to the first slug: it is the map again, the rest
      // point at it.
      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: 'storage');
      expect(store.data('publicFacilityMaps/storage')!.containsKey('movedToSlug'),
          isFalse);
      for (final slug in ['second', _live]) {
        expect((await FacilityMapV2Service.resolvePublicMap(slug))?.slug, 'storage',
            reason: slug);
      }
    });

    test('a meta that named a pointer repoints it, with no map to carry', () async {
      meta('storage');
      store.put('publicFacilityMaps/storage', _pointer('older'));

      await FacilityMapV2Service.setPublicSlug(facilityId: _facility, slug: _live);

      expect(store.data('publicFacilityMaps/storage')!['movedToSlug'], _live);
      expect(store.data('publicFacilityMaps/$_live'), isNull);
    });
  });

  group('resolvePublicMap', () {
    test('a published map is served where it is', () async {
      store.put('publicFacilityMaps/$_live', _map(_live));
      final served = await FacilityMapV2Service.resolvePublicMap(_live);
      expect(served?.slug, _live);
      expect(served?.snapshot.units, hasLength(3));
      expect(await FacilityMapV2Service.resolvePublicMap('missing'), isNull);
    });

    test("a pointer to another facility's map is not followed", () async {
      store.put('publicFacilityMaps/rival', _map('rival', facilityId: 'rival-facility'));
      store.put('publicFacilityMaps/storage', _pointer('rival'));
      expect(await FacilityMapV2Service.resolvePublicMap('storage'), isNull);
      expect(await FacilityMapV2Service.getPublicSnapshotBySlug('storage'), isNull);
    });

    test('one hop only: not to another pointer, to itself, or to nothing',
        () async {
      store.put('publicFacilityMaps/$_live', _map(_live));
      store.put('publicFacilityMaps/storage', _pointer(_live));
      store.put('publicFacilityMaps/older', _pointer('storage'));
      store.put('publicFacilityMaps/loop', _pointer('loop'));
      store.put('publicFacilityMaps/dangling', _pointer('gone'));
      store.put('publicFacilityMaps/anon', {'movedToSlug': _live});
      for (final slug in ['older', 'loop', 'dangling', 'anon']) {
        expect(await FacilityMapV2Service.resolvePublicMap(slug), isNull,
            reason: slug);
      }
    });

    test("a publish over a pointer serves the map, not the pointer's target",
        () async {
      store.put('publicFacilityMaps/$_live', _map(_live));
      store.put('publicFacilityMaps/storage', _pointer(_live));
      final snapshot = PublicFacilityMapSnapshot.fromMap(_map('storage', units: 2));

      await store.collection('publicFacilityMaps').doc('storage').set(
            FacilityMapV2Service.publishedMapFields(snapshot,
                unitsTotal: 2, unitsOmitted: 0),
            SetOptions(merge: true),
          );

      final doc = store.data('publicFacilityMaps/storage')!;
      expect(doc.containsKey('movedToSlug'), isFalse);
      expect(doc.containsKey('movedAt'), isFalse);
      final served = await FacilityMapV2Service.resolvePublicMap('storage');
      expect(served?.slug, 'storage');
      expect(served?.snapshot.units, hasLength(2));
    });
  });

  group('getPublicSlugForFacility', () {
    void pinewoodDocs() {
      // As found on 2026-09-24: four old slugs, frozen, and the live one.
      for (final slug in [
        _facility,
        'p3xk9qw2ntv7h5jz8mbd',
        'storage',
        'storageunitrentals',
      ]) {
        store.put('publicFacilityMaps/$slug', _map(slug));
      }
      store.put('publicFacilityMaps/$_live',
          _map(_live, syncedAt: Timestamp.fromDate(DateTime(2026, 9, 24))));
    }

    test('answers with the meta slug, not the first doc by id', () async {
      pinewoodDocs();
      meta(_live);
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility), _live);
      expect(store.queries, isEmpty);
    });

    test('with no meta, the doc written most recently, never a pointer',
        () async {
      pinewoodDocs();
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility), _live);

      store.put('publicFacilityMaps/$_facility', _pointer(_live));
      store.put('publicFacilityMaps/$_live', _pointer('storage'));
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility),
          'p3xk9qw2ntv7h5jz8mbd');
    });

    test('staff and the public pages, who cannot read the meta, get the query',
        () async {
      pinewoodDocs();
      meta('storage');
      FacilityMapV2Service.overrideForTesting(
        collection: (path) =>
            path == 'facilities' ? _DeniedCollection() : store.collection(path),
        batch: store.batch,
      );
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility), _live);
    });

    test('only pointers, or no docs: no slug', () async {
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility), isNull);
      store.put('publicFacilityMaps/storage', _pointer(_live));
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility), isNull);
    });

    test("a meta slug another facility's doc holds is passed over", () async {
      pinewoodDocs();
      meta('rival');
      store.put('publicFacilityMaps/rival', _map('rival', facilityId: 'rival-facility'));
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility), _live);

      // A slug not published yet is still the facility's answer.
      meta('not-yet');
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility), 'not-yet');
    });

    test('a meta with no slug falls back to the query', () async {
      store.put('facilities/$_facility/mapEngine/meta', {'publicSlug': '  '});
      store.put('publicFacilityMaps/$_live', _map(_live));
      expect(await FacilityMapV2Service.getPublicSlugForFacility(_facility), _live);
    });
  });

  test('movedToSlugOf: only a non-empty string is a pointer', () {
    expect(FacilityMapV2Service.movedToSlugOf({'movedToSlug': ' a '}), 'a');
    expect(FacilityMapV2Service.movedToSlugOf({'movedToSlug': ''}), isNull);
    expect(FacilityMapV2Service.movedToSlugOf({'movedToSlug': 3}), isNull);
    expect(FacilityMapV2Service.movedToSlugOf({'units': []}), isNull);
    expect(FacilityMapV2Service.movedToSlugOf(null), isNull);
  });
}
