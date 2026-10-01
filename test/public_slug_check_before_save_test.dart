// ignore_for_file: subtype_of_sealed_class

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/save_then_publish.dart';

import 'support/fake_firestore_store.dart';

// The settings screens saved publicRentalSlug and only then called
// setPublicSlug, which refuses another facility's slug. The settings kept
// the taken slug, and rent links built from them opened the other
// facility's storefront.

/// Every doc read refused, as a lost connection or the rules would.
class _DeniedCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) => _DeniedDoc();
}

class _DeniedDoc extends Fake implements DocumentReference<Map<String, dynamic>> {
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future.error(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'));
}

const _facility = 'kT4mZ8vLr2QpWx7NbY3d';

Map<String, dynamic> _map({String facilityId = _facility}) =>
    {'facilityId': facilityId, 'units': const []};

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

  Future<String> check(String slug) =>
      FacilityMapV2Service.ensurePublicSlugAvailable(
          facilityId: _facility, slug: slug);

  group('ensurePublicSlugAvailable', () {
    test('a slug no doc holds is free, normalized as setPublicSlug stores it',
        () async {
      expect(await check(' Pinewood Online Rentals '), 'pinewood-online-rentals');
      expect(store.writes, isEmpty);
    });

    test("the facility's own map or pointer is free to it", () async {
      store.put('publicFacilityMaps/live', _map());
      store.put('publicFacilityMaps/storage', _pointer('live'));
      expect(await check('live'), 'live');
      expect(await check('storage'), 'storage');
    });

    test("another facility's map or pointer is refused, whatever the case",
        () async {
      store.put('publicFacilityMaps/rival', _map(facilityId: 'rival-facility'));
      store.put('publicFacilityMaps/old-rival',
          _pointer('rival', facilityId: 'rival-facility'));
      for (final slug in ['rival', 'Rival ', 'old-rival']) {
        await expectLater(
          check(slug),
          throwsA(isA<PublicSlugTakenException>().having(
              (e) => e.slug, 'slug', slug.trim().toLowerCase())),
          reason: slug,
        );
      }
      expect(store.writes, isEmpty);
    });

    test('a failed read is thrown, not taken as free', () async {
      FacilityMapV2Service.overrideForTesting(
        collection: (path) => path == 'publicFacilityMaps'
            ? _DeniedCollection()
            : store.collection(path),
        batch: store.batch,
      );
      await expectLater(check('live'), throwsA(isA<FirebaseException>()));
    });
  });

  test('the screens show the refusal, and do not say the settings were saved',
      () {
    final taken = PublicSlugTakenException('rival');
    const message =
        'The website URL name "rival" is already used by another facility.';
    // facility_edit_screen.dart
    expect(ErrorMessageHelper.getUserFriendlyMessage(taken), contains(message));
    // facility_website_setup_screen.dart
    final text = saveThenPublishErrorText(taken,
        saveFailed: 'Failed to save website settings');
    expect(text, startsWith('Failed to save website settings: $message'));
    expect(text, isNot(contains('Settings saved')));
  });

  // The screens need Firebase to reach Save, so the order of their calls is
  // checked in their source: the check, then the settings save.
  // (OnlineRentalsManagementScreen saves the slug the same way, but no route
  // opens it: /online-rentals shows Website Setup.)
  for (final (path, method) in [
    ('lib/screens/facility_edit_screen.dart', '_savePublicRentalSettings()'),
    ('lib/screens/facility_website_setup_screen.dart', '_save()'),
  ]) {
    test('$path checks the slug before it saves the settings', () {
      final source = File(path).readAsStringSync();
      final start = source.indexOf('Future<void> $method async {');
      expect(start, greaterThan(0));
      final body = source.substring(
          start, source.indexOf(RegExp(r'\r?\n  }\r?\n'), start));

      // Inside the try, so the refusal is shown, and with the slug saved.
      final tryAt = body.indexOf('try {');
      final checkAt = body.indexOf(RegExp(
          r'await FacilityMapV2Service\.ensurePublicSlugAvailable\(\s*'
          r'facilityId: widget\.[\w.]+,\s*slug: slug\)'));
      final saveAt = body.indexOf('FacilityPublicService.update');
      expect(tryAt, greaterThan(0));
      expect(checkAt, greaterThan(tryAt));
      expect(saveAt, greaterThan(checkAt));
      expect(body, contains('publicRentalSlug: slug,'));
    });
  }
}
