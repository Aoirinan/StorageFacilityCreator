import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';
import 'package:sfcapp/utils/facility_clock.dart';
import 'package:sfcapp/utils/local_date.dart';

import 'fake_stays_callables.dart';
import 'fake_stays_repository.dart';

/// Widget-test scaffolding for Stays screens: a fake repository and fake
/// callables, a fixed facility clock, every permission unless told
/// otherwise, and a tall surface so a whole month fits. Test data is made up.
class StaysWidgetHarness {
  StaysWidgetHarness({
    this.facilityId = 'f1',
    LocalDate? today,
    DateTime? nowUtc,
    this.facilityTimeZone,
    Set<PermissionType>? permissions,
  })  : today = today ?? LocalDate(2026, 10, 10),
        nowUtc = nowUtc ?? DateTime.utc(2026, 10, 10, 18),
        permissions = permissions ?? PermissionType.values.toSet();

  final String facilityId;
  final LocalDate today;
  final DateTime nowUtc;
  final String? facilityTimeZone;
  final Set<PermissionType> permissions;
  final repository = FakeStaysRepository();
  final callables = FakeStaysCallables();

  /// Text put on the clipboard.
  final List<String> clipboard = [];

  /// Make the clipboard refuse writes, as a browser can.
  bool clipboardFails = false;

  /// stayControls/current. [confirmedZone] stamps the zone as confirmed.
  void seedControls({bool moduleEnabled = true, String? confirmedZone = 'America/Denver', Map<String, dynamic> extra = const {}}) {
    repository.seed(facilityId, StaysCollections.controls, StaysCollections.currentDocId, {
      'moduleEnabled': moduleEnabled,
      if (confirmedZone != null) 'timeZone': confirmedZone,
      if (confirmedZone != null) 'timeZoneConfirmedAt': DateTime.utc(2026, 9, 1),
      ...extra,
    });
  }

  void seedListing(String id, String name, {String kind = 'house', String shortCode = '', int nightly = 0}) {
    repository.seed(facilityId, StaysCollections.listings, id, {
      'facilityId': facilityId,
      'name': name,
      'shortCode': shortCode,
      'kind': kind,
      'active': true,
      'archived': false,
      'ratesCents': {'nightly': nightly},
      'version': 1,
    });
  }

  Future<void> pump(WidgetTester tester, Widget child, {Size surface = const Size(1200, 2400)}) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (clipboardFails) throw PlatformException(code: 'denied', message: 'Clipboard write refused');
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(ProviderScope(
      retry: (_, __) => null,
      overrides: [
        // These screens sit behind the route's flag check; the flag is on here.
        staysUiStateProvider.overrideWithValue(StaysUiState.on),
        staysRepositoryProvider.overrideWithValue(repository),
        staysCallablesProvider.overrideWithValue(callables),
        facilityClockProvider.overrideWithValue(FixedFacilityClock(todayValue: today, nowUtcValue: nowUtc)),
        stayPermissionResolverProvider.overrideWithValue((fid, p) async => fid == facilityId && permissions.contains(p)),
        staysFacilityTimeZoneProvider.overrideWith((ref, fid) => facilityTimeZone),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ));
    await settle(tester);
  }
}

/// Streams and spinners may never settle; pump a fixed number of frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}
