import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/screens/stays/stays_hub_screen.dart';
import 'package:sfcapp/screens/stays/stays_listings_tab.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';

import 'support/stays_widget_harness.dart';

// Made-up listings and guests only.

StaysWidgetHarness _harness({Set<PermissionType>? permissions}) {
  final h = StaysWidgetHarness(permissions: permissions);
  h.seedControls();
  h.seedListing('l1', 'Blue House', shortCode: 'BH', nightly: 12500);
  h.seedListing('l2', 'Cabin 2', kind: 'cabin', shortCode: 'C2');
  h.repository.seed(h.facilityId, StaysCollections.stays, 'airbnb_HMFAKE09', {
    'listingId': 'l1',
    'listingName': 'Blue House',
    'kind': 'reservation',
    'source': 'airbnb',
    'status': 'confirmed',
    'checkIn': '2026-11-01',
    'checkOut': '2026-11-03',
    'guestDisplayName': 'Jane D.',
  });
  h.repository.seed(h.facilityId, StaysCollections.stays, 'man_fake1', {
    'listingId': 'l1',
    'listingName': 'Blue House',
    'kind': 'reservation',
    'source': 'phone',
    'status': 'conflict',
    'checkIn': '2026-11-02',
    'checkOut': '2026-11-04',
    'guestDisplayName': 'Sam P.',
    'conflict': {
      'stayIds': ['airbnb_HMFAKE09'],
      'nights': ['2026-11-02'],
    },
  });
  return h;
}

void main() {
  testWidgets('a double booking is flagged on the listing and in a banner naming both guests', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysListingsTab(facilityId: h.facilityId));
    expect(find.byKey(const Key('stay-conflict-banner')), findsOneWidget);
    expect(find.text('Blue House: Sam P. and Jane D. both have Nov 2.'), findsOneWidget);
    final blueHouse = find.byKey(const Key('stays-listing-l1'));
    expect(find.descendant(of: blueHouse, matching: find.text('Double booked')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('stays-listing-l2')), matching: find.text('Double booked')), findsNothing);
    expect(find.textContaining(r'$125 a night'), findsOneWidget);
    expect(find.byKey(const Key('stays-listings-add')), findsOneWidget);
  });

  testWidgets('acknowledged conflicts, and ones whose nights are all past, raise no banner or chip', (tester) async {
    final h = _harness();
    // Today is Oct 10 at the facility (the harness clock).
    h.repository.seed(h.facilityId, StaysCollections.stays, 'man_fake1', {
      ...h.repository.read(h.facilityId, StaysCollections.stays, 'man_fake1')!,
      'conflict': {
        'stayIds': ['airbnb_HMFAKE09'],
        'nights': ['2026-11-02'],
        'acknowledgedAt': DateTime.utc(2026, 10, 1),
      },
    });
    h.repository.seed(h.facilityId, StaysCollections.stays, 'man_past', {
      'listingId': 'l2',
      'listingName': 'Cabin 2',
      'kind': 'reservation',
      'source': 'direct',
      'status': 'conflict',
      'checkIn': '2026-10-01',
      'checkOut': '2026-10-03',
      'conflict': {
        'stayIds': ['x'],
        'nights': ['2026-10-01', '2026-10-02'],
      },
    });
    await h.pump(tester, StaysListingsTab(facilityId: h.facilityId));
    expect(find.byKey(const Key('stay-conflict-banner')), findsNothing);
    expect(find.text('Double booked'), findsNothing);
  });

  testWidgets('staff see the listings read-only', (tester) async {
    final h = _harness(permissions: {PermissionType.viewStays});
    await h.pump(tester, StaysListingsTab(facilityId: h.facilityId));
    expect(find.byKey(const Key('stays-listing-l1')), findsOneWidget);
    expect(find.byKey(const Key('stays-listings-add')), findsNothing);
    expect(find.text('Calendars'), findsNothing);
    expect(h.callables.calls, isEmpty);
  });

  testWidgets('the hub opens the calendar unless ?tab=listings', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysHubScreen(facilityId: h.facilityId));
    expect(find.byKey(const Key('stays-calendar-listing')), findsOneWidget);

    await h.pump(tester, StaysHubScreen(facilityId: h.facilityId, initialTab: 'listings'));
    expect(find.byKey(const Key('stays-listing-l2')), findsOneWidget);
  });
}
