import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/screens/unit_creation_screen.dart';
import 'package:sfcapp/services/facility_subcollections.dart';
import 'package:sfcapp/services/unit_service.dart';

import 'support/fake_facility_collection.dart';

/// The RV Site unit type: an owner with an RV park puts each site in as a
/// unit, so it gets a map box and a monthly guest is billed like a tenant.

const _listingLabel = 'List on public website';

UnitModel _unit({String unitType = 'rvSite', bool publicListingEnabled = true}) =>
    UnitModel(
      id: 'u1',
      facilityId: 'fac1',
      unitNumber: 'RV-1',
      unitType: unitType,
      status: UnitStatus.available,
      monthlyRate: 900,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner-1',
      publicListingEnabled: publicListingEnabled,
    );

/// Serves the facility's units from [docs] and returns what was written.
FakeQueryLog _serveUnits(List<FakeDoc> docs) {
  final log = FakeQueryLog();
  final units = FakeCollection(docs, log: log);
  FacilitySubcollections.overrideForTesting((facilityId, name) {
    expect(facilityId, 'fac1');
    expect(name, 'units');
    return units;
  });
  return log;
}

/// Opens [UnitCreationScreen] the way the app does (pushed over a page), with
/// a signed-in owner.
Future<void> _openScreen(WidgetTester tester, {UnitModel? unit}) async {
  // Tall enough that the whole form is on screen: taps then land on the
  // switches and buttons themselves.
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(
          (ref) =>
              Stream.value(MockUser(uid: 'owner-1', isEmailVerified: true)),
        ),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            // Keeps the signed-in user loaded for the screen's ref.read.
            ref.watch(authStateProvider);
            return Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        UnitCreationScreen(facilityId: 'fac1', unit: unit),
                  ),
                ),
                child: const Text('open'),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Picks [label] in the Unit Type dropdown.
Future<void> _chooseUnitType(WidgetTester tester, String label) async {
  await _tapVisible(
    tester,
    find.ancestor(
      of: find.text('Unit Type *'),
      matching: find.byType(DropdownButtonFormField<String>),
    ),
  );
  // The open menu lists every type; the button shows only the chosen one.
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

bool _switchValue(WidgetTester tester, String title) => tester
    .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
    .value;

Future<void> _fillNewUnit(WidgetTester tester) async {
  await tester.enterText(
      find.widgetWithText(TextFormField, 'Unit Number *'), 'RV-1');
  await tester.enterText(
      find.widgetWithText(TextFormField, 'Monthly Rate *'), '900');
}

void main() {
  setUp(() {
    UnitService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
  });
  tearDown(() {
    UnitService.authForTesting = null;
    FacilitySubcollections.overrideForTesting(null);
  });

  group('UnitType', () {
    test('every type reads back from its stored name with the same label', () {
      // The stored string is switched on in unitTypeDisplayName and the enum
      // in UnitTypeExtension; a type added to one and not the other would
      // show as 'Standard' on the unit page.
      for (final type in UnitType.values) {
        expect(_unit(unitType: type.name).unitTypeDisplayName, type.displayName,
            reason: type.name);
      }
      expect(UnitType.rvSite.displayName, 'RV Site');
      expect(
        UnitModel.fromFirestore(
                FakeDoc('u1', {'unitNumber': 'RV-1', 'unitType': 'rvSite'}))
            .unitTypeDisplayName,
        'RV Site',
      );
    });

    test('a stored type the app does not know still reads, as Standard', () {
      // As before this type was added: not a name to trust, but nothing
      // throws, and the Units list still lists the unit.
      final unit = UnitModel.fromFirestore(
          FakeDoc('u1', {'unitNumber': 'S-1', 'unitType': 'rv_site'}));
      expect(unit.unitType, 'rv_site');
      expect(unit.unitTypeDisplayName, 'Standard');
    });
  });

  group('UnitCreationScreen RV Site', () {
    testWidgets('choosing RV Site on Create Unit starts the unit unlisted',
        (tester) async {
      final log = _serveUnits([]);
      await _openScreen(tester);
      await _fillNewUnit(tester);

      expect(_switchValue(tester, _listingLabel), isTrue);
      await _chooseUnitType(tester, 'RV Site');

      // A new unit is listed and Available by default, so each empty site
      // would otherwise go on the public map as available at $900/month.
      expect(_switchValue(tester, _listingLabel), isFalse);
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Create Unit'));

      final created = log.writes.single;
      expect(created.$1, 'set');
      expect(created.$3['unitNumber'], 'RV-1');
      expect(created.$3['unitType'], 'rvSite');
      expect(created.$3['publicListingEnabled'], isFalse);
      expect(created.$3['internalUse'], isFalse);
      expect(find.byType(UnitCreationScreen), findsNothing);
    });

    testWidgets('the listing switch stays free to turn on for an RV site',
        (tester) async {
      final log = _serveUnits([]);
      await _openScreen(tester);
      await _fillNewUnit(tester);
      await _chooseUnitType(tester, 'RV Site');

      final listing = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, _listingLabel));
      expect(listing.onChanged, isNotNull);
      await _tapVisible(tester, find.text(_listingLabel));
      expect(_switchValue(tester, _listingLabel), isTrue);

      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Create Unit'));
      expect(log.writes.single.$3['unitType'], 'rvSite');
      expect(log.writes.single.$3['publicListingEnabled'], isTrue);
    });

    testWidgets('choosing another type again puts the listing back',
        (tester) async {
      _serveUnits([]);
      await _openScreen(tester);

      await _chooseUnitType(tester, 'RV Site');
      expect(_switchValue(tester, _listingLabel), isFalse);
      await _chooseUnitType(tester, 'Standard');
      // A storage unit picked after a change of mind should not quietly
      // stay off the website.
      expect(_switchValue(tester, _listingLabel), isTrue);

      // Turned off by hand before RV Site: it stays off afterwards.
      await _tapVisible(tester, find.text(_listingLabel));
      expect(_switchValue(tester, _listingLabel), isFalse);
      await _chooseUnitType(tester, 'RV Site');
      await _chooseUnitType(tester, 'Outdoor Storage');
      expect(_switchValue(tester, _listingLabel), isFalse);
    });

    testWidgets('editing a listed RV site keeps it listed', (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'RV-1',
          'unitType': 'rvSite',
          'status': 'available',
          'publicListingEnabled': true,
        }),
      ]);
      await _openScreen(tester, unit: _unit());

      // The stored type is one of the dropdown's items, so the editor opens
      // on it instead of failing the dropdown's one-matching-item check.
      expect(find.text('RV Site'), findsOneWidget);
      // The default is for new units only; a saved choice is the owner's.
      expect(_switchValue(tester, _listingLabel), isTrue);
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));

      expect(log.writes.single.$1, 'update');
      expect(log.writes.single.$3['unitType'], 'rvSite');
      expect(log.writes.single.$3['publicListingEnabled'], isTrue);
    });

    testWidgets('changing a listed unit to RV Site while editing keeps it listed',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'RV-1',
          'unitType': 'outdoor',
          'status': 'available',
          'publicListingEnabled': true,
        }),
      ]);
      await _openScreen(tester, unit: _unit(unitType: 'outdoor'));

      await _chooseUnitType(tester, 'RV Site');
      expect(_switchValue(tester, _listingLabel), isTrue);
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));

      expect(log.writes.single.$3['unitType'], 'rvSite');
      expect(log.writes.single.$3['publicListingEnabled'], isTrue);
    });
  });
}
