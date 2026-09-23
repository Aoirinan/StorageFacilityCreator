import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';

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

  test('a facility picked while the saved one is still loading is not overwritten', () async {
    final saved = Completer<String?>();
    final notifier = ActiveFacilityNotifier(
      load: () => saved.future,
      save: (_) async {},
    );
    addTearDown(notifier.dispose);

    // e.g. the single-facility auto-select on first sign-in, while the
    // saved value is still coming from the users doc.
    await notifier.setActiveFacilityId('fac-picked');
    saved.complete('fac-saved');
    await Future<void>.delayed(Duration.zero);

    // Before: the late load replaced the pick with the saved value.
    expect(notifier.state, const AsyncValue<String?>.data('fac-picked'));
  });

  test('a refresh started after a pick still applies', () async {
    var stored = 'fac-a';
    final notifier = ActiveFacilityNotifier(
      load: () async => stored,
      save: (id) async => stored = id!,
    );
    addTearDown(notifier.dispose);
    await Future<void>.delayed(Duration.zero);

    await notifier.setActiveFacilityId('fac-b');
    stored = 'fac-c';
    await notifier.refresh();
    expect(notifier.state, const AsyncValue<String?>.data('fac-c'));
  });

  group('the selection belongs to the signed-in account', () {
    late StreamController<User?> auth;
    late Map<String, String?> savedByUid;
    late String? currentUid;
    late int loads;
    late ProviderContainer container;

    setUp(() {
      auth = StreamController<User?>();
      savedByUid = {'owner-a': 'fac-a', 'owner-b': 'fac-b'};
      currentUid = null;
      loads = 0;
      container = ProviderContainer(overrides: [
        authStateProvider.overrideWith((ref) => auth.stream),
        activeFacilityStoreProvider.overrideWithValue((
          load: () async {
            loads++;
            return savedByUid[currentUid];
          },
          save: (id) async => savedByUid[currentUid!] = id,
        )),
      ]);
      final sub = container.listen(activeFacilityIdProvider, (_, __) {});
      addTearDown(sub.close);
      addTearDown(container.dispose);
      addTearDown(() => unawaited(auth.close()));
    });

    Future<void> signIn(String? uid) async {
      currentUid = uid;
      auth.add(uid == null ? null : MockUser(uid: uid));
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    AsyncValue<String?> selection() => container.read(activeFacilityIdProvider);

    test('nothing is read before auth reports', () async {
      await Future<void>.delayed(Duration.zero);
      expect(selection().isLoading, isTrue);
      expect(loads, 0);
    });

    test("signing out and in as another account never keeps the first account's facility", () async {
      await signIn('owner-a');
      expect(selection(), const AsyncValue<String?>.data('fac-a'));

      await container
          .read(activeFacilityIdProvider.notifier)
          .setActiveFacilityId('fac-a2');
      expect(selection(), const AsyncValue<String?>.data('fac-a2'));

      await signIn(null);
      // Before: still 'fac-a2', for as long as the tab stayed open.
      expect(selection(), const AsyncValue<String?>.data(null));

      await signIn('owner-b');
      expect(selection(), const AsyncValue<String?>.data('fac-b'));
    });
  });
}
