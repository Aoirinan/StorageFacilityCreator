// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/facility_stats_service.dart';
import 'package:sfcapp/services/facility_subcollections.dart';

import 'support/fake_facility_collection.dart';

/// A collection whose every read fails.
class _FailingCollection extends Fake
    implements CollectionReference<Map<String, dynamic>> {
  @override
  Query<Map<String, dynamic>> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) =>
      this;

  @override
  Query<Map<String, dynamic>> limit(int limit) => this;

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) =>
      Future.error(
          FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'));
}

/// The onboarding checklist's two yes-or-no probes
/// (onboardingProgressProvider passes these very functions), run on fake
/// collections.
void main() {
  void serve(Map<String, CollectionReference<Map<String, dynamic>>> byName) {
    FacilitySubcollections.overrideForTesting((facilityId, name) {
      expect(facilityId, 'fac1');
      return byName[name]!;
    });
  }

  tearDown(() => FacilitySubcollections.overrideForTesting(null));

  group('facilityHasAnyUnitDoc', () {
    test('is false for a facility with no unit docs and true with one',
        () async {
      final log = FakeQueryLog();
      serve({'units': FakeCollection([], log: log)});
      expect(await FacilityStatsService.facilityHasAnyUnitDoc('fac1'), isFalse);

      serve({
        'units': FakeCollection([
          FakeDoc('office', {'unitNumber': 'OFF', 'internalUse': true}),
        ], log: log),
      });
      // Any unit doc, internal-use included: the owner has added units.
      expect(await FacilityStatsService.facilityHasAnyUnitDoc('fac1'), isTrue);
      // A one-doc probe, not a read of the facility's units.
      expect(log.limits, [1, 1]);
    });

    test('a failed read answers no', () async {
      serve({'units': _FailingCollection()});
      expect(await FacilityStatsService.facilityHasAnyUnitDoc('fac1'), isFalse);
    });
  });

  group('facilityHasAnyActiveTenant', () {
    test('only a tenant with isActive exactly true counts', () async {
      serve({
        'tenants': FakeCollection([
          FakeDoc('archived', {'name': 'Bo', 'isActive': false}),
          // A partial doc with no isActive is not an active tenant anywhere.
          FakeDoc('partial', {
            'autopay': {'status': 'OFF'}
          }),
          FakeDoc('stray', {'name': 'Cy', 'isActive': 'true'}),
        ]),
      });
      expect(await FacilityStatsService.facilityHasAnyActiveTenant('fac1'),
          isFalse);

      final log = FakeQueryLog();
      serve({
        'tenants': FakeCollection([
          FakeDoc('archived', {'name': 'Bo', 'isActive': false}),
          FakeDoc('active', {'name': 'Al', 'isActive': true}),
        ], log: log),
      });
      expect(await FacilityStatsService.facilityHasAnyActiveTenant('fac1'),
          isTrue);
      expect(log.equalityFilters, [('isActive', true)]);
      expect(log.limits, [1]);
    });

    test('a failed read answers no', () async {
      serve({'tenants': _FailingCollection()});
      expect(await FacilityStatsService.facilityHasAnyActiveTenant('fac1'),
          isFalse);
    });
  });
}
