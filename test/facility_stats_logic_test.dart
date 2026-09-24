import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_autopay_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_stats_service.dart';
import 'package:sfcapp/utils/count_helpers.dart';

TenantModel _tenant({
  required String id,
  required double rate,
  bool isActive = true,
  TenantAutopayModel autopay = const TenantAutopayModel(),
}) {
  return TenantModel(
    id: id,
    facilityId: 'fac1',
    name: 'T',
    email: 't@test',
    phone: '',
    unitNumber: '1',
    monthlyRate: rate,
    createdAt: DateTime(2026, 1, 1),
    isActive: isActive,
    autopay: autopay,
  );
}

UnitModel _occupiedUnit({required String id, required String tenantId}) {
  return UnitModel(
    id: id,
    facilityId: 'fac1',
    unitNumber: id,
    unitType: 'standard',
    status: UnitStatus.occupied,
    tenantId: tenantId,
    monthlyRate: 100,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    createdBy: 'test',
  );
}

UnitModel _unit(
  String id, {
  UnitStatus status = UnitStatus.available,
  String? tenantId,
  bool publicListingEnabled = true,
  bool internalUse = false,
}) {
  return UnitModel(
    id: id,
    facilityId: 'fac1',
    unitNumber: id,
    unitType: 'standard',
    status: status,
    tenantId: tenantId,
    monthlyRate: 100,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    createdBy: 'test',
    publicListingEnabled: publicListingEnabled,
    internalUse: internalUse,
  );
}

/// The seven cases behind the dashboard/Units list disagreement (82/74 against
/// 78/72 at one facility).
List<UnitModel> _mixedFacility() => [
      _unit('active', status: UnitStatus.occupied, tenantId: 'active-t'),
      _unit('archived-tenant', status: UnitStatus.occupied, tenantId: 'archived-t'),
      _unit('office',
          status: UnitStatus.occupied,
          tenantId: 'active-t',
          internalUse: true,
          publicListingEnabled: false),
      _unit('orphan', status: UnitStatus.occupied, tenantId: 'deleted-t'),
      _unit('reserved', status: UnitStatus.reserved, tenantId: 'active-t'),
      _unit('free'),
      // Kept off the website only: still a unit the owner rents.
      _unit('unlisted',
          status: UnitStatus.occupied,
          tenantId: 'active-t',
          publicListingEnabled: false),
    ];

