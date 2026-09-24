// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_public_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/save_then_publish.dart';

import 'support/fake_facility_collection.dart';
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

/// An owner's saved setup, including the fields neither save below passes.
const Map<String, dynamic> _ownerSetup = {
  'facilityId': 'fac1',
  'enabled': true,
  'publicRentalsEnabled': true,
  'publicRentalSlug': 'main-street-storage',
  'enabledPublicUnitTypes': ['standard', 'climate'],
  'customDomain': 'rent.mainstreetstorage.com',
  'publicLogoUrl': 'https://example.com/logo.png',
  'unitTypeImageUrls': {'standard': 'https://example.com/standard.png'},
  'allowOnlineMoveIn': true,
  'onlineMoveInContractTemplateId': 'lease-2026',
  'chargeNextMonthAfterMidMonthMoveIn': true,
  'chargeInsuranceAtMoveIn': true,
  'publicInsuranceAmount': 12.0,
  'chargeSecurityDepositAtMoveIn': true,
  'publicSecurityDepositAmount': 50.0,
};

/// What a Website Setup save writes (FacilityWebsiteSetupScreen._save).
Future<void> _saveWebsite({String? customDomain}) =>
    FacilityPublicService.updateWebsiteSettings(
      facilityId: 'fac1',
      enabled: true,
      publicRentalSlug: 'main-street-storage',
      customDomain: customDomain,
      pageTitle: 'Main Street Storage | Self Storage',
      widgets: const {'websiteTemplate': 'cookie-cutter-v2'},
    );

/// What an Edit Facility save of the public rental settings writes
/// (FacilityEditScreen._savePublicRentalSettings).
Future<void> _saveRentalSettings() =>
    FacilityPublicService.updateRentalSettings(
      facilityId: 'fac1',
      publicRentalsEnabled: true,
      publicPricingEnabled: true,
      publicUnitNumbersEnabled: true,
      allowAutoAssign: true,
      allowUnitSelection: true,
      showAvailabilityCount: true,
      hideUnavailableTypes: true,
      enabledPublicUnitTypes: const ['standard', 'climate'],
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

  group('when the saved settings cannot be read', () {
    setUp(() {
      store.put(_settingsPath, _ownerSetup);
      store.refuseRead = (path) => path == _settingsPath;
    });

    test('a Website Setup save writes nothing', () async {
      // With a new custom domain, which a save goes on to claim: no writes
      // at all means no claim either.
      await expectLater(
        _saveWebsite(customDomain: 'www.mainstreetstorage.com'),
        throwsA(isA<PublicSettingsNotReadException>()),
      );

      expect(store.writes, isEmpty);
      expect(store.data(_settingsPath), _ownerSetup);
    });

    test('an Edit Facility save writes nothing', () async {
      await expectLater(
        _saveRentalSettings(),
        throwsA(isA<PublicSettingsNotReadException>()),
      );

      expect(store.writes, isEmpty);
      expect(store.data(_settingsPath), _ownerSetup);
    });

    test('the refusal is what the settings screens show', () async {
      Object? error;
      try {
        await _saveWebsite();
      } catch (e) {
        error = e;
      }

      const expected = "This facility's saved website and rental settings "
          'could not be loaded, so nothing was saved. Check your connection '
          'and try again.';
      // Edit Facility's error line.
      expect(ErrorMessageHelper.getUserFriendlyMessage(error), expected);
      // Website Setup's error line.
      expect(
        saveThenPublishErrorText(error!,
            saveFailed: 'Failed to save website settings'),
        'Failed to save website settings: $expected',
      );
    });

    test('getPublicSettings still returns null for its display callers',
        () async {
      expect(await FacilityPublicService.getPublicSettings('fac1'), isNull);
      await expectLater(
        FacilityPublicService.getPublicSettingsOrThrow('fac1'),
        throwsA(isA<FirebaseException>()),
      );
    });

    group('the public map', () {
      const metaPath = 'facilities/fac1/mapEngine/meta';
      const publicMapPath = 'publicFacilityMaps/main-street-storage';

      setUp(() {
        FacilityMapV2Service.firestoreForTesting = _StoreFirestore(store);
        FacilityMapV2Service.authForTesting = MockFirebaseAuth(
            signedIn: true, mockUser: MockUser(uid: 'owner-1'));
        TenantService.authForTesting = MockFirebaseAuth(
            signedIn: true, mockUser: MockUser(uid: 'owner-1'));
        // No units and no tenants, so a refresh that got past the settings
        // read would reach the public map write.
        FacilitySubcollections.overrideForTesting(
            (facilityId, name) => FakeCollection(const []));
      });

      tearDown(() {
        FacilityMapV2Service.firestoreForTesting = null;
        FacilityMapV2Service.authForTesting = null;
        TenantService.authForTesting = null;
        FacilitySubcollections.overrideForTesting(null);
      });

      test('a publish fails and writes nothing', () async {
        // No meta doc yet, which the publish would otherwise create.
        await expectLater(
          FacilityMapV2Service.publishCurrentDraft(facilityId: 'fac1'),
          throwsA(isA<FirebaseException>()
              .having((e) => e.code, 'code', 'unavailable')),
        );

        expect(store.writes, isEmpty);
      });

      test('the live-units refresh leaves the published units alone',
          () async {
        store.put(metaPath, {
          'facilityId': 'fac1',
          'publicSlug': 'main-street-storage',
        });
        const published = {
          'units': [
            {'unitId': 'u1', 'unitType': 'standard'},
          ],
          'unitsTotal': 1,
          'unitsOmitted': 0,
        };
        store.put(publicMapPath, published);

        await FacilityMapV2Service.refreshPublicMapInventoryFromLiveUnits(
            'fac1');

        expect(store.writes, isEmpty);
        expect(store.data(publicMapPath), published);
      });
    });
  });

  test('settings the webhook created without a facilityId are read and kept',
      () async {
    // The website-subscription webhook and the custom-domain sync merge into
    // this doc without a facilityId; reading it used to fail.
    store.put(_settingsPath, {
      'enabled': false,
      'customDomain': 'rent.mainstreetstorage.com',
      'onlineMoveInContractTemplateId': 'lease-2026',
      'allowOnlineMoveIn': true,
      'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 9, 1)),
      'updatedBy': 'stripeWebhook',
    });

    final read = await FacilityPublicService.getPublicSettings('fac1');
    expect(read?.facilityId, 'fac1');
    expect(read?.customDomain, 'rent.mainstreetstorage.com');

    await _saveWebsite();

    final saved = store.data(_settingsPath)!;
    expect(saved['facilityId'], 'fac1');
    expect(saved['enabled'], isTrue);
    expect(saved['customDomain'], 'rent.mainstreetstorage.com');
    expect(saved['onlineMoveInContractTemplateId'], 'lease-2026');
    expect(saved['allowOnlineMoveIn'], isTrue);
  });
}
