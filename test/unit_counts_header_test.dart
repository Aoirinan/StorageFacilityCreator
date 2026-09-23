import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/screens/unit_list_screen.dart';

UnitModel _unit(
  String id, {
  UnitStatus status = UnitStatus.available,
  String? tenantId,
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
    publicListingEnabled: publicListingEnabled,
  );
}

void main() {
  test('says the count is of rentable units and how many staff-only rows are not in it', () {
    // The table lists staff-only units, so a bare "1 / 2 units occupied" over
    // three rows read as a miscount.
    final header = unitCountsHeader(
      [
        _unit('1', status: UnitStatus.occupied, tenantId: 't1'),
        _unit('2'),
        _unit('office', status: UnitStatus.occupied, tenantId: 't1', publicListingEnabled: false),
      ],
      {'t1'},
    );
    expect(header, '1 / 2 rentable units occupied (1 staff-only not counted)');
  });

  test('no note when there are no staff-only units', () {
    final header = unitCountsHeader(
      [
        _unit('1', status: UnitStatus.occupied, tenantId: 'archived-tenant'),
        _unit('2', status: UnitStatus.occupied, tenantId: 'deleted-tenant'),
      ],
      {'archived-tenant'},
    );
    // Archived tenant's unit counts; the orphan does not.
    expect(header, '1 / 2 rentable units occupied');
  });

  test('a stream error after the first list keeps that list for the header and rows', () async {
    final source = StreamController<List<TenantModel>>();
    final container = ProviderContainer(
      overrides: [
        facilityTenantsProvider('fac1').overrideWith((ref) => source.stream),
      ],
      retry: (_, __) => null,
    );
    addTearDown(container.dispose);
    addTearDown(() => unawaited(source.close()));
    final sub = container.listen(facilityTenantsProvider('fac1'), (_, __) {});
    addTearDown(sub.close);

    source.add([
      TenantModel(
        id: 't1',
        facilityId: 'fac1',
        name: 'Al',
        email: '',
        phone: '',
        unitNumber: '1',
        monthlyRate: 100,
        createdAt: DateTime(2026, 1, 1),
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    source.addError(Exception('unavailable'));
    await Future<void>.delayed(Duration.zero);

    final tenantsAsync = container.read(facilityTenantsProvider('fac1'));
    // The state the screen sees: an error that still holds the last list,
    // so the header is shown.
    expect(tenantsAsync.hasError, isTrue);
    expect(tenantsAsync.hasValue, isTrue);

    final tenants = unitListTenants(tenantsAsync);
    // Before: whenOrNull(data:) gave null here, so the header read
    // "0 / 2 rentable units occupied" and the rented unit was hidden.
    expect(tenants.map((t) => t.id), ['t1']);
    expect(
      unitCountsHeader(
        [_unit('1', status: UnitStatus.occupied, tenantId: 't1'), _unit('2')],
        tenants.map((t) => t.id).toSet(),
      ),
      '1 / 2 rentable units occupied',
    );
  });
}