void main() {
  group('sumAutopayMonthlyRevenue', () {
    test('sums monthlyRate only for autopay ON', () {
      final tenants = [
        _tenant(
          id: 'a',
          rate: 100,
          autopay: const TenantAutopayModel(status: AutopayStatus.on, enabled: true),
        ),
        _tenant(id: 'b', rate: 50),
        _tenant(
          id: 'c',
          rate: 25,
          autopay: const TenantAutopayModel(status: AutopayStatus.requested, enabled: false),
        ),
      ];
      expect(FacilityStatsService.sumAutopayMonthlyRevenue(tenants), 100.0);
    });
  });

  group('effectiveTotalUnits', () {
    test('always returns the actual unit-document count', () {
      // Capacity max (first arg) is intentionally ignored — dashboards display
      // the number of unit documents that actually exist, not the editable cap.
      expect(effectiveTotalUnits(200, 6), 6);
      expect(effectiveTotalUnits(0, 50), 50);
      expect(effectiveTotalUnits(0, 0), 0);
      expect(effectiveTotalUnits(1, 0), 0);
    });
  });

  group('canonical occupancy / orphan heal', () {
    test('archived tenant id in set is not treated as orphan', () {
      final active = _tenant(id: 'active-1', rate: 100);
      final archived = _tenant(id: 'archived-1', rate: 80, isActive: false);
      final units = [_occupiedUnit(id: 'u1', tenantId: 'archived-1')];

      // All tenant doc ids (active + archived) — matches CF stats heal fix.
      final allTenantIds = {active.id, archived.id};
      final activeOnlyIds = {active.id};

      final occupiedWithAll = units
          .where((u) =>
              u.status == UnitStatus.occupied &&
              u.tenantId != null &&
              allTenantIds.contains(u.tenantId))
          .length;
      final occupiedActiveOnly = units
          .where((u) =>
              u.status == UnitStatus.occupied &&
              u.tenantId != null &&
              activeOnlyIds.contains(u.tenantId))
          .length;

      expect(occupiedWithAll, 1);
      expect(occupiedActiveOnly, 0);
    });
  });

  group('countUnits (the one definition every screen uses)', () {
    test('leaves internal-use units out and counts archived tenants as occupying', () {
      final counts = FacilityStatsService.countUnits(
        _mixedFacility(),
        {'active-t', 'archived-t'},
      );
      // Internal-use office excluded from the total; orphan and reserved are
      // vacant; the unit kept off the website counts.
      expect(counts.totalUnits, 6);
      expect(counts.occupiedUnits, 3);
    });

    test('units kept off the public website still count', () {
      // One owner's rental page was not live yet, so 86 of 89 units had
      // "List on public website" off. Counting that switch showed 3 units.
      final units = [
        for (var i = 0; i < 86; i++)
          _unit('u$i',
              status: i < 40 ? UnitStatus.occupied : UnitStatus.available,
              tenantId: i < 40 ? 't$i' : null,
              publicListingEnabled: false),
        for (var i = 86; i < 89; i++) _unit('u$i'),
      ];
      final counts = FacilityStatsService.countUnits(
        units,
        {for (var i = 0; i < 40; i++) 't$i'},
      );
      expect(counts.totalUnits, 89);
      expect(counts.occupiedUnits, 40);
    });

    test('countsTowardOccupancy is false only for internal use', () {
      expect(FacilityStatsService.countsTowardOccupancy(_unit('a')), isTrue);
      expect(
        FacilityStatsService.countsTowardOccupancy(
            _unit('b', publicListingEnabled: false)),
        isTrue,
      );
      expect(
        FacilityStatsService.countsTowardOccupancy(
            _unit('c', internalUse: true)),
        isFalse,
      );
    });

    test('an archived tenant id missing from the set means the unit reads vacant', () {
      // Why callers must pass every tenant doc id, not only active ones.
      final counts = FacilityStatsService.countUnits(
        _mixedFacility(),
        {'active-t'},
      );
      expect(counts.occupiedUnits, 2);
    });

    test('a facility of only internal-use units has a total of zero', () {
      final counts = FacilityStatsService.countUnits(
        [_unit('office', internalUse: true)],
        const {},
      );
      expect(counts.totalUnits, 0);
      expect(counts.occupiedUnits, 0);
    });
  });

  group('cachedUnitTotalDrifted', () {
    test('a cache holding the counted total is not stale when an internal-use unit exists', () {
      final units = [
        ...List.generate(78, (i) => _unit('u$i')),
        _unit('unlisted', publicListingEnabled: false),
        _unit('office', internalUse: true),
      ];
      // Before: compared against all 80 units, so this recomputed on every
      // load forever.
      expect(FacilityStatsService.cachedUnitTotalDrifted(79, units), isFalse);
      expect(FacilityStatsService.cachedUnitTotalDrifted(80, units), isTrue);
    });
  });

  group('Sync counts', () {
    test('tallies failures per facility instead of stopping at the first', () async {
      final seen = <String>[];
      final result = await FacilityStatsService.runForEachFacility(
        ['a', 'b', 'c'],
        (id) async {
          seen.add(id);
          if (id == 'b') throw Exception('permission-denied');
        },
      );
      expect(seen, unorderedEquals(['a', 'b', 'c']));
      expect(result.synced, 2);
      expect(result.failed, 1);
    });

    test('never reports success when any facility failed', () {
      // Before: both buttons always said "Counts synced" while every stats
      // write behind them was denied.
      final partial =
          FacilityStatsService.syncCountsMessage((synced: 2, failed: 1));
      expect(partial.isError, isTrue);
      expect(partial.message, contains('1 of 3'));

      final none = FacilityStatsService.syncCountsMessage((synced: 0, failed: 1));
      expect(none.isError, isTrue);
      expect(none.message.toLowerCase(), isNot(contains('updated')));

      final ok = FacilityStatsService.syncCountsMessage((synced: 3, failed: 0));
      expect(ok.isError, isFalse);
    });

    test('an empty facility list is a failed load, not "nothing to sync"', () {
      // getUserFacilities returns [] when its read fails, and the button only
      // shows for an owner with facilities. Before: a green "No facilities
      // to sync."
      final empty = FacilityStatsService.syncCountsMessage((synced: 0, failed: 0));
      expect(empty.isError, isTrue);
      expect(empty.message, contains('Could not load your facilities'));
    });

    test('a failure never claims nothing was changed', () {
      // The server can heal units before a later step of the pass fails.
      for (final result in [(synced: 0, failed: 2), (synced: 1, failed: 1)]) {
        final outcome = FacilityStatsService.syncCountsMessage(result);
        expect(outcome.isError, isTrue);
        expect(outcome.message, startsWith('Could not finish syncing counts'));
        expect(outcome.message.toLowerCase(), isNot(contains('nothing was changed')));
      }
    });
  });

  group('countsMatchFacilityMirror', () {
    FacilityModel facility({required int unitDocCount, required int occupiedUnits}) =>
        FacilityModel(
          id: 'fac1',
          name: 'Fac',
          ownerUid: 'owner',
          createdAt: DateTime(2026, 1, 1),
          unitDocCount: unitDocCount,
          occupiedUnits: occupiedUnits,
        );

    test('agrees only when both counts match the mirror', () {
      final f = facility(unitDocCount: 78, occupiedUnits: 72);
      expect(
        FacilityStatsService.countsMatchFacilityMirror(
            (totalUnits: 78, occupiedUnits: 72), f),
        isTrue,
      );
      // What computeUnitCounts returns for a failed read, and for a failed
      // tenant read: never kept on the facility card.
      expect(
        FacilityStatsService.countsMatchFacilityMirror(
            (totalUnits: 0, occupiedUnits: 0), f),
        isFalse,
      );
      expect(
        FacilityStatsService.countsMatchFacilityMirror(
            (totalUnits: 78, occupiedUnits: 0), f),
        isFalse,
      );
    });
  });
}
