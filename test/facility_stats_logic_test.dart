import 'package:flutter_test/flutter_test.dart';
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
}
