// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_public_service.dart';

import 'support/fake_firestore_store.dart';

/// Serves [FakeStore]'s documents as Firestore.
class _StoreFirestore extends Fake implements FirebaseFirestore {
  _StoreFirestore(this.store);

  final FakeStore store;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      store.collection(path);
}

const _settingsPath = 'facilities/fac1/settings/public';

/// What a Website Setup save writes (FacilityWebsiteSetupScreen._save).
Future<void> _saveWebsite() => FacilityPublicService.updateWebsiteSettings(
      facilityId: 'fac1',
      enabled: true,
      publicRentalSlug: 'main-street-storage',
      pageTitle: 'Main Street Storage | Self Storage',
      customStyles: const {'ctaButtonColor': '#103A86'},
      widgets: const {
        'websiteTemplate': 'cookie-cutter-v2',
        'websiteConfig': {'heroHeadline': 'Main Street Storage'},
      },
    );

void main() {
  late FakeStore store;

  setUp(() {
    store = FakeStore();
    FacilityPublicService.firestoreForTesting = _StoreFirestore(store);
    FacilityPublicService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
  });

  tearDown(() {
    FacilityPublicService.firestoreForTesting = null;
    FacilityPublicService.authForTesting = null;
  });

  test('a website save leaves online rentals off when the owner turned them off',
      () async {
    store.put(_settingsPath, {
      'facilityId': 'fac1',
      'enabled': false,
      'publicRentalsEnabled': false,
      'allowOnlineMoveIn': true,
      'enabledPublicUnitTypes': ['standard'],
    });

    await _saveWebsite();

    final saved = store.data(_settingsPath)!;
    expect(saved['publicRentalsEnabled'], isFalse);
    // The website's own fields were written...
    expect(saved['enabled'], isTrue);
    expect(saved['publicRentalSlug'], 'main-street-storage');
    expect(saved['pageTitle'], 'Main Street Storage | Self Storage');
    expect((saved['widgets'] as Map)['websiteTemplate'], 'cookie-cutter-v2');
    // ...and the rest of the rental setup was left alone.
    expect(saved['allowOnlineMoveIn'], isTrue);
    expect(saved['enabledPublicUnitTypes'], ['standard']);
  });

  test('a website save leaves online rentals on when they were on', () async {
    store.put(_settingsPath, {'facilityId': 'fac1', 'publicRentalsEnabled': true});

    await _saveWebsite();

    expect(store.data(_settingsPath)!['publicRentalsEnabled'], isTrue);
  });

  test('a first website save does not turn online rentals on', () async {
    // No settings doc yet: rentals are off by default, and saving the website
    // used to switch them on.
    await _saveWebsite();

    final saved = store.data(_settingsPath)!;
    expect(saved['publicRentalsEnabled'], isFalse);
    expect(saved['enabled'], isTrue);
  });
}
