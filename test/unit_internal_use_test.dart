import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/screens/unit_creation_screen.dart';
import 'package:sfcapp/services/audit_service.dart';
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

  group('UnitService.updateUnit audit log', () {
    late List<AuditLogEntry> logged;
    setUp(() {
      logged = [];
      AuditService.recordForTesting = logged.add;
    });
    tearDown(() => AuditService.recordForTesting = null);

    test('turning internal use on or off is logged', () async {
      _serveUnits([
        FakeDoc('u1', {'unitNumber': 'OFF', 'status': 'available'}),
      ]);

      await UnitService.updateUnit(
          facilityId: 'fac1', unitId: 'u1', internalUse: true);
      await UnitService.updateUnit(
          facilityId: 'fac1', unitId: 'u1', internalUse: false);

      // Before: nothing, although each change moves Total, Occupied and
      // Vacant.
      expect(logged.map((e) => e.eventType),
          ['unit.internalUseChanged', 'unit.internalUseChanged']);
      expect(logged[0].targetType, 'unit');
      expect(logged[0].targetId, 'u1');
      expect(logged[0].facilityId, 'fac1');
      expect(logged[0].before, {'internalUse': false});
      expect(logged[0].after, {'internalUse': true});
      expect(logged[0].metadata?['unitNumber'], 'OFF');
      expect(logged[1].before, {'internalUse': true});
      expect(logged[1].after, {'internalUse': false});
    });

    test('a save that leaves internal use as it was logs nothing', () async {
      _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'OFF',
          'status': 'available',
          'internalUse': true,
        }),
      ]);

      // The editor sends internalUse on every save.
      await UnitService.updateUnit(
          facilityId: 'fac1', unitId: 'u1', internalUse: true, notes: 'x');
      await UnitService.updateUnit(
          facilityId: 'fac1', unitId: 'u1', notes: 'y');

      expect(logged, isEmpty);
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

    testWidgets('the listing switch is off and locked while internal use is on',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {'unitNumber': 'OFF', 'status': 'available'}),
      ]);
      await _openScreen(tester, unit: _unit());

      await _tapVisible(tester, find.text(_internalUseLabel));
      final listing = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'List on public website'));
      // Before: it stayed switchable, so an office could be listed again
      // and the public map offered it as rentable.
      expect(listing.onChanged, isNull);
      expect(listing.value, isFalse);

      await _tapVisible(tester, find.text('List on public website'));
      expect(_switchValue(tester, 'List on public website'), isFalse);

      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));
      expect(log.writes.single.$3['internalUse'], isTrue);
      expect(log.writes.single.$3['publicListingEnabled'], isFalse);
    });

    testWidgets(
        'turning internal use on and off again puts a listed unit back on the website',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {'unitNumber': 'A1', 'status': 'available'}),
      ]);
      await _openScreen(tester, unit: _unit());

      expect(_switchValue(tester, 'List on public website'), isTrue);
      await _tapVisible(tester, find.text(_internalUseLabel));
      await _tapVisible(tester, find.text(_internalUseLabel));

      // Before: the auto-unlist stuck, and the save quietly took a listed
      // unit off the website.
      expect(_switchValue(tester, _internalUseLabel), isFalse);
      expect(_switchValue(tester, 'List on public website'), isTrue);
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));
      expect(log.writes.single.$3['internalUse'], isFalse);
      expect(log.writes.single.$3['publicListingEnabled'], isTrue);
    });

    testWidgets('an unlisted unit stays unlisted after the same round trip',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'A1',
          'status': 'available',
          'publicListingEnabled': false,
        }),
      ]);
      await _openScreen(tester, unit: _unit(publicListingEnabled: false));

      await _tapVisible(tester, find.text(_internalUseLabel));
      await _tapVisible(tester, find.text(_internalUseLabel));

      expect(_switchValue(tester, 'List on public website'), isFalse);
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));
      expect(log.writes.single.$3['publicListingEnabled'], isFalse);
    });

    testWidgets(
        'a stored internal-use unit whose listing is on opens with the listing switch off',
        (tester) async {
      final log = _serveUnits([
        FakeDoc('u1', {
          'unitNumber': 'OFF',
          'status': 'available',
          'internalUse': true,
          'publicListingEnabled': true,
        }),
      ]);
      // An office saved before the switch was locked, with listing left on.
      await _openScreen(
        tester,
        unit: _unit(internalUse: true, publicListingEnabled: true),
      );

      // The website and online rentals leave it out whatever the field says,
      // so showing the switch on would tell the owner it is listed.
      final listing = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'List on public website'));
      expect(listing.value, isFalse);
      expect(listing.onChanged, isNull);

      // Turning internal use off offers the unit online again: the listing
      // it was saved with comes back.
      await _tapVisible(tester, find.text(_internalUseLabel));
      expect(_switchValue(tester, 'List on public website'), isTrue);
      await _tapVisible(
          tester, find.widgetWithText(ElevatedButton, 'Update Unit'));
      expect(log.writes.single.$3['internalUse'], isFalse);
      expect(log.writes.single.$3['publicListingEnabled'], isTrue);
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

  group('UnitCreationScreen amounts', () {
    test('only finite amounts of at least zero are accepted', () {
      expect(parseUnitAmount('129.5'), 129.5);
      expect(parseUnitAmount(' 0 '), 0);
      // double.tryParse accepts all of these, and none is below zero.
      for (final bad in ['Infinity', 'NaN', '1e999', '-Infinity', '-1', 'abc']) {
        expect(parseUnitAmount(bad), isNull, reason: bad);
      }
    });

    for (final (field, value, error) in [
      ('Monthly Rate *', 'Infinity', 'Please enter a valid monthly rate'),
      ('Monthly Rate *', 'NaN', 'Please enter a valid monthly rate'),
      ('Security Deposit', '1e999', 'Please enter a valid security deposit'),
      ('Width (ft)', 'Infinity', 'Enter a valid width'),
      ('Depth/Length (ft)', 'NaN', 'Enter a valid depth'),
      ('Height (ft)', 'Infinity', 'Enter a valid height'),
    ]) {
      testWidgets('$field "$value" is refused and nothing is saved',
          (tester) async {
        final log = _serveUnits([]);
        await _openScreen(tester);

        await tester.enterText(
            find.widgetWithText(TextFormField, 'Unit Number *'), 'A1');
        await tester.enterText(
            find.widgetWithText(TextFormField, 'Monthly Rate *'), '100');
        await tester.enterText(find.widgetWithText(TextFormField, field), value);
        await _tapVisible(
            tester, find.widgetWithText(ElevatedButton, 'Create Unit'));

        // Before: saved; a rate of Infinity or NaN then read back as $0 and
        // went on the public map at that price.
        expect(find.text(error), findsOneWidget);
        expect(log.writes, isEmpty);
        expect(find.byType(UnitCreationScreen), findsOneWidget);
      });
    }
  });
}
