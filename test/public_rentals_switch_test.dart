import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_map_v2_models.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/facility_public_settings_model.dart';
import 'package:sfcapp/screens/public_facility_map_screen.dart';
import 'package:sfcapp/screens/public_facility_page_screen.dart';
import 'package:sfcapp/screens/public_rental_portal_screen.dart';
import 'package:sfcapp/utils/renter_account_message.dart';
import 'package:sfcapp/widgets/unit_availability_widget.dart';

/// Public pages offer a rental only when the reservation hold would take one.
///
/// createPublicReservationHold refuses every unit while the facility's online
/// rentals switch (settings/public publicRentalsEnabled) is off. The public
/// pages still offered "Rent Now" and "Reserve", so at a facility with rentals
/// off (Caprock) every one of those buttons ended in that refusal.

/// The switch as a publicFacilityMaps doc carries it: on, off, or never set.
const _switches = <String, Map<String, dynamic>>{
  'on': {'publicRentalsEnabled': true},
  'off': {'publicRentalsEnabled': false},
  'missing': {},
};

bool _isOn(String name) => name == 'on';

const _phone = '(806) 555-0100';

/// A published, rentable unit, as the inventory sync writes it.
const _rentableUnit = <String, dynamic>{
  'unitId': 'u1',
  'unitNumber': 'A1',
  'unitLabel': 'A1',
  'status': 'available',
  'unitType': 'standard',
  'categorySlug': 'standard',
  'size': '10x10',
  'monthlyRate': 100,
  'isRentable': true,
};

PublicFacilityMapSnapshot _snapshot(
  Map<String, dynamic> rentalSwitch, {
  List<Map<String, dynamic>> units = const [_rentableUnit],
  List<FacilityMapElement> elements = const [],
  Map<String, dynamic> contact = const {'facilityPhone': _phone},
}) =>
    PublicFacilityMapSnapshot(
      facilityId: 'fac1',
      facilitySlug: 'caprock',
      publishedVersionId: 'v1',
      publishedAt: DateTime(2026, 9, 24),
      publicSettings: {
        'enabled': true,
        'facilityName': 'Caprock Storage',
        ...contact,
        ...rentalSwitch,
      },
      elements: elements,
      units: units,
      rentalRouteTemplate: '/f/caprock/rent?unitId={unitId}',
      moveInRouteTemplate: '/public-move-in?token={token}',
    );

