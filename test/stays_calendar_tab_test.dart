import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/screens/stays/stays_calendar_tab.dart';
import 'package:sfcapp/services/stays/stays_calendar_grid.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';
import 'package:sfcapp/widgets/stays/stay_month_calendar.dart';

import 'support/stays_widget_harness.dart';

// Made-up guests, codes and listings only.

Map<String, dynamic> _stay(
  String checkIn,
  String checkOut, {
  String kind = 'reservation',
  String source = 'airbnb',
  String origin = 'feed',
  String status = 'confirmed',
  String guest = '',
  int createdAtMs = 1000,
  Map<String, dynamic>? conflict,
  int version = 1,
}) =>
    {
      'facilityId': 'f1',
      'listingId': 'l1',
      'listingName': 'Blue House',
      'kind': kind,
      'source': source,
      'origin': origin,
      'status': status,
      'checkIn': checkIn,
      'checkOut': checkOut,
      'guestDisplayName': guest,
      'createdAtMs': createdAtMs,
      if (conflict != null) 'conflict': conflict,
      'version': version,
    };

StayNightStyle _style(WidgetTester tester, String ymd) =>
    tester.widget<StayNightCellView>(find.byKey(Key('stay-night-$ymd'))).cell.style;

StaysWidgetHarness _harness({Set<PermissionType>? permissions}) {
  final h = StaysWidgetHarness(permissions: permissions);
  h.seedControls();
  h.seedListing('l1', 'Blue House', shortCode: 'BH');
  void stay(String id, Map<String, dynamic> data) => h.repository.seed(h.facilityId, StaysCollections.stays, id, data);
  stay('airbnb_HMFAKE01', _stay('2026-10-03', '2026-10-06', guest: 'Jane D.'));
  stay('man_block1', _stay('2026-10-12', '2026-10-14', kind: 'owner_block', source: 'owner', origin: 'sfc', version: 3));
  stay('airbnb_HMFAKE02', _stay('2026-10-20', '2026-10-22', status: 'removed_from_feed'));
  stay('airbnb_HMFAKE03', _stay('2026-10-25', '2026-10-27', guest: 'Sam P.', createdAtMs: 500));
  stay(
    'man_direct1',
    _stay(
      '2026-10-26',
      '2026-10-28',
      source: 'direct',
      origin: 'sfc',
      status: 'conflict',
      guest: 'Alex R.',
      createdAtMs: 900,
      conflict: {
        'stayIds': ['airbnb_HMFAKE03'],
        'nights': ['2026-10-26'],
      },
    ),
  );
  h.repository.seed(h.facilityId, StaysCollections.channelBlocks, 'ch1', {
    'listingId': 'l1',
    'provider': 'airbnb',
    'ranges': [
      {'checkIn': '2026-10-16', 'checkOut': '2026-10-18', 'echo': false},
      {'checkIn': '2026-10-30', 'checkOut': '2026-10-31', 'echo': true},
    ],
  });
  return h;
}

