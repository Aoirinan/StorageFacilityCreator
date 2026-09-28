import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/screens/stays/stays_channels_screen.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';

import 'support/stays_widget_harness.dart';

// Made-up listing, hosts and links only.

StaysWidgetHarness _harness({bool icalSyncEnabled = false}) {
  final h = StaysWidgetHarness(nowUtc: DateTime.utc(2026, 10, 10, 18));
  h.seedControls(extra: {'icalSyncEnabled': icalSyncEnabled});
  h.seedListing('l1', 'Blue House', shortCode: 'BH');
  final now = h.nowUtc;
  h.repository.seed(h.facilityId, StaysCollections.channels, 'ch_ok', {
    'listingId': 'l1',
    'provider': 'airbnb',
    'label': 'Airbnb – Blue House',
    'active': true,
    'urlHost': 'www.airbnb.com',
    'createdAt': DateTime.utc(2026, 9, 1),
    'sync': {
      'lastAttemptAt': now.subtract(const Duration(minutes: 6)),
      'lastSuccessAt': now.subtract(const Duration(minutes: 6)),
      'lastStatus': 'ok',
    },
  });
  h.repository.seed(h.facilityId, StaysCollections.channels, 'ch_bad', {
    'listingId': 'l1',
    'provider': 'vrbo',
    'label': '',
    'active': true,
    'urlHost': 'www.vrbo.com',
    'createdAt': DateTime.utc(2026, 9, 2),
    'sync': {
      'lastAttemptAt': now.subtract(const Duration(minutes: 3)),
      'lastSuccessAt': now.subtract(const Duration(days: 2)),
      'lastStatus': 'gone',
      'lastHttpStatus': 404,
      'consecutiveFailures': 4,
    },
  });
  h.repository.seed(h.facilityId, StaysCollections.channels, 'ch_new', {
    'listingId': 'l1',
    'provider': 'booking',
    'label': 'Booking.com',
    'active': true,
    'createdAt': DateTime.utc(2026, 9, 3),
    'sync': <String, dynamic>{},
  });
  h.repository.seed(h.facilityId, StaysCollections.channels, 'ch_removed', {
    'listingId': 'l1',
    'provider': 'google',
    'label': 'Old Google calendar',
    'active': false,
  });
  h.repository.seed(h.facilityId, StaysCollections.exportLinks, 'xl1', {
    'listingId': 'l1',
    'targetProvider': 'airbnb',
    'label': 'SFC to Airbnb',
    'scope': 'blocks_only',
    'active': true,
    'stats': {'lastFetchedAt': now.subtract(const Duration(hours: 2)), 'lastFetcher': 'airbnb'},
  });
  return h;
}

