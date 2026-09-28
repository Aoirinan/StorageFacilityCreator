// ignore_for_file: subtype_of_sealed_class

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/facility_website_setup_screen.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
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

FacilityModel _facility(String name) => FacilityModel(
      id: 'fac1',
      name: name,
      ownerUid: 'owner-1',
      currentUserOwnsFacility: true,
      createdAt: DateTime(2026),
      // Unlocks Website Setup without a Stripe subscription (and so without
      // the Cancel website plan button in the header).
      billingExempt: true,
    );

/// Website Setup's reads and publish outside the settings doc. The settings
/// doc itself goes through the real FacilityPublicService, against FakeStore.
class _FakeActions extends WebsiteSetupActions {
  _FakeActions(this.facilityDoc);

  FacilityModel facilityDoc;
  String? mapSlug;
  bool failFacilityRead = false;

  /// The slug of every publish, in order.
  final published = <String>[];

  @override
  String? currentUid() => 'owner-1';

  @override
  Future<FacilityModel?> facility(String facilityId) async {
    if (failFacilityRead) throw Exception('unavailable');
    return facilityDoc;
  }

  @override
  Future<String?> publishedSlug(String facilityId) async => mapSlug;

  @override
  Future<void> publish({
    required String facilityId,
    required String slug,
  }) async =>
      published.add(slug);
}

/// Opens the real Website Setup for fac1. Edit Facility is a stand-in page
/// whose button runs [editFacilitySave] (what the owner saves there) and
/// goes back, as the real one does after a save.
Future<void> _openWebsiteSetup(
  WidgetTester tester,
  _FakeActions actions, {
  Future<void> Function()? editFacilitySave,
  List<String>? editFacilityOpenedFor,
}) async {
  final router = GoRouter(
    initialLocation: AppRoute.websiteSetup,
    routes: [
      GoRoute(
        path: AppRoute.websiteSetup,
        builder: (context, state) => const Scaffold(
          body: FacilityWebsiteSetupScreen(facilityId: 'fac1'),
        ),
      ),
      GoRoute(
        path: AppRoute.facilityEdit,
        builder: (context, state) {
          editFacilityOpenedFor?.add(state.uri.queryParameters['facilityId']!);
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  await editFacilitySave?.call();
                  if (context.mounted) context.pop();
                },
                child: const Text('Save in Edit Facility'),
              ),
            ),
          );
        },
      ),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      websiteSetupActionsProvider.overrideWithValue(actions),
      userFacilitiesProvider
          .overrideWith((ref, uid) => Stream.value([actions.facilityDoc])),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      // The app shell watches the facility list (app_router.dart), which
      // keeps the screen's ref.read(....future) from waiting on a paused
      // provider.
      builder: (context, child) => Consumer(builder: (context, ref, _) {
        ref.watch(userFacilitiesProvider('owner-1'));
        return child!;
      }),
    ),
  ));
  await tester.pumpAndSettle();
}

/// What Edit Facility's Save Public Rental Settings writes
/// (FacilityEditScreen._savePublicRentalSettings), with rentals on.
Future<void> _saveInEditFacility({required String slug}) =>
    FacilityPublicService.updateRentalSettings(
      facilityId: 'fac1',
      publicRentalsEnabled: true,
      publicPricingEnabled: true,
      publicUnitNumbersEnabled: true,
      allowAutoAssign: true,
      allowUnitSelection: true,
      showAvailabilityCount: true,
      hideUnavailableTypes: true,
      enabledPublicUnitTypes: const [],
      publicRentalSlug: slug,
    );

