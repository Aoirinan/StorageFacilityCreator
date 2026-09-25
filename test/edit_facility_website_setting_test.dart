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

/// What an Edit Facility save writes
/// (FacilityEditScreen._savePublicRentalSettings).
Future<void> _saveRentals() => FacilityPublicService.updateRentalSettings(
      facilityId: 'fac1',
      publicRentalsEnabled: true,
      publicPricingEnabled: true,
      publicUnitNumbersEnabled: false,
      allowAutoAssign: true,
      allowUnitSelection: true,
      showAvailabilityCount: true,
      hideUnavailableTypes: true,
      enabledPublicUnitTypes: const ['standard'],
      publicRentalSlug: 'main-street-storage',
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

  test('an Edit Facility save leaves the website off when the owner turned it off',
      () async {
    store.put(_settingsPath, {
      'facilityId': 'fac1',
      'enabled': false,
      'publicRentalsEnabled': false,
      'pageTitle': 'Main Street Storage | Self Storage',
      'widgets': {'websiteTemplate': 'cookie-cutter-v2'},
    });

    await _saveRentals();

    final saved = store.data(_settingsPath)!;
    expect(saved['enabled'], isFalse);
    // The rental fields were written...
    expect(saved['publicRentalsEnabled'], isTrue);
    expect(saved['publicUnitNumbersEnabled'], isFalse);
    expect(saved['enabledPublicUnitTypes'], ['standard']);
    expect(saved['publicRentalSlug'], 'main-street-storage');
    // ...and the website's own fields were left alone.
    expect(saved['pageTitle'], 'Main Street Storage | Self Storage');
    expect((saved['widgets'] as Map)['websiteTemplate'], 'cookie-cutter-v2');
  });

  test('an Edit Facility save leaves the website on when it was on', () async {
    store.put(_settingsPath, {'facilityId': 'fac1', 'enabled': true});

    await _saveRentals();

    expect(store.data(_settingsPath)!['enabled'], isTrue);
  });

  test('a first Edit Facility save does not turn the website on', () async {
    // No settings doc yet: the website is off by default, and saving Edit
    // Facility used to switch it on.
    await _saveRentals();

    final saved = store.data(_settingsPath)!;
    expect(saved['enabled'], isFalse);
    expect(saved['publicRentalsEnabled'], isTrue);
  });
}
