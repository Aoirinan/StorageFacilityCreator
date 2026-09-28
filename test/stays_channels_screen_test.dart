import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/screens/stays/stays_channels_screen.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';

import 'support/stays_widget_harness.dart';

// Made-up listing, hosts and links only.

StaysWidgetHarness _harness({bool icalSyncEnabled = false, bool icalExportEnabled = false, bool withChannels = true}) {
  final h = StaysWidgetHarness(nowUtc: DateTime.utc(2026, 10, 10, 18));
  h.seedControls(extra: {'icalSyncEnabled': icalSyncEnabled, 'icalExportEnabled': icalExportEnabled});
  h.seedListing('l1', 'Blue House', shortCode: 'BH');
  final now = h.nowUtc;
  if (!withChannels) return h;
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

/// Paste a link, preview it, connect it.
Future<void> _connect(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('stays-add-channel-l1')));
  await settle(tester);
  await tester.enterText(find.byKey(const Key('stays-channel-url')), 'https://www.airbnb.com/calendar/ical/9.ics?s=fake');
  await tester.tap(find.byKey(const Key('stays-channel-check')));
  await settle(tester);
  await tester.tap(find.byKey(const Key('stays-channel-connect')));
  await settle(tester);
}

void main() {
  testWidgets('each calendar shows its state: healthy, failing, not synced yet; removed ones are gone', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));

    expect(find.byKey(const Key('stays-channel-ch_ok')), findsOneWidget);
    expect(find.text('Checked 6 min ago · Last synced 6 min ago'), findsOneWidget);
    // Airbnb's fetch of our link, shown on the Airbnb calendar.
    expect(find.text('Airbnb last fetched your SFC calendar 2 h ago'), findsOneWidget);

    expect(find.byKey(const Key('stays-channel-ch_bad')), findsOneWidget);
    expect(find.textContaining('no longer works'), findsOneWidget);
    expect(find.textContaining('4 failed checks in a row'), findsOneWidget);
    expect(find.text('Checked 3 min ago · Last synced 2 days ago'), findsOneWidget);

    expect(find.text('Not checked yet · Not synced yet'), findsOneWidget);
    expect(find.byKey(const Key('stays-channel-ch_removed')), findsNothing);

    // Checks are off: no promise of 30 minutes, and Airbnb's own delay is said.
    final timing = tester.widget<Text>(find.byKey(const Key('stays-import-timing-l1'))).data!;
    expect(timing, contains('Automatic checks are off'));
    expect(timing, contains('Airbnb itself can take a few hours'));
    expect(timing, isNot(contains('every 30 minutes')));
  });

  testWidgets('before sending is on: no export links to make or copy, just the one-week note', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    expect(
      tester.widget<Text>(find.byKey(const Key('stays-export-off-note'))).data,
      "Sending your calendar to Airbnb comes after a one-week check; we'll turn it on.",
    );
    expect(find.byKey(const Key('stays-export-xl1')), findsNothing);
    expect(find.byKey(const Key('stays-export-copy-xl1')), findsNothing);
    expect(find.byKey(const Key('stays-add-export-l1')), findsNothing);
    expect(find.textContaining('Paste it into'), findsNothing);
    // Not cleared by support: the switch is locked, with who to ask.
    expect(find.byKey(const Key('stays-switch-export')), findsNothing);
    expect(find.byKey(const Key('stays-switch-export-locked')), findsOneWidget);
    expect(find.textContaining('Contact support to turn on calendar sending'), findsOneWidget);
    expect(h.callables.countOf(StaysCallableNames.getExportUrl), 0);
  });

  testWidgets('cleared by support: the export switch works and asks first', (tester) async {
    final h = _harness(icalSyncEnabled: true);
    h.callables.availability = const StaysAvailability(allowed: true, paused: false, exportAllowed: true);
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    expect(find.byKey(const Key('stays-switch-export-locked')), findsNothing);
    await tester.tap(find.byKey(const Key('stays-switch-export')));
    await settle(tester);
    await tester.tap(find.text('Start sending'));
    await settle(tester);
    final controls = h.callables.requestsOf<StaysSetControlsRequest>(StaysCallableNames.setControls);
    expect(controls.single.changes.toJson(), {'icalExportEnabled': true});
    // Checks are on: now the 30-minute promise is made, still with Airbnb's delay.
    final timing = tester.widget<Text>(find.byKey(const Key('stays-import-timing-l1'))).data!;
    expect(timing, contains('every 30 minutes'));
    expect(timing, contains('Airbnb itself can take a few hours'));
  });

  testWidgets('once sending is on: the link, what it sends, and honest timing', (tester) async {
    final h = _harness(icalExportEnabled: true);
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    expect(find.byKey(const Key('stays-export-xl1')), findsOneWidget);
    expect(find.text('Sends: Owner and maintenance blocks only'), findsOneWidget);
    expect(find.textContaining('on their own schedule, often only every few hours'), findsWidgets);
    expect(find.byKey(const Key('stays-export-off-note')), findsNothing);
    // Turning it off stays possible even without the allowlist.
    final exportSwitch = tester.widget<SwitchListTile>(find.byKey(const Key('stays-switch-export')));
    expect(exportSwitch.onChanged, isNotNull);
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

  testWidgets('the very first calendar turns the 30-minute checks on by itself', (tester) async {
    final h = _harness(withChannels: false);
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    // Never offered before a first calendar, so never set by the owner.
    expect(find.byKey(const Key('stays-switch-import')), findsNothing);
    expect(find.byKey(const Key('stays-import-first-note')), findsOneWidget);
    await _connect(tester);
    expect(find.byKey(const Key('stays-turn-on-checks')), findsNothing, reason: 'no question on the first one');
    final controls = h.callables.requestsOf<StaysSetControlsRequest>(StaysCallableNames.setControls);
    expect(controls.single.changes.toJson(), {'icalSyncEnabled': true});
  });

  testWidgets('checks the owner turned off stay off unless she says so', (tester) async {
    final h = _harness();
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    await _connect(tester);
    await tester.tap(find.text('Leave off'));
    await settle(tester);
    expect(h.callables.countOf(StaysCallableNames.setControls), 0);
  });

  testWidgets('a clipboard that refuses still leaves the link on screen to select', (tester) async {
    final h = _harness(icalExportEnabled: true);
    h.clipboardFails = true;
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    await tester.tap(find.byKey(const Key('stays-export-copy-xl1')));
    await settle(tester);
    expect(find.text('Copy failed — select and copy the link above.'), findsOneWidget);
    final shown = tester.widget<SelectableText>(find.descendant(
      of: find.byKey(const Key('stays-export-xl1')),
      matching: find.byType(SelectableText),
    ));
    expect(shown.data, startsWith('https://app.example/api/ical/'));
    expect(find.text('Link copied.'), findsNothing);
  });

  testWidgets('adding a calendar previews it first, then connects it; off checks are offered, not forced', (tester) async {
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
    expect(h.callables.countOf(StaysCallableNames.setControls), 0, reason: 'asked first');
    await tester.tap(find.byKey(const Key('stays-turn-on-checks')));
    await settle(tester);
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
    final h = _harness(icalExportEnabled: true);
    await h.pump(tester, StaysChannelsScreen(facilityId: h.facilityId));
    await tester.tap(find.byKey(const Key('stays-export-copy-xl1')));
    await settle(tester);
    final gets = h.callables.calls.where((c) => c.name == StaysCallableNames.getExportUrl).toList();
    expect(gets.single.request, {'facilityId': h.facilityId, 'linkId': 'xl1'});
    expect(h.clipboard.single, startsWith('https://app.example/api/ical/'));
  });

  testWidgets('making a link sends a request id, so a retry cannot make a second one', (tester) async {
    final h = _harness(icalExportEnabled: true);
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
