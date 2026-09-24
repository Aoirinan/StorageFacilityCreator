import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/utils/save_then_publish.dart';

/// The website and online-rental settings screens save, then publish the
/// public map (saveThenPublish). A failed publish read "Failed to save
/// settings" although the settings were saved.
void main() {
  group('saveThenPublish', () {
    test('a failed publish says the settings were saved', () async {
      final steps = <String>[];
      Object? caught;
      try {
        await saveThenPublish(
          save: () async => steps.add('save'),
          publish: () async {
            steps.add('publish');
            throw FirebaseException(
                plugin: 'cloud_firestore', code: 'unavailable');
          },
        );
      } catch (e) {
        caught = e;
      }

      expect(steps, ['save', 'publish']);
      expect(caught, isA<PublishAfterSaveException>());
      final text =
          saveThenPublishErrorText(caught!, saveFailed: 'Failed to save settings');
      // Before: 'Failed to save settings: ...'.
      expect(text, startsWith('Settings saved, but publishing the map failed: '));
      expect(text, contains('unavailable'));
      expect(text, isNot(contains('Failed to save')));
    });

    test('a failed save is reported as a failed save, and nothing publishes',
        () async {
      var published = false;
      Object? caught;
      try {
        await saveThenPublish(
          save: () async => throw StateError('rules refused'),
          publish: () async => published = true,
        );
      } catch (e) {
        caught = e;
      }

      expect(published, isFalse);
      expect(caught, isA<StateError>());
      expect(
        saveThenPublishErrorText(caught!,
            saveFailed: 'Failed to save website settings'),
        'Failed to save website settings: Bad state: rules refused',
      );
    });

    test('a save and publish that both work return normally', () async {
      final steps = <String>[];
      await saveThenPublish(
        save: () async => steps.add('save'),
        publish: () async => steps.add('publish'),
      );
      expect(steps, ['save', 'publish']);
    });
  });

  group('FacilityMapV2Service.migrateLegacyMapReportingFailure', () {
    test('a failed migration is reported, not left uncaught', () async {
      final reported = <Object>[];
      final uncaught = <Object>[];

      // Unawaited, as the map builder's initState starts it.
      runZonedGuarded(
        () {
          unawaited(FacilityMapV2Service.migrateLegacyMapReportingFailure(
            'fac1',
            reported.add,
            migrate: (_) async => throw FirebaseException(
                plugin: 'cloud_firestore', code: 'unavailable'),
          ));
        },
        (e, _) => uncaught.add(e),
      );
      await pumpEventQueue();

      // Before: the builder ran the migration unawaited with no catch, so
      // this was an uncaught async error and the owner saw nothing.
      expect(uncaught, isEmpty);
      expect(reported.single, isA<FirebaseException>());
    });

    test('a migration that works reports nothing', () async {
      final reported = <Object>[];
      final migrated = <String>[];
      await FacilityMapV2Service.migrateLegacyMapReportingFailure(
        'fac1',
        reported.add,
        migrate: (facilityId) async => migrated.add(facilityId),
      );
      expect(migrated, ['fac1']);
      expect(reported, isEmpty);
    });
  });
}
