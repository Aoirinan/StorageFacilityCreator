import 'dart:async';

import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/active_facility_provider.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/dashboard_provider.dart';

UnitModel _unit(
  String id, {
  UnitStatus status = UnitStatus.occupied,
  String? tenantId = 't1',
  DateTime? moveOutNoticeDate,
  bool publicListingEnabled = true,
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
    moveOutNoticeDate: moveOutNoticeDate,
    publicListingEnabled: publicListingEnabled,
  );
}

TenantModel _tenant(String id, {bool isActive = true}) => TenantModel(
      id: id,
      facilityId: 'fac1',
      name: id,
      email: '',
      phone: '',
      unitNumber: '',
      monthlyRate: 100,
      createdAt: DateTime(2026, 1, 1),
      isActive: isActive,
    );

void main() {
  group('waiting for the saved facility selection', () {
    test('only an unresolved selection waits', () {
      expect(dashboardWaitsForActiveFacility(const AsyncValue<String?>.loading()), isTrue);
      expect(dashboardWaitsForActiveFacility(const AsyncValue<String?>.data(null)), isFalse);
      expect(dashboardWaitsForActiveFacility(const AsyncValue<String?>.data('fac1')), isFalse);
      // A failed read falls back to "All Facilities", as it always has.
      expect(
        dashboardWaitsForActiveFacility(
          AsyncValue<String?>.error(Exception('offline'), StackTrace.empty),
        ),
        isFalse,
      );
    });

    test('the dashboard loads nothing while the selection is still being read', () async {
      final selection = Completer<String?>();
      final container = ProviderContainer(overrides: [
        authStateProvider.overrideWith(
          (ref) => Stream.value(MockUser(uid: 'owner-1', isEmailVerified: true)),
        ),
        activeFacilityIdProvider.overrideWith(
          (ref) => ActiveFacilityNotifier(
            load: () => selection.future,
            save: (_) async {},
          ),
        ),
      ]);
      addTearDown(container.dispose);

      final sub = container.listen(dashboardStatsProvider, (_, __) {});
      addTearDown(sub.close);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      // Before: the loading selection was read as "All Facilities" and the
      // whole load ran (here it fails on the first Firebase call, since no
      // Firebase app exists in tests). Now it waits for the real id.
      final state = container.read(dashboardStatsProvider);
      expect(state.isLoading, isTrue);
      expect(state.hasError, isFalse);
    });
  });

  group('positiveBalances', () {
    test('fetches a chunk together, drops failures and non-positive balances, keeps order', () async {
      final gates = <String, Completer<double>>{};
      final started = <String>[];
      final result = positiveBalances<String>(
        ['a', 'b', 'c', 'd'],
        (id) {
          started.add(id);
          return (gates[id] = Completer<double>()).future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      // Before: one awaited ledger sum per tenant, in series.
      expect(started, ['a', 'b', 'c', 'd']);

      gates['d']!.complete(40);
      gates['b']!.completeError(Exception('ledger read failed'));
      gates['c']!.complete(0);
      gates['a']!.complete(125.5);

      final rows = await result;
      // One failed sum drops only that tenant; it used to abandon the rest.
      expect(rows.map((r) => r.$1), ['a', 'd']);
      expect(rows.map((r) => r.$2), [125.5, 40]);
    });
  });

  group('upcomingMoveOutUnits', () {
    test('occupied units whose notice + 30 days lands in the next week', () {
      final now = DateTime(2026, 9, 23, 12);
      final due = upcomingMoveOutUnits([
        _unit('in-window', moveOutNoticeDate: DateTime(2026, 8, 27)),
        _unit('too-late', moveOutNoticeDate: DateTime(2026, 9, 10)),
        _unit('past', moveOutNoticeDate: DateTime(2026, 8, 1)),
        _unit('no-notice'),
        _unit('vacant', status: UnitStatus.available, tenantId: null,
            moveOutNoticeDate: DateTime(2026, 8, 27)),
      ], now);
      expect(due.map((d) => d.unit.id), ['in-window']);
      expect(due.single.moveOutDate, DateTime(2026, 9, 26));
    });
  });

  group('facilityUnitCounts (what the dashboard shows per facility)', () {
    test("counts an archived tenant's unit and leaves staff-only units out", () {
      final counts = facilityUnitCounts(
        [
          _unit('active', tenantId: 'active-t'),
          _unit('archived', tenantId: 'archived-t'),
          _unit('office', tenantId: 'active-t', publicListingEnabled: false),
          _unit('orphan', tenantId: 'deleted-t'),
          _unit('free', status: UnitStatus.available, tenantId: null),
        ],
        [_tenant('active-t'), _tenant('archived-t', isActive: false)],
      );
      // Before: the dashboard counted every unit doc and only active
      // tenants' units, giving 5 total / 2 occupied here (the office in, the
      // archived tenant's unit out) against the Units list's 4 / 2.
      expect(counts.totalUnits, 4);
      expect(counts.occupiedUnits, 2);
      expect(counts.unitDocs, 5);
    });
  });

  test('staff-only units are reported, never negative', () {
    DashboardStats stats(int total, int docs) => DashboardStats(
          totalFacilities: 1,
          totalTenants: 0,
          totalUnits: total,
          occupiedUnits: 0,
          availableUnits: total,
          totalUnitDocs: docs,
          occupancyRate: 0,
          monthlyRevenue: 0,
          pastDueCount: 0,
          openLeads: 0,
        );
    expect(stats(78, 82).staffOnlyUnits, 4);
    expect(stats(3, 0).staffOnlyUnits, 0);
  });
}