Future<void> _useTallView(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  group('facilityTakesOnlineRentals', () {
    test('only an exact true takes rentals, as the hold reads the switch', () {
      expect(facilityTakesOnlineRentals({'publicRentalsEnabled': true}), isTrue);
      for (final settings in <Map<String, dynamic>?>[
        {'publicRentalsEnabled': false},
        {},
        null,
        {'publicRentalsEnabled': 'true'},
        {'publicRentalsEnabled': null},
      ]) {
        expect(facilityTakesOnlineRentals(settings), isFalse, reason: '$settings');
      }
    });

    test('a snapshot offers a unit only when the facility takes rentals', () {
      expect(_snapshot(_switches['on']!).offersUnitOnline(_rentableUnit), isTrue);
      expect(_snapshot(_switches['off']!).offersUnitOnline(_rentableUnit), isFalse);
      expect(_snapshot(_switches['missing']!).offersUnitOnline(_rentableUnit), isFalse);
      // isRentable, not the status: a type the owner keeps off online rental.
      expect(
        _snapshot(_switches['on']!)
            .offersUnitOnline({..._rentableUnit, 'isRentable': false}),
        isFalse,
      );
    });
  });

  group('public facility map', () {
    Future<void> pumpMap(
      WidgetTester tester,
      PublicFacilityMapSnapshot snapshot,
    ) async {
      await _useTallView(tester);
      await tester.pumpWidget(MaterialApp(
        home: PublicFacilityMapScreen(
          facilitySlug: 'caprock',
          loadSnapshot: (_) async => snapshot,
        ),
      ));
      await tester.pumpAndSettle();
    }

    for (final entry in _switches.entries) {
      testWidgets('list view with rentals ${entry.key}', (tester) async {
        await pumpMap(tester, _snapshot(entry.value));
        await tester.tap(find.byTooltip('List view'));
        await tester.pumpAndSettle();

        expect(find.text('Unit A1'), findsOneWidget);
        expect(find.text('Rent Now'), _isOn(entry.key) ? findsOneWidget : findsNothing);
        expect(find.text(onlineRentalsOffMessage),
            _isOn(entry.key) ? findsNothing : findsOneWidget);
      });

      testWidgets('unit panel with rentals ${entry.key}', (tester) async {
        const element = FacilityMapElement(
          id: 'e1',
          facilityId: 'fac1',
          elementType: FacilityMapElementType.unit,
          linkedUnitId: 'u1',
          x: 10,
          y: 10,
          width: 80,
          height: 60,
        );
        await pumpMap(tester, _snapshot(entry.value, elements: const [element]));
        await tester.tap(find.text('A1'));
        await tester.pumpAndSettle();

        expect(find.text('Rent Now'), _isOn(entry.key) ? findsOneWidget : findsNothing);
        expect(find.text('Call $_phone to rent'),
            _isOn(entry.key) ? findsNothing : findsOneWidget);
      });
    }

    testWidgets('the panel offers no rental for a unit the hold would refuse, whatever its status',
        (tester) async {
      const element = FacilityMapElement(
        id: 'e1',
        facilityId: 'fac1',
        elementType: FacilityMapElementType.unit,
        linkedUnitId: 'u1',
        x: 10,
        y: 10,
        width: 80,
        height: 60,
      );
      // Status available, but a unit type the owner keeps off online rental.
      await pumpMap(
        tester,
        _snapshot(
          _switches['on']!,
          units: [
            {..._rentableUnit, 'isRentable': false},
          ],
          elements: const [element],
        ),
      );
      await tester.tap(find.text('A1'));
      await tester.pumpAndSettle();

      expect(find.text('Rent Now'), findsNothing);
    });
  });

  group('public rental portal', () {
    late List<Uri> opened;
    late bool openSucceeds;

    setUp(() {
      opened = [];
      openSucceeds = true;
    });

    Future<void> pumpPortal(
      WidgetTester tester,
      Map<String, dynamic> rentalSwitch, {
      Map<String, String> query = const {},
      PublicFacilityMapSnapshot? snapshot,
    }) async {
      await _useTallView(tester);
      await tester.pumpWidget(MaterialApp(
        home: PublicRentalPortalScreen(
          facilitySlug: 'caprock',
          loadSnapshot: (_) async => snapshot ?? _snapshot(rentalSwitch),
          queryParamsForTesting: query,
          openUrl: (uri) async {
            opened.add(uri);
            return openSucceeds;
          },
        ),
      ));
      await tester.pumpAndSettle();
    }

    /// Every card button, as (label, enabled).
    List<(String, bool)> cardButtons(WidgetTester tester) => [
          for (final button
              in tester.widgetList<ElevatedButton>(find.byType(ElevatedButton)))
            (
              ((button.child! as Text).data)!,
              button.onPressed != null,
            ),
        ];

    // Caprock: website not live, online rentals off. Every unit a renter can
    // take must offer a way to rent it that works, not a greyed-out
    // "Reserve" with no reason.
    testWidgets('with rentals off, every available unit type offers a call',
        (tester) async {
      await pumpPortal(
        tester,
        _switches['off']!,
        snapshot: _snapshot(_switches['off']!, units: [
          _rentableUnit,
          {
            ..._rentableUnit,
            'unitId': 'u2',
            'unitNumber': 'B7',
            'unitLabel': 'B7',
            'unitType': 'climateControlled',
            'categorySlug': 'climatecontrolled',
            'size': '5x10',
          },
        ]),
      );

      expect(cardButtons(tester), [
        ('Call $_phone to rent', true),
        ('Call $_phone to rent', true),
      ]);
      await tester.tap(find.text('Call $_phone to rent').first);
      await tester.pumpAndSettle();
      expect(opened, [Uri(scheme: 'tel', path: '8065550100')]);
    });

    testWidgets('a call that nothing opens still gives the number',
        (tester) async {
      openSucceeds = false;
      await pumpPortal(tester, _switches['off']!);

      await tester.tap(find.text('Call $_phone to rent'));
      await tester.pumpAndSettle();

      expect(find.text('Call $_phone to rent.'), findsOneWidget);
    });

    testWidgets("the website's phone number is the one offered, as on /w/",
        (tester) async {
      await pumpPortal(
        tester,
        _switches['off']!,
        snapshot: _snapshot(_switches['off']!, contact: {
          'facilityPhone': _phone,
          'websiteConfig': {'phoneNumber': '806-555-0199'},
        }),
      );

      expect(cardButtons(tester), [('Call 806-555-0199 to rent', true)]);
    });

    testWidgets('with no phone, the email is offered', (tester) async {
      await pumpPortal(
        tester,
        _switches['off']!,
        snapshot: _snapshot(_switches['off']!, contact: {
          'websiteConfig': {'contactEmail': 'office@caprock.example'},
        }),
      );

      expect(cardButtons(tester),
          [('Email office@caprock.example to rent', true)]);
      await tester.tap(find.text('Email office@caprock.example to rent'));
      await tester.pumpAndSettle();
      expect(opened, [Uri(scheme: 'mailto', path: 'office@caprock.example')]);
    });

    testWidgets('with no phone or email, the card says why instead of a dead '
        'button', (tester) async {
      await pumpPortal(
        tester,
        _switches['off']!,
        snapshot: _snapshot(_switches['off']!, contact: const {}),
      );

      expect(cardButtons(tester), isEmpty);
      expect(
          find.text(
              'Not available online. Contact the facility to rent this unit.'),
          findsOneWidget);
    });

    testWidgets('with rentals on but no way to pick a unit, it offers a call',
        (tester) async {
      await pumpPortal(tester, const {
        'publicRentalsEnabled': true,
        'allowAutoAssign': false,
        'allowUnitSelection': false,
      });

      expect(cardButtons(tester), [('Call $_phone to rent', true)]);
    });

    for (final entry in _switches.entries) {
      testWidgets('with rentals ${entry.key}', (tester) async {
        await pumpPortal(tester, entry.value);
        final on = _isOn(entry.key);

        final reserve = find.widgetWithText(ElevatedButton, 'Reserve This Unit');
        expect(reserve, on ? findsOneWidget : findsNothing);
        if (on) {
          expect(tester.widget<ElevatedButton>(reserve).onPressed, isNotNull);
        }
        final call = find.widgetWithText(ElevatedButton, 'Call $_phone to rent');
        expect(call, on ? findsNothing : findsOneWidget);
        if (!on) {
          expect(tester.widget<ElevatedButton>(call).onPressed, isNotNull);
        }
        expect(find.text(onlineRentalsOffMessage), on ? findsNothing : findsOneWidget);
        expect(find.text('Reserve online'), on ? findsOneWidget : findsNothing);
        expect(find.text('Online reservation flow'), on ? findsOneWidget : findsNothing);
      });
    }

    testWidgets(
        'with rentals off, a renter the website sent to reserve is told to contact the facility, '
        'not left on "Completing your reservation..."', (tester) async {
      await pumpPortal(tester, _switches['off']!, query: const {
        'embed': '1',
        'autoSubmit': '1',
        'email': 'renter@example.com',
      });

      expect(find.text('Completing your reservation...'), findsNothing);
      expect(find.text(onlineRentalsOffMessage), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Call $_phone to rent'),
          findsOneWidget);
      expect(find.text('Reserve this unit'), findsNothing);
    });
  });

  group('public facility page', () {
    final facility = FacilityModel(
      id: 'fac1',
      name: 'Caprock Storage',
      ownerUid: 'owner1',
      createdAt: DateTime(2026, 1, 1),
    );

    Future<void> pumpPage(WidgetTester tester, FacilityPublicSettings? settings) async {
      await _useTallView(tester);
      await tester.pumpWidget(MaterialApp(
        home: PublicFacilityPageScreen(
          facilityId: 'fac1',
          loadForTesting: (_) async => (facility, settings, 'caprock'),
        ),
      ));
      await tester.pumpAndSettle();
    }

    for (final (name, settings) in <(String, FacilityPublicSettings?)>[
      (
        'on',
        const FacilityPublicSettings(
            facilityId: 'fac1', enabled: true, publicRentalsEnabled: true),
      ),
      // allowOnlineReservations is left at its default, true: the page read
      // that, not the switch the hold reads.
      (
        'off',
        const FacilityPublicSettings(facilityId: 'fac1', enabled: true),
      ),
      ('missing', null),
    ]) {
      testWidgets('with rentals $name', (tester) async {
        await pumpPage(tester, settings);
        final on = name == 'on';

        expect(find.text('View All Units & Reserve'), on ? findsOneWidget : findsNothing);
        expect(find.text(onlineRentalsOffMessage), on ? findsNothing : findsOneWidget);
        expect(
          tester.widget<UnitAvailabilityWidget>(find.byType(UnitAvailabilityWidget)).allowReservation,
          on,
        );
        // The map is not a rental; it stays either way.
        expect(find.text('View Facility Map'), findsOneWidget);
      });
    }
  });

  group('renter account message', () {
    final facility = FacilityModel(
      id: 'fac1',
      name: 'Caprock Storage',
      ownerUid: 'owner1',
      createdAt: DateTime(2026, 1, 1),
      phone: '(806) 555-0100',
    );

    test('carries the rent link only while online rentals are on', () {
      String message(bool on) => buildRenterAccountMessage(
            facility: facility,
            slug: 'caprock',
            linkBaseUrl: 'https://app.storagefacilitycreator.com',
            onlineRentalsEnabled: on,
          );

      expect(message(true), contains('Rent or reserve a unit online:'));
      expect(message(true), contains('/f/caprock'));

      final off = message(false);
      expect(off, isNot(contains('Rent or reserve')));
      expect(off, isNot(contains('/f/caprock')));
      expect(off, isNot(contains('online rentals')));
      // The rest of the message is unchanged.
      expect(off, contains('https://app.storagefacilitycreator.com/#/tenant-portal'));
      expect(off, contains('[PAYMENT_LINK]'));
      expect(off, contains('Questions? Call us at (806) 555-0100.'));
    });
  });
}
