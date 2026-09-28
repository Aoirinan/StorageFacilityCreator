// ignore_for_file: subtype_of_sealed_class

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/router/public_rent_entry_page.dart';
import 'package:sfcapp/screens/public_rental_portal_screen.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';

import 'support/fake_firestore_store.dart';

/// Serves [FakeStore]'s documents as Firestore.
class _StoreFirestore extends Fake implements FirebaseFirestore {
  _StoreFirestore(this.store);

  final FakeStore store;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      store.collection(path);
}

const _slug = 'main-street';

/// A published rental page, as publishFacilityMap writes it: online rentals
/// on, the website [websiteOn] or off.
void _publish(FakeStore store, {required bool websiteOn}) {
  store.put('publicFacilityMaps/$_slug', {
    'facilityId': 'fac1',
    'facilitySlug': _slug,
    'publicSettings': {
      'enabled': websiteOn,
      'publicRentalsEnabled': true,
      'facilityName': 'Main Street Storage',
    },
    'units': [
      {
        'unitId': 'u1',
        'unitNumber': 'A1',
        'unitType': 'standard',
        'size': '10x10',
        'status': 'available',
        'isRentable': true,
        'monthlyRate': 95,
      },
    ],
  });
}

/// The website's own links in the portal's nav bar.
final _websiteNav = find.text('About');

/// Stands in for the router: rebuilds the route's widget on demand, the way
/// GoRouter re-runs a route builder when auth, locale or theme settle.
class _Host extends StatefulWidget {
  const _Host({required this.buildRoute});

  final Widget Function() buildRoute;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => widget.buildRoute();
}

void _useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  late FakeStore store;

  setUp(() {
    store = FakeStore();
    FacilityMapV2Service.firestoreForTesting = _StoreFirestore(store);
  });

  tearDown(() => FacilityMapV2Service.firestoreForTesting = null);

  group('the Main Rent Link and All Available Units Link', () {
    testWidgets('show the rental portal when the website is not live',
        (tester) async {
      // The bug: these always sent the browser to /w/{slug}, which is
      // "Website not found" for a facility without the website add-on or
      // with the website off, though online rentals were on.
      final opened = <Uri>[];
      await tester.pumpWidget(MaterialApp(
        home: PublicRentEntryPage(
          slug: _slug,
          websiteIsLive: (_) async => false,
          openWebsite: (target) async {
            opened.add(target);
            return true;
          },
          buildPortal: (_) => const Text('rental portal'),
        ),
      ));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump();

      expect(find.text('rental portal'), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('open the website unit list when the website is live',
        (tester) async {
      final asked = <String>[];
      final opened = <Uri>[];
      await tester.pumpWidget(MaterialApp(
        home: PublicRentEntryPage(
          slug: _slug,
          websiteIsLive: (slug) async {
            asked.add(slug);
            return true;
          },
          openWebsite: (target) async {
            opened.add(target);
            return true;
          },
          buildPortal: (_) => const Text('rental portal'),
        ),
      ));
      await tester.pump();

      expect(asked, [_slug]);
      expect(opened, hasLength(1));
      expect(opened.single.path, '/w/$_slug');
      expect(opened.single.fragment, 'unit-list');
      // The browser is leaving; nothing else to show.
      expect(find.text('rental portal'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('show the portal when a live website will not open',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: PublicRentEntryPage(
          slug: _slug,
          websiteIsLive: (_) async => true,
          openWebsite: (_) async => false,
          buildPortal: (_) => const Text('rental portal'),
        ),
      ));
      await tester.pump();

      expect(find.text('rental portal'), findsOneWidget);
    });

    testWidgets('show the portal when the website check fails', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: PublicRentEntryPage(
          slug: _slug,
          websiteIsLive: (_) async => throw StateError('offline'),
          openWebsite: (_) async => fail('must not open the website'),
          buildPortal: (_) => const Text('rental portal'),
        ),
      ));
      await tester.pump();

      expect(find.text('rental portal'), findsOneWidget);
    });

    testWidgets('router rebuilds do not ask again', (tester) async {
      var asks = 0;
      final answer = Completer<bool>();
      await tester.pumpWidget(MaterialApp(
        home: _Host(
          buildRoute: () => PublicRentEntryPage(
            key: const ValueKey('public-rent-$_slug'),
            slug: _slug,
            websiteIsLive: (_) {
              asks += 1;
              return answer.future;
            },
            buildPortal: (_) => const Text('rental portal'),
          ),
        ),
      ));

      final host = tester.state<_HostState>(find.byType(_Host));
      for (var i = 0; i < 3; i++) {
        host.rebuild();
        await tester.pump();
      }
      answer.complete(false);
      await tester.pump();
      host.rebuild();
      await tester.pump();

      expect(asks, 1);
      expect(find.text('rental portal'), findsOneWidget);
    });

    testWidgets(
        'All Available Units opens the portal on available units, told the '
        'website is not live', (tester) async {
      _useTallScreen(tester);
      _publish(store, websiteOn: false);

      await tester.pumpWidget(MaterialApp(
        home: PublicRentEntryPage(
          slug: _slug,
          availableOnly: true,
          websiteIsLive: (_) async => false,
        ),
      ));
      await tester.pumpAndSettle();

      final portal = tester
          .widget<PublicRentalPortalScreen>(find.byType(PublicRentalPortalScreen));
      expect(portal.facilitySlug, _slug);
      expect(portal.availableOnly, isTrue);
      expect(portal.websiteLive, isFalse);
      expect(find.text('Main Street Storage'), findsWidgets);
      expect(find.text('Reserve This Unit'), findsOneWidget);
      expect(_websiteNav, findsNothing);
    });
  });

  group('the rental portal nav bar', () {
    Future<void> pumpPortal(
      WidgetTester tester, {
      bool? websiteLive,
      Future<bool> Function(String slug)? websiteIsLive,
    }) async {
      _useTallScreen(tester);
      await tester.pumpWidget(MaterialApp(
        home: PublicRentalPortalScreen(
          facilitySlug: _slug,
          websiteLive: websiteLive,
          websiteIsLive: websiteIsLive ??
              (_) async => fail('the portal was told; it must not ask'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Reserve This Unit'), findsOneWidget);
    }

    testWidgets('is hidden when the caller says the website is not live',
        (tester) async {
      _publish(store, websiteOn: true);

      await pumpPortal(tester, websiteLive: false);

      expect(_websiteNav, findsNothing);
      expect(find.text('Contact'), findsNothing);
    });

    testWidgets('links into the website when the caller says it is live',
        (tester) async {
      _publish(store, websiteOn: true);

      await pumpPortal(tester, websiteLive: true);

      for (final label in ['Home', 'About', 'Units', 'Map', 'Contact']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets(
        'is hidden on a category link when the website is off, without '
        'asking the server', (tester) async {
      _publish(store, websiteOn: false);

      await pumpPortal(tester); // asking fails the test

      expect(_websiteNav, findsNothing);
    });

    testWidgets(
        'is hidden on a category link when the website is on but not live '
        '(no website add-on)', (tester) async {
      _publish(store, websiteOn: true);
      final asked = <String>[];

      await pumpPortal(tester, websiteIsLive: (slug) async {
        asked.add(slug);
        return false;
      });

      expect(asked, [_slug]);
      expect(_websiteNav, findsNothing);
    });

    testWidgets('shows on a category link when the website is live',
        (tester) async {
      _publish(store, websiteOn: true);

      await pumpPortal(tester, websiteIsLive: (_) async => true);

      expect(_websiteNav, findsOneWidget);
    });
  });
}