/// The Save Website button, scrolled into view.
Future<ButtonStyleButton> _saveWebsiteButton(WidgetTester tester) async {
  final label = find.text('Save Website');
  await tester.scrollUntilVisible(label, 300,
      scrollable: find.byType(Scrollable).first);
  return tester.widget<ButtonStyleButton>(find.ancestor(
      of: label, matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
}

Future<void> _tapSaveWebsite(WidgetTester tester) async {
  final save = find.text('Save Website');
  await tester.scrollUntilVisible(save, 300,
      scrollable: find.byType(Scrollable).first);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

Future<void> _roundTripThroughEditFacility(WidgetTester tester) async {
  await tester.tap(find.text('Change in Edit Facility'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save in Edit Facility'));
  await tester.pumpAndSettle();
}

/// The text in the Website URL Name field.
String _slugField(WidgetTester tester) => tester
    .widget<TextField>(find.widgetWithText(TextField, 'Website URL Name'))
    .controller!
    .text;

final _promisesOnlineRentals =
    RegExp(r'online rental|reserve online', caseSensitive: false);

void main() {
  late FakeStore store;

  setUp(() {
    store = FakeStore();
    FacilityPublicService.firestoreForTesting = _StoreFirestore(store);
    FacilityPublicService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
    // Save asks it whether the URL name is free before saving.
    FacilityMapV2Service.firestoreForTesting = _StoreFirestore(store);
  });

  tearDown(() {
    FacilityPublicService.firestoreForTesting = null;
    FacilityPublicService.authForTesting = null;
    FacilityMapV2Service.firestoreForTesting = null;
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

  // The tests above run the service method; these run the real screen's
  // Save Website, so they fail if the screen stops calling it (the old call
  // passed publicRentalsEnabled: true and the service tests still passed).
  group('Website Setup screen', () {
    testWidgets('saving the site leaves online rentals off', (tester) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'enabled': true,
        'publicRentalsEnabled': false,
        'publicRentalSlug': 'main-street',
        'allowOnlineMoveIn': true,
      });
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);
      expect(find.text('Online rentals are off'), findsOneWidget);

      await _tapSaveWebsite(tester);

      expect(find.text('Website settings saved and published.'),
          findsOneWidget);
      expect(store.writes, contains('set $_settingsPath'));
      final saved = store.data(_settingsPath)!;
      expect(saved['publicRentalsEnabled'], isFalse);
      expect(saved['enabled'], isTrue);
      expect(saved['allowOnlineMoveIn'], isTrue);
      expect(actions.published, ['main-street']);
    });

    testWidgets('a first save leaves online rentals off, and one that was on '
        'stays on', (tester) async {
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);
      await _tapSaveWebsite(tester);
      expect(store.data(_settingsPath)!['publicRentalsEnabled'], isFalse);

      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'publicRentalsEnabled': true,
        'publicRentalSlug': 'main-street',
      });
      await _openWebsiteSetup(tester, actions);
      expect(find.text('Online rentals are on'), findsOneWidget);
      await _tapSaveWebsite(tester);
      expect(store.data(_settingsPath)!['publicRentalsEnabled'], isTrue);
    });

    testWidgets('starter copy does not promise online rentals while they are '
        'off', (tester) async {
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);
      await _tapSaveWebsite(tester);

      final saved = store.data(_settingsPath)!;
      final config = (saved['widgets'] as Map)['websiteConfig'] as Map;
      for (final text in [
        saved['pageDescription'],
        saved['marketingContent'],
        config['heroSubheadline'],
        config['amenities'],
        config['testimonials'],
      ]) {
        expect(text, isA<String>());
        expect(text, isNot(matches(_promisesOnlineRentals)));
      }
      // The copy that is not about renting is unchanged.
      expect(config['amenities'], contains('Drive-up Access'));
      expect(config['heroHeadline'], 'Main Street Storage');
    });

    testWidgets('starter copy offers online rentals while they are on',
        (tester) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'publicRentalsEnabled': true,
        'publicRentalSlug': 'main-street',
      });
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);
      await _tapSaveWebsite(tester);

      final saved = store.data(_settingsPath)!;
      final config = (saved['widgets'] as Map)['websiteConfig'] as Map;
      expect(saved['marketingContent'], contains('reserve online'));
      expect(config['amenities'], startsWith('Online Rentals, '));
    });

    testWidgets('copy the owner wrote is kept whatever the rentals setting',
        (tester) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'publicRentalsEnabled': false,
        'publicRentalSlug': 'main-street',
        'marketingContent': 'Book online today.',
        'widgets': {
          'websiteConfig': {'amenities': 'Online Rentals, Boat Storage'},
        },
      });
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);
      await _tapSaveWebsite(tester);

      final saved = store.data(_settingsPath)!;
      expect(saved['marketingContent'], 'Book online today.');
      expect(((saved['widgets'] as Map)['websiteConfig'] as Map)['amenities'],
          'Online Rentals, Boat Storage');
    });

    testWidgets('after Edit Facility, a save here keeps what was saved there',
        (tester) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'enabled': true,
        'publicRentalsEnabled': false,
        'publicRentalSlug': 'old-name',
      });
      final actions = _FakeActions(_facility('Main Street Storage'))
        ..mapSlug = 'old-name';
      final openedFor = <String>[];
      await _openWebsiteSetup(
        tester,
        actions,
        editFacilityOpenedFor: openedFor,
        // What Edit Facility saves: its facility fields, then the rental
        // settings (rentals, URL name; never the website switch) and a
        // publish under the new name.
        editFacilitySave: () async {
          actions.facilityDoc = _facility('Main Street Self Storage');
          await _saveInEditFacility(slug: 'new-name');
          actions.mapSlug = 'new-name';
        },
      );
      // An edit made here before leaving, to a field Edit Facility did not
      // change: it must survive the return.
      await tester.tap(find.text('Website Enabled'));
      await tester.pumpAndSettle();

      await _roundTripThroughEditFacility(tester);

      expect(openedFor, ['fac1']);
      expect(find.text('Online rentals are on'), findsOneWidget);
      expect(_slugField(tester), 'new-name');
      expect(find.text('Main Street Self Storage'), findsOneWidget);

      await _tapSaveWebsite(tester);

      final saved = store.data(_settingsPath)!;
      expect(saved['publicRentalSlug'], 'new-name');
      expect(actions.published, ['new-name']);
      expect(saved['publicRentalsEnabled'], isTrue);
      expect(saved['enabled'], isFalse);
      // Starter copy followed the new name and the rentals now on.
      final config = (saved['widgets'] as Map)['websiteConfig'] as Map;
      expect(config['heroHeadline'], 'Main Street Self Storage');
      expect(saved['pageTitle'], 'Main Street Self Storage | Self Storage');
      expect(saved['marketingContent'], contains('reserve online'));
    });

    testWidgets('a URL name typed here stands unless Edit Facility changes it',
        (tester) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'publicRentalsEnabled': false,
        'publicRentalSlug': 'old-name',
      });
      final actions = _FakeActions(_facility('Main Street Storage'));
      var editFacilitySlug = 'old-name';
      await _openWebsiteSetup(
        tester,
        actions,
        editFacilitySave: () => _saveInEditFacility(slug: editFacilitySlug),
      );
      await tester.enterText(
          find.widgetWithText(TextField, 'Website URL Name'), 'typed-here');

      await _roundTripThroughEditFacility(tester);
      expect(_slugField(tester), 'typed-here');

      // Saved there after it was typed here, so Edit Facility's name wins,
      // and the owner is told what was replaced.
      editFacilitySlug = 'new-name';
      await _roundTripThroughEditFacility(tester);
      expect(_slugField(tester), 'new-name');
      expect(find.textContaining('replaced "typed-here"'), findsOneWidget);
    });

    testWidgets("another facility's URL name saves nothing", (tester) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'publicRentalsEnabled': false,
        'publicRentalSlug': 'main-street',
      });
      store.put('publicFacilityMaps/rival', {'facilityId': 'rival-facility'});
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);
      await tester.enterText(
          find.widgetWithText(TextField, 'Website URL Name'), 'Rival');
      store.writes.clear();

      await _tapSaveWebsite(tester);

      expect(
          find.textContaining(
              '"rival" is already used by another facility. Choose a different one.'),
          findsOneWidget);
      expect(find.text('Website settings saved and published.'), findsNothing);
      expect(store.writes, isEmpty);
      expect(store.data(_settingsPath)!['publicRentalSlug'], 'main-street');
      expect(actions.published, isEmpty);
    });

    testWidgets('a failed re-read after Edit Facility turns Save off',
        (tester) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'publicRentalsEnabled': false,
        'publicRentalSlug': 'old-name',
      });
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions, editFacilitySave: () async {
        await _saveInEditFacility(slug: 'new-name');
        store.refuseRead = (path) => path == _settingsPath;
      });

      await _roundTripThroughEditFacility(tester);

      // Shown above Save Website, where the owner goes to save.
      final warning = find.textContaining('so saving is off');
      await tester.scrollUntilVisible(warning, 300,
          scrollable: find.byType(Scrollable).first);
      expect(warning, findsOneWidget);
      // A save now would write old-name back over what Edit Facility saved.
      expect((await _saveWebsiteButton(tester)).onPressed, isNull);
      expect(store.data(_settingsPath)!['publicRentalSlug'], 'new-name');
    });

    testWidgets('a failed facility re-read after Edit Facility turns Save off',
        (tester) async {
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions,
          editFacilitySave: () async => actions.failFacilityRead = true);

      await _roundTripThroughEditFacility(tester);

      expect((await _saveWebsiteButton(tester)).onPressed, isNull);
      expect(find.textContaining('so saving is off'), findsOneWidget);
    });

    testWidgets('settings the page cannot read say to contact support',
        (tester) async {
      store.put(_settingsPath, {
        'facilityId': 'fac1',
        'publicRentalSlug': 'main-street',
        // Not text: the page cannot show it, and saving would overwrite it.
        'widgets': {
          'websiteConfig': {'address': 42},
        },
      });
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);

      // Shown above Save Website.
      expect((await _saveWebsiteButton(tester)).onPressed, isNull);
      expect(find.textContaining('could not be read correctly. Contact support'),
          findsOneWidget);
      // Not "check your connection": a retry reads the same value.
      expect(find.textContaining('Check your connection'), findsNothing);
    });

    testWidgets('settings that could not be loaded say to try again',
        (tester) async {
      store.put(_settingsPath, {'facilityId': 'fac1'});
      store.refuseRead = (path) => path == _settingsPath;
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);

      expect((await _saveWebsiteButton(tester)).onPressed, isNull);
      expect(find.textContaining('Check your connection'), findsOneWidget);
      expect(find.textContaining('Press Refresh'), findsOneWidget);
    });

    testWidgets('the rentals tile fits a phone-width screen', (tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final actions = _FakeActions(_facility('Main Street Storage'));
      await _openWebsiteSetup(tester, actions);
      expect(tester.takeException(), isNull);

      final title = find.text('Online rentals are off');
      final subtitle = find.textContaining('Renters can see your units');
      final link = find.text('Change in Edit Facility');
      // The link sits under the text, which keeps the tile's full width; as
      // a trailing button it squeezed the title and subtitle into a sliver.
      expect(tester.getTopLeft(link).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(subtitle).dy));
      expect(tester.getTopLeft(link).dx, tester.getTopLeft(subtitle).dx);
      expect(tester.getSize(subtitle).width, greaterThan(412 / 2));
      expect(tester.getTopLeft(title).dx, tester.getTopLeft(subtitle).dx);
    });
  });

  // A backstop for the screen tests: the save must go through the method
  // that has no rentals parameter.
  test('Website Setup saves through updateWebsiteSettings and never sets '
      'online rentals', () {
    final screen = File('lib/screens/facility_website_setup_screen.dart')
        .readAsStringSync();
    expect(screen, contains('FacilityPublicService.updateWebsiteSettings('));
    expect(screen, isNot(contains('updatePublicSettings(')));
    expect(screen, isNot(contains('publicRentalsEnabled:')));
  });
}
