import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/permission_model.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';
import 'package:sfcapp/services/permission_service.dart';
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
    /// Runs the migration unawaited, as the map builder's initState starts
    /// it, and returns what was reported and what escaped.
    Future<({List<Object> reported, List<Object> uncaught})> runMigration({
      required Future<void> Function(String facilityId) migrate,
      required Future<bool> Function(String facilityId) canPublish,
    }) async {
      final reported = <Object>[];
      final uncaught = <Object>[];
      runZonedGuarded(
        () {
          unawaited(FacilityMapV2Service.migrateLegacyMapReportingFailure(
            'fac1',
            reported.add,
            migrate: migrate,
            canPublish: canPublish,
          ));
        },
        (e, _) => uncaught.add(e),
      );
      await pumpEventQueue();
      return (reported: reported, uncaught: uncaught);
    }

    Future<void> failingMigration(String _) async => throw FirebaseException(
        plugin: 'cloud_firestore', code: 'permission-denied');

    test('a failed migration is reported to an owner or manager, not left uncaught',
        () async {
      final checked = <String>[];
      final result = await runMigration(
        migrate: failingMigration,
        canPublish: (facilityId) async {
          checked.add(facilityId);
          return true;
        },
      );

      // Before: the builder ran the migration unawaited with no catch, so
      // this was an uncaught async error and the owner saw nothing.
      expect(result.uncaught, isEmpty);
      expect(result.reported.single, isA<FirebaseException>());
      expect(checked, ['fac1']);
    });

    test('a user who cannot publish is not shown the failure', () async {
      final result = await runMigration(
        migrate: failingMigration,
        canPublish: (_) async => false,
      );

      // Before: staff opening a map with no version got a red
      // permission-denied snackbar every time.
      expect(result.reported, isEmpty);
      expect(result.uncaught, isEmpty);
    });

    test('a failed role check shows nothing and escapes nothing', () async {
      final result = await runMigration(
        migrate: failingMigration,
        canPublish: (_) async =>
            throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
      );

      expect(result.reported, isEmpty);
      expect(result.uncaught, isEmpty);
    });

    test('a migration that works reports nothing and checks no role', () async {
      final migrated = <String>[];
      var roleChecks = 0;
      final result = await runMigration(
        migrate: (facilityId) async => migrated.add(facilityId),
        canPublish: (_) async {
          roleChecks++;
          return true;
        },
      );
      expect(migrated, ['fac1']);
      expect(result.reported, isEmpty);
      expect(roleChecks, 0);
    });

    test('only owners and managers hold the permission the role check uses',
        () {
      // The rules let owners and managers (and the legacy admin role, read
      // as manager) publish; the default check must not let staff through,
      // nor leave managers out.
      bool holds(RoleType type) =>
          PermissionService.getRoleByType(type)!
              .permissions
              .contains(FacilityMapV2Service.publishMapPermission);
      expect(holds(RoleType.owner), isTrue);
      expect(holds(RoleType.manager), isTrue);
      expect(holds(RoleType.employee), isFalse);
      expect(holds(RoleType.viewer), isFalse);
      expect(PermissionService.roleTypeFromFirestoreString('admin'),
          RoleType.manager);
    });
  });
}
