// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/facility_edit_screen.dart';
import 'package:sfcapp/screens/facility_website_setup_screen.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/facility_public_service.dart';

import 'support/fake_firestore_store.dart';

/// Edit Facility's public rental section, run as the real screen: its
/// settings reads and saves go through FacilityPublicService against
/// FakeStore, and its publish through [FacilityEditActions]. The service
/// tests (edit_facility_website_setting_test.dart and
/// public_settings_failed_read_test.dart) passed with every one of these
/// screen changes reverted.

/// Serves [FakeStore]'s documents as Firestore.
class _StoreFirestore extends Fake implements FirebaseFirestore {
  _StoreFirestore(this.store);

  final FakeStore store;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      store.collection(path);
}

const _settingsPath = 'facilities/fac1/settings/public';

FacilityModel _facility({bool entitled = true}) => FacilityModel(
      id: 'fac1',
      name: 'Main Street Storage',
      ownerUid: 'owner-1',
      currentUserOwnsFacility: true,
      createdAt: DateTime(2026),
      // The website add-on, without a Stripe subscription.
      billingExempt: entitled,
    );

/// Edit Facility's facility read and publish. Whether the published map has
/// the website on is read for real, from publicFacilityMaps in FakeStore.
class _FakeEditActions extends FacilityEditActions {
  _FakeEditActions(this.facilityDoc);

  FacilityModel facilityDoc;
  bool failPublish = false;

  /// The slug of every publish, in order.
  final published = <String>[];

  @override
  Future<FacilityModel?> facility(String facilityId) async => facilityDoc;

  @override
  Future<void> publish({
    required String facilityId,
    required String slug,
  }) async {
    if (failPublish) {
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    published.add(slug);
  }
}

/// Website Setup's reads and publish outside the settings doc.
class _FakeWebsiteActions extends WebsiteSetupActions {
  _FakeWebsiteActions(this.facilityDoc);

  final FacilityModel facilityDoc;
  final published = <String>[];

  @override
  String? currentUid() => 'owner-1';

  @override
  Future<FacilityModel?> facility(String facilityId) async => facilityDoc;

  @override
  Future<String?> publishedSlug(String facilityId) async => null;