void main() {
  testWidgets('each calendar shows its state: healthy, failing, not synced yet; removed ones are gone', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));

    expect(find.byKey(const Key('stays-channel-ch_ok')), findsOneWidget);
    expect(find.text('Checked 6 min ago · Last synced 6 min ago'), findsOneWidget);
    // Airbnb's fetch of our link, on the Airbnb calendar and on the link itself.
    expect(find.text('Airbnb last fetched your SFC calendar 2 h ago'), findsNWidgets(2));

    expect(find.byKey(const Key('stays-channel-ch_bad')), findsOneWidget);
    expect(find.textContaining('no longer works'), findsOneWidget);
    expect(find.textContaining('4 failed checks in a row'), findsOneWidget);
    expect(find.text('Checked 3 min ago · Last synced 2 days ago'), findsOneWidget);

    expect(find.text('Not checked yet · Not synced yet'), findsOneWidget);
    expect(find.byKey(const Key('stays-channel-ch_removed')), findsNothing);

    // Export: the link, what it sends, and the honest timing; sending is off.
    expect(find.byKey(const Key('stays-export-xl1')), findsOneWidget);
    expect(find.text('Sends: Owner and maintenance blocks only'), findsOneWidget);
    expect(find.textContaining('on their own schedule, often only every few hours'), findsWidgets);
    expect(find.byKey(const Key('stays-export-off-note')), findsOneWidget);
  });

  testWidgets('fits a phone at 375 px without overflow', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId), surface: const Size(375, 812));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('stays-channel-ch_ok')), findsOneWidget);
  });

  testWidgets('Sync now and Remove call the engine for that calendar only', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));

    await tester.tap(find.byKey(const Key('stays-sync-now-ch_ok')));
    await settle(tester);
    final syncs = h.callables.calls.where((c) => c.name == StaysCallableNames.syncNow).toList();
    expect(syncs.single.request, {'facilityId': h.facilityId, 'channelId': 'ch_ok'});

    await tester.tap(find.byKey(const Key('stays-channel-remove-ch_bad')));
    await settle(tester);
    expect(find.textContaining('Bookings it brought in stay on the calendar'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stays-channel-remove-confirm')));
    await settle(tester);
    final removes = h.callables.calls.where((c) => c.name == StaysCallableNames.removeChannel).toList();
    expect(removes.single.request, {'facilityId': h.facilityId, 'channelId': 'ch_bad'});
  });

  testWidgets('adding a calendar previews it first, then connects it and turns on the 30-minute checks', (tester) async {
    final h = _harness();
    h.callables.onUpsertChannel = (req) => req.dryRun
        ? const StaysChannelPreview(status: ChannelSyncStatus.ok, reservations: 2, blocks: 1, nextArrival: '2026-10-14')
        : const StaysChannelSaved(
            channelId: 'ch_added',
            urlHost: 'www.airbnb.com',
            urlFingerprint: 'fp0000000000',
            firstSync: StaysChannelSyncResult(channelId: 'ch_added', status: ChannelSyncStatus.ok, created: 2, blocks: 1),
          );
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));

    await tester.tap(find.byKey(const Key('stays-add-channel-l1')));
    await settle(tester);
    expect(find.byKey(const Key('stays-channel-connect')), findsNothing, reason: 'no connect before a preview');
    await tester.enterText(find.byKey(const Key('stays-channel-url')), 'https://www.airbnb.com/calendar/ical/000.ics?s=fake');
    await tester.tap(find.byKey(const Key('stays-channel-check')));
    await settle(tester);
    expect(find.text('Found 2 upcoming reservations, 1 blocked range, next arrival Oct 14.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stays-channel-connect')));
    await settle(tester);

    final upserts = h.callables.requestsOf<StaysUpsertChannelRequest>(StaysCallableNames.upsertChannel);
    expect(upserts.map((r) => r.dryRun), [true, false]);
    expect(upserts.every((r) => r.listingId == 'l1' && r.provider == ChannelProvider.airbnb), isTrue);
    expect(upserts.last.url, 'https://www.airbnb.com/calendar/ical/000.ics?s=fake');
    final controls = h.callables.requestsOf<StaysSetControlsRequest>(StaysCallableNames.setControls);
    expect(controls.single.changes.toJson(), {'icalSyncEnabled': true});
  });

  testWidgets('changing the link after a preview needs a new preview', (tester) async {
    final h = _harness(icalSyncEnabled: true);
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    await tester.tap(find.byKey(const Key('stays-add-channel-l1')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('stays-channel-url')), 'https://www.airbnb.com/calendar/ical/1.ics');
    await tester.tap(find.byKey(const Key('stays-channel-check')));
    await settle(tester);
    expect(find.byKey(const Key('stays-channel-preview')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('stays-channel-url')), 'https://www.airbnb.com/calendar/ical/2.ics');
    await settle(tester);
    expect(find.byKey(const Key('stays-channel-preview')), findsNothing);
    expect(find.byKey(const Key('stays-channel-connect')), findsNothing);
  });

  testWidgets('a refused link shows the server reason under the box', (tester) async {
    final h = _harness(icalSyncEnabled: true);
    h.callables.failures[StaysCallableNames.upsertChannel] = const StaysCallableException(
      StaysErrorReason.feedHostNotAllowed,
      message: 'That website is not one Stays can read calendars from.',
    );
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    await tester.tap(find.byKey(const Key('stays-add-channel-l1')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('stays-channel-url')), 'https://calendar.example.test/x.ics');
    await tester.tap(find.byKey(const Key('stays-channel-check')));
    await settle(tester);
    expect(find.text('That website is not one Stays can read calendars from.'), findsOneWidget);
  });

  testWidgets('Copy fetches the export URL through the audited callable and copies it', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    await tester.tap(find.byKey(const Key('stays-export-copy-xl1')));
    await settle(tester);
    final gets = h.callables.calls.where((c) => c.name == StaysCallableNames.getExportUrl).toList();
    expect(gets.single.request, {'facilityId': h.facilityId, 'linkId': 'xl1'});
    expect(h.clipboard.single, startsWith('https://app.example/api/ical/'));
  });

  testWidgets('making a link sends a request id, so a retry cannot make a second one', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    await tester.tap(find.byKey(const Key('stays-add-export-l1')));
    await settle(tester);
    // Airbnb already has a link; VRBO does not.
    await tester.tap(find.text('For VRBO'));
    await settle(tester);
    final creates = h.callables.calls.where((c) => c.name == StaysCallableNames.createExportLink).toList();
    final req = creates.single.request! as Map;
    expect(req['targetProvider'], 'vrbo');
    expect(req['scope'], 'blocks_only');
    expect(req['requestId'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(h.clipboard, hasLength(1));
  });
}
