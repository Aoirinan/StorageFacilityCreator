import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';

void main() {
  test('a facility switch is published before the remote write finishes', () async {
    final remoteWrite = Completer<void>();
    final notifier = ActiveFacilityNotifier(
      load: () async => 'fac-a',
      save: (_) => remoteWrite.future,
    );
    addTearDown(notifier.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state, const AsyncValue<String?>.data('fac-a'));

    final switching = notifier.setActiveFacilityId('fac-b');
    // Before: AsyncLoading until the users-doc write returned, which the
    // dashboard read as "All Facilities" and loaded in full, then discarded.
    expect(notifier.state, const AsyncValue<String?>.data('fac-b'));

    remoteWrite.complete();
    await switching;
    expect(notifier.state, const AsyncValue<String?>.data('fac-b'));
  });

  test('a failed remote write keeps the choice made on this device', () async {
    final notifier = ActiveFacilityNotifier(
      load: () async => null,
      save: (_) async => throw Exception('unavailable'),
    );
    addTearDown(notifier.dispose);
    await Future<void>.delayed(Duration.zero);

    await notifier.setActiveFacilityId('fac-b');
    // Before: AsyncError, which every screen read as "All Facilities".
    expect(notifier.state, const AsyncValue<String?>.data('fac-b'));
  });
}
