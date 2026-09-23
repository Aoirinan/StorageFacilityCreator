import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/unit_model.dart';
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
}