void main() {
  testWidgets('draws bookings, blocks, soft blocks, removed stays and double bookings apart', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysCalendarTab(facilityId: h.facilityId));

    expect(find.text('October 2026'), findsOneWidget);
    expect(_style(tester, '2026-10-03'), StayNightStyle.booking);
    expect(_style(tester, '2026-10-06'), StayNightStyle.empty);
    expect(_style(tester, '2026-10-12'), StayNightStyle.block);
    expect(_style(tester, '2026-10-16'), StayNightStyle.soft);
    expect(_style(tester, '2026-10-30'), StayNightStyle.echo);
    expect(_style(tester, '2026-10-20'), StayNightStyle.removed);
    expect(_style(tester, '2026-10-25'), StayNightStyle.booking);
    expect(_style(tester, '2026-10-26'), StayNightStyle.conflict);
    expect(_style(tester, '2026-10-27'), StayNightStyle.booking);

    // Labels: the guest on the arrival night, the channel on its block.
    expect(find.text('Jane D.'), findsWidgets);
    expect(find.text('Blocked on Airbnb'), findsWidgets);
    expect(find.text('Removed'), findsOneWidget);
    expect(find.text('Double booked'), findsWidgets);

    // The listing's conflict banner, from the engine's conflict data.
    expect(find.byKey(const Key('stay-conflict-banner')), findsOneWidget);
    expect(find.text('Alex R. and Sam P. both have Oct 26.'), findsOneWidget);
  });

  testWidgets('tapping a night shows what is on it; an owner block can be removed', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysCalendarTab(facilityId: h.facilityId));

    await tester.tap(find.byKey(const Key('stay-night-2026-10-26')));
    await settle(tester);
    expect(find.textContaining('Double booked: more than one booking claims this night'), findsOneWidget);
    expect(find.byKey(const Key('stay-night-entry-airbnb_HMFAKE03')), findsOneWidget);
    expect(find.byKey(const Key('stay-night-entry-man_direct1')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // close the sheet
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const Key('stay-night-2026-10-12')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('stay-night-entry-man_block1')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('stay-block-remove')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('stay-block-remove-confirm')));
    await settle(tester);

    final cancels = h.callables.requestsOf<StaysCancelStayRequest>(StaysCallableNames.cancelStay);
    expect(cancels, hasLength(1));
    expect(cancels.single.stayId, 'man_block1');
    expect(cancels.single.expectedVersion, 3);
    expect(cancels.single.reason, isNotEmpty);
  });

  testWidgets('without Manage Stays: no Block dates, and a block cannot be removed', (tester) async {
    final h = _harness(permissions: {PermissionType.viewStays});
    await h.pump(tester, StaysCalendarTab(facilityId: h.facilityId));
    expect(find.byKey(const Key('stays-calendar-block')), findsNothing);

    await tester.tap(find.byKey(const Key('stay-night-2026-10-12')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('stay-night-entry-man_block1')));
    await settle(tester);
    expect(find.byKey(const Key('stay-block-remove')), findsNothing);
  });

  testWidgets('blocking dates goes through staysCreateStay and confirms a soft block first', (tester) async {
    final h = _harness();
    var calls = 0;
    h.callables.onCreateStay = (req) {
      calls++;
      if (req.overrideSoftBlocks != true) {
        throw const StaysCallableException(StaysErrorReason.softBlock, details: {
          'dates': ['2026-10-16'],
        });
      }
      return StaysCreateStayResult(stayId: 'man_${req.requestId}', created: true, status: StayStatus.confirmed);
    };
    await h.pump(tester, StaysCalendarTab(facilityId: h.facilityId));

    await tester.tap(find.byKey(const Key('stay-night-2026-10-16')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('stay-night-block')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('stay-block-save')));
    await settle(tester);
    expect(find.text('Already blocked on a channel'), findsOneWidget);
    await tester.tap(find.text('Block them'));
    await settle(tester);

    final creates = h.callables.requestsOf<StaysCreateStayRequest>(StaysCallableNames.createStay);
    expect(calls, 2);
    expect(creates.map((r) => r.requestId).toSet(), hasLength(1), reason: 'one request id per sheet');
    final last = creates.last;
    expect(last.kind.wire, 'owner_block');
    expect(last.source.wire, 'owner');
    expect(last.checkIn, '2026-10-16');
    expect(last.checkOut, '2026-10-17');
    expect(last.overrideSoftBlocks, isTrue);
  });

  testWidgets('fits a phone: the month renders at 375 px without overflow', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysCalendarTab(facilityId: h.facilityId), surface: const Size(375, 812));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('stay-night-2026-10-03')), findsOneWidget);
  });

  testWidgets('without a confirmed time zone the calendar asks for one instead of guessing', (tester) async {
    final h = StaysWidgetHarness();
    h.seedControls(confirmedZone: null);
    h.seedListing('l1', 'Blue House');
    await h.pump(tester, StaysCalendarTab(facilityId: h.facilityId));
    expect(find.text('Confirm the time zone first'), findsOneWidget);
    expect(find.byType(StayMonthCalendar), findsNothing);
  });
}
