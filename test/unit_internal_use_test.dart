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

const _internalUseLabel =
    'Internal use (office, residence, personal space) - not counted in occupancy';

UnitModel _unit({bool internalUse = false, bool publicListingEnabled = true}) =>
    UnitModel(
      id: 'u1',
      facilityId: 'fac1',
      unitNumber: 'OFF',
      unitType: 'standard',
      status: UnitStatus.available,
      monthlyRate: 0,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      createdBy: 'owner-1',
      internalUse: internalUse,
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

bool _switchValue(WidgetTester tester, String title) => tester
    .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
    .value;

void main() {
  setUp(() {
    UnitService.authForTesting =
        MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'owner-1'));
  });
  tearDown(() {
    UnitService.authForTesting = null;
    FacilitySubcollections.overrideForTesting(null);
  });

  group('UnitModel.internalUse', () {
    test('only an exact true marks internal use', () {
      UnitModel read(Object? value) => UnitModel.fromFirestore(
          FakeDoc('u1', {'unitNumber': '1', 'internalUse': value}));
      expect(read(true).internalUse, isTrue);
      for (final other in [false, null, 'true', 1]) {
        expect(read(other).internalUse, isFalse, reason: '$other');
      }
      expect(
        UnitModel.fromFirestore(FakeDoc('u2', {'unitNumber': '2'})).internalUse,
        isFalse,
      );
    });
  });

  group('UnitService writes internalUse', () {
    test('createUnit stores it, false unless asked', () async {
      final log = _serveUnits([]);

      await UnitService.createUnit(
        facilityId: 'fac1',
        unitNumber: 'OFF',
        unitType: 'standard',
        monthlyRate: 0,
        internalUse: true,
      );
      await UnitService.createUnit(
        facilityId: 'fac1',
        unitNumber: 'A1',
        unitType: 'standard',
        monthlyRate: 100,
      );

      expect(log.writes.map((w) => w.$1), ['set', 'set']);
      expect(log.writes[0].$3['internalUse'], isTrue);
      expect(log.writes[1].$3['internalUse'], isFalse);
    });

    test('updateUnit changes it only when given', () async {
      final log = _serveUnits([
        FakeDoc('u1', {'unitNumber': 'OFF', 'status': 'available'}),
      ]);

      await UnitService.updateUnit(
        facilityId: 'fac1',
        unitId: 'u1',
        internalUse: true,
      );
      await UnitService.updateUnit(
        facilityId: 'fac1',
        unitId: 'u1',
        notes: 'Front office',
      );

      expect(log.writes.map((w) => w.$1), ['update', 'update']);
      expect(log.writes[0].$3['internalUse'], isTrue);
      expect(log.writes[1].$3.containsKey('internalUse'), isFalse);
    });
  });

  group('UnitCreationScreen', () {
    testWidgets(
        'creating an internal-use unit saves it as internal use and unlisted',
        (tester) async {
      final log = _serveUnits([]);
      await _openScreen(tester);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Unit Number *'), 'OFF');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Monthly Rate *'), '0');
      expect(_switchValue(tester, _internalUseLabel), isFalse);
      await _tapVisible(tester, find.text(_internalUseLabel));

      // Space that is not rented is not offered online either.
      expect(_switchValue(tester, 'List on public website'), isFalse);

      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Create Unit'));

      final created = log.writes.single;
      expect(created.$1, 'set');
      expect(created.$3['unitNumber'], 'OFF');
      expect(created.$3['internalUse'], isTrue);
      expect(created.$3['publicListingEnabled'], isFalse);
      // Saved and closed.
      expect(find.byType(UnitCreationScreen), findsNothing);
    });

    testWidgets(
        'editing keeps a unit internal use unless the switch is turned off',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'OFF',
          'status': 'available',
          'internalUse': true,
          'publicListingEnabled': false,
        }),
      ]);
      await _openScreen(
        tester,
        unit: _unit(internalUse: true, publicListingEnabled: false),
      );

      // The switch starts from the unit, so a save for any other change
      // (a rate, a note) does not quietly put the office back in the counts.
      expect(_switchValue(tester, _internalUseLabel), isTrue);
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));

      expect(log.writes.single.$1, 'update');
      expect(log.writes.single.$3['internalUse'], isTrue);
    });

    testWidgets('editing can mark a unit internal use', (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {'unitNumber': 'OFF', 'status': 'available'}),
      ]);
      await _openScreen(tester, unit: _unit());

      await _tapVisible(tester, find.text(_internalUseLabel));
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));

      expect(log.writes.single.$3['internalUse'], isTrue);
    });
  });
}