  @override
  Future<void> publish({
    required String facilityId,
    required String slug,
  }) async =>
      published.add(slug);
}

/// Opens the real Edit Facility for fac1, with the real Website Setup
/// behind its "Change in Website Setup" link.
Future<GoRouter> _openEditFacility(
  WidgetTester tester,
  _FakeEditActions actions, {
  _FakeWebsiteActions? websiteActions,
}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final website = websiteActions ?? _FakeWebsiteActions(actions.facilityDoc);
  final router = GoRouter(
    initialLocation: AppRoute.facilityEdit,
    routes: [
      GoRoute(
        path: AppRoute.facilityEdit,
        builder: (context, state) =>
            Scaffold(body: FacilityEditScreen(facility: actions.facilityDoc)),
      ),
      GoRoute(
        path: AppRoute.websiteSetup,
        builder: (context, state) => Scaffold(
          body: FacilityWebsiteSetupScreen(
            facilityId: state.uri.queryParameters['facilityId']!,
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authStateProvider
          .overrideWith((ref) => Stream.value(MockUser(uid: 'owner-1'))),
      facilityEditActionsProvider.overrideWithValue(actions),
      websiteSetupActionsProvider.overrideWithValue(website),
      userFacilitiesProvider
          .overrideWith((ref, uid) => Stream.value([actions.facilityDoc])),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      // As app_router.dart's shell does, so Website Setup's
      // ref.read(userFacilitiesProvider(uid).future) does not wait on a
      // paused provider.
      builder: (context, child) => Consumer(builder: (context, ref, _) {
        ref.watch(userFacilitiesProvider('owner-1'));
        return child!;
      }),
    ),
  ));
  await tester.pumpAndSettle();
  return router;
}

Future<void> _tap(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.scrollUntilVisible(target, 300,
      scrollable: find.byType(Scrollable).first);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

String _slugField(WidgetTester tester) => tester
    .widget<TextField>(find.widgetWithText(TextField, 'Public URL Name'))
    .controller!
    .text;

void main() {
  late FakeStore store;

  setUp(() {
    store = FakeStore();
    final firestore = _StoreFirestore(store);
    final auth =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
    FacilityPublicService.firestoreForTesting = firestore;
    FacilityPublicService.authForTesting = auth;
    FacilityMapV2Service.firestoreForTesting = firestore;
    FacilityMapV2Service.authForTesting = auth;
  });

  tearDown(() {
    FacilityPublicService.firestoreForTesting = null;
    FacilityPublicService.authForTesting = null;
    FacilityMapV2Service.firestoreForTesting = null;
    FacilityMapV2Service.authForTesting = null;
  });

  testWidgets('saving the rental settings leaves the website off and publishes',
      (tester) async {
    store.put(_settingsPath, {
      'facilityId': 'fac1',
      'enabled': false,
      'publicRentalsEnabled': false,
      'publicRentalSlug': 'main-street',
      'pageTitle': 'Main Street Storage | Self Storage',
    });
    final actions = _FakeEditActions(_facility());
    await _openEditFacility(tester, actions);

    await _tap(tester, 'Enable Public Online Rentals');
    await _tap(tester, 'Save Public Rental Settings');

    expect(find.text('Public rental links saved and published.'),
        findsOneWidget);
    final saved = store.data(_settingsPath)!;
    // It used to save enabled: true, which put the website back up.
    expect(saved['enabled'], isFalse);
    expect(saved['publicRentalsEnabled'], isTrue);
    expect(saved['pageTitle'], 'Main Street Storage | Self Storage');
    expect(actions.published, ['main-street']);
  });

  testWidgets('a failed settings read hides the rental form until it loads',
      (tester) async {
    store.put(_settingsPath, {
      'facilityId': 'fac1',
      'publicRentalsEnabled': true,
      'enabledPublicUnitTypes': ['standard'],
    });
    store.refuseRead = (path) => path == _settingsPath;
    final actions = _FakeEditActions(_facility());
    await _openEditFacility(tester, actions);

    // The form would show defaults (rentals off, no unit types), and saving
    // it would write them over the owner's setup.
    expect(find.text('Save Public Rental Settings'), findsNothing);
    expect(find.textContaining('Check your connection'), findsOneWidget);

    store.refuseRead = null;
    await _tap(tester, 'Load public rental settings again');
    await tester.scrollUntilVisible(
        find.text('Save Public Rental Settings'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Save Public Rental Settings'), findsOneWidget);
    expect(store.writes, isEmpty);
  });

  testWidgets('a failed publish after a save says the settings were saved',
      (tester) async {
    store.put(_settingsPath, {
      'facilityId': 'fac1',
      'publicRentalsEnabled': false,
      'publicRentalSlug': 'main-street',
    });
    final actions = _FakeEditActions(_facility())..failPublish = true;
    await _openEditFacility(tester, actions);

    await _tap(tester, 'Enable Public Online Rentals');
    await _tap(tester, 'Save Public Rental Settings');

    expect(store.data(_settingsPath)!['publicRentalsEnabled'], isTrue);
    // Not a generic failure, which sent owners to re-enter saved settings.
    expect(find.textContaining('Settings saved, but publishing the map failed'),
        findsOneWidget);
  });

  testWidgets('a URL name saved in Website Setup is kept by the next save here',
      (tester) async {
    store.put(_settingsPath, {
      'facilityId': 'fac1',
      'enabled': true,
      'publicRentalsEnabled': true,
      'publicRentalSlug': 'old-name',
    });
    final actions = _FakeEditActions(_facility());
    final website = _FakeWebsiteActions(actions.facilityDoc);
    final router =
        await _openEditFacility(tester, actions, websiteActions: website);
    expect(_slugField(tester), 'old-name');

    // The real Website Setup: rename the site and save it.
    await _tap(tester, 'Change in Website Setup');
    await tester.enterText(
        find.widgetWithText(TextField, 'Website URL Name'), 'new-name');
    await _tap(tester, 'Save Website');
    expect(website.published, ['new-name']);
    router.pop();
    await tester.pumpAndSettle();

    expect(_slugField(tester), 'new-name');
    await _tap(tester, 'Save Public Rental Settings');

    // It used to write old-name back and republish under it.
    expect(store.data(_settingsPath)!['publicRentalSlug'], 'new-name');
    expect(actions.published, ['new-name']);
  });

  testWidgets('a failed re-read after Website Setup turns saving here off',
      (tester) async {
    store.put(_settingsPath, {
      'facilityId': 'fac1',
      'publicRentalsEnabled': true,
      'publicRentalSlug': 'old-name',
    });
    final actions = _FakeEditActions(_facility());
    final router = await _openEditFacility(tester, actions);

    await _tap(tester, 'Change in Website Setup');
    store.refuseRead = (path) => path == _settingsPath;
    router.pop();
    await tester.pumpAndSettle();

    // Saving would write the URL name read before Website Setup back.
    expect(find.textContaining('Saving here is off'), findsOneWidget);
    expect(find.text('Load public rental settings again'), findsOneWidget);
    expect(find.text('Save Public Rental Settings'), findsNothing);
  });

  group('the website tile follows the published map', () {
    const mapPath = 'publicFacilityMaps/main-street';

    Future<void> open(
      WidgetTester tester, {
      required bool savedOn,
      bool? publishedOn,
      bool entitled = true,
    }) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'enabled': savedOn,
        'publicRentalSlug': 'main-street',
      });
      if (publishedOn != null) {
        store.put(mapPath, {
          'facilityId': 'fac1',
          'publicSettings': {'enabled': publishedOn},
        });
      }
      await _openEditFacility(
          tester, _FakeEditActions(_facility(entitled: entitled)));
      // The tile sits below the sections above it (late fees, logo), past
      // what the test view builds without scrolling.
      await tester.scrollUntilVisible(
          find.text('Change in Website Setup'), 300,
          scrollable: find.byType(Scrollable).first);
    }

    testWidgets('on when the published map has it on', (tester) async {
      await open(tester, savedOn: true, publishedOn: true);
      expect(find.text('Your website is on'), findsOneWidget);
    });

    testWidgets('not published when the saved setting never reached the map',
        (tester) async {
      // A save whose publish failed: the tile said "on" while /w/ was down.
      await open(tester, savedOn: true, publishedOn: false);
      expect(find.text('Your website is not published'), findsOneWidget);
      expect(find.text('Your website is on'), findsNothing);
    });

    testWidgets('on, with a warning, when only the saved setting is off',
        (tester) async {
      await open(tester, savedOn: false, publishedOn: true);
      expect(find.text('Your website is on'), findsOneWidget);
      expect(find.textContaining('the next save here or there takes it down'),
          findsOneWidget);
    });

    testWidgets('off when nothing is published', (tester) async {
      await open(tester, savedOn: false);
      expect(find.text('Your website is off'), findsOneWidget);
    });

    testWidgets('needs the add-on when the facility does not have it',
        (tester) async {
      await open(tester, savedOn: true, publishedOn: true, entitled: false);
      expect(find.text('Your website needs the website add-on'),
          findsOneWidget);
    });

    testWidgets('says it could not check when the map cannot be read',
        (tester) async {
      store.refuseRead = (path) => path == mapPath;
      await open(tester, savedOn: true, publishedOn: true);
      expect(find.text('Could not check your website'), findsOneWidget);
    });
  });
}
